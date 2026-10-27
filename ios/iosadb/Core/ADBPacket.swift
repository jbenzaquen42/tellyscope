import Foundation

struct ADBPacket: Sendable {
    static let headerSize = 24

    enum Command: UInt32, Sendable {
        case sync = 0x434e5953
        case connect = 0x4e584e43
        case auth = 0x48545541
        case startTLS = 0x534c5453
        case open = 0x4e45504f
        case okay = 0x59414b4f
        case close = 0x45534c43
        case write = 0x45545257
    }

    let command: Command
    let argument0: UInt32
    let argument1: UInt32
    let payload: Data

    init(command: Command, argument0: UInt32 = 0, argument1: UInt32 = 0, payload: Data = Data()) {
        self.command = command
        self.argument0 = argument0
        self.argument1 = argument1
        self.payload = payload
    }

    var encoded: Data {
        var result = Data(capacity: Self.headerSize + payload.count)
        result.appendUInt32LE(command.rawValue)
        result.appendUInt32LE(argument0)
        result.appendUInt32LE(argument1)
        result.appendUInt32LE(UInt32(payload.count))
        result.appendUInt32LE(payload.reduce(0) { $0 &+ UInt32($1) })
        result.appendUInt32LE(command.rawValue ^ 0xffff_ffff)
        result.append(payload)
        return result
    }

    static func decode(header: Data, payload: Data) throws -> ADBPacket {
        guard header.count == headerSize else { throw ADBEncodingError.truncatedData }
        let rawCommand = try header.uint32LE(at: 0)
        guard let command = Command(rawValue: rawCommand) else {
            throw ADBClientError.protocolViolation(
                L10n.format("text.unknown_command_0x_value", String(rawCommand, radix: 16))
            )
        }
        let expectedLength = try header.uint32LE(at: 12)
        let expectedChecksum = try header.uint32LE(at: 16)
        let magic = try header.uint32LE(at: 20)
        guard magic == rawCommand ^ 0xffff_ffff else {
            throw ADBClientError.protocolViolation(L10n.string("text.packet_magic_validation_failed"))
        }
        guard payload.count == Int(expectedLength) else { throw ADBEncodingError.truncatedData }
        let checksum = payload.reduce(0) { $0 &+ UInt32($1) }
        // ADB protocol 0x01000001 and newer may intentionally put zero in
        // data_check ("skip checksum"). Older peers still send the additive
        // checksum, so accept either representation during negotiation.
        guard expectedChecksum == 0 || checksum == expectedChecksum else {
            throw ADBClientError.protocolViolation(L10n.string("text.packet_checksum_validation_failed"))
        }
        return ADBPacket(
            command: command,
            argument0: try header.uint32LE(at: 4),
            argument1: try header.uint32LE(at: 8),
            payload: payload
        )
    }
}
