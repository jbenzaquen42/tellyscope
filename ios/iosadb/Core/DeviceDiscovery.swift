@preconcurrency import Foundation
@preconcurrency import Network
import Combine
import Darwin

private struct LegacyADBProbeResult: Sendable {
    let host: String
    let serviceName: String?
}

private struct IPv4ScanRange: Sendable, Hashable {
    let network: UInt32
    let prefix: Int
    let excludedAddresses: Set<UInt32>

    var displayName: String {
        "\(DeviceDiscovery.ipv4String(network))/\(prefix)"
    }

    var hosts: [String] {
        let mask = prefix == 32
            ? UInt32.max
            : UInt32.max << UInt32(32 - prefix)
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast)
            .filter { !excludedAddresses.contains($0) }
            .map(DeviceDiscovery.ipv4String)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.network == rhs.network && lhs.prefix == rhs.prefix
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(network)
        hasher.combine(prefix)
    }
}

private let legacyADBDefaultPort: UInt16 = 5555
private let legacyADBProbeTimeout: TimeInterval = 1.2

private final class LegacyADBProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var completion: ((LegacyADBProbeResult?) -> Void)?
    private var isFinished = false

    init?(host: String, port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        queue = DispatchQueue(label: "com.tvadb.discovery.\(host)")
    }

    func run(host: String, timeout: TimeInterval) async -> LegacyADBProbeResult? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(host: host, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            self.finish(nil)
        }
    }

    private func start(
        host: String,
        timeout: TimeInterval,
        completion: @escaping (LegacyADBProbeResult?) -> Void
    ) {
        lock.lock()
        if isFinished {
            lock.unlock()
            completion(nil)
            return
        }
        self.completion = completion
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake(host: host)
            case .failed, .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    private func sendHandshake(host: String) {
        let identity = Data("host::features=shell_v2,cmd,stat_v2,ls_v2\0".utf8)
        let packet = ADBPacket(
            command: .connect,
            argument0: 0x0100_0001,
            argument1: 1024 * 1024,
            payload: identity
        )
        connection.send(content: packet.encoded, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.finish(nil)
                return
            }
            self.receiveExactly(ADBPacket.headerSize) { header in
                guard let header,
                      let payloadLength = try? header.uint32LE(at: 12),
                      payloadLength <= 64 * 1024 else {
                    self.finish(nil)
                    return
                }
                self.receiveExactly(Int(payloadLength)) { payload in
                    guard let payload,
                          let response = try? ADBPacket.decode(header: header, payload: payload),
                          [.connect, .auth, .startTLS].contains(response.command) else {
                        self.finish(nil)
                        return
                    }
                    let name = response.command == .connect
                        ? Self.deviceName(from: response.payload)
                        : nil
                    self.finish(LegacyADBProbeResult(host: host, serviceName: name))
                }
            }
        })
    }

    private func receiveExactly(
        _ length: Int,
        buffer: Data = Data(),
        completion: @escaping (Data?) -> Void
    ) {
        guard length > buffer.count else {
            completion(buffer)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: length - buffer.count
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && (content?.isEmpty ?? true)) {
                completion(nil)
                return
            }
            var accumulated = buffer
            if let content { accumulated.append(content) }
            guard !accumulated.isEmpty else {
                completion(nil)
                return
            }
            self.receiveExactly(length, buffer: accumulated, completion: completion)
        }
    }

    private func finish(_ result: LegacyADBProbeResult?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let target = completion
        completion = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        target?(result)
    }

    private static func deviceName(from payload: Data) -> String? {
        let banner = String(decoding: payload.drop(while: { $0 == 0 }).prefix { $0 != 0 }, as: UTF8.self)
        guard let properties = banner.components(separatedBy: "::").last else { return nil }
        var values: [String: String] = [:]
        for item in properties.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0]] = pair[1]
        }
        return values["ro.product.model"] ?? values["ro.product.name"] ?? values["ro.product.device"]
    }
}

@MainActor
final class DeviceDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusText = ""
    @Published private(set) var scanProgress: Double?
    @Published private(set) var discoveryError: String?

    private static let serviceTypes = ["_adb._tcp.", "_adb-tls-pairing._tcp.", "_adb-tls-connect._tcp."]
    private static let maximumConcurrentProbes = 32
    private static let minimumBonjourScanDuration: TimeInterval = 5

    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    func start(additionalHosts: [String] = []) {
        cancelCurrentScan()
        devices = []
        discoveryError = nil
        scanProgress = nil
        statusText = L10n.string("text.scanning")
        isScanning = true
        scanID = UUID()
        let currentScanID = scanID
        let startedAt = Date()

        for type in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanLegacyADBDevices(
                additionalHosts: additionalHosts
            )
            guard !Task.isCancelled else { return }

            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = max(0, Self.minimumBonjourScanDuration - elapsed)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self.finishScan(id: currentScanID)
        }
    }

    func stop() {
        let wasScanning = isScanning
        cancelCurrentScan()
        if wasScanning {
            statusText = devices.isEmpty
                ? L10n.string("text.no_devices_found")
                : String(format: L10n.string("text.found_value_devices"), devices.count)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        discoveryError = UserFacingFailure.text(.deviceScan)
#if DEBUG
        print("[TVADB][error.device_scan] Bonjour error \(Self.errorCode(from: errorDict))")
#endif
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 === sender } }
        guard sender.port > 0, sender.port <= Int(UInt16.max) else { return }
        let resolvedAddresses = sender.addresses?.compactMap(Self.ipAddress) ?? []
        // Prefer IPv4 for TV LANs. Link-local IPv6 addresses require an
        // interface scope that NetService's raw sockaddr does not expose in
        // our editable host field.
        let host = resolvedAddresses.first(where: { !$0.contains(":") })
            ?? resolvedAddresses.first
            ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            ?? ""
        guard !host.isEmpty else { return }

        var device = devices.first(where: { $0.id == host })
            ?? DiscoveredDevice(serviceName: sender.name, host: host)
        let port = UInt16(sender.port)
        if sender.type.contains("adb-tls-pairing") {
            device.pairingPort = port
        } else if sender.type.contains("adb-tls-connect") {
            device.connectPort = port
        } else {
            device.legacyPort = port
        }
        merge(device)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
        if devices.isEmpty {
            discoveryError = UserFacingFailure.text(.resolveDeviceAddress)
#if DEBUG
            print("[TVADB][error.resolve_device_address] Bonjour error \(Self.errorCode(from: errorDict))")
#endif
        }
    }

    private func scanLegacyADBDevices(
        additionalHosts: [String]
    ) async {
        let subnets = Self.ipv4ScanRanges(
            additionalHosts: additionalHosts
        )
        guard !subnets.isEmpty else {
            statusText = L10n.string("text.scanning")
            discoveryError = UserFacingFailure.text(.wifiUnavailable)
            return
        }

        let totalHostCount = subnets.reduce(0) {
            $0 + $1.hosts.count
        }
        guard totalHostCount > 0 else { return }
        var totalCompletedCount = 0
        scanProgress = 0

        for subnet in subnets {
            guard !Task.isCancelled else { return }
            let hosts = subnet.hosts
            guard !hosts.isEmpty else { continue }
            statusText = String(
                format: L10n.string("text.scanning_value"),
                subnet.displayName
            )
            var nextHostIndex = 0

            await withTaskGroup(
                of: LegacyADBProbeResult?.self
            ) { group in
                let initialCount = min(
                    Self.maximumConcurrentProbes,
                    hosts.count
                )
                for _ in 0..<initialCount {
                    let host = hosts[nextHostIndex]
                    nextHostIndex += 1
                    group.addTask {
                        await Self.probeLegacyADB(host: host)
                    }
                }

                while let result = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    totalCompletedCount += 1
                    if let result {
                        mergeLegacyProbe(result)
                    }
                    scanProgress = Double(totalCompletedCount)
                        / Double(totalHostCount)

                    if nextHostIndex < hosts.count {
                        let host = hosts[nextHostIndex]
                        nextHostIndex += 1
                        group.addTask {
                            await Self.probeLegacyADB(host: host)
                        }
                    }
                }
            }
        }
    }

    private func mergeLegacyProbe(_ result: LegacyADBProbeResult) {
        let existing = devices.first(where: { $0.id == result.host })
        let fallbackName = L10n.format(
            "text.adb_device_value",
            String(result.host.split(separator: ".").last ?? "")
        )
        let name = result.serviceName ?? existing?.serviceName ?? fallbackName
        var device = existing ?? DiscoveredDevice(serviceName: name, host: result.host)
        if let discoveredName = result.serviceName, !discoveredName.isEmpty {
            device.serviceName = discoveredName
        }
        device.legacyPort = legacyADBDefaultPort
        merge(device)
    }

    private func merge(_ device: DiscoveredDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }
    }

    private func finishScan(id: UUID) {
        guard scanID == id else { return }
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        scanTask = nil
        scanProgress = nil
        isScanning = false
        if devices.isEmpty {
            statusText = L10n.string("text.no_devices_found")
        } else {
            statusText = String(
                format: L10n.string("text.found_value_devices"),
                devices.count
            )
        }
    }

    private func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        scanProgress = nil
        isScanning = false
    }

    nonisolated private static func probeLegacyADB(host: String) async -> LegacyADBProbeResult? {
        guard let probe = LegacyADBProbe(host: host, port: legacyADBDefaultPort) else { return nil }
        return await probe.run(host: host, timeout: legacyADBProbeTimeout)
    }

    nonisolated private static func ipv4ScanRanges(
        additionalHosts: [String]
    ) -> [IPv4ScanRange] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0,
              let firstInterface = interfacePointer else {
            return []
        }
        defer { freeifaddrs(interfacePointer) }

        var candidates: [(
            priority: Int,
            address: UInt32,
            mask: UInt32
        )] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  let maskPointer = interface.ifa_netmask,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            let address = Self.hostOrderIPv4(addressPointer)
            let mask = Self.hostOrderIPv4(maskPointer)
            let firstOctet = UInt8((address >> 24) & 0xff)
            guard firstOctet != 0, firstOctet != 127, !(firstOctet == 169 && UInt8((address >> 16) & 0xff) == 254) else { continue }

            let priority = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            candidates.append((priority, address, mask))
        }

        var ranges: [IPv4ScanRange] = []
        for candidate in candidates.sorted(
            by: { $0.priority < $1.priority }
        ) {
            let originalPrefix = candidate.mask.nonzeroBitCount
            guard originalPrefix >= 8 else { continue }
            // Cap broad enterprise/VPN routes to one /24 per interface.
            let prefix = max(originalPrefix, 24)
            let mask = UInt32.max << UInt32(32 - prefix)
            let range = IPv4ScanRange(
                network: candidate.address & mask,
                prefix: prefix,
                excludedAddresses: [candidate.address]
            )
            Self.merge(range, into: &ranges)
        }

        for host in additionalHosts {
            guard let address = Self.parseIPv4(host) else { continue }
            let range = IPv4ScanRange(
                network: address & 0xFFFF_FF00,
                prefix: 24,
                excludedAddresses: []
            )
            Self.merge(range, into: &ranges)
        }

        // The two most common consumer-TV subnets are useful when the iPhone
        // sits on a routed company/guest subnet while the TV remains behind a
        // home-style gateway. Keep the overall scan bounded to four /24s.
        if let primary = candidates
            .sorted(by: { $0.priority < $1.priority })
            .first,
           Self.isPrivateIPv4(primary.address) {
            for address in [UInt32(0xC0A8_0000), 0xC0A8_0100] {
                Self.merge(
                    IPv4ScanRange(
                        network: address,
                        prefix: 24,
                        excludedAddresses: []
                    ),
                    into: &ranges
                )
            }
        }
        return Array(ranges.prefix(4))
    }

    nonisolated private static func merge(
        _ range: IPv4ScanRange,
        into ranges: inout [IPv4ScanRange]
    ) {
        if let index = ranges.firstIndex(of: range) {
            let exclusions = ranges[index].excludedAddresses
                .union(range.excludedAddresses)
            ranges[index] = IPv4ScanRange(
                network: range.network,
                prefix: range.prefix,
                excludedAddresses: exclusions
            )
        } else {
            ranges.append(range)
        }
    }

    nonisolated private static func parseIPv4(
        _ value: String
    ) -> UInt32? {
        let octets = value
            .split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let value = UInt8(octet) else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    nonisolated private static func isPrivateIPv4(
        _ address: UInt32
    ) -> Bool {
        (address & 0xFF00_0000) == 0x0A00_0000
            || (address & 0xFFF0_0000) == 0xAC10_0000
            || (address & 0xFFFF_0000) == 0xC0A8_0000
    }

    nonisolated private static func hostOrderIPv4(_ pointer: UnsafePointer<sockaddr>) -> UInt32 {
        let value = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
        return UInt32(bigEndian: value)
    }

    nonisolated fileprivate static func ipv4String(
        _ address: UInt32
    ) -> String {
        [24, 16, 8, 0]
            .map { String((address >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }

    nonisolated private static func errorCode(from dictionary: [String: NSNumber]) -> Int {
        dictionary[NetService.errorCode]?.intValue ?? -1
    }

    nonisolated private static func ipAddress(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if family == sa_family_t(AF_INET), data.count >= MemoryLayout<sockaddr_in>.size {
                var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                guard inet_ntop(AF_INET, &address, &output, socklen_t(output.count)) != nil else { return nil }
                return String(cString: output)
            }
            if family == sa_family_t(AF_INET6), data.count >= MemoryLayout<sockaddr_in6>.size {
                var address = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                guard inet_ntop(AF_INET6, &address, &output, socklen_t(output.count)) != nil else { return nil }
                return String(cString: output)
            }
            return nil
        }
    }
}
