import Foundation
import CryptoKit
import Security

struct APKInspection: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let fileSize: UInt64
    let iconData: Data?
    let applicationName: String
    let packageName: String
    let versionCode: String
    let versionName: String
    let minSDK: String
    let targetSDK: String
    let abis: [String]
    let signatureSchemes: [String]
    let certificateSubject: String?
    let certificateSHA256: String?
    let permissions: [String]
    let activities: [String]
    let services: [String]
    let receivers: [String]
    let providers: [String]
    let sharedUserID: String?
}

enum APKInspectionError: LocalizedError {
    case missingManifest
    case invalidManifest
    case invalidResources

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            L10n.string("text.androidmanifest_xml_was_not_found_in_the_apk")
        case .invalidManifest:
            L10n.string("text.the_apk_binary_manifest_could_not_be_parsed")
        case .invalidResources:
            L10n.string("text.the_apk_resource_table_could_not_be_parsed")
        }
    }
}

enum APKInspector {
    struct PresentationMetadata: Sendable {
        let applicationName: String
        let versionName: String
        let iconPaths: [String]
    }

    static func inspect(data: Data, filename: String) throws -> APKInspection {
        let entryNames = try ZipArchiveReader.entryNames(in: data)
        let metadataEntries = try ZipArchiveReader.extractEntries(from: data) { path in
            let lowercased = path.lowercased()
            return lowercased == "androidmanifest.xml"
                || lowercased == "resources.arsc"
                || (lowercased.hasPrefix("meta-inf/")
                    && (lowercased.hasSuffix(".rsa")
                        || lowercased.hasSuffix(".dsa")
                        || lowercased.hasSuffix(".ec")))
        }
        guard let manifestData = metadataEntries.first(where: {
            $0.key.caseInsensitiveCompare("AndroidManifest.xml") == .orderedSame
        })?.value else {
            throw APKInspectionError.missingManifest
        }

        let manifest = try BinaryAndroidManifest(data: manifestData).parse()
        let resourceTable: AndroidResourceTable?
        if let resources = metadataEntries.first(where: {
            $0.key.caseInsensitiveCompare("resources.arsc") == .orderedSame
        })?.value {
            resourceTable = try? AndroidResourceTable(data: resources)
        } else {
            resourceTable = nil
        }

        let applicationName: String
        if let literal = manifest.applicationLabel?.text, !literal.isEmpty {
            applicationName = literal
        } else if let resourceID = manifest.applicationLabel?.reference,
                  let resolved = resourceTable?.resolvedText(for: resourceID) {
            applicationName = resolved
        } else {
            applicationName = manifest.packageName
        }

        let iconData = try extractIcon(
            archive: data,
            entryNames: entryNames,
            resourceTable: resourceTable,
            iconResourceID: manifest.applicationIcon?.reference
        )
        let signature = APKSignatureReader.inspect(
            archive: data,
            metadataEntries: metadataEntries
        )
        let abis = Set(entryNames.compactMap { path -> String? in
            let components = path.split(separator: "/")
            guard components.count >= 3,
                  components[0].lowercased() == "lib",
                  components.last?.lowercased().hasSuffix(".so") == true else {
                return nil
            }
            return String(components[1])
        }).sorted()

        return APKInspection(
            filename: filename,
            fileSize: UInt64(data.count),
            iconData: iconData,
            applicationName: applicationName,
            packageName: manifest.packageName,
            versionCode: manifest.versionCode,
            versionName: manifest.versionName,
            minSDK: manifest.minSDK,
            targetSDK: manifest.targetSDK,
            abis: abis,
            signatureSchemes: signature.schemes,
            certificateSubject: signature.subject,
            certificateSHA256: signature.sha256,
            permissions: manifest.permissions.sorted(),
            activities: manifest.activities,
            services: manifest.services,
            receivers: manifest.receivers,
            providers: manifest.providers,
            sharedUserID: manifest.sharedUserID
        )
    }

    /// Parses only the fields required by the installed-app list. Unlike
    /// `inspect`, this deliberately skips signatures, components, permissions,
    /// and ABI enumeration.
    static func installedPresentation(data: Data) throws -> InstalledAppPresentation {
        let entryNames = try ZipArchiveReader.entryNames(in: data)
        let metadataEntries = try ZipArchiveReader.extractEntries(from: data) { path in
            path.caseInsensitiveCompare("AndroidManifest.xml") == .orderedSame
                || path.caseInsensitiveCompare("resources.arsc") == .orderedSame
        }
        guard let manifestData = metadataEntries.first(where: {
            $0.key.caseInsensitiveCompare("AndroidManifest.xml") == .orderedSame
        })?.value else {
            throw APKInspectionError.missingManifest
        }
        let resourcesData = metadataEntries.first(where: {
            $0.key.caseInsensitiveCompare("resources.arsc") == .orderedSame
        })?.value
        let metadata = try presentationMetadata(
            manifestData: manifestData,
            resourcesData: resourcesData,
            entryNames: entryNames
        )
        let iconData: Data?
        if let iconPath = metadata.iconPaths.first {
            iconData = try ZipArchiveReader.extractEntries(from: data) {
                $0 == iconPath
            }[iconPath]
        } else {
            iconData = nil
        }
        return InstalledAppPresentation(
            name: metadata.applicationName,
            iconData: iconData,
            versionName: metadata.versionName
        )
    }

    /// Builds the installed-app presentation from individual APK entries.
    /// This allows the ADB layer to extract a few ZIP members on the TV rather
    /// than transferring the complete APK to iOS.
    static func presentationMetadata(
        manifestData: Data,
        resourcesData: Data?,
        entryNames: [String]
    ) throws -> PresentationMetadata {
        let manifest = try BinaryAndroidManifest(data: manifestData).parse()
        let resourceTable = resourcesData.flatMap {
            try? AndroidResourceTable(data: $0)
        }
        let applicationName: String
        if let literal = manifest.applicationLabel?.text, !literal.isEmpty {
            applicationName = literal
        } else if let resourceID = manifest.applicationLabel?.reference,
                  let resolved = resourceTable?.resolvedText(for: resourceID) {
            applicationName = resolved
        } else {
            applicationName = manifest.packageName
        }
        return PresentationMetadata(
            applicationName: applicationName,
            versionName: manifest.versionName,
            iconPaths: iconCandidatePaths(
                entryNames: entryNames,
                resourceTable: resourceTable,
                iconResourceID: manifest.applicationIcon?.reference
            )
        )
    }

    static func bestEffortIcon(data: Data) throws -> Data? {
        let entryNames = try ZipArchiveReader.entryNames(in: data)
        return try extractBestIcon(
            archive: data,
            entryNames: entryNames,
            resourceNames: []
        )
    }

    static func bestEffortIconPaths(entryNames: [String]) -> [String] {
        iconCandidatePaths(
            entryNames: entryNames,
            resourceTable: nil,
            iconResourceID: nil
        )
    }

    private static func extractIcon(
        archive: Data,
        entryNames: [String],
        resourceTable: AndroidResourceTable?,
        iconResourceID: UInt32?
    ) throws -> Data? {
        guard let selected = iconCandidatePaths(
            entryNames: entryNames,
            resourceTable: resourceTable,
            iconResourceID: iconResourceID
        ).first else {
            return nil
        }
        return try ZipArchiveReader.extractEntries(from: archive) {
            $0 == selected
        }[selected]
    }

    private static func iconCandidatePaths(
        entryNames: [String],
        resourceTable: AndroidResourceTable?,
        iconResourceID: UInt32?
    ) -> [String] {
        var candidates: [AndroidResourceTable.FileCandidate] = []
        var resourceNames: Set<String> = []
        if let iconResourceID, let resourceTable {
            candidates = resourceTable.fileCandidates(for: iconResourceID)
                .filter { isRasterImage($0.path) }
            resourceNames = resourceTable.resourceNames(for: iconResourceID)
        }
        if candidates.isEmpty, !resourceNames.isEmpty {
            candidates = entryNames.compactMap { path in
                let baseName = ((path as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                guard isRasterImage(path),
                      resourceNames.contains(where: {
                          baseName == $0
                              || baseName.hasPrefix($0 + "_")
                              || $0.hasPrefix(baseName + "_")
                      }) else {
                    return nil
                }
                return AndroidResourceTable.FileCandidate(
                    path: path,
                    density: densityScore(for: path)
                )
            }
        }
        let exactPaths = candidates.sorted {
            iconScore($0) > iconScore($1)
        }.map(\.path)
        let fallbackPaths = entryNames.compactMap {
            path -> AndroidResourceTable.FileCandidate? in
            guard isLikelyApplicationIcon(path, resourceNames: resourceNames) else {
                return nil
            }
            return AndroidResourceTable.FileCandidate(
                path: path,
                density: densityScore(for: path)
            )
        }.sorted {
            fallbackIconScore($0, resourceNames: resourceNames)
                > fallbackIconScore($1, resourceNames: resourceNames)
        }.map(\.path)

        var seen: Set<String> = []
        return (exactPaths + fallbackPaths).filter { seen.insert($0).inserted }
    }

    private static func extractBestIcon(
        archive: Data,
        entryNames: [String],
        resourceNames: Set<String>
    ) throws -> Data? {
        let candidates = entryNames.compactMap { path -> AndroidResourceTable.FileCandidate? in
            guard isLikelyApplicationIcon(path, resourceNames: resourceNames) else {
                return nil
            }
            return AndroidResourceTable.FileCandidate(
                path: path,
                density: densityScore(for: path)
            )
        }
        guard let selected = candidates.max(by: {
            fallbackIconScore($0, resourceNames: resourceNames)
                < fallbackIconScore($1, resourceNames: resourceNames)
        }) else {
            return nil
        }
        return try ZipArchiveReader.extractEntries(from: archive) {
            $0 == selected.path
        }[selected.path]
    }

    private static func isRasterImage(_ path: String) -> Bool {
        ["png", "webp", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func isLikelyApplicationIcon(
        _ path: String,
        resourceNames: Set<String>
    ) -> Bool {
        guard isRasterImage(path) else { return false }
        let value = path.lowercased()
        guard value.hasPrefix("res/"),
              value.contains("/mipmap") || value.contains("/drawable") else {
            return false
        }
        let baseName = (((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension).lowercased()
        if resourceNames.contains(where: {
            let name = $0.lowercased()
            return baseName == name
                || baseName.hasPrefix(name + "_")
                || name.hasPrefix(baseName + "_")
        }) {
            return true
        }
        return baseName == "icon"
            || baseName == "app_icon"
            || baseName == "ic_launcher"
            || baseName.hasPrefix("ic_launcher_")
            || baseName.hasPrefix("launcher_icon")
    }

    private static func iconScore(_ candidate: AndroidResourceTable.FileCandidate) -> Int {
        let path = candidate.path.lowercased()
        return candidate.density
            + (path.contains("/mipmap") ? 10_000 : 0)
            + (path.contains("xxxhdpi") ? 640 : densityScore(for: path))
    }

    private static func fallbackIconScore(
        _ candidate: AndroidResourceTable.FileCandidate,
        resourceNames: Set<String>
    ) -> Int {
        let path = candidate.path.lowercased()
        let baseName = (((candidate.path as NSString).lastPathComponent as NSString)
            .deletingPathExtension).lowercased()
        let exactResourceName = resourceNames.contains {
            $0.lowercased() == baseName
        }
        let isLayer = baseName.contains("foreground")
            || baseName.contains("background")
            || baseName.contains("monochrome")
        return iconScore(candidate)
            + (exactResourceName ? 50_000 : 0)
            + (baseName == "ic_launcher" || baseName == "app_icon" || baseName == "icon" ? 20_000 : 0)
            + (isLayer ? 0 : 5_000)
            + (path.contains("-v26") ? 200 : 0)
    }

    private static func densityScore(for path: String) -> Int {
        let value = path.lowercased()
        if value.contains("xxxhdpi") { return 640 }
        if value.contains("xxhdpi") { return 480 }
        if value.contains("xhdpi") { return 320 }
        if value.contains("hdpi") { return 240 }
        if value.contains("tvdpi") { return 213 }
        if value.contains("mdpi") { return 160 }
        if value.contains("ldpi") { return 120 }
        return 0
    }
}

private struct XMLAttributeValue {
    let text: String?
    let reference: UInt32?
    let integer: UInt32?
}

private struct ParsedManifest {
    var packageName = ""
    var versionCode = "—"
    var versionName = "—"
    var minSDK = "—"
    var targetSDK = "—"
    var applicationLabel: XMLAttributeValue?
    var applicationIcon: XMLAttributeValue?
    var sharedUserID: String?
    var permissions: Set<String> = []
    var activities: [String] = []
    var services: [String] = []
    var receivers: [String] = []
    var providers: [String] = []
}

private struct BinaryAndroidManifest {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> ParsedManifest {
        guard data.count >= 8,
              try data.uint16LE(at: 0) == 0x0003 else {
            throw APKInspectionError.invalidManifest
        }
        let declaredSize = Int(try data.uint32LE(at: 4))
        let end = min(declaredSize, data.count)
        var cursor = Int(try data.uint16LE(at: 2))
        var strings: AndroidStringPool?
        var manifest = ParsedManifest()
        var versionCodeLow: UInt32?
        var versionCodeHigh: UInt32?

        while cursor + 8 <= end {
            let type = try data.uint16LE(at: cursor)
            let headerSize = Int(try data.uint16LE(at: cursor + 2))
            let chunkSize = Int(try data.uint32LE(at: cursor + 4))
            guard headerSize >= 8, chunkSize >= headerSize, cursor + chunkSize <= end else {
                throw APKInspectionError.invalidManifest
            }
            if type == 0x0001 {
                strings = try AndroidStringPool(data: data, offset: cursor)
            } else if type == 0x0102, let strings {
                let element = try parseStartElement(at: cursor, strings: strings)
                switch element.name {
                case "manifest":
                    manifest.packageName = element.attributes.value("package")?.text ?? ""
                    versionCodeLow = element.attributes.value("versionCode")?.integer
                    versionCodeHigh = element.attributes.value("versionCodeMajor")?.integer
                    manifest.versionName = displayValue(element.attributes.value("versionName"))
                    manifest.sharedUserID = element.attributes.value("sharedUserId")?.text
                case "uses-sdk":
                    manifest.minSDK = displayValue(element.attributes.value("minSdkVersion"))
                    manifest.targetSDK = displayValue(element.attributes.value("targetSdkVersion"))
                case "uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m":
                    if let name = element.attributes.value("name")?.text, !name.isEmpty {
                        manifest.permissions.insert(name)
                    }
                case "application":
                    manifest.applicationLabel = element.attributes.value("label")
                    manifest.applicationIcon = element.attributes.value("icon")
                case "activity", "activity-alias":
                    appendComponent(element.attributes.value("name")?.text, package: manifest.packageName, to: &manifest.activities)
                case "service":
                    appendComponent(element.attributes.value("name")?.text, package: manifest.packageName, to: &manifest.services)
                case "receiver":
                    appendComponent(element.attributes.value("name")?.text, package: manifest.packageName, to: &manifest.receivers)
                case "provider":
                    appendComponent(element.attributes.value("name")?.text, package: manifest.packageName, to: &manifest.providers)
                default:
                    break
                }
            }
            cursor += chunkSize
        }

        guard !manifest.packageName.isEmpty else {
            throw APKInspectionError.invalidManifest
        }
        if let low = versionCodeLow {
            let combined = (UInt64(versionCodeHigh ?? 0) << 32) | UInt64(low)
            manifest.versionCode = String(combined)
        }
        return manifest
    }

    private func parseStartElement(
        at offset: Int,
        strings: AndroidStringPool
    ) throws -> (name: String, attributes: [(name: String, value: XMLAttributeValue)]) {
        guard offset + 36 <= data.count else { throw APKInspectionError.invalidManifest }
        let nameIndex = try data.uint32LE(at: offset + 20)
        guard let elementName = strings.string(at: nameIndex) else {
            throw APKInspectionError.invalidManifest
        }
        let attributeStart = Int(try data.uint16LE(at: offset + 24))
        let attributeSize = Int(try data.uint16LE(at: offset + 26))
        let attributeCount = Int(try data.uint16LE(at: offset + 28))
        guard attributeSize >= 20 else { throw APKInspectionError.invalidManifest }
        let firstAttribute = offset + 16 + attributeStart
        var attributes: [(String, XMLAttributeValue)] = []
        attributes.reserveCapacity(attributeCount)

        for index in 0..<attributeCount {
            let attributeOffset = firstAttribute + index * attributeSize
            guard attributeOffset + 20 <= data.count else {
                throw APKInspectionError.invalidManifest
            }
            let attributeNameIndex = try data.uint32LE(at: attributeOffset + 4)
            let rawValueIndex = try data.uint32LE(at: attributeOffset + 8)
            let valueType = data[attributeOffset + 15]
            let typedData = try data.uint32LE(at: attributeOffset + 16)
            guard let attributeName = strings.string(at: attributeNameIndex) else { continue }
            let rawText = rawValueIndex == UInt32.max ? nil : strings.string(at: rawValueIndex)
            let value: XMLAttributeValue
            switch valueType {
            case 0x01:
                value = XMLAttributeValue(text: rawText, reference: typedData, integer: nil)
            case 0x03:
                value = XMLAttributeValue(
                    text: rawText ?? strings.string(at: typedData),
                    reference: nil,
                    integer: nil
                )
            case 0x10, 0x11:
                value = XMLAttributeValue(
                    text: rawText ?? String(typedData),
                    reference: nil,
                    integer: typedData
                )
            case 0x12:
                value = XMLAttributeValue(
                    text: rawText ?? (typedData == 0 ? "false" : "true"),
                    reference: nil,
                    integer: typedData
                )
            default:
                value = XMLAttributeValue(text: rawText, reference: nil, integer: typedData)
            }
            attributes.append((attributeName, value))
        }
        return (elementName, attributes)
    }

    private func displayValue(_ value: XMLAttributeValue?) -> String {
        if let text = value?.text, !text.isEmpty { return text }
        if let integer = value?.integer { return String(integer) }
        if let reference = value?.reference {
            return String(format: "@0x%08x", reference)
        }
        return "—"
    }

    private func appendComponent(
        _ value: String?,
        package: String,
        to components: inout [String]
    ) {
        guard let value, !value.isEmpty else { return }
        let resolved: String
        if value.hasPrefix(".") {
            resolved = package + value
        } else if value.contains(".") {
            resolved = value
        } else {
            resolved = package + "." + value
        }
        components.append(resolved)
    }
}

private extension Array where Element == (name: String, value: XMLAttributeValue) {
    func value(_ name: String) -> XMLAttributeValue? {
        first(where: { $0.name == name })?.value
    }
}

private struct AndroidStringPool {
    private let values: [String]

    init(data: Data, offset: Int) throws {
        guard offset + 28 <= data.count,
              try data.uint16LE(at: offset) == 0x0001 else {
            throw APKInspectionError.invalidResources
        }
        let headerSize = Int(try data.uint16LE(at: offset + 2))
        let chunkSize = Int(try data.uint32LE(at: offset + 4))
        let stringCount = Int(try data.uint32LE(at: offset + 8))
        let flags = try data.uint32LE(at: offset + 16)
        let stringsStart = Int(try data.uint32LE(at: offset + 20))
        guard headerSize >= 28,
              stringCount >= 0,
              offset + chunkSize <= data.count,
              offset + headerSize + stringCount * 4 <= offset + chunkSize else {
            throw APKInspectionError.invalidResources
        }
        let utf8 = flags & 0x0000_0100 != 0
        var parsed: [String] = []
        parsed.reserveCapacity(stringCount)
        for index in 0..<stringCount {
            let relativeOffset = Int(try data.uint32LE(at: offset + headerSize + index * 4))
            var stringOffset = offset + stringsStart + relativeOffset
            guard stringOffset < offset + chunkSize else {
                throw APKInspectionError.invalidResources
            }
            if utf8 {
                _ = try Self.readLength8(data, cursor: &stringOffset, limit: offset + chunkSize)
                let byteLength = try Self.readLength8(data, cursor: &stringOffset, limit: offset + chunkSize)
                guard stringOffset + byteLength <= offset + chunkSize else {
                    throw APKInspectionError.invalidResources
                }
                parsed.append(String(decoding: data[stringOffset..<stringOffset + byteLength], as: UTF8.self))
            } else {
                let utf16Length = try Self.readLength16(data, cursor: &stringOffset, limit: offset + chunkSize)
                guard stringOffset + utf16Length * 2 <= offset + chunkSize else {
                    throw APKInspectionError.invalidResources
                }
                var units: [UInt16] = []
                units.reserveCapacity(utf16Length)
                for position in 0..<utf16Length {
                    units.append(try data.uint16LE(at: stringOffset + position * 2))
                }
                parsed.append(String(decoding: units, as: UTF16.self))
            }
        }
        values = parsed
    }

    func string(at index: UInt32) -> String? {
        guard index != UInt32.max, Int(index) < values.count else { return nil }
        return values[Int(index)]
    }

    private static func readLength8(_ data: Data, cursor: inout Int, limit: Int) throws -> Int {
        guard cursor < limit else { throw APKInspectionError.invalidResources }
        let first = Int(data[cursor])
        cursor += 1
        if first & 0x80 == 0 { return first }
        guard cursor < limit else { throw APKInspectionError.invalidResources }
        let second = Int(data[cursor])
        cursor += 1
        return ((first & 0x7f) << 8) | second
    }

    private static func readLength16(_ data: Data, cursor: inout Int, limit: Int) throws -> Int {
        guard cursor + 2 <= limit else { throw APKInspectionError.invalidResources }
        let first = Int(try data.uint16LE(at: cursor))
        cursor += 2
        if first & 0x8000 == 0 { return first }
        guard cursor + 2 <= limit else { throw APKInspectionError.invalidResources }
        let second = Int(try data.uint16LE(at: cursor))
        cursor += 2
        return ((first & 0x7fff) << 16) | second
    }
}

private struct AndroidResourceTable {
    struct FileCandidate {
        let path: String
        let density: Int
    }

    private struct Record {
        let resourceID: UInt32
        let keyName: String
        let valueType: UInt8
        let valueData: UInt32
        let stringValue: String?
        let density: Int
        let isDefaultLocale: Bool
    }

    private let records: [UInt32: [Record]]

    init(data: Data) throws {
        guard data.count >= 12,
              try data.uint16LE(at: 0) == 0x0002 else {
            throw APKInspectionError.invalidResources
        }
        let tableHeaderSize = Int(try data.uint16LE(at: 2))
        let tableSize = min(Int(try data.uint32LE(at: 4)), data.count)
        var cursor = tableHeaderSize
        var globalStrings: AndroidStringPool?
        var parsedRecords: [UInt32: [Record]] = [:]

        while cursor + 8 <= tableSize {
            let type = try data.uint16LE(at: cursor)
            let headerSize = Int(try data.uint16LE(at: cursor + 2))
            let chunkSize = Int(try data.uint32LE(at: cursor + 4))
            guard headerSize >= 8, chunkSize >= headerSize, cursor + chunkSize <= tableSize else {
                throw APKInspectionError.invalidResources
            }
            if type == 0x0001 {
                globalStrings = try AndroidStringPool(data: data, offset: cursor)
            } else if type == 0x0200, let globalStrings {
                try Self.parsePackage(
                    data: data,
                    offset: cursor,
                    globalStrings: globalStrings,
                    records: &parsedRecords
                )
            }
            cursor += chunkSize
        }
        records = parsedRecords
    }

    func resolvedText(for resourceID: UInt32) -> String? {
        resolve(resourceID, wantFile: false, visited: []).first?.path
    }

    func fileCandidates(for resourceID: UInt32) -> [FileCandidate] {
        resolve(resourceID, wantFile: true, visited: [])
    }

    func resourceNames(for resourceID: UInt32) -> Set<String> {
        Set(records[resourceID, default: []].map(\.keyName))
    }

    private func resolve(
        _ resourceID: UInt32,
        wantFile: Bool,
        visited: Set<UInt32>
    ) -> [FileCandidate] {
        guard !visited.contains(resourceID) else { return [] }
        var nextVisited = visited
        nextVisited.insert(resourceID)
        let candidates = records[resourceID, default: []].sorted {
            if $0.isDefaultLocale != $1.isDefaultLocale {
                return $0.isDefaultLocale
            }
            return $0.density > $1.density
        }
        var output: [FileCandidate] = []
        for record in candidates {
            if record.valueType == 0x01 {
                output.append(contentsOf: resolve(record.valueData, wantFile: wantFile, visited: nextVisited))
            } else if record.valueType == 0x03, let string = record.stringValue {
                let isFile = string.hasPrefix("res/")
                if isFile == wantFile {
                    output.append(FileCandidate(path: string, density: record.density))
                }
            }
        }
        return output
    }

    private static func parsePackage(
        data: Data,
        offset: Int,
        globalStrings: AndroidStringPool,
        records: inout [UInt32: [Record]]
    ) throws {
        let headerSize = Int(try data.uint16LE(at: offset + 2))
        let chunkSize = Int(try data.uint32LE(at: offset + 4))
        guard headerSize >= 284, offset + chunkSize <= data.count else {
            throw APKInspectionError.invalidResources
        }
        let packageID = try data.uint32LE(at: offset + 8)
        let typeStringsOffset = Int(try data.uint32LE(at: offset + 268))
        let keyStringsOffset = Int(try data.uint32LE(at: offset + 276))
        let typeIDOffset = headerSize >= 288 ? try data.uint32LE(at: offset + 284) : 0
        let typeStrings = try AndroidStringPool(data: data, offset: offset + typeStringsOffset)
        let keyStrings = try AndroidStringPool(data: data, offset: offset + keyStringsOffset)
        var cursor = offset + headerSize

        while cursor + 8 <= offset + chunkSize {
            let type = try data.uint16LE(at: cursor)
            let childHeaderSize = Int(try data.uint16LE(at: cursor + 2))
            let childSize = Int(try data.uint32LE(at: cursor + 4))
            guard childHeaderSize >= 8,
                  childSize >= childHeaderSize,
                  cursor + childSize <= offset + chunkSize else {
                throw APKInspectionError.invalidResources
            }
            if type == 0x0201 {
                try parseTypeChunk(
                    data: data,
                    offset: cursor,
                    packageID: packageID,
                    typeIDOffset: typeIDOffset,
                    typeStrings: typeStrings,
                    keyStrings: keyStrings,
                    globalStrings: globalStrings,
                    records: &records
                )
            }
            cursor += childSize
        }
    }

    private static func parseTypeChunk(
        data: Data,
        offset: Int,
        packageID: UInt32,
        typeIDOffset: UInt32,
        typeStrings: AndroidStringPool,
        keyStrings: AndroidStringPool,
        globalStrings: AndroidStringPool,
        records: inout [UInt32: [Record]]
    ) throws {
        let headerSize = Int(try data.uint16LE(at: offset + 2))
        let chunkSize = Int(try data.uint32LE(at: offset + 4))
        let rawTypeID = UInt32(data[offset + 8])
        let flags = data[offset + 9]
        let entryCount = Int(try data.uint32LE(at: offset + 12))
        let entriesStart = Int(try data.uint32LE(at: offset + 16))
        guard rawTypeID > 0,
              headerSize >= 20,
              entriesStart >= headerSize,
              offset + chunkSize <= data.count else {
            throw APKInspectionError.invalidResources
        }
        let configOffset = offset + 20
        let configSize = Int(try data.uint32LE(at: configOffset))
        let density = configSize >= 16 ? Int(try data.uint16LE(at: configOffset + 14)) : 0
        let isDefaultLocale = configSize < 12
            || (data[configOffset + 8] == 0
                && data[configOffset + 9] == 0
                && data[configOffset + 10] == 0
                && data[configOffset + 11] == 0)
        let typeID = rawTypeID + typeIDOffset
        _ = typeStrings.string(at: typeID - 1)

        var entryOffsets: [(index: Int, offset: Int)] = []
        if flags & 0x01 != 0 {
            let sparseCount = (entriesStart - headerSize) / 4
            for index in 0..<sparseCount {
                let itemOffset = offset + headerSize + index * 4
                let entryIndex = Int(try data.uint16LE(at: itemOffset))
                let entryOffset = Int(try data.uint16LE(at: itemOffset + 2)) * 4
                entryOffsets.append((entryIndex, entryOffset))
            }
        } else if flags & 0x02 != 0 {
            guard offset + headerSize + entryCount * 2 <= offset + entriesStart else {
                throw APKInspectionError.invalidResources
            }
            for index in 0..<entryCount {
                let value = try data.uint16LE(at: offset + headerSize + index * 2)
                if value != UInt16.max {
                    entryOffsets.append((index, Int(value) * 4))
                }
            }
        } else {
            guard offset + headerSize + entryCount * 4 <= offset + entriesStart else {
                throw APKInspectionError.invalidResources
            }
            for index in 0..<entryCount {
                let value = try data.uint32LE(at: offset + headerSize + index * 4)
                if value != UInt32.max {
                    entryOffsets.append((index, Int(value)))
                }
            }
        }

        for item in entryOffsets {
            let entryOffset = offset + entriesStart + item.offset
            guard entryOffset + 8 <= offset + chunkSize else { continue }
            let entrySize = Int(try data.uint16LE(at: entryOffset))
            let entryFlags = try data.uint16LE(at: entryOffset + 2)
            let keyIndex = try data.uint32LE(at: entryOffset + 4)
            guard entrySize >= 8,
                  entryFlags & 0x0001 == 0,
                  let keyName = keyStrings.string(at: keyIndex) else {
                continue
            }
            let valueOffset = entryOffset + entrySize
            guard valueOffset + 8 <= offset + chunkSize else { continue }
            let valueType = data[valueOffset + 3]
            let valueData = try data.uint32LE(at: valueOffset + 4)
            let resourceID = (packageID << 24) | (typeID << 16) | UInt32(item.index)
            let record = Record(
                resourceID: resourceID,
                keyName: keyName,
                valueType: valueType,
                valueData: valueData,
                stringValue: valueType == 0x03 ? globalStrings.string(at: valueData) : nil,
                density: density,
                isDefaultLocale: isDefaultLocale
            )
            records[resourceID, default: []].append(record)
        }
    }
}

private enum APKSignatureReader {
    struct Result {
        let schemes: [String]
        let subject: String?
        let sha256: String?
    }

    private static let signingBlockMagic = Data("APK Sig Block 42".utf8)
    private static let v2ID: UInt32 = 0x7109_871a
    private static let v3ID: UInt32 = 0xf053_68c0
    private static let v31ID: UInt32 = 0x1b93_ad61

    static func inspect(archive: Data, metadataEntries: [String: Data]) -> Result {
        var schemes: [String] = []
        let v1Entry = metadataEntries.first {
            let path = $0.key.lowercased()
            return path.hasPrefix("meta-inf/")
                && (path.hasSuffix(".rsa") || path.hasSuffix(".dsa") || path.hasSuffix(".ec"))
        }
        if v1Entry != nil { schemes.append("V1") }

        var certificateData: Data?
        if let pairs = signingBlockPairs(in: archive) {
            if let value = pairs[v2ID] {
                schemes.append("V2")
                certificateData = certificateData ?? firstCertificate(inSignerSequence: value)
            }
            if let value = pairs[v3ID] {
                schemes.append("V3")
                certificateData = certificateData ?? firstCertificate(inSignerSequence: value)
            }
            if let value = pairs[v31ID] {
                schemes.append("V3.1")
                certificateData = certificateData ?? firstCertificate(inSignerSequence: value)
            }
        }

        if let certificateData {
            let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)
            let subject = certificate.flatMap {
                SecCertificateCopySubjectSummary($0) as String?
            }
            return Result(
                schemes: schemes,
                subject: subject,
                sha256: formattedSHA256(certificateData)
            )
        }
        if let signatureData = v1Entry?.value {
            return Result(
                schemes: schemes,
                subject: nil,
                sha256: formattedSHA256(signatureData)
            )
        }
        return Result(schemes: schemes, subject: nil, sha256: nil)
    }

    private static func signingBlockPairs(in archive: Data) -> [UInt32: Data]? {
        guard let endOffset = findEOCD(in: archive),
              let centralOffset32 = try? archive.uint32LE(at: endOffset + 16) else {
            return nil
        }
        let centralOffset = Int(centralOffset32)
        guard centralOffset >= 24,
              centralOffset <= archive.count,
              archive.subdata(in: centralOffset - 16..<centralOffset) == signingBlockMagic,
              let footerSize = try? uint64LE(archive, at: centralOffset - 24),
              footerSize <= UInt64(Int.max) else {
            return nil
        }
        let blockStart = centralOffset - Int(footerSize) - 8
        guard blockStart >= 0,
              blockStart + 8 <= centralOffset - 24,
              (try? uint64LE(archive, at: blockStart)) == footerSize else {
            return nil
        }
        var pairs: [UInt32: Data] = [:]
        var cursor = blockStart + 8
        let pairsEnd = centralOffset - 24
        while cursor + 8 <= pairsEnd {
            guard let pairSize64 = try? uint64LE(archive, at: cursor),
                  pairSize64 >= 4,
                  pairSize64 <= UInt64(Int.max) else { return nil }
            let pairSize = Int(pairSize64)
            cursor += 8
            guard cursor + pairSize <= pairsEnd,
                  let identifier = try? archive.uint32LE(at: cursor) else {
                return nil
            }
            pairs[identifier] = archive.subdata(in: cursor + 4..<cursor + pairSize)
            cursor += pairSize
        }
        return pairs
    }

    private static func firstCertificate(inSignerSequence data: Data) -> Data? {
        var outerCursor = 0
        guard let signers = readLengthPrefixed(data, cursor: &outerCursor) else { return nil }
        var signersCursor = 0
        guard let signer = readLengthPrefixed(signers, cursor: &signersCursor) else { return nil }
        var signerCursor = 0
        guard let signedData = readLengthPrefixed(signer, cursor: &signerCursor) else { return nil }
        var signedCursor = 0
        guard readLengthPrefixed(signedData, cursor: &signedCursor) != nil,
              let certificates = readLengthPrefixed(signedData, cursor: &signedCursor) else {
            return nil
        }
        var certificatesCursor = 0
        return readLengthPrefixed(certificates, cursor: &certificatesCursor)
    }

    private static func readLengthPrefixed(_ data: Data, cursor: inout Int) -> Data? {
        guard cursor + 4 <= data.count,
              let size32 = try? data.uint32LE(at: cursor) else { return nil }
        cursor += 4
        let size = Int(size32)
        guard size >= 0, cursor + size <= data.count else { return nil }
        defer { cursor += size }
        return data.subdata(in: cursor..<cursor + size)
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if (try? data.uint32LE(at: offset)) == 0x0605_4b50 {
                return offset
            }
        }
        return nil
    }

    private static func uint64LE(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw APKInspectionError.invalidManifest
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func formattedSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

private extension Data {
    func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw APKInspectionError.invalidManifest
        }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
}
