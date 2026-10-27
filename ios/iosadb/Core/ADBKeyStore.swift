import Foundation
import Security

final class ADBKeyStore: @unchecked Sendable {
    // v1 persisted both halves of the RSA pair under one tag. Depending on
    // Keychain ordering it could later return the public half as if it were
    // the private key. Keep the old entry untouched and migrate to a clean,
    // private-only identity.
    private let tag = Data("com.tvadb.identity.v2".utf8)
    private let privateKey: SecKey

    init() throws {
        if let existing = Self.loadPrivateKey(tag: tag) {
            privateKey = existing
            return
        }

        let privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateKeyAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw ADBClientError.authenticationFailed
        }
        privateKey = generated
    }

    func sign(token: Data) throws -> Data {
        guard token.count == 20 else {
            throw ADBClientError.protocolViolation(L10n.string("text.the_auth_token_is_not_20_bytes"))
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            &error
        ) else {
            if let error { throw error.takeRetainedValue() }
            throw ADBClientError.authenticationFailed
        }
        return signature as Data
    }

    func androidPublicKey() throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ADBEncodingError.malformedKey
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw ADBEncodingError.malformedKey
        }
        let modulus = try Self.parseRSAPublicModulus(external as Data)
        guard modulus.count <= 256 else { throw ADBEncodingError.malformedKey }

        let padded = Data(repeating: 0, count: 256 - modulus.count) + modulus
        var words = [UInt32](repeating: 0, count: 64)
        for wordIndex in 0..<64 {
            let highOffset = padded.count - (wordIndex + 1) * 4
            words[wordIndex] = UInt32(padded[highOffset]) << 24
                | UInt32(padded[highOffset + 1]) << 16
                | UInt32(padded[highOffset + 2]) << 8
                | UInt32(padded[highOffset + 3])
        }

        let inverse = Self.modularInverse32(words[0])
        let rr = Self.rSquaredModN(modulus: words)

        var binary = Data(capacity: 524)
        binary.appendUInt32LE(64)
        binary.appendUInt32LE(0 &- inverse)
        words.forEach { binary.appendUInt32LE($0) }
        rr.forEach { binary.appendUInt32LE($0) }
        binary.appendUInt32LE(65_537)

        let line = binary.base64EncodedString() + " tvadb@iphone\0"
        return Data(line.utf8)
    }

    /// Keeps the embedded AOSP client and the native authorization handshake
    /// on the same RSA identity. Without this, a TV can authorize one client
    /// while the other remains stuck in the unauthorized state.
    func synchronizeADBPrivateKey(at privateKeyURL: URL) throws {
        guard let external = SecKeyCopyExternalRepresentation(privateKey, nil) else {
            throw ADBClientError.authenticationFailed
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: privateKeyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let base64 = (external as Data).base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        )
        let privatePEM = """
        -----BEGIN RSA PRIVATE KEY-----
        \(base64)
        -----END RSA PRIVATE KEY-----

        """
        let privateData = Data(privatePEM.utf8)
        if (try? Data(contentsOf: privateKeyURL)) != privateData {
            try privateData.write(to: privateKeyURL, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )

        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        let publicLine = String(decoding: try androidPublicKey(), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
            + "\n"
        let publicData = Data(publicLine.utf8)
        if (try? Data(contentsOf: publicKeyURL)) != publicData {
            try publicData.write(to: publicKeyURL, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: publicKeyURL.path
        )
    }

    private static func loadPrivateKey(tag: Data) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            // A generated RSA key pair can expose both key classes under the
            // same application tag. Without this constraint Keychain may
            // return the public half, which is only ~270 bytes and cannot be
            // parsed by AOSP as an RSA private key.
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    private static func parseRSAPublicModulus(_ der: Data) throws -> Data {
        var cursor = 0

        func readLength() throws -> Int {
            guard cursor < der.count else { throw ADBEncodingError.malformedKey }
            let first = Int(der[cursor])
            cursor += 1
            if first & 0x80 == 0 { return first }
            let byteCount = first & 0x7f
            guard byteCount > 0, byteCount <= 4, cursor + byteCount <= der.count else {
                throw ADBEncodingError.malformedKey
            }
            var value = 0
            for _ in 0..<byteCount {
                value = value << 8 | Int(der[cursor])
                cursor += 1
            }
            return value
        }

        func readElement(tag: UInt8) throws -> Data {
            guard cursor < der.count, der[cursor] == tag else { throw ADBEncodingError.malformedKey }
            cursor += 1
            let length = try readLength()
            guard cursor + length <= der.count else { throw ADBEncodingError.malformedKey }
            let value = der[cursor..<(cursor + length)]
            cursor += length
            return Data(value)
        }

        _ = try readElement(tag: 0x30)
        cursor = 0
        guard der[cursor] == 0x30 else { throw ADBEncodingError.malformedKey }
        cursor += 1
        _ = try readLength()
        var modulus = try readElement(tag: 0x02)
        while modulus.first == 0, modulus.count > 1 { modulus.removeFirst() }
        return modulus
    }

    private static func modularInverse32(_ odd: UInt32) -> UInt32 {
        var inverse = odd
        inverse = inverse &* (2 &- odd &* inverse)
        inverse = inverse &* (2 &- odd &* inverse)
        inverse = inverse &* (2 &- odd &* inverse)
        inverse = inverse &* (2 &- odd &* inverse)
        inverse = inverse &* (2 &- odd &* inverse)
        return inverse
    }

    private static func rSquaredModN(modulus: [UInt32]) -> [UInt32] {
        var value = [UInt32](repeating: 0, count: 64)
        value[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for index in 0..<64 {
                let nextCarry = value[index] >> 31
                value[index] = value[index] << 1 | carry
                carry = nextCarry
            }
            if carry != 0 || compare(value, modulus) >= 0 {
                value = subtract(value, modulus)
            }
        }
        return value
    }

    private static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        for index in stride(from: 63, through: 0, by: -1) {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
        }
        return 0
    }

    private static func subtract(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var result = lhs
        var borrow: UInt64 = 0
        for index in 0..<64 {
            let left = UInt64(lhs[index])
            let right = UInt64(rhs[index]) + borrow
            result[index] = UInt32(truncatingIfNeeded: left &- right)
            borrow = left < right ? 1 : 0
        }
        return result
    }
}
