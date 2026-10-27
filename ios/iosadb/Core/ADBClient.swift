@preconcurrency import Network
import Foundation

enum ADBClientError: LocalizedError, Sendable {
    case invalidAddress
    case notConnected
    case connectionFailed(String)
    case connectionClosed
    case connectionTimedOut
    case authenticationFailed
    case authorizationRejected
    case wirelessPairingRequired
    case protocolViolation(String)
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: L10n.string("text.the_ip_address_or_port_is_invalid")
        case .notConnected: L10n.string("text.no_android_device_is_connected")
        case .connectionFailed(let message): L10n.format("text.connection_failed_value", message)
        case .connectionClosed: L10n.string("text.the_android_device_disconnected")
        case .connectionTimedOut: L10n.string("error.connect_device.timeout")
        case .authenticationFailed: L10n.string("text.unable_to_generate_or_use_the_adb_identity_key")
        case .authorizationRejected: L10n.string("text.the_android_device_has_not_authorized_this_iphone_conf_7185573d")
        case .wirelessPairingRequired:
            L10n.string("text.this_port_requires_android_11_wireless_debugging_pairi_8abda5e7")
        case .protocolViolation(let message): L10n.format("text.adb_protocol_error_value", message)
        case .remoteFailure(let message): message
        }
    }
}

private final class OneShotContinuation<T>: @unchecked Sendable {
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

private final class ADBTCPTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.tvadb.transport")
    private let timeoutLock = NSLock()
    private var timeoutWorkItem: DispatchWorkItem?
    private var didTimeOut = false

    init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ADBClientError.invalidAddress
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let oneShot = OneShotContinuation(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    oneShot.resume(returning: ())
                case .failed(let error):
                    oneShot.resume(
                        throwing: self?.connectionError(fallback: error)
                            ?? ADBClientError.connectionFailed(error.localizedDescription)
                    )
                case .cancelled:
                    oneShot.resume(
                        throwing: self?.connectionError()
                            ?? ADBClientError.connectionClosed
                    )
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ADBClientError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        guard length >= 0 else { throw ADBEncodingError.valueOutOfRange }
        if length == 0 { return Data() }
        var result = Data(capacity: length)
        while result.count < length {
            let remaining = length - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
                    [weak self] content, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: self?.connectionError(fallback: error)
                                ?? ADBClientError.connectionFailed(error.localizedDescription)
                        )
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(
                            throwing: self?.connectionError()
                                ?? ADBClientError.connectionClosed
                        )
                    } else {
                        continuation.resume(
                            throwing: ADBClientError.protocolViolation(L10n.string("text.received_an_empty_tcp_packet"))
                        )
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    func cancel() {
        cancelTimeout()
        connection.cancel()
    }

    func startTimeout(after interval: TimeInterval) {
        guard interval > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timeoutLock.lock()
            self.didTimeOut = true
            self.timeoutWorkItem = nil
            self.timeoutLock.unlock()
            self.connection.cancel()
        }
        timeoutLock.lock()
        timeoutWorkItem?.cancel()
        didTimeOut = false
        timeoutWorkItem = workItem
        timeoutLock.unlock()
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    func cancelTimeout() {
        timeoutLock.lock()
        let workItem = timeoutWorkItem
        timeoutWorkItem = nil
        timeoutLock.unlock()
        workItem?.cancel()
    }

    private func connectionError(fallback: Error? = nil) -> ADBClientError {
        timeoutLock.lock()
        let timedOut = didTimeOut
        timeoutLock.unlock()
        if timedOut {
            return .connectionTimedOut
        }
        if let fallback {
            return .connectionFailed(fallback.localizedDescription)
        }
        return .connectionClosed
    }
}

actor ADBClient {
    struct StreamHandle: Sendable {
        let localID: UInt32
        let remoteID: UInt32
    }

    private var transport: ADBTCPTransport?
    private var nextLocalID: UInt32 = 1
    private var negotiatedMaxPayload = 256 * 1024
    private(set) var banner = ""

    func connect(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 60,
        keyStore: ADBKeyStore,
        publicKey: Data,
        authorizationRequested: @escaping @Sendable () async -> Void
    ) async throws {
        disconnect()
        let newTransport = try ADBTCPTransport(host: host, port: port)
        transport = newTransport
        let authorizationDeadline = Date().addingTimeInterval(timeout)
        // This direct connection is only an authorization accelerator. Some
        // vendor adbd builds accept TCP but never answer the first AUTH
        // exchange. Do not let that consume the entire user-facing
        // authorization window before the embedded AOSP client can retry.
        newTransport.startTimeout(after: min(timeout, 5))
        defer { newTransport.cancelTimeout() }

        do {
            try await newTransport.connect()
            let identity = Data("host::features=shell_v2,cmd,stat_v2,ls_v2\0".utf8)
            try await send(ADBPacket(
                command: .connect,
                argument0: 0x0100_0001,
                argument1: 1024 * 1024,
                payload: identity
            ))

            var sentSignature = false
            var sentPublicKey = false

            while true {
                let packet = try await receivePacket()
                switch packet.command {
                case .connect:
                    negotiatedMaxPayload = max(4096, min(Int(packet.argument1), 1024 * 1024))
                    banner = String(data: packet.payload.dropLast(packet.payload.last == 0 ? 1 : 0), encoding: .utf8) ?? "Android"
                    return

                case .auth where packet.argument0 == 1:
                    if !sentSignature {
                        let signature = try keyStore.sign(token: packet.payload)
                        try await send(ADBPacket(command: .auth, argument0: 2, payload: signature))
                        sentSignature = true
                    } else {
                        if !sentPublicKey {
                            await authorizationRequested()
                            sentPublicKey = true
                        }
                        // Once the public key has been sent, the connection is
                        // legitimately waiting for the person at the TV. Give
                        // that confirmation dialog the rest of the original
                        // 60-second window instead of the five-second
                        // pre-authorization handshake limit.
                        newTransport.startTimeout(
                            after: max(
                                1,
                                authorizationDeadline.timeIntervalSinceNow
                            )
                        )
                        try await send(ADBPacket(command: .auth, argument0: 3, payload: publicKey))
                    }

                case .startTLS:
                    throw ADBClientError.wirelessPairingRequired

                case .close:
                    throw sentPublicKey ? ADBClientError.authorizationRejected : ADBClientError.connectionClosed

                default:
                    throw ADBClientError.protocolViolation(
                        L10n.format("text.received_unexpected_command_value_during_the_handshake", String(describing: packet.command))
                    )
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        transport?.cancel()
        transport = nil
        banner = ""
        nextLocalID = 1
    }

    func shell(_ command: String) async throws -> String {
        let output = try await shellData(command)
        return String(decoding: output, as: UTF8.self)
    }

    func shellData(_ command: String) async throws -> Data {
        let stream = try await openService("shell:\(command)")
        return try await readUntilClose(stream)
    }

    func exec(_ command: String) async throws -> Data {
        let stream = try await openService("exec:\(command)")
        return try await readUntilClose(stream)
    }

    func openService(_ service: String) async throws -> StreamHandle {
        guard transport != nil else { throw ADBClientError.notConnected }
        let localID = nextLocalID
        nextLocalID &+= 1
        try await send(ADBPacket(
            command: .open,
            argument0: localID,
            payload: Data((service + "\0").utf8)
        ))

        while true {
            let packet = try await receivePacket()
            switch packet.command {
            case .okay where packet.argument1 == localID:
                return StreamHandle(localID: localID, remoteID: packet.argument0)
            case .close where packet.argument1 == localID:
                try? await send(ADBPacket(command: .close, argument0: localID, argument1: packet.argument0))
                throw ADBClientError.remoteFailure(L10n.format("text.android_refused_to_open_the_service_value", service))
            default:
                throw ADBClientError.protocolViolation(L10n.string("text.received_unexpected_data_while_waiting_for_the_open_response"))
            }
        }
    }

    func write(_ data: Data, to stream: StreamHandle) async throws {
        var offset = 0
        repeat {
            let end = min(data.count, offset + negotiatedMaxPayload)
            let chunk = data.subdata(in: offset..<end)
            try await send(ADBPacket(
                command: .write,
                argument0: stream.localID,
                argument1: stream.remoteID,
                payload: chunk
            ))
            let acknowledgement = try await receivePacket()
            guard acknowledgement.command == .okay,
                  acknowledgement.argument0 == stream.remoteID,
                  acknowledgement.argument1 == stream.localID else {
                throw ADBClientError.protocolViolation(L10n.string("text.wrte_did_not_receive_the_expected_okay"))
            }
            offset = end
        } while offset < data.count
    }

    func read(from stream: StreamHandle) async throws -> Data? {
        let packet = try await receivePacket()
        guard packet.argument0 == stream.remoteID, packet.argument1 == stream.localID else {
            throw ADBClientError.protocolViolation(L10n.string("text.received_data_for_a_different_adb_stream"))
        }
        switch packet.command {
        case .write:
            try await send(ADBPacket(
                command: .okay,
                argument0: stream.localID,
                argument1: stream.remoteID
            ))
            return packet.payload
        case .close:
            try await send(ADBPacket(
                command: .close,
                argument0: stream.localID,
                argument1: stream.remoteID
            ))
            return nil
        default:
            throw ADBClientError.protocolViolation(
                L10n.format("text.received_value_while_reading_the_stream", String(describing: packet.command))
            )
        }
    }

    func close(_ stream: StreamHandle) async throws {
        try await send(ADBPacket(
            command: .close,
            argument0: stream.localID,
            argument1: stream.remoteID
        ))
    }

    private func readUntilClose(_ stream: StreamHandle) async throws -> Data {
        var result = Data()
        while let chunk = try await read(from: stream) {
            result.append(chunk)
        }
        return result
    }

    private func send(_ packet: ADBPacket) async throws {
        guard let transport else { throw ADBClientError.notConnected }
        try await transport.send(packet.encoded)
    }

    private func receivePacket() async throws -> ADBPacket {
        guard let transport else { throw ADBClientError.notConnected }
        let header = try await transport.receiveExactly(ADBPacket.headerSize)
        let payloadLength = try header.uint32LE(at: 12)
        guard payloadLength <= 16 * 1024 * 1024 else {
            throw ADBClientError.protocolViolation(L10n.string("text.the_packet_is_too_large"))
        }
        let payload = try await transport.receiveExactly(Int(payloadLength))
        return try ADBPacket.decode(header: header, payload: payload)
    }
}
