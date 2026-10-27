import Foundation

enum ADBEncodingError: LocalizedError {
    case truncatedData
    case malformedKey
    case valueOutOfRange

    var errorDescription: String? {
        switch self {
        case .truncatedData: L10n.string("text.adb_returned_incomplete_data")
        case .malformedKey: L10n.string("text.unable_to_parse_the_adb_rsa_public_key")
        case .valueOutOfRange: L10n.string("text.adb_data_is_outside_the_supported_range")
        }
    }
}

extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ADBEncodingError.truncatedData
        }
        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
    }
}

extension String {
    var adbShellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
