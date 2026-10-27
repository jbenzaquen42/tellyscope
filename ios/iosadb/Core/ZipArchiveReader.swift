import Foundation
import Compression

enum ZipArchiveError: LocalizedError {
    case invalidArchive
    case unsupportedCompression(UInt16)
    case archiveTooLarge
    case noAPK
    case unsafePath(String)
    case missingOBBTarget(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            L10n.string("text.the_package_is_not_a_valid_zip_apks_xapk_apkm_archive")
        case .unsupportedCompression(let method):
            String(
                format: L10n.string("text.the_package_uses_an_unsupported_zip_compression_method_value"),
                Int(method)
            )
        case .archiveTooLarge:
            L10n.string("text.the_extracted_package_is_too_large")
        case .noAPK:
            L10n.string("text.no_apk_was_found_in_the_archive")
        case .unsafePath(let path):
            String(
                format: L10n.string("text.the_package_contains_an_unsafe_path_value"),
                path
            )
        case .missingOBBTarget(let path):
            String(
                format: L10n.string("text.the_destination_for_the_obb_file_could_not_be_determined_value"),
                path
            )
        }
    }
}

struct APKArchiveEntry: Sendable {
    let archivePath: String
    let data: Data

    var name: String { (archivePath as NSString).lastPathComponent }
}

struct OBBArchiveEntry: Sendable {
    let archivePath: String
    let remotePath: String
    let data: Data
}

struct APKPackageArchive: Sendable {
    let apkEntries: [APKArchiveEntry]
    let obbEntries: [OBBArchiveEntry]
    let packageName: String?
}

enum ZipArchiveReader {
    private static let maxTotalOutput = 2 * 1024 * 1024 * 1024

    static func extractPackage(from archive: Data, fileExtension: String) throws -> APKPackageArchive {
        guard let endOffset = findEndOfCentralDirectory(in: archive) else {
            throw ZipArchiveError.invalidArchive
        }
        let entryCount = Int(try uint16(archive, at: endOffset + 10))
        var cursor = Int(try archive.uint32LE(at: endOffset + 16))
        var apkEntries: [APKArchiveEntry] = []
        var rawOBBEntries: [APKArchiveEntry] = []
        var manifestData: Data?
        var totalOutput = 0

        for _ in 0..<entryCount {
            guard try archive.uint32LE(at: cursor) == 0x0201_4b50 else {
                throw ZipArchiveError.invalidArchive
            }
            let method = try uint16(archive, at: cursor + 10)
            let compressedSize = Int(try archive.uint32LE(at: cursor + 20))
            let uncompressedSize = Int(try archive.uint32LE(at: cursor + 24))
            let nameLength = Int(try uint16(archive, at: cursor + 28))
            let extraLength = Int(try uint16(archive, at: cursor + 30))
            let commentLength = Int(try uint16(archive, at: cursor + 32))
            let localOffset = Int(try archive.uint32LE(at: cursor + 42))
            guard cursor + 46 + nameLength <= archive.count else { throw ZipArchiveError.invalidArchive }
            let nameData = archive.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let name = String(decoding: nameData, as: UTF8.self)
            try validateArchivePath(name)
            let lowercasedName = name.lowercased()
            let shouldExtract = lowercasedName.hasSuffix(".apk")
                || (fileExtension == "xapk" && lowercasedName.hasSuffix(".obb"))
                || (fileExtension == "xapk" && (name as NSString).lastPathComponent.lowercased() == "manifest.json")

            if shouldExtract, !name.hasSuffix("/") {
                totalOutput += uncompressedSize
                guard totalOutput <= maxTotalOutput else { throw ZipArchiveError.archiveTooLarge }
                let data = try extract(
                    archive: archive,
                    localOffset: localOffset,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method
                )
                if lowercasedName.hasSuffix(".apk") {
                    apkEntries.append(APKArchiveEntry(archivePath: name, data: data))
                } else if lowercasedName.hasSuffix(".obb") {
                    rawOBBEntries.append(APKArchiveEntry(archivePath: name, data: data))
                } else {
                    manifestData = data
                }
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }

        guard !apkEntries.isEmpty else { throw ZipArchiveError.noAPK }
        let manifest = parseXAPKManifest(manifestData)
        let obbEntries = try rawOBBEntries.map { entry -> OBBArchiveEntry in
            guard let remotePath = try obbRemotePath(
                archivePath: entry.archivePath,
                packageName: manifest.packageName,
                manifestPaths: manifest.expansionPaths
            ) else {
                throw ZipArchiveError.missingOBBTarget(entry.archivePath)
            }
            return OBBArchiveEntry(
                archivePath: entry.archivePath,
                remotePath: remotePath,
                data: entry.data
            )
        }
        let sortedAPKs = apkEntries.sorted { lhs, rhs in
            if lhs.name.lowercased() == "base.apk" { return true }
            if rhs.name.lowercased() == "base.apk" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return APKPackageArchive(
            apkEntries: sortedAPKs,
            obbEntries: obbEntries,
            packageName: manifest.packageName
        )
    }

    static func entryNames(in archive: Data) throws -> [String] {
        guard let endOffset = findEndOfCentralDirectory(in: archive) else {
            throw ZipArchiveError.invalidArchive
        }
        let entryCount = Int(try uint16(archive, at: endOffset + 10))
        var cursor = Int(try archive.uint32LE(at: endOffset + 16))
        var names: [String] = []
        names.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard try archive.uint32LE(at: cursor) == 0x0201_4b50 else {
                throw ZipArchiveError.invalidArchive
            }
            let nameLength = Int(try uint16(archive, at: cursor + 28))
            let extraLength = Int(try uint16(archive, at: cursor + 30))
            let commentLength = Int(try uint16(archive, at: cursor + 32))
            guard cursor + 46 + nameLength <= archive.count else {
                throw ZipArchiveError.invalidArchive
            }
            let data = archive.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let name = String(decoding: data, as: UTF8.self)
            try validateArchivePath(name)
            names.append(name)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return names
    }

    static func extractEntries(
        from archive: Data,
        matching shouldExtract: (String) -> Bool
    ) throws -> [String: Data] {
        guard let endOffset = findEndOfCentralDirectory(in: archive) else {
            throw ZipArchiveError.invalidArchive
        }
        let entryCount = Int(try uint16(archive, at: endOffset + 10))
        var cursor = Int(try archive.uint32LE(at: endOffset + 16))
        var entries: [String: Data] = [:]
        var totalOutput = 0

        for _ in 0..<entryCount {
            guard try archive.uint32LE(at: cursor) == 0x0201_4b50 else {
                throw ZipArchiveError.invalidArchive
            }
            let method = try uint16(archive, at: cursor + 10)
            let compressedSize = Int(try archive.uint32LE(at: cursor + 20))
            let uncompressedSize = Int(try archive.uint32LE(at: cursor + 24))
            let nameLength = Int(try uint16(archive, at: cursor + 28))
            let extraLength = Int(try uint16(archive, at: cursor + 30))
            let commentLength = Int(try uint16(archive, at: cursor + 32))
            let localOffset = Int(try archive.uint32LE(at: cursor + 42))
            guard cursor + 46 + nameLength <= archive.count else {
                throw ZipArchiveError.invalidArchive
            }
            let nameData = archive.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let name = String(decoding: nameData, as: UTF8.self)
            try validateArchivePath(name)
            if !name.hasSuffix("/"), shouldExtract(name) {
                totalOutput += uncompressedSize
                guard totalOutput <= maxTotalOutput else {
                    throw ZipArchiveError.archiveTooLarge
                }
                entries[name] = try extract(
                    archive: archive,
                    localOffset: localOffset,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func extract(
        archive: Data,
        localOffset: Int,
        compressedSize: Int,
        uncompressedSize: Int,
        method: UInt16
    ) throws -> Data {
        guard try archive.uint32LE(at: localOffset) == 0x0403_4b50 else {
            throw ZipArchiveError.invalidArchive
        }
        let nameLength = Int(try uint16(archive, at: localOffset + 26))
        let extraLength = Int(try uint16(archive, at: localOffset + 28))
        let payloadOffset = localOffset + 30 + nameLength + extraLength
        guard compressedSize >= 0, uncompressedSize >= 0,
              payloadOffset >= 0, payloadOffset + compressedSize <= archive.count else {
            throw ZipArchiveError.invalidArchive
        }
        let compressed = archive.subdata(in: payloadOffset..<payloadOffset + compressedSize)
        if method == 0 {
            guard compressed.count == uncompressedSize else { throw ZipArchiveError.invalidArchive }
            return compressed
        }
        guard method == 8 else { throw ZipArchiveError.unsupportedCompression(method) }
        if uncompressedSize == 0 { return Data() }

        var output = Data(count: uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    compressedSize,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == uncompressedSize else { throw ZipArchiveError.invalidArchive }
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if (try? data.uint32LE(at: offset)) == 0x0605_4b50 { return offset }
        }
        return nil
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipArchiveError.invalidArchive }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func validateArchivePath(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let hasWindowsDrivePrefix = normalized.count >= 2
            && normalized[normalized.index(after: normalized.startIndex)] == ":"
        guard !path.contains("\0"),
              !normalized.hasPrefix("/"),
              !hasWindowsDrivePrefix,
              !components.contains("..") else {
            throw ZipArchiveError.unsafePath(path)
        }
    }

    private static func parseXAPKManifest(_ data: Data?) -> (
        packageName: String?,
        expansionPaths: [String: String]
    ) {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return (nil, [:])
        }
        let packageName = dictionary["package_name"] as? String
        var paths: [String: String] = [:]
        if let expansions = dictionary["expansions"] as? [[String: Any]] {
            for expansion in expansions {
                guard let file = expansion["file"] as? String else { continue }
                let installPath = expansion["install_path"] as? String
                    ?? expansion["path"] as? String
                    ?? file
                paths[(file as NSString).lastPathComponent] = installPath
            }
        }
        return (packageName, paths)
    }

    private static func obbRemotePath(
        archivePath: String,
        packageName: String?,
        manifestPaths: [String: String]
    ) throws -> String? {
        let filename = (archivePath as NSString).lastPathComponent
        let manifestPath = manifestPaths[filename]
        let candidate = (manifestPath ?? archivePath)
            .replacingOccurrences(of: "\\", with: "/")
        try validateArchivePath(candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        if let range = candidate.range(of: "Android/obb/", options: [.caseInsensitive]) {
            let suffix = String(candidate[range.lowerBound...])
            return "/sdcard/" + suffix
        }
        guard let packageName,
              !packageName.isEmpty,
              !packageName.contains("/"),
              !packageName.contains("..") else {
            return nil
        }
        return "/sdcard/Android/obb/\(packageName)/\(filename)"
    }
}
