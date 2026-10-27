import Foundation

struct DirectorySyncSummary: Sendable {
    let transferredFiles: Int
    let skippedFiles: Int
    let createdDirectories: Int
}

actor ADBFileService {
    private struct RemoteTreeEntry: Sendable {
        let remotePath: String
        let relativePath: String
        let isDirectory: Bool
        let size: UInt64
        let modifiedAt: Date
    }

    private static let transferChunkSize = 8 * 1024 * 1024
    private static let ddBlockSize = 1024 * 1024

    private let client: ADBMobileClient

    init(client: ADBMobileClient) {
        self.client = client
    }

    func list(path: String) async throws -> [RemoteFile] {
        let output = try await client.list(remotePath: path)
        let files = output.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFile? in
            // AOSP sync ls returns: mode(hex) size(hex) mtime(hex) filename.
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let mode = UInt32(parts[0], radix: 16),
                  let size64 = UInt64(parts[1], radix: 16),
                  let modified = UInt64(parts[2], radix: 16) else { return nil }
            let name = String(parts[3])
            guard name != ".", name != ".." else { return nil }
            return RemoteFile(
                name: name,
                mode: mode,
                size: size64,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(modified))
            )
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let entries = try localTransferEntries(root: localURL)
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.size }
        var completedBytes: UInt64 = 0

        for entry in entries where entry.isDirectory {
            try Task.checkCancellation()
            let destination = appendingRemotePath(entry.relativePath, to: remotePath)
            try await createDirectory(destination)
        }

        for entry in entries where !entry.isDirectory {
            try Task.checkCancellation()
            let destination = appendingRemotePath(entry.relativePath, to: remotePath)
            let parent = (destination as NSString).deletingLastPathComponent
            try await createDirectory(parent)
            let completedBeforeFile = completedBytes
            try await uploadFileResumable(
                localURL: entry.url,
                remotePath: destination
            ) { value in
                let currentBytes = UInt64(Double(entry.size) * value)
                let overall: Double
                if totalBytes == 0 {
                    overall = 1
                } else {
                    overall = Double(completedBeforeFile + currentBytes) / Double(totalBytes)
                }
                await progress(min(max(overall, 0), 1))
            }
            completedBytes += entry.size
        }

        try Task.checkCancellation()
        await progress(1)
    }

    /// Incrementally copies the current iPhone directory into the current TV
    /// directory. Unrelated destination items are intentionally retained.
    func synchronizeLocalDirectory(
        _ localDirectory: URL,
        to remoteDirectory: String,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> DirectorySyncSummary {
        let rootValues = try localDirectory.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard rootValues.isDirectory == true else {
            throw ADBClientError.remoteFailure(
                L10n.string("text.the_selected_folder_could_not_be_read")
            )
        }

        let localEntries = try localTransferEntries(
            root: localDirectory
        ).filter { !$0.relativePath.isEmpty }
        let remoteEntries = try await remoteTransferEntries(
            rootPath: remoteDirectory
        )
        let remoteByPath = Dictionary(
            uniqueKeysWithValues: remoteEntries.map {
                ($0.relativePath, $0)
            }
        )
        let totalBytes = localEntries.reduce(UInt64(0)) {
            $0 + ($1.isDirectory ? 0 : $1.size)
        }
        var completedBytes: UInt64 = 0
        var transferredFiles = 0
        var skippedFiles = 0
        var createdDirectories = 0

        for entry in localEntries where entry.isDirectory {
            try Task.checkCancellation()
            let destination = appendingRemotePath(
                entry.relativePath,
                to: remoteDirectory
            )
            if let existing = remoteByPath[entry.relativePath],
               !existing.isDirectory {
                try await delete(destination)
                try await createDirectory(destination)
                createdDirectories += 1
            } else if remoteByPath[entry.relativePath] == nil {
                try await createDirectory(destination)
                createdDirectories += 1
            }
        }

        for entry in localEntries where !entry.isDirectory {
            try Task.checkCancellation()
            let destination = appendingRemotePath(
                entry.relativePath,
                to: remoteDirectory
            )
            let existing = remoteByPath[entry.relativePath]
            if let existing, existing.isDirectory {
                try await delete(destination)
            }
            let unchanged = existing?.isDirectory == false
                && existing?.size == entry.size
                && abs(
                    (existing?.modifiedAt ?? .distantPast)
                        .timeIntervalSince(entry.modifiedAt)
                ) < 2
            if unchanged {
                skippedFiles += 1
                completedBytes += entry.size
                await progress(
                    totalBytes == 0
                        ? 1
                        : Double(completedBytes) / Double(totalBytes)
                )
                continue
            }

            let parent = (destination as NSString)
                .deletingLastPathComponent
            try await createDirectory(parent)
            let completedBeforeFile = completedBytes
            try await uploadFileResumable(
                localURL: entry.url,
                remotePath: destination
            ) { value in
                let currentBytes = UInt64(
                    Double(entry.size) * value
                )
                await progress(
                    totalBytes == 0
                        ? 1
                        : min(
                            Double(completedBeforeFile + currentBytes)
                                / Double(totalBytes),
                            1
                        )
                )
            }
            transferredFiles += 1
            completedBytes += entry.size
            await preserveRemoteModificationDate(
                entry.modifiedAt,
                at: destination
            )
        }

        await progress(1)
        return DirectorySyncSummary(
            transferredFiles: transferredFiles,
            skippedFiles: skippedFiles,
            createdDirectories: createdDirectories
        )
    }

    /// Incrementally copies the current TV directory into the current iPhone
    /// directory. Unrelated local files are intentionally retained.
    func synchronizeRemoteDirectory(
        _ remoteDirectory: String,
        to localDirectory: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> DirectorySyncSummary {
        try FileManager.default.createDirectory(
            at: localDirectory,
            withIntermediateDirectories: true
        )
        let remoteEntries = try await remoteTransferEntries(
            rootPath: remoteDirectory
        )
        let localEntries = try localTransferEntries(
            root: localDirectory
        ).filter { !$0.relativePath.isEmpty }
        let localByPath = Dictionary(
            uniqueKeysWithValues: localEntries.map {
                ($0.relativePath, $0)
            }
        )
        let totalBytes = remoteEntries.reduce(UInt64(0)) {
            $0 + ($1.isDirectory ? 0 : $1.size)
        }
        var completedBytes: UInt64 = 0
        var transferredFiles = 0
        var skippedFiles = 0
        var createdDirectories = 0

        for entry in remoteEntries where entry.isDirectory {
            try Task.checkCancellation()
            let destination = localDirectory.appendingPathComponent(
                entry.relativePath,
                isDirectory: true
            )
            if let existing = localByPath[entry.relativePath],
               !existing.isDirectory {
                try FileManager.default.removeItem(at: destination)
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                createdDirectories += 1
            } else if localByPath[entry.relativePath] == nil {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                createdDirectories += 1
            }
        }

        for entry in remoteEntries where !entry.isDirectory {
            try Task.checkCancellation()
            let destination = localDirectory.appendingPathComponent(
                entry.relativePath
            )
            if let existing = localByPath[entry.relativePath],
               existing.isDirectory {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = localByPath[entry.relativePath]
            let unchanged = existing?.isDirectory == false
                && existing?.size == entry.size
                && abs(
                    (existing?.modifiedAt ?? .distantPast)
                        .timeIntervalSince(entry.modifiedAt)
                ) < 2
            if unchanged {
                skippedFiles += 1
                completedBytes += entry.size
                await progress(
                    totalBytes == 0
                        ? 1
                        : Double(completedBytes) / Double(totalBytes)
                )
                continue
            }

            let completedBeforeFile = completedBytes
            try await downloadFileResumable(
                remotePath: entry.remotePath,
                remoteSize: entry.size,
                remoteModifiedAt: entry.modifiedAt,
                destination: destination
            ) { value in
                let currentBytes = UInt64(
                    Double(entry.size) * value
                )
                await progress(
                    totalBytes == 0
                        ? 1
                        : min(
                            Double(completedBeforeFile + currentBytes)
                                / Double(totalBytes),
                            1
                        )
                )
            }
            transferredFiles += 1
            completedBytes += entry.size
        }

        await progress(1)
        return DirectorySyncSummary(
            transferredFiles: transferredFiles,
            skippedFiles: skippedFiles,
            createdDirectories: createdDirectories
        )
    }

    func download(
        _ remoteFile: RemoteFile,
        from remotePath: String,
        resumeIdentifier: String,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let cacheRoot = try transferCacheDirectory()
            .appendingPathComponent(stableIdentifier("\(resumeIdentifier)|\(remotePath)"), isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let safeName = sanitizedFilename(remoteFile.name, fallback: remoteFile.isDirectory ? "download" : "download.bin")
        let destination = cacheRoot.appendingPathComponent(safeName, isDirectory: remoteFile.isDirectory)

        if remoteFile.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let manifest = try await remoteTransferEntries(rootPath: remotePath)
            removeStaleDirectoryItems(at: destination, manifest: manifest)
            let totalBytes = manifest.reduce(UInt64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
            var completedBytes: UInt64 = 0

            for entry in manifest where entry.isDirectory {
                try Task.checkCancellation()
                let localDirectory = destination.appendingPathComponent(entry.relativePath, isDirectory: true)
                try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            }

            for entry in manifest where !entry.isDirectory {
                try Task.checkCancellation()
                let localFile = destination.appendingPathComponent(entry.relativePath)
                try FileManager.default.createDirectory(
                    at: localFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let completedBeforeFile = completedBytes
                try await downloadFileResumable(
                    remotePath: entry.remotePath,
                    remoteSize: entry.size,
                    remoteModifiedAt: entry.modifiedAt,
                    destination: localFile
                ) { value in
                    let currentBytes = UInt64(Double(entry.size) * value)
                    let overall: Double
                    if totalBytes == 0 {
                        overall = 1
                    } else {
                        overall = Double(completedBeforeFile + currentBytes) / Double(totalBytes)
                    }
                    await progress(min(max(overall, 0), 1))
                }
                completedBytes += entry.size
            }
        } else {
            try await downloadFileResumable(
                remotePath: remotePath,
                remoteSize: remoteFile.size,
                remoteModifiedAt: remoteFile.modifiedAt,
                destination: destination,
                progress: progress
            )
        }

        try Task.checkCancellation()
        await progress(1)
        return destination
    }

    func createDirectory(_ remotePath: String) async throws {
        let output = try await client.shell("mkdir -p -- \(remotePath.adbShellQuoted) 2>&1")
        try validateShellOutput(output, action: L10n.string("text.create_folder"))
    }

    func delete(_ remotePath: String) async throws {
        let output = try await client.shell("rm -rf -- \(remotePath.adbShellQuoted) 2>&1")
        try validateShellOutput(output, action: L10n.string("text.delete"))
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let output = try await client.shell("mv -- \(oldPath.adbShellQuoted) \(newPath.adbShellQuoted) 2>&1")
        try validateShellOutput(output, action: L10n.string("text.rename"))
    }

    func installAPK(
        data: Data,
        filename: String,
        packageName: String,
        packageABIs: [String],
        replace: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        await progress(0)
        try await validateAPKCompatibility(packageABIs)
        let localURL = try temporaryFile(data: data, preferredName: filename)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        let output = try await installStagedAPKs(
            localURLs: [localURL],
            replace: replace
        )
        try await verifyInstalledPackage(packageName)
        await progress(1)
        return output
    }

    func installAPKSet(
        package: APKPackageArchive,
        expectedPackageName: String?,
        replace: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let entries = try await compatibleAPKEntries(package.apkEntries)
        guard !entries.isEmpty else { throw ZipArchiveError.noAPK }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var urls: [URL] = []
        let total = Double(max(1, entries.count))

        for (index, entry) in entries.enumerated() {
            let safeName = sanitizedFilename(entry.name, fallback: "split-\(index).apk")
            let url = directory.appendingPathComponent("\(index)-\(safeName)")
            try entry.data.write(to: url, options: .atomic)
            urls.append(url)
            await progress(Double(index + 1) / total * 0.15)
        }

        let output = try await installStagedAPKs(
            localURLs: urls,
            replace: replace
        )
        if let expectedPackageName, !expectedPackageName.isEmpty {
            try await verifyInstalledPackage(expectedPackageName)
        }
        await progress(package.obbEntries.isEmpty ? 1 : 0.55)

        for (index, entry) in package.obbEntries.enumerated() {
            let parent = (entry.remotePath as NSString).deletingLastPathComponent
            try await createDirectory(parent)
            let localURL = try temporaryFile(
                data: entry.data,
                preferredName: (entry.archivePath as NSString).lastPathComponent
            )
            defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
            let completedBeforeOBB = Double(index)
            let obbCount = Double(package.obbEntries.count)
            try await uploadFileResumable(
                localURL: localURL,
                remotePath: entry.remotePath
            ) { value in
                let obbProgress = (completedBeforeOBB + value) / obbCount
                await progress(0.55 + obbProgress * 0.45)
            }
        }

        await progress(1)
        if package.obbEntries.isEmpty {
            return output
        }
        return output + "\n" + String(
            format: L10n.string("text.deployed_value_obb_files"),
            package.obbEntries.count
        )
    }

    /// The embedded ADB client's `install` command writes package-manager
    /// failures to process stderr instead of its returned output buffer on
    /// some devices. Stage the APKs and execute `pm` through the shell
    /// protocol so Success/Failure is returned to Swift reliably.
    private func installStagedAPKs(
        localURLs: [URL],
        replace: Bool
    ) async throws -> String {
        guard !localURLs.isEmpty else {
            throw ADBClientError.remoteFailure(
                L10n.string("text.no_installable_apk_was_found")
            )
        }

        let transferID = UUID().uuidString.lowercased()
        let remoteURLs = localURLs.enumerated().map { index, _ in
            "/data/local/tmp/tvadb-install-\(transferID)-\(index).apk"
        }

        do {
            for (localURL, remoteURL) in zip(localURLs, remoteURLs) {
                try Task.checkCancellation()
                _ = try await client.push(
                    localURL: localURL,
                    remotePath: remoteURL
                )
            }

            try Task.checkCancellation()
            var arguments = localURLs.count == 1
                ? ["pm", "install"]
                : ["pm", "install-multiple"]
            if replace {
                arguments.append("-r")
            }
            arguments.append(contentsOf: remoteURLs.map(\.adbShellQuoted))
            let output = try await client.shell(
                arguments.joined(separator: " ") + " 2>&1"
            )
            try validatePackageManagerInstallOutput(output)
            await removeRemoteInstallFiles(remoteURLs)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await removeRemoteInstallFiles(remoteURLs)
            throw error
        }
    }

    private func validatePackageManagerInstallOutput(_ output: String) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.contains("Success") else {
            let reason = trimmed.isEmpty
                ? "TVADB_INSTALL_VERIFICATION_FAILED"
                : trimmed
            throw ADBClientError.remoteFailure(reason)
        }
    }

    private func validateAPKCompatibility(_ packageABIs: [String]) async throws {
        guard !packageABIs.isEmpty else { return }
        let configuration = try await deviceSplitConfiguration()
        let normalizedPackageABIs = Set(packageABIs.map(normalizedSplitName))
        guard !normalizedPackageABIs.isDisjoint(
            with: Set(configuration.supportedABIs)
        ) else {
            throw ADBClientError.remoteFailure(
                "INSTALL_FAILED_NO_MATCHING_ABIS"
            )
        }
    }

    private func verifyInstalledPackage(_ packageName: String) async throws {
        guard !packageName.isEmpty else {
            throw ADBClientError.remoteFailure(
                "TVADB_INSTALL_VERIFICATION_FAILED"
            )
        }
        let output = try await client.shell(
            "pm path \(packageName.adbShellQuoted) 2>&1"
        )
        let installed = output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("package:")
        }
        guard installed else {
            throw ADBClientError.remoteFailure(
                "TVADB_INSTALL_VERIFICATION_FAILED"
            )
        }
    }

    private func removeRemoteInstallFiles(_ remoteURLs: [String]) async {
        guard !remoteURLs.isEmpty else { return }
        let paths = remoteURLs.map(\.adbShellQuoted).joined(separator: " ")
        _ = try? await client.shell("rm -f -- \(paths) 2>/dev/null")
    }

    private func temporaryFile(data: Data, preferredName: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(sanitizedFilename(preferredName, fallback: "upload.bin"))
        try data.write(to: url, options: .atomic)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVADB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sanitizedFilename(_ value: String, fallback: String) -> String {
        let name = (value as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return name.isEmpty || name == "." ? fallback : name
    }

    private func validateShellOutput(_ output: String, action: String) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            throw ADBClientError.remoteFailure(L10n.format("text.value_failed_value", action, trimmed))
        }
    }

    private struct DeviceSplitConfiguration {
        let supportedABIs: [String]
        let density: String
    }

    private func compatibleAPKEntries(_ entries: [APKArchiveEntry]) async throws -> [APKArchiveEntry] {
        if let universal = entries.first(where: {
            $0.name.lowercased() == "universal.apk"
                || $0.archivePath.lowercased().hasSuffix("/universal.apk")
        }) {
            return [universal]
        }

        let configuration = try await deviceSplitConfiguration()
        let standaloneEntries = entries.filter {
            let value = $0.archivePath.lowercased()
            return value.contains("/standalones/") || $0.name.lowercased().hasPrefix("standalone-")
        }
        if !standaloneEntries.isEmpty {
            for abi in configuration.supportedABIs {
                if let match = standaloneEntries.first(where: {
                    detectedABI(in: $0.archivePath) == abi
                }) {
                    return [match]
                }
            }
            if let generic = standaloneEntries.first(where: {
                !containsKnownABI($0.archivePath)
            }) {
                return [generic]
            }
        }

        let densityValues: [String: Int] = [
            "ldpi": 120,
            "mdpi": 160,
            "tvdpi": 213,
            "hdpi": 240,
            "xhdpi": 320,
            "xxhdpi": 480,
            "xxxhdpi": 640
        ]
        let availableDensities = Set(entries.compactMap { detectedDensity(in: $0.archivePath) })
        let preferredDensity: String
        if availableDensities.contains(configuration.density) {
            preferredDensity = configuration.density
        } else {
            let target = densityValues[configuration.density] ?? 320
            preferredDensity = availableDensities.min {
                abs((densityValues[$0] ?? target) - target)
                    < abs((densityValues[$1] ?? target) - target)
            } ?? configuration.density
        }

        return entries.filter { entry in
            let value = normalizedSplitName(entry.archivePath)
            if let abi = detectedABI(in: value),
               !configuration.supportedABIs.contains(abi) {
                return false
            }
            if let density = detectedDensity(in: value),
               density != preferredDensity {
                return false
            }
            return !value.contains("/standalones/")
                && !entry.name.lowercased().hasPrefix("standalone-")
        }
    }

    private func deviceSplitConfiguration() async throws -> DeviceSplitConfiguration {
        let abiOutput = try await client.shell(
            "getprop ro.product.cpu.abilist; getprop ro.product.cpu.abi"
        )
        var abis: [String] = []
        for value in abiOutput
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init) {
            let normalized = normalizedSplitName(value)
            if !normalized.isEmpty, !abis.contains(normalized) {
                abis.append(normalized)
            }
        }
        if abis.isEmpty {
            abis = ["arm64_v8a", "armeabi_v7a"]
        }

        let densityOutput = try await client.shell("wm density")
        let densityValue = densityOutput
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .last ?? 320
        let densityBuckets: [(name: String, value: Int)] = [
            ("ldpi", 120),
            ("mdpi", 160),
            ("tvdpi", 213),
            ("hdpi", 240),
            ("xhdpi", 320),
            ("xxhdpi", 480),
            ("xxxhdpi", 640)
        ]
        let density = densityBuckets.min {
            abs($0.value - densityValue) < abs($1.value - densityValue)
        }?.name ?? "xhdpi"
        return DeviceSplitConfiguration(supportedABIs: abis, density: density)
    }

    private func containsKnownABI(_ value: String) -> Bool {
        detectedABI(in: value) != nil
    }

    private func detectedABI(in value: String) -> String? {
        let normalized = normalizedSplitName(value)
        return ["armeabi_v7a", "arm64_v8a", "x86_64", "armeabi", "x86"]
            .first(where: normalized.contains)
    }

    private func detectedDensity(in value: String) -> String? {
        let normalized = normalizedSplitName(value)
        return ["xxxhdpi", "xxhdpi", "xhdpi", "tvdpi", "hdpi", "mdpi", "ldpi"]
            .first(where: normalized.contains)
    }

    private func normalizedSplitName(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private struct LocalTransferEntry {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        let size: UInt64
        let modifiedAt: Date
    }

    private func localTransferEntries(root: URL) throws -> [LocalTransferEntry] {
        let values = try root.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
        )
        guard values.isDirectory == true else {
            return [LocalTransferEntry(
                url: root,
                relativePath: "",
                isDirectory: false,
                size: UInt64(max(values.fileSize ?? 0, 0)),
                modifiedAt: values.contentModificationDate
                    ?? .distantPast
            )]
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ADBClientError.remoteFailure(L10n.string("text.the_selected_folder_could_not_be_read"))
        }

        var entries: [LocalTransferEntry] = [
            LocalTransferEntry(
                url: root,
                relativePath: "",
                isDirectory: true,
                size: 0,
                modifiedAt: values.contentModificationDate
                    ?? .distantPast
            )
        ]
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: keys)
            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = String(url.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            if resourceValues.isDirectory == true {
                entries.append(LocalTransferEntry(
                    url: url,
                    relativePath: relativePath,
                    isDirectory: true,
                    size: 0,
                    modifiedAt: resourceValues
                        .contentModificationDate ?? .distantPast
                ))
            } else if resourceValues.isRegularFile == true {
                entries.append(LocalTransferEntry(
                    url: url,
                    relativePath: relativePath,
                    isDirectory: false,
                    size: UInt64(max(resourceValues.fileSize ?? 0, 0)),
                    modifiedAt: resourceValues
                        .contentModificationDate ?? .distantPast
                ))
            }
        }
        return entries
    }

    private func preserveRemoteModificationDate(
        _ date: Date,
        at remotePath: String
    ) async {
        let seconds = Int64(date.timeIntervalSince1970)
        _ = try? await client.shell(
            "touch -m -d @\(seconds) -- "
                + "\(remotePath.adbShellQuoted) 2>/dev/null"
        )
    }

    private func uploadFileResumable(
        localURL: URL,
        remotePath: String,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let totalSize = UInt64(max(values.fileSize ?? 0, 0))
        let remotePartial = remotePath + ".tvadb.part"
        let remoteChunk = remotePath + ".tvadb.chunk"
        let remoteMetadata = remotePath + ".tvadb.meta"
        let fingerprint = try localFileFingerprint(localURL, size: totalSize)
        let savedFingerprint = try await client.shell(
            "if [ -f \(remoteMetadata.adbShellQuoted) ]; then cat \(remoteMetadata.adbShellQuoted) 2>/dev/null; fi"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var offset = try await remoteSize(at: remotePartial) ?? 0

        if savedFingerprint != fingerprint
            || offset > totalSize
            || (offset != totalSize && offset % UInt64(Self.transferChunkSize) != 0) {
            _ = try? await client.shell(
                "rm -f \(remotePartial.adbShellQuoted) \(remoteChunk.adbShellQuoted) \(remoteMetadata.adbShellQuoted)"
            )
            offset = 0
        }

        if offset == 0 {
            let output = try await client.shell(
                "printf %s \(fingerprint.adbShellQuoted) > \(remoteMetadata.adbShellQuoted)"
                    + " && : > \(remotePartial.adbShellQuoted) 2>&1"
            )
            try validateShellOutput(output, action: L10n.string("text.prepare_upload"))
        }

        if totalSize == 0 {
            let output = try await client.shell(
                "mv -f \(remotePartial.adbShellQuoted) \(remotePath.adbShellQuoted)"
                    + " && rm -f \(remoteMetadata.adbShellQuoted) 2>&1"
            )
            try validateShellOutput(output, action: L10n.string("text.complete_upload"))
            await progress(1)
            return
        }

        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        let stagingDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let localChunk = stagingDirectory.appendingPathComponent("chunk")

        while offset < totalSize {
            try Task.checkCancellation()
            let remaining = totalSize - offset
            let count = Int(min(UInt64(Self.transferChunkSize), remaining))
            guard let data = try file.read(upToCount: count), !data.isEmpty else {
                throw ADBClientError.remoteFailure(L10n.string("text.the_local_file_ended_unexpectedly_while_reading"))
            }
            try data.write(to: localChunk, options: .atomic)
            _ = try await client.push(localURL: localChunk, remotePath: remoteChunk)
            let appendOutput = try await client.shell(
                "cat \(remoteChunk.adbShellQuoted) >> \(remotePartial.adbShellQuoted) && rm -f \(remoteChunk.adbShellQuoted) 2>&1"
            )
            try validateShellOutput(appendOutput, action: L10n.string("text.write_upload_chunk"))
            offset += UInt64(data.count)
            await progress(Double(offset) / Double(totalSize))
        }

        try Task.checkCancellation()
        let finalizeOutput = try await client.shell(
            "mv -f \(remotePartial.adbShellQuoted) \(remotePath.adbShellQuoted)"
                + " && rm -f \(remoteMetadata.adbShellQuoted) 2>&1"
        )
        try validateShellOutput(finalizeOutput, action: L10n.string("text.complete_upload"))
    }

    private func downloadFileResumable(
        remotePath: String,
        remoteSize: UInt64,
        remoteModifiedAt: Date,
        destination: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let partial = downloadPartialURL(
            for: destination,
            remoteSize: remoteSize,
            remoteModifiedAt: remoteModifiedAt
        )
        let existingFinalSize = localFileSize(destination)
        let existingFinalDate = try? destination.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if existingFinalSize == remoteSize,
           let existingFinalDate,
           abs(existingFinalDate.timeIntervalSince(remoteModifiedAt)) < 1 {
            await progress(1)
            return
        }
        if existingFinalSize != nil {
            try? FileManager.default.removeItem(at: destination)
        }
        removeStalePartials(for: destination, keeping: partial)

        var offset = localFileSize(partial) ?? 0
        if offset > remoteSize
            || (offset != remoteSize && offset % UInt64(Self.transferChunkSize) != 0) {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }

        if remoteSize == 0 {
            try replaceItem(at: destination, with: partial)
            try FileManager.default.setAttributes(
                [.modificationDate: remoteModifiedAt],
                ofItemAtPath: destination.path
            )
            await progress(1)
            return
        }

        let remoteChunk = "/data/local/tmp/.tvadb-pull-\(UUID().uuidString).chunk"
        let localChunk = partial.deletingLastPathComponent()
            .appendingPathComponent(".tvadb-pull-\(UUID().uuidString).chunk")
        let output = try FileHandle(forWritingTo: partial)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: localChunk)
        }
        try output.seekToEnd()

        do {
            while offset < remoteSize {
                try Task.checkCancellation()
                let skipBlocks = offset / UInt64(Self.ddBlockSize)
                let ddOutput = try await client.shell(
                    "dd if=\(remotePath.adbShellQuoted) of=\(remoteChunk.adbShellQuoted) bs=\(Self.ddBlockSize) skip=\(skipBlocks) count=8 2>/dev/null"
                )
                try validateShellOutput(ddOutput, action: L10n.string("text.prepare_download_chunk"))
                _ = try await client.pull(remotePath: remoteChunk, localURL: localChunk)
                let chunkSize = localFileSize(localChunk) ?? 0
                guard chunkSize > 0 else {
                    throw ADBClientError.remoteFailure(L10n.string("text.android_returned_an_empty_download_chunk"))
                }
                try appendFile(localChunk, to: output)
                offset += chunkSize
                try? FileManager.default.removeItem(at: localChunk)
                _ = try? await client.shell("rm -f \(remoteChunk.adbShellQuoted)")
                await progress(min(Double(offset) / Double(remoteSize), 1))
            }
        } catch is CancellationError {
            _ = try? await client.shell(
                "rm -f \(remoteChunk.adbShellQuoted)"
            )
            throw CancellationError()
        } catch {
            _ = try? await client.shell("rm -f \(remoteChunk.adbShellQuoted)")
            if offset == 0 {
                try? output.close()
                try? FileManager.default.removeItem(at: partial)
                _ = try await client.pull(remotePath: remotePath, localURL: partial)
            } else {
                throw error
            }
        }

        try Task.checkCancellation()
        guard localFileSize(partial) == remoteSize else {
            throw ADBClientError.remoteFailure(L10n.string("text.the_downloaded_file_size_does_not_match_the_file_on_the_tv"))
        }
        try? output.close()
        try replaceItem(at: destination, with: partial)
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: destination.path
        )
    }

    private func remoteTransferEntries(rootPath: String) async throws -> [RemoteTreeEntry] {
        var entries: [RemoteTreeEntry] = []
        try await appendRemoteEntries(
            remoteDirectory: rootPath,
            relativeDirectory: "",
            entries: &entries
        )
        return entries
    }

    private func appendRemoteEntries(
        remoteDirectory: String,
        relativeDirectory: String,
        entries: inout [RemoteTreeEntry]
    ) async throws {
        for file in try await list(path: remoteDirectory) {
            guard !file.name.contains("/"), !file.name.contains("\0") else { continue }
            let remote = appendingRemotePath(file.name, to: remoteDirectory)
            let relative = relativeDirectory.isEmpty
                ? file.name
                : "\(relativeDirectory)/\(file.name)"
            entries.append(RemoteTreeEntry(
                remotePath: remote,
                relativePath: relative,
                isDirectory: file.isDirectory,
                size: file.size,
                modifiedAt: file.modifiedAt
            ))
            if file.isDirectory {
                try await appendRemoteEntries(
                    remoteDirectory: remote,
                    relativeDirectory: relative,
                    entries: &entries
                )
            }
        }
    }

    private func remoteSize(at path: String) async throws -> UInt64? {
        let output = try await client.shell(
            "if [ -f \(path.adbShellQuoted) ]; then (stat -c %s \(path.adbShellQuoted) 2>/dev/null || wc -c < \(path.adbShellQuoted)); else echo -1; fi"
        )
        let value = output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    private func localFileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else {
            return nil
        }
        return value.uint64Value
    }

    private func localFileFingerprint(_ url: URL, size: UInt64) throws -> String {
        let modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?
            .timeIntervalSince1970 ?? 0
        var hash: UInt64 = 14_695_981_039_346_656_037
        func include<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        include("\(size)|\(modifiedAt)|".utf8)

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let sampleSize = 64 * 1024
        if let first = try input.read(upToCount: sampleSize) {
            include(first)
        }
        if size > UInt64(sampleSize) {
            try input.seek(toOffset: size - UInt64(sampleSize))
            if let last = try input.read(upToCount: sampleSize) {
                include(last)
            }
        }
        return String(hash, radix: 16)
    }

    private func removeStalePartials(for destination: URL, keeping current: URL) {
        let directory = destination.deletingLastPathComponent()
        let prefix = destination.lastPathComponent + ".tvadb."
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for candidate in candidates
        where candidate != current
            && candidate.lastPathComponent.hasPrefix(prefix)
            && candidate.pathExtension == "part" {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private func downloadPartialURL(
        for destination: URL,
        remoteSize: UInt64,
        remoteModifiedAt: Date
    ) -> URL {
        let version = "\(remoteSize)|\(Int64(remoteModifiedAt.timeIntervalSince1970))"
        let versionID = stableIdentifier(version)
        return destination.appendingPathExtension("tvadb.\(versionID).part")
    }

    private func removeStaleDirectoryItems(
        at destination: URL,
        manifest: [RemoteTreeEntry]
    ) {
        var allowedPaths = Set(manifest.map(\.relativePath))
        for entry in manifest where !entry.isDirectory {
            let localURL = destination.appendingPathComponent(entry.relativePath)
            let partialURL = downloadPartialURL(
                for: localURL,
                remoteSize: entry.size,
                remoteModifiedAt: entry.modifiedAt
            )
            let relativePartial = String(
                partialURL.path.dropFirst(destination.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            allowedPaths.insert(relativePartial)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let existingURLs = enumerator.compactMap { $0 as? URL }.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }
        for url in existingURLs {
            let relativePath = String(
                url.path.dropFirst(destination.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !allowedPaths.contains(relativePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func appendFile(_ source: URL, to destination: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try destination.write(contentsOf: data)
        }
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func transferCacheDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TVADBTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func appendingRemotePath(_ relativePath: String, to root: String) -> String {
        guard !relativePath.isEmpty else { return root }
        if root == "/" { return "/" + relativePath }
        return root + "/" + relativePath
    }
}
