@preconcurrency import Network
import Foundation

private struct ADBMobileCommandOutput: Sendable {
    let status: Int32
    let data: Data

    var text: String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ADBMobileBridge {
    static func initialize(homeDirectory: String) throws {
        let status = homeDirectory.withCString { home in
            "15037".withCString { port in
                tvadb_adb_initialize(home, port)
            }
        }
        guard status == 0 else {
            throw ADBClientError.authenticationFailed
        }
    }

    static func execute(_ arguments: [String]) -> ADBMobileCommandOutput {
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        let result = pointers.withUnsafeMutableBufferPointer { buffer in
            tvadb_adb_execute(Int32(arguments.count), buffer.baseAddress)
        }
        defer { tvadb_adb_result_destroy(result) }
        let data: Data
        if let bytes = result.bytes, result.length > 0 {
            data = Data(bytes: bytes, count: result.length)
        } else {
            data = Data()
        }
        return ADBMobileCommandOutput(status: result.status, data: data)
    }

    static func authenticationPublicKey() throws -> Data {
        let result = tvadb_adb_auth_public_key()
        defer { tvadb_adb_result_destroy(result) }
        guard result.status == 0, let bytes = result.bytes, result.length > 0 else {
            throw ADBClientError.authenticationFailed
        }
        var data = Data(bytes: bytes, count: result.length)
        if data.last != 0 {
            data.append(0)
        }
        return data
    }
}

fileprivate final class ADBSmartSocketTransport: @unchecked Sendable {
    private final class ContinuationBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let target = continuation
            continuation = nil
            lock.unlock()
            target?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let target = continuation
            continuation = nil
            lock.unlock()
            target?.resume(throwing: error)
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "com.tvadb.aosp-smart-socket"
    )
    private let stateLock = NSLock()
    private var remoteClosed = false

    init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ADBClientError.invalidAddress
        }
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpointPort,
            using: .tcp
        )
    }

    func connect(timeout: TimeInterval = 4) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.connection.cancel()
                box.resume(throwing: ADBClientError.connectionTimedOut)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutItem.cancel()
                    box.resume(returning: ())
                case .failed(let error):
                    timeoutItem.cancel()
                    box.resume(
                        throwing: ADBClientError.connectionFailed(
                            error.localizedDescription
                        )
                    )
                case .cancelled:
                    timeoutItem.cancel()
                    box.resume(throwing: ADBClientError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )
        }
    }

    func selectTransport(serial: String) async throws {
        try await request("host:transport:\(serial)")
    }

    func openService(_ service: String) async throws {
        try await request(service)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: ADBClientError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    func receive() async throws -> Data? {
        if isRemoteClosed { return nil }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 256 * 1024
            ) { [weak self] content, _, complete, error in
                if let error {
                    continuation.resume(
                        throwing: ADBClientError.connectionFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }
                if complete {
                    self?.markRemoteClosed()
                }
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func cancel() {
        markRemoteClosed()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private var isRemoteClosed: Bool {
        stateLock.lock()
        let value = remoteClosed
        stateLock.unlock()
        return value
    }

    private func markRemoteClosed() {
        stateLock.lock()
        remoteClosed = true
        stateLock.unlock()
    }

    private func request(_ value: String) async throws {
        let payload = Data(value.utf8)
        guard payload.count <= 0xFFFF else {
            throw ADBClientError.protocolViolation(
                L10n.string("text.the_packet_is_too_large")
            )
        }
        let header = String(
            format: "%04X",
            payload.count
        )
        try await send(Data((header + value).utf8))

        let status = String(
            decoding: try await receiveExactly(4),
            as: UTF8.self
        )
        switch status {
        case "OKAY":
            return
        case "FAIL":
            let lengthText = String(
                decoding: try await receiveExactly(4),
                as: UTF8.self
            )
            let length = Int(lengthText, radix: 16) ?? 0
            let message = length > 0
                ? String(
                    decoding: try await receiveExactly(length),
                    as: UTF8.self
                )
                : value
            throw ADBClientError.remoteFailure(message)
        default:
            throw ADBClientError.protocolViolation(
                L10n.format(
                    "text.received_value_while_reading_the_stream",
                    status
                )
            )
        }
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        guard length >= 0 else {
            throw ADBClientError.protocolViolation(
                L10n.string("text.received_an_empty_tcp_packet")
            )
        }
        var result = Data(capacity: length)
        while result.count < length {
            let remaining = length - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { content, _, complete, error in
                    if let error {
                        continuation.resume(
                            throwing: ADBClientError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if complete {
                        continuation.resume(
                            throwing: ADBClientError.connectionClosed
                        )
                    } else {
                        continuation.resume(
                            throwing: ADBClientError.protocolViolation(
                                L10n.string(
                                    "text.received_an_empty_tcp_packet"
                                )
                            )
                        )
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

/// Owns one long-lived ADB service stream. The preferred backend is the
/// embedded AOSP server's smart socket, so auxiliary streams share the
/// server's already-authenticated classic or TLS transport. A direct classic
/// connection remains available for older devices and server failures.
actor ADBPersistentShellSession {
    private enum Backend {
        case direct(
            client: ADBClient,
            stream: ADBClient.StreamHandle
        )
        case smart(ADBSmartSocketTransport)
    }

    private var backend: Backend?

    init(client: ADBClient, stream: ADBClient.StreamHandle) {
        backend = .direct(client: client, stream: stream)
    }

    fileprivate init(smartTransport: ADBSmartSocketTransport) {
        backend = .smart(smartTransport)
    }

    func write(_ data: Data) async throws {
        guard let backend else {
            throw ADBClientError.connectionClosed
        }
        switch backend {
        case .direct(let client, let stream):
            try await client.write(data, to: stream)
        case .smart(let transport):
            try await transport.send(data)
        }
    }

    func read() async throws -> Data? {
        guard let backend else {
            throw ADBClientError.connectionClosed
        }
        switch backend {
        case .direct(let client, let stream):
            return try await client.read(from: stream)
        case .smart(let transport):
            return try await transport.receive()
        }
    }

    func close() async {
        guard let backend else { return }
        self.backend = nil
        switch backend {
        case .direct(let client, let stream):
            try? await client.close(stream)
            await client.disconnect()
        case .smart(let transport):
            transport.cancel()
        }
    }
}

/// Serializes access to the embedded AOSP ADB server. This implementation
/// supports both classic RSA/TCP transports and Android 11+ SPAKE2/TLS.
actor ADBMobileClient {
    private static let embeddedServerPort: UInt16 = 15_037
    private var serial: String?
    private var connectedHost: String?
    private var connectedPort: UInt16?
    private(set) var banner = ""
    private var isInitialized = false
    private var authorizationKeyStore: ADBKeyStore?
    private var authorizationPublicKey: Data?
    private var connectionAttemptID: UUID?
    private var connectingEndpoint: String?
    private var authorizationClient: ADBClient?

    func pair(host: String, port: UInt16, code: String) async throws -> String {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == 6, normalizedCode.allSatisfy(\.isNumber) else {
            throw ADBClientError.remoteFailure(L10n.string("text.enter_the_six_digit_pairing_code_shown_on_the_tv"))
        }
        try initializeIfNeeded()
        let endpoint = Self.endpoint(host: host, port: port)
        let result = await execute(["pair", endpoint, normalizedCode])
        guard result.status == 0 else {
            let reason = result.text.isEmpty
                ? L10n.string("text.check_the_pairing_port_and_code_and_keep_the_tv_pairin_b8522852")
                : result.text
            throw ADBClientError.remoteFailure(L10n.format("text.wireless_pairing_failed_value", reason))
        }
        return result.text.isEmpty ? L10n.string("text.wireless_pairing_succeeded") : result.text
    }

    func connect(
        attemptID: UUID,
        host: String,
        port: UInt16,
        authorizationRequested: @escaping @Sendable () async -> Void = {}
    ) async throws {
        try initializeIfNeeded()
        let endpoint = Self.endpoint(host: host, port: port)
        connectedHost = nil
        connectedPort = nil
        connectionAttemptID = attemptID
        connectingEndpoint = endpoint
        defer {
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
                connectingEndpoint = nil
                authorizationClient = nil
            }
        }
        let authorizationDeadline = Date().addingTimeInterval(60)
        guard let authorizationKeyStore, let authorizationPublicKey else {
            throw ADBClientError.authenticationFailed
        }

        // A direct classic-ADB handshake makes the RSA authorization prompt
        // appear immediately. It is an authorization accelerator, not the
        // authoritative transport: vendor-specific handshakes must still fall
        // back to the embedded AOSP client that performs all real operations.
        let authorizationClient = ADBClient()
        self.authorizationClient = authorizationClient
        do {
            try await authorizationClient.connect(
                host: host,
                port: port,
                timeout: max(1, authorizationDeadline.timeIntervalSinceNow),
                keyStore: authorizationKeyStore,
                publicKey: authorizationPublicKey,
                authorizationRequested: authorizationRequested
            )
            await authorizationClient.disconnect()
            try ensureConnectionAttemptIsActive(attemptID)
        } catch ADBClientError.wirelessPairingRequired {
            await authorizationClient.disconnect()
            try ensureConnectionAttemptIsActive(attemptID)
        } catch is CancellationError {
            await authorizationClient.disconnect()
            throw CancellationError()
        } catch {
            await authorizationClient.disconnect()
            try ensureConnectionAttemptIsActive(attemptID)
            UserFacingFailure.log(.connectAuthorization, underlying: error)
            guard Date() < authorizationDeadline else {
                throw ADBClientError.connectionTimedOut
            }
        }
        if connectionAttemptID == attemptID {
            self.authorizationClient = nil
        }

        let connected = await execute(["connect", endpoint])
        try ensureConnectionAttemptIsActive(attemptID)
        let authorizationPending = Self.indicatesPendingAuthorization(connected.text)
        guard connected.status == 0 || authorizationPending else {
            let reason = connected.text.isEmpty ? L10n.string("text.android_did_not_accept_the_connection") : connected.text
            throw ADBClientError.connectionFailed(reason)
        }
        if authorizationPending {
            await authorizationRequested()
        }
        serial = endpoint

        var lastReason = connected.text
        while Date() < authorizationDeadline {
            try ensureConnectionAttemptIsActive(attemptID)
            let state = await execute(["-s", endpoint, "get-state"])
            try ensureConnectionAttemptIsActive(attemptID)
            if state.status == 0, state.text == "device" {
                let model = try? await shell("getprop ro.product.model")
                let product = try? await shell("getprop ro.product.name")
                let name = [model, product]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                banner = "device::model:\((name ?? "Android_Device").replacingOccurrences(of: " ", with: "_"));"
                connectedHost = host
                connectedPort = port
                return
            }
            if !state.text.isEmpty {
                lastReason = state.text
                if Self.indicatesPendingAuthorization(state.text) {
                    await authorizationRequested()
                }
            }
            if Date() < authorizationDeadline {
                try await Task.sleep(for: .milliseconds(350))
            }
        }

        serial = nil
        connectedHost = nil
        connectedPort = nil
        if Self.indicatesPendingAuthorization(lastReason) {
            throw ADBClientError.connectionTimedOut
        }
        throw ADBClientError.connectionFailed(
            lastReason.isEmpty ? L10n.string("text.the_device_is_not_ready_confirm_wireless_debugging_authorization") : lastReason
        )
    }

    func cancelConnectionAttempt(attemptID: UUID) async {
        guard connectionAttemptID == attemptID else { return }
        connectionAttemptID = nil
        let endpoint = connectingEndpoint
        connectingEndpoint = nil
        let authorizationClient = authorizationClient
        self.authorizationClient = nil
        await authorizationClient?.disconnect()
        if let endpoint {
            _ = await execute(["disconnect", endpoint])
        }
        if serial == endpoint {
            serial = nil
            banner = ""
            connectedHost = nil
            connectedPort = nil
        }
    }

    func disconnect() async {
        connectionAttemptID = nil
        connectingEndpoint = nil
        let authorizationClient = authorizationClient
        self.authorizationClient = nil
        await authorizationClient?.disconnect()
        if let serial {
            _ = await execute(["disconnect", serial])
        }
        self.serial = nil
        connectedHost = nil
        connectedPort = nil
        banner = ""
    }

    func shell(_ command: String) async throws -> String {
        let result = try await runForCurrentDevice(["shell", command])
        return result.text
    }

    func checkedShell(_ command: String, host: String, port: UInt16) async throws -> (output: String, exitCode: Int) {
        guard let serial, serial == Self.endpoint(host: host, port: port) else {
            throw ADBClientError.connectionClosed
        }
        try Task.checkCancellation()
        let result = await execute(["-s", serial, "shell", command])
        return (result.text, Int(result.status))
    }

    func exec(_ command: String) async throws -> Data {
        try await runForCurrentDevice(["exec-out", command]).data
    }

    /// Opens an additional service through the embedded AOSP server. This
    /// preserves Android 11+ TLS because the smart socket selects the server's
    /// existing transport instead of starting an unencrypted direct handshake.
    func openPersistentShell(
        _ command: String
    ) async throws -> ADBPersistentShellSession {
        try await openPersistentService("shell:\(command)")
    }

    func openPersistentExec(
        _ command: String
    ) async throws -> ADBPersistentShellSession {
        try await openPersistentService("exec:\(command)")
    }

    private func openPersistentService(
        _ service: String
    ) async throws -> ADBPersistentShellSession {
        guard let serial,
              let connectedHost,
              let connectedPort,
              let authorizationKeyStore,
              let authorizationPublicKey else {
            throw ADBClientError.notConnected
        }

        let smartTransport = try ADBSmartSocketTransport(
            port: Self.embeddedServerPort
        )
        do {
            try await smartTransport.connect()
            try await smartTransport.selectTransport(serial: serial)
            try await smartTransport.openService(service)
            return ADBPersistentShellSession(
                smartTransport: smartTransport
            )
        } catch {
            smartTransport.cancel()
        }

        // Classic ADB devices can still use an independent direct connection
        // if the embedded server's smart socket is temporarily unavailable.
        let streamClient = ADBClient()
        do {
            try await streamClient.connect(
                host: connectedHost,
                port: connectedPort,
                timeout: 4,
                keyStore: authorizationKeyStore,
                publicKey: authorizationPublicKey,
                authorizationRequested: {}
            )
            let stream = try await streamClient.openService(service)
            return ADBPersistentShellSession(
                client: streamClient,
                stream: stream
            )
        } catch {
            await streamClient.disconnect()
            throw error
        }
    }

    func push(localURL: URL, remotePath: String) async throws -> String {
        try await runForCurrentDevice(["push", localURL.path, remotePath]).text
    }

    func pull(remotePath: String, localURL: URL) async throws -> String {
        try await runForCurrentDevice(["pull", remotePath, localURL.path]).text
    }

    func list(remotePath: String) async throws -> String {
        try await runForCurrentDevice(["ls", remotePath]).text
    }

    func reboot(target: String = "") async throws {
        var arguments = ["reboot"]
        if !target.isEmpty { arguments.append(target) }
        _ = try await runForCurrentDevice(arguments)
    }

    private func initializeIfNeeded() throws {
        guard !isInitialized else { return }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("EmbeddedADB", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".android", isDirectory: true),
            withIntermediateDirectories: true
        )
        let keyStore = try ADBKeyStore()
        let privateKeyURL = root
            .appendingPathComponent(".android", isDirectory: true)
            .appendingPathComponent("adbkey")
        try keyStore.synchronizeADBPrivateKey(at: privateKeyURL)
        try ADBMobileBridge.initialize(homeDirectory: root.path)
        let publicKey = try ADBMobileBridge.authenticationPublicKey()
        try Self.writeCanonicalPublicKey(publicKey, privateKeyURL: privateKeyURL)
        authorizationKeyStore = keyStore
        authorizationPublicKey = publicKey
        isInitialized = true
    }

    private func runForCurrentDevice(_ arguments: [String]) async throws -> ADBMobileCommandOutput {
        guard let serial else { throw ADBClientError.notConnected }
        let result = await execute(["-s", serial] + arguments)
        guard result.status == 0 else {
            let message = result.text.isEmpty
                ? L10n.format("text.the_adb_command_failed_status_value", result.status)
                : result.text
            throw ADBClientError.remoteFailure(message)
        }
        return result
    }

    private func execute(_ arguments: [String]) async -> ADBMobileCommandOutput {
        // Keep this call inside the actor without an `await` suspension. The
        // embedded AOSP command entry point owns process-global state and is
        // not safe to invoke concurrently. The previous detached task made
        // this actor re-entrant and allowed several large pulls/exec-outs to
        // contend with interactive Shell commands.
        ADBMobileBridge.execute(arguments)
    }

    private static func endpoint(host: String, port: UInt16) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":"), !trimmed.hasPrefix("[") {
            return "[\(trimmed)]:\(port)"
        }
        return "\(trimmed):\(port)"
    }

    private static func writeCanonicalPublicKey(
        _ publicKey: Data,
        privateKeyURL: URL
    ) throws {
        var line = publicKey
        if line.last == 0 {
            line.removeLast()
        }
        line.append(contentsOf: Data("\n".utf8))
        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        if (try? Data(contentsOf: publicKeyURL)) != line {
            try line.write(to: publicKeyURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: publicKeyURL.path
        )
    }

    private static func indicatesPendingAuthorization(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("unauthorized")
            || normalized.contains("authenticate")
            || normalized.contains("authorization")
    }

    private func ensureConnectionAttemptIsActive(_ attemptID: UUID) throws {
        guard connectionAttemptID == attemptID, !Task.isCancelled else {
            throw CancellationError()
        }
    }
}
