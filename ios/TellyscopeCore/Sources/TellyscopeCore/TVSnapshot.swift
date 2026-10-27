// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

public struct TVNetworkInterface: Equatable, Sendable {
    public let name: String
    public let addresses: [String]
    public let rxBytes: Int64
    public let txBytes: Int64
}

public struct TVSnapshot: Equatable, Sendable {
    public let model: String?
    public let manufacturer: String?
    public let brand: String?
    public let androidVersion: String?
    public let sdk: Int?
    public let securityPatch: String?
    public let storageTotalBytes: Int64?
    public let storageUsedBytes: Int64?
    public var storageFreeBytes: Int64? {
        guard let storageTotalBytes, let storageUsedBytes else { return nil }
        return max(0, storageTotalBytes - storageUsedBytes)
    }
    public let memoryTotalBytes: Int64?
    public let memoryAvailableBytes: Int64?
    public var memoryUsedBytes: Int64? {
        guard let memoryTotalBytes, let memoryAvailableBytes else { return nil }
        return max(0, memoryTotalBytes - memoryAvailableBytes)
    }
    public let cpuPercent: Double?
    public let temperatureCelsius: Double?
    public let uptimeSeconds: Double?
    public let networkBytesPerSecond: Double?
    public let networkInterfaces: [TVNetworkInterface]?
}

public struct TVProcess: Equatable, Sendable {
    public let pid: Int
    public let user: String
    public let name: String
    public let packageName: String?
    public let rssBytes: Int64
    public let cpuPercent: Double
}

public struct TVTraffic: Equatable, Sendable {
    public let rxBytes: Int64
    public let txBytes: Int64
}

public struct TVConnection: Equatable, Sendable {
    public let uid: Int
    public let packageName: String?
    public let address: String
    public let port: Int
    public let state: String
}

public struct TVAllowedADBKey: Equatable, Sendable {
    public let fingerprint: String
    public let name: String?
    public let lastSeenMilliseconds: Int64?
}

public struct TVADBClient: Equatable, Sendable {
    public let address: String
    public let port: Int
}

public struct TVAdvancedSnapshot: Equatable, Sendable {
    public let processes: [TVProcess]?
    public let packageUIDs: [Int: [String]]?
    public let trafficByUID: [Int: TVTraffic]?
    public let connections: [TVConnection]?
    public let allowedADBKeys: [TVAllowedADBKey]?
    public let connectedADBClients: [TVADBClient]?
    public let pairedPeripherals: [String]?
}

/// Bounded, read-only telemetry. Each field remains nil when the TV does not report it.
public struct TVSnapshotReader {
    private let executor: any ShellExecutor
    private let adbPort: Int?

    public init(executor: any ShellExecutor, adbPort: Int? = nil) {
        self.executor = executor
        self.adbPort = adbPort
    }

    public func read() async throws -> TVSnapshot {
        let slow = try await executor.run([
            "getprop",
            "df -k /data",
            "cat /proc/uptime",
            "for z in /sys/class/thermal/thermal_zone*; do echo \"$(cat $z/type 2>/dev/null)=$(cat $z/temp 2>/dev/null)\"; done",
        ].joined(separator: "; echo \(Self.separator); "))
        guard slow.exitCode == 0 else { throw SafePackageError.commandFailed(slow.output) }
        let slowParts = Self.sections(slow.output, count: 4, separator: Self.separator)
        let props = Self.props(slowParts[0])
        let storage = Self.storage(slowParts[1])

        let first = try await executor.run("cat /proc/stat 2>/dev/null; echo \(Self.separator); cat /proc/meminfo 2>/dev/null; echo \(Self.separator); cat /proc/net/dev 2>/dev/null; true")
        guard first.exitCode == 0 else { throw SafePackageError.commandFailed(first.output) }
        let firstParts = Self.sections(first.output, count: 3, separator: Self.separator)
        let sampleStarted = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 500_000_000)
        let second = try await executor.run("cat /proc/stat 2>/dev/null; echo \(Self.separator); cat /proc/net/dev 2>/dev/null; echo \(Self.separator); ip -o addr show 2>/dev/null; true")
        guard second.exitCode == 0 else { throw SafePackageError.commandFailed(second.output) }
        let secondParts = Self.sections(second.output, count: 3, separator: Self.separator)
        let elapsed = ProcessInfo.processInfo.systemUptime - sampleStarted

        return TVSnapshot(
            model: props["ro.product.model"],
            manufacturer: props["ro.product.manufacturer"],
            brand: props["ro.product.brand"],
            androidVersion: props["ro.build.version.release"],
            sdk: props["ro.build.version.sdk"].flatMap(Int.init),
            securityPatch: props["ro.build.version.security_patch"],
            storageTotalBytes: storage.map { $0.total * 1024 },
            storageUsedBytes: storage.map { $0.used * 1024 },
            memoryTotalBytes: Self.meminfo(firstParts[1], key: "MemTotal"),
            memoryAvailableBytes: Self.meminfo(firstParts[1], key: "MemAvailable") ?? Self.fallbackAvailable(firstParts[1]),
            cpuPercent: Self.cpuPercent(firstParts[0], secondParts[0]),
            temperatureCelsius: Self.temperature(slowParts[3]),
            uptimeSeconds: Double(slowParts[2].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first ?? ""),
            networkBytesPerSecond: Self.rate(firstParts[2], secondParts[1], elapsed: elapsed),
            networkInterfaces: Self.interfaces(secondParts[1], addresses: secondParts[2])
        )
    }

    /// Advanced reads are independent: an unsupported shell command only hides its own section.
    public func advanced() async -> TVAdvancedSnapshot {
        let commands = [
            "top -b -n 1 -o PID,USER,RES,%CPU,NAME",
            "pm list packages -U",
            "dumpsys netstats --uid 2>/dev/null; echo \(Self.separator); cat /proc/net/xt_qtaguid/stats 2>/dev/null",
            "cat /proc/net/tcp6 /proc/net/tcp 2>/dev/null",
            "dumpsys adb",
            "getprop service.adb.tls.port",
            "dumpsys bluetooth_manager | sed -n '/Bonded devices:/,/^\\s*$/p'",
        ]
        let output = try? await executor.run(commands.map { "\($0) 2>/dev/null" }.joined(separator: "; echo \(Self.advancedSeparator); ") + "; true")
        let parts = output.flatMap { $0.exitCode == 0 ? Self.sections($0.output, count: 7, separator: Self.advancedSeparator) : nil }
        let uidMap = (parts?[1]).flatMap(Self.packageUIDs)
        let traffic = (parts?[2]).flatMap(Self.traffic)
        let sockets = (parts?[3]).flatMap { Self.connections($0, uids: uidMap ?? [:]) }
        let tlsPort = (parts?[5]).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let ports = Set([5555, adbPort, tlsPort].compactMap { $0 }.filter { $0 > 0 })
        return TVAdvancedSnapshot(
            processes: (parts?[0]).flatMap { Self.processes($0, uids: uidMap ?? [:]) },
            packageUIDs: uidMap,
            trafficByUID: traffic,
            connections: sockets,
            allowedADBKeys: (parts?[4]).flatMap(Self.allowedKeys),
            connectedADBClients: (parts?[3]).flatMap { Self.adbClients($0, ports: ports) },
            pairedPeripherals: (parts?[6]).flatMap(Self.pairedBluetooth)
        )
    }

    private static let separator = "@@tellyscope-ios@@"
    private static let advancedSeparator = "@@tellyscope-advanced@@"

    private static func sections(_ output: String, count: Int, separator: String) -> [String] {
        let parts = output.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (0..<count).map { parts.indices.contains($0) ? parts[$0] : "" }
    }

    private static func props(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.first == "[", let keyEnd = text.range(of: "]: ["), text.last == "]" else { continue }
            let key = String(text[text.index(after: text.startIndex)..<keyEnd.lowerBound])
            let valueStart = keyEnd.upperBound
            let value = String(text[valueStart..<text.index(before: text.endIndex)])
            result[key] = value.isEmpty ? nil : value
        }
        return result
    }

    private static func storage(_ output: String) -> (total: Int64, used: Int64)? {
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let values = line.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
            if values.count >= 3 { return (values[0], values[1]) }
        }
        return nil
    }

    private static func meminfo(_ output: String, key: String) -> Int64? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(key + ":") }),
              let kb = line.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    private static func fallbackAvailable(_ output: String) -> Int64? {
        guard let free = meminfo(output, key: "MemFree") else { return nil }
        return free + (meminfo(output, key: "Cached") ?? 0)
    }

    private static func cpuPercent(_ before: String, _ after: String) -> Double? {
        func counters(_ output: String) -> (busy: Int64, total: Int64)? {
            guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("cpu ") }) else { return nil }
            let v = line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Int64($0) }
            guard v.count >= 4 else { return nil }
            let total = v.prefix(8).reduce(0, +)
            return (total - v[3] - (v.count > 4 ? v[4] : 0), total)
        }
        guard let a = counters(before), let b = counters(after), b.total > a.total else { return nil }
        return min(100, max(0, Double(b.busy - a.busy) / Double(b.total - a.total) * 100))
    }

    private static func netBytes(_ output: String) -> Int64? {
        var sum: Int64 = 0
        var found = false
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo" else { continue }
            let values = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
            guard values.count >= 9 else { continue }
            sum += values[0] + values[8]
            found = true
        }
        return found ? sum : nil
    }

    private static func rate(_ before: String, _ after: String, elapsed: Double) -> Double? {
        guard let a = netBytes(before), let b = netBytes(after), b >= a else { return nil }
        return Double(b - a) / elapsed
    }

    private static func interfaces(_ counters: String, addresses: String) -> [TVNetworkInterface]? {
        var addrs: [String: [String]] = [:]
        for line in addresses.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count > 3, fields[0].hasSuffix(":"), (fields[2] == "inet" || fields[2] == "inet6") else { continue }
            let name = String(fields[1]).components(separatedBy: "@").first ?? String(fields[1])
            let address = String(fields[3].split(separator: "/").first ?? "")
            if !address.isEmpty { addrs[name, default: []].append(address) }
        }
        var found: [TVNetworkInterface] = []
        for line in counters.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo" else { continue }
            let values = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
            guard values.count >= 9 else { continue }
            found.append(TVNetworkInterface(name: name, addresses: addrs[name] ?? [], rxBytes: values[0], txBytes: values[8]))
        }
        return found.isEmpty ? nil : found
    }

    private static func temperature(_ output: String) -> Double? {
        let zones = output.split(whereSeparator: \.isNewline).compactMap { line -> (String, Double)? in
            guard let equal = line.firstIndex(of: "="), let raw = Double(line[line.index(after: equal)...]) else { return nil }
            let c = raw > 1000 ? raw / 1000 : raw
            guard (1...150).contains(c) else { return nil }
            return (String(line[..<equal]).lowercased(), c)
        }
        let cpu = zones.filter { ["cpu", "soc", "tsens", "core"].contains(where: $0.0.contains) }
        return (cpu.isEmpty ? zones : cpu).map(\.1).max()
    }

    private static func processes(_ output: String, uids: [Int: [String]]) -> [TVProcess]? {
        let known = Set(uids.values.flatMap { $0 })
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> TVProcess? in
            let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 5, let pid = Int(fields[0]), let cpu = Double(fields[3]), let rss = sizeBytes(String(fields[2])) else { return nil }
            let user = String(fields[1]), name = String(fields[4])
            let baseName = String(name.split(separator: ":").first ?? "")
            let appUid = user.range(of: #"^u(\d+)_a(\d+)$"#, options: .regularExpression).flatMap { range -> Int? in
                let groups = user[range].split(separator: "_")
                guard groups.count == 2, let user = Int(groups[0].dropFirst()), let app = Int(groups[1].dropFirst()) else { return nil }
                return user * 100_000 + 10_000 + app
            }
            let package = known.contains(baseName) ? baseName : appUid.flatMap { uid in
                uids[uid]?.first(where: { name.hasPrefix($0) }) ?? uids[uid]?.first
            }
            return TVProcess(pid: pid, user: user, name: name, packageName: package, rssBytes: rss, cpuPercent: cpu)
        }
        return rows.isEmpty ? nil : rows
    }

    private static func sizeBytes(_ value: String) -> Int64? {
        let suffix = value.last?.uppercased()
        let number = suffix.map { "KMG".contains($0) ? String(value.dropLast()) : value } ?? value
        guard let n = Double(number), n >= 0 else { return nil }
        let multiplier: Double = switch suffix {
        case "K": 1024
        case "M": 1024 * 1024
        case "G": 1024 * 1024 * 1024
        default: 1
        }
        return Int64(n * multiplier)
    }

    private static func packageUIDs(_ output: String) -> [Int: [String]]? {
        var result: [Int: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasPrefix("package:"), let range = text.range(of: #"\buid:(\d+)"#, options: .regularExpression) else { continue }
            let name = text.dropFirst("package:".count).split(whereSeparator: \.isWhitespace).first.map(String.init)
            let uid = Int(text[range].dropFirst("uid:".count))
            if let name, let uid { result[uid, default: []].append(name) }
        }
        return result.isEmpty ? nil : result
    }

    private static func traffic(_ output: String) -> [Int: TVTraffic]? {
        let sections = Self.sections(output, count: 2, separator: Self.separator)
        var result: [Int: TVTraffic] = [:]
        var inUID = false
        var uid: Int?
        for rawLine in sections[0].split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !line.isEmpty && line.first?.isWhitespace == false {
                inUID = line.trimmingCharacters(in: .whitespaces) == "UID stats:"
                uid = nil
                continue
            }
            guard inUID else { continue }
            if let range = line.range(of: #"\buid=(-?\d+)"#, options: .regularExpression) {
                uid = Int(line[range].dropFirst("uid=".count)); continue
            }
            guard let u = uid,
                  let rxRange = line.range(of: #"\brb=(\d+)"#, options: .regularExpression),
                  let rx = Int64(line[rxRange].dropFirst(3)) else { continue }
            let tx = line.range(of: #"\btb=(\d+)"#, options: .regularExpression).flatMap { Int64(line[$0].dropFirst(3)) } ?? 0
            let old = result[u] ?? TVTraffic(rxBytes: 0, txBytes: 0)
            result[u] = TVTraffic(rxBytes: old.rxBytes + rx, txBytes: old.txBytes + tx)
        }
        if result.isEmpty {
            for line in sections[1].split(whereSeparator: \.isNewline).dropFirst() {
                let f = line.split(whereSeparator: \.isWhitespace)
                guard f.count >= 8, f[2] == "0x0", let uid = Int(f[3]), let rx = Int64(f[5]), let tx = Int64(f[7]) else { continue }
                let old = result[uid] ?? TVTraffic(rxBytes: 0, txBytes: 0)
                result[uid] = TVTraffic(rxBytes: old.rxBytes + rx, txBytes: old.txBytes + tx)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func connections(_ output: String, uids: [Int: [String]]) -> [TVConnection]? {
        guard output.contains("local_address") else { return nil }
        let known = uids.values.flatMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> TVConnection? in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 8, f[0].hasSuffix(":"), let remote = endpoint(String(f[2])),
                  let state = Int(f[3], radix: 16), let uid = Int(f[7]), remote.port != 0,
                  !isLocal(remote.address), ![0x06, 0x07, 0x0A].contains(state) else { return nil }
            let package = uids[uid]?.first(where: { known.contains($0) })
            return TVConnection(uid: uid, packageName: package, address: remote.address, port: remote.port, state: tcpState(state))
        }
        return rows
    }

    private static func adbClients(_ output: String, ports: Set<Int>) -> [TVADBClient]? {
        guard output.contains("local_address") else { return nil }
        let clients: [TVADBClient] = output.split(whereSeparator: \.isNewline).compactMap { (line: Substring) -> TVADBClient? in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 4, f[0].hasSuffix(":"), f[3].uppercased() == "01",
                  let local = endpoint(String(f[1])), ports.contains(local.port),
                  let remote = endpoint(String(f[2])) else { return nil }
            return TVADBClient(address: remote.address, port: remote.port)
        }
        return clients.reduce(into: [TVADBClient]()) { rows, client in
            if !rows.contains(client) { rows.append(client) }
        }
    }

    private static func endpoint(_ text: String) -> (address: String, port: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1], radix: 16), let address = ipAddress(String(parts[0])) else { return nil }
        return (address, port)
    }

    private static func ipAddress(_ hex: String) -> String? {
        guard hex.count == 8 || hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for word in stride(from: 0, to: hex.count, by: 8) {
            let start = hex.index(hex.startIndex, offsetBy: word)
            let end = hex.index(start, offsetBy: 8)
            let chunk = String(hex[start..<end])
            let base = bytes.count
            for pair in stride(from: 0, to: 8, by: 2) {
                let a = chunk.index(chunk.startIndex, offsetBy: pair)
                let b = chunk.index(a, offsetBy: 2)
                guard let byte = UInt8(chunk[a..<b], radix: 16) else { return nil }
                bytes.append(byte)
            }
            bytes.replaceSubrange(base..<bytes.count, with: bytes[base..<bytes.count].reversed())
        }
        if bytes.count == 4 { return bytes.map { String($0) }.joined(separator: ".") }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            return bytes.suffix(4).map { String($0) }.joined(separator: ".")
        }
        let groups = stride(from: 0, to: 16, by: 2).map { String(format: "%x", UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])) }
        return groups.joined(separator: ":")
    }

    private static func isLocal(_ address: String) -> Bool {
        address == "::1" || address == "0:0:0:0:0:0:0:1" || address == "127.0.0.1" || address.hasPrefix("127.")
    }

    private static func tcpState(_ value: Int) -> String {
        [1: "Established", 2: "Connecting", 3: "Handshake", 4: "Closing", 5: "Closing", 8: "Closing" ][value] ?? "Open"
    }

    private static func allowedKeys(_ output: String) -> [TVAllowedADBKey]? {
        guard output.contains("debugging_manager") else { return nil }
        let keyPattern = #"(QAAAA[A-Za-z0-9+/]+={0,2})(?:[ \t]+([^\r\n\"]*))?"#
        let keyRegex = try! NSRegularExpression(pattern: keyPattern)
        let tagRegex = try! NSRegularExpression(pattern: #"<adbKey\b[^>]*>"#)
        let attrRegex = try! NSRegularExpression(pattern: #"([\w-]+)=\"([^\"]*)\""#)
        var seen: Set<String> = []
        var rows: [TVAllowedADBKey] = []
        func append(_ line: String, stamp: Int64?) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = keyRegex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line), let data = Data(base64Encoded: String(line[keyRange])) else { return }
            let fingerprint = Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
            guard seen.insert(fingerprint).inserted else { return }
            let name = Range(match.range(at: 2), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(TVAllowedADBKey(fingerprint: fingerprint, name: name, lastSeenMilliseconds: stamp))
        }
        var stamps: [String: Int64] = [:]
        for match in tagRegex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)) {
            guard let range = Range(match.range, in: output) else { continue }
            let tag = String(output[range])
            var attrs: [String: String] = [:]
            for attr in attrRegex.matches(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) {
                guard let kr = Range(attr.range(at: 1), in: tag), let vr = Range(attr.range(at: 2), in: tag) else { continue }
                attrs[String(tag[kr])] = String(tag[vr])
            }
            if let key = attrs["key"], let stamp = attrs["lastConnection"].flatMap(Int64.init), stamp > 0 { stamps[key] = stamp }
        }
        let lines = output.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { $0.contains("user_keys=") }) {
            var raw = lines[index].components(separatedBy: "user_keys=").dropFirst().joined(separator: "user_keys=")
            if raw.isEmpty {
                for line in lines.dropFirst(index + 1) {
                    if line.range(of: #"^\s*(?:[a-z_]+=|[{}])"#, options: .regularExpression) != nil { break }
                    raw += "\n" + line
                }
            }
            for rawLine in raw.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                if let match = keyRegex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                   let kr = Range(match.range(at: 1), in: line) {
                    let key = String(line[kr]); append(line, stamp: stamps[key])
                }
            }
        }
        for line in lines where line.contains("<adbKey") { append(line, stamp: nil) }
        return rows
    }

    private static func pairedBluetooth(_ output: String) -> [String]? {
        guard let start = output.range(of: "Bonded devices:") else { return nil }
        let tail = String(output[start.upperBound...]).components(separatedBy: .newlines).dropFirst()
        let pattern = try! NSRegularExpression(pattern: #"^\s*[0-9A-Fa-fX]{2}(?::[0-9A-Fa-fX]{2}){5}\s+\[\s*[\w/?]+\s*]\s+(.+)$"#)
        var seen: Set<String> = []
        return tail.prefix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).compactMap { text in
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let name = String(text[range]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
    }
}
