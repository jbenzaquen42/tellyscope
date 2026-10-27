import Foundation
import OSLog

enum AndroidMouseButton: Int, Sendable {
    case left = 1
    case right = 2
    case middle = 4

    var linuxInputCode: Int {
        switch self {
        case .left: 272
        case .right: 273
        case .middle: 274
        }
    }
}

actor ADBCommandService {
    private enum VirtualMouseBackend: Sendable {
        case bundledUHID
        case aospUInput
        case bundledUInput
    }

    private let client: ADBMobileClient
    private let iconHelperLogger = Logger(
        subsystem: "com.tvadb.ios",
        category: "IconHelper"
    )
    private let screenRecordingLogger = Logger(
        subsystem: "com.tvadb.ios",
        category: "ScreenRecording"
    )
    private let mouseLogger = Logger(
        subsystem: "com.tvadb.ios",
        category: "VirtualMouse"
    )
    private var iconHelperAvailable: Bool?
    private var androidHelperUploaded = false
    private let remoteIconHelperPath = "/data/local/tmp/tvadb-icon-helper-v1.dex"
    private var virtualMouseAvailable: Bool?
    private var virtualMouseActive = false
    private var virtualMouseBackend: VirtualMouseBackend?
    private var virtualMouseDisplayAssociationAvailable: Bool?
    private var virtualMouseDisplayAssociated = false
    private var virtualMouseHelperUploaded = false
    private var virtualMouseStream: ADBPersistentShellSession?
    private var virtualMouseStreamAvailable: Bool?
    private var virtualMousePosition: (x: Int, y: Int)?
    private var coordinateTouchMode = false
    private let virtualMouseName = "TVADB Virtual Mouse"
    private let virtualMouseInputPort = "tvadb:virtual-mouse"
    private let remoteVirtualMouseHelperPath =
        "/data/local/tmp/tvadb-virtual-mouse-v1"
    private let virtualMouseFIFOPath =
        "/data/local/tmp/.tvadb-virtual-mouse.fifo"
    private let virtualMousePIDPath =
        "/data/local/tmp/.tvadb-virtual-mouse.pid"
    private let virtualMouseWriterPIDPath =
        "/data/local/tmp/.tvadb-virtual-mouse-writer.pid"
    private let virtualMouseLogPath =
        "/data/local/tmp/.tvadb-virtual-mouse.log"

    init(client: ADBMobileClient) {
        self.client = client
        Self.cleanupStaleScreenshotTemporaryDirectories()
        Self.cleanupStaleRecordingCache()
    }

    func listApplications() async throws -> [AndroidApp] {
        // `-f` returns the base APK path together with the package name. Apart
        // from removing one `pm path` round trip per row, the path changes when
        // an application is updated and therefore doubles as a cache version.
        let users = try await client.shell("pm list packages -3 -f")
        let systems = try await client.shell("pm list packages -s -f")
        let userApps = parsePackages(users, isSystem: false)
        let systemApps = parsePackages(systems, isSystem: true)
        return (userApps + systemApps).sorted {
            $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending
        }
    }

    func resetSessionCapabilities() async {
        await closeVirtualMouseStream()
        iconHelperAvailable = nil
        androidHelperUploaded = false
        virtualMouseAvailable = nil
        virtualMouseActive = false
        virtualMouseBackend = nil
        virtualMouseDisplayAssociationAvailable = nil
        virtualMouseDisplayAssociated = false
        virtualMouseHelperUploaded = false
        virtualMouseStreamAvailable = nil
        virtualMousePosition = nil
        coordinateTouchMode = false
    }

    func cleanupSessionArtifacts() async {
        await stopVirtualMouse()
        _ = try? await client.shell(
            "rm -f /data/local/tmp/.tvadb-screenshot-*.png"
        )
        _ = try? await client.shell(
            "rm -rf /data/local/tmp/.tvadb-recording-*"
        )
        if androidHelperUploaded {
            _ = try? await client.shell("rm -f \(remoteIconHelperPath.adbShellQuoted)")
        }
        if virtualMouseHelperUploaded {
            _ = try? await client.shell(
                "rm -f \(remoteVirtualMouseHelperPath.adbShellQuoted)"
            )
        }
        iconHelperAvailable = nil
        androidHelperUploaded = false
        virtualMouseAvailable = nil
        virtualMouseDisplayAssociationAvailable = nil
        virtualMouseDisplayAssociated = false
        coordinateTouchMode = false
        virtualMouseHelperUploaded = false
    }

    func launch(packageName: String) async throws -> String {
        let output = try await client.shell(
            "monkey -p \(packageName.adbShellQuoted) -c android.intent.category.LAUNCHER 1 2>&1"
        )
        try validateCommandOutput(output)
        return L10n.format("text.launched_value", packageName)
    }

    func openApplicationDetails(packageName: String) async throws -> String {
        let output = try await client.shell(
            "am start -a android.settings.APPLICATION_DETAILS_SETTINGS"
                + " -d \(("package:" + packageName).adbShellQuoted) 2>&1"
        )
        try validateCommandOutput(output)
        return L10n.string("text.application_details_opened")
    }

    func forceStop(packageName: String) async throws {
        let output = try await client.shell(
            "am force-stop \(packageName.adbShellQuoted) 2>&1"
        )
        try validateCommandOutput(output)
    }

    func clearCache(packageName: String) async throws -> String {
        let output = try await client.shell(
            "pm clear --cache-only \(packageName.adbShellQuoted) 2>&1"
        )
        let normalized = output.lowercased()
        if normalized.contains("unknown option")
            || normalized.contains("unrecognized option")
            || normalized.contains("usage: pm clear") {
            throw ADBClientError.remoteFailure("TVADB_CACHE_CLEAR_UNSUPPORTED")
        }
        try validateCommandOutput(output)
        return L10n.string("text.cache_cleared")
    }

    func clearData(packageName: String) async throws -> String {
        let output = try await client.shell(
            "pm clear \(packageName.adbShellQuoted) 2>&1"
        )
        try validateCommandOutput(output)
        return L10n.string("text.app_data_cleared")
    }

    func uninstall(packageName: String) async throws -> String {
        let output = try await client.shell(
            "pm uninstall \(packageName.adbShellQuoted) 2>&1"
        )
        try validateCommandOutput(output)
        return L10n.string("text.app_uninstalled")
    }

    func apkPaths(packageName: String) async throws -> [String] {
        let output = try await client.shell("pm path \(packageName.adbShellQuoted)")
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            guard value.hasPrefix("package:") else { return nil }
            return String(value.dropFirst("package:".count))
        }
    }

    /// Resolves labels, versions and rendered icons in batches on the Android
    /// device through PackageManager. The helper is an install-free DEX run by
    /// app_process as the already-authorized ADB shell user.
    func inspectInstalledApplicationsWithHelper(
        _ apps: [AndroidApp]
    ) async -> [String: InstalledAppPresentation] {
        guard !apps.isEmpty, await prepareIconHelper() else { return [:] }

        var presentations: [String: InstalledAppPresentation] = [:]
        // Rendered PNG icons make the response much larger than normal shell
        // output. Keep each exec-out result comfortably below vendor/bridge
        // buffer limits instead of waiting for one multi-megabyte response.
        let batchSize = 8
        for start in stride(from: 0, to: apps.count, by: batchSize) {
            let end = min(start + batchSize, apps.count)
            let batch = apps[start..<end]
            let packageArguments = batch
                .map { $0.packageName.adbShellQuoted }
                .joined(separator: " ")
            let command = "CLASSPATH=\(remoteIconHelperPath.adbShellQuoted) "
                + "app_process / com.tvadb.helper.AppPresentationHelper "
                + packageArguments
                + " 2>/dev/null"

            do {
                // Some TV adbd builds return an empty payload for app_process
                // through exec-out even though the same process writes valid
                // stdout over the normal shell service. The protocol is
                // Base64 text, so shell is the compatible transport here.
                let responseText = try await client.shell(command)
                let response = Data(responseText.utf8)
                let parsed = Self.parseIconHelperResponse(response)
                guard parsed.isValid else {
                    iconHelperLogger.error(
                        "Invalid helper response (\(response.count, privacy: .public) bytes)"
                    )
#if DEBUG
                    let diagnostic = String(
                        decoding: response.prefix(1_024),
                        as: UTF8.self
                    )
                    print("[TVADB IconHelper] Invalid response: \(diagnostic)")
#endif
                    iconHelperAvailable = false
                    break
                }
#if DEBUG
                print(
                    "[TVADB IconHelper] Resolved "
                        + "\(parsed.presentations.count)/\(batch.count) applications"
                )
#endif
                iconHelperLogger.debug(
                    "Resolved \(parsed.presentations.count, privacy: .public)/\(batch.count, privacy: .public) applications"
                )
                presentations.merge(parsed.presentations) { _, newest in newest }
            } catch {
                iconHelperLogger.error(
                    "Execution failed: \(error.localizedDescription, privacy: .public)"
                )
#if DEBUG
                print("[TVADB IconHelper] Execution failed: \(error)")
#endif
                iconHelperAvailable = false
                break
            }
        }
        return presentations
    }

    private func prepareIconHelper() async -> Bool {
        if iconHelperAvailable == false { return false }

        do {
            guard try await prepareAndroidHelperResource() else {
                iconHelperLogger.error("Helper upload could not be verified")
                iconHelperAvailable = false
                return false
            }
            iconHelperLogger.debug("Helper uploaded and ready")
            iconHelperAvailable = true
            return true
        } catch {
            iconHelperLogger.error(
                "Upload failed: \(error.localizedDescription, privacy: .public)"
            )
#if DEBUG
            print("[TVADB IconHelper] Upload failed: \(error)")
#endif
            iconHelperAvailable = false
            return false
        }
    }

    private func prepareAndroidHelperResource() async throws -> Bool {
        if androidHelperUploaded { return true }
        guard let localURL = Bundle.main.url(
            forResource: "TVADBIconHelper",
            withExtension: "dex"
        ) else {
            return false
        }

        _ = try await client.push(
            localURL: localURL,
            remotePath: remoteIconHelperPath
        )
        let output = try await client.shell(
            "chmod 600 \(remoteIconHelperPath.adbShellQuoted)"
                + " && echo TVADB_HELPER_READY"
        )
        guard output.contains("TVADB_HELPER_READY") else {
            return false
        }
        androidHelperUploaded = true
        return true
    }

    private nonisolated static func parseIconHelperResponse(
        _ data: Data
    ) -> (
        isValid: Bool,
        presentations: [String: InstalledAppPresentation]
    ) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(
            whereSeparator: \.isNewline
        ).map(String.init)
        guard lines.first == "TVADB_ICON_HELPER_V1" else {
            return (false, [:])
        }

        var presentations: [String: InstalledAppPresentation] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard fields.count == 5,
                  fields[0] == "A",
                  let packageName = decodeIconHelperString(fields[1]),
                  let label = decodeIconHelperString(fields[2]),
                  let versionName = decodeIconHelperString(fields[3]),
                  let iconBytes = Data(base64Encoded: String(fields[4])) else {
                continue
            }
            presentations[packageName] = InstalledAppPresentation(
                name: label.isEmpty ? packageName : label,
                iconData: iconBytes.isEmpty ? nil : iconBytes,
                versionName: versionName
            )
        }
        return (true, presentations)
    }

    private nonisolated static func decodeIconHelperString(
        _ value: Substring
    ) -> String? {
        guard let data = Data(base64Encoded: String(value)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportApplication(packageName: String) async throws -> URL {
        let paths = try await apkPaths(packageName: packageName)
        guard !paths.isEmpty else {
            throw ADBClientError.remoteFailure(L10n.string("text.no_application_apk_was_found"))
        }
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TVADBAppExports", isDirectory: true)
        let exportRoot = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safePackageName = packageName.replacingOccurrences(of: "/", with: "_")
        let packageDirectory = exportRoot.appendingPathComponent(safePackageName, isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        do {
            var localFiles: [URL] = []
            var usedFilenames: Set<String> = []
            for (index, remotePath) in paths.enumerated() {
                var filename = (remotePath as NSString).lastPathComponent
                if filename.isEmpty {
                    filename = index == 0 ? "base.apk" : "split-\(index).apk"
                }
                if usedFilenames.contains(filename) {
                    filename = "\(index)-\(filename)"
                }
                usedFilenames.insert(filename)
                let localURL = packageDirectory.appendingPathComponent(filename)
                _ = try await client.pull(remotePath: remotePath, localURL: localURL)
                localFiles.append(localURL)
            }
            if localFiles.count == 1, let file = localFiles.first {
                let exportedFile = exportRoot.appendingPathComponent("\(safePackageName).apk")
                try FileManager.default.moveItem(at: file, to: exportedFile)
                try? FileManager.default.removeItem(at: packageDirectory)
                return exportedFile
            }
            return packageDirectory
        } catch {
            try? FileManager.default.removeItem(at: exportRoot)
            throw error
        }
    }

    func sendKey(_ code: Int) async throws {
        _ = try await client.shell("input keyevent \(code)")
    }

    func sendText(_ text: String) async throws {
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                let output = try await client.shell(
                    "input text \(line.adbShellQuoted) 2>&1"
                )
                try validateCommandOutput(output)
            }
            if index < lines.count - 1 {
                try await sendKey(66)
            }
        }
    }

    func screenRotation() async throws -> Int? {
        let inputOutput = try await client.shell(
            "dumpsys input 2>/dev/null"
                + " | grep -m 1 'SurfaceOrientation'"
        )
        if let rotation = Self.parseScreenRotation(inputOutput) {
            return rotation
        }

        let windowOutput = try await client.shell(
            "dumpsys window displays 2>/dev/null"
                + " | grep -m 1 -E 'mRotation=|mCurrentRotation='"
        )
        return Self.parseScreenRotation(windowOutput)
    }

    func synchronizeVirtualMousePosition(x: Int, y: Int) {
        guard virtualMouseActive else { return }
        virtualMousePosition = (x, y)
    }

    func screenSize() async throws -> (width: Int, height: Int) {
        let output = try await client.shell("wm size")
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            for token in line.split(whereSeparator: \.isWhitespace).reversed() {
                let dimensions = token.split(separator: "x", maxSplits: 1)
                if dimensions.count == 2,
                   let width = Int(dimensions[0]),
                   let height = Int(dimensions[1]),
                   width > 0, height > 0 {
                    return (width, height)
                }
            }
        }
        throw ADBClientError.remoteFailure(L10n.string("text.the_tv_resolution_could_not_be_read"))
    }

    /// Registers a kernel-level virtual mouse. Prefer `/dev/uhid`, which
    /// passes a standard mouse report descriptor through Linux's HID
    /// subsystem and is the closest wireless equivalent to a physical mouse.
    /// Fall back to AOSP `uinput`, then TVADB's direct `/dev/uinput` helper.
    func prepareVirtualMouse(
        screenWidth: Int,
        screenHeight: Int
    ) async -> Bool {
        let center = (
            x: max(screenWidth, 1) / 2,
            y: max(screenHeight, 1) / 2
        )
        if virtualMouseActive {
            let current = virtualMousePosition ?? (x: 0, y: 0)
            let deltaX = center.x - current.x
            let deltaY = center.y - current.y
            if deltaX != 0 || deltaY != 0 {
                do {
                    try await sendVirtualMouseMove(
                        deltaX: deltaX,
                        deltaY: deltaY
                    )
                    virtualMousePosition = center
                } catch {
                    mouseLogger.notice(
                        "Existing virtual mouse could not be recentered"
                    )
                }
            }
            return true
        }
        if virtualMouseAvailable == false {
            return false
        }

        await stopVirtualMouse()

        do {
            let capability = try await client.shell(
                "if command -v mkfifo >/dev/null 2>&1"
                    + " && command -v tail >/dev/null 2>&1;"
                    + " then"
                    + " if test -r /dev/uhid && test -w /dev/uhid;"
                    + " then echo TVADB_UHID_AVAILABLE; fi;"
                    + " if command -v uinput >/dev/null 2>&1;"
                    + " then echo TVADB_AOSP_UINPUT_AVAILABLE; fi;"
                    + " if test -w /dev/uinput;"
                    + " then echo TVADB_RAW_UINPUT_AVAILABLE; fi;"
                    + " fi"
            )

            if await isDesktopAndroidEmulator() {
                // MuMu and several other desktop emulators render their visible
                // cursor in the host process. ADB-created UHID/uinput devices
                // still produce Android hover highlights, but the host never
                // draws an arrow and may discard their mouse-button actions.
                // Keep the position locally and use reliable absolute
                // touchscreen taps instead of leaving an invisible hover
                // device active.
                coordinateTouchMode = true
                mouseLogger.notice(
                    "Host-rendered emulator cursor detected; using coordinate touch mode"
                )
                return false
            }

            if capability.contains("TVADB_UHID_AVAILABLE"),
               await prepareVirtualMouseDisplayAssociation(),
               await prepareBundledVirtualMouseHelper(
                    requiredDeviceNode: "/dev/uhid"
               ) {
                let backend = await startVirtualMouseBackend(
                    preferredBackend: .bundledUHID,
                    readerScript:
                        "exec \(remoteVirtualMouseHelperPath.adbShellQuoted)"
                        + " < \(virtualMouseFIFOPath.adbShellQuoted)",
                    registrationEvent: nil
                )
                if let backend {
                    if case .bundledUInput = backend {
                        await removeVirtualMouseDisplayAssociation()
                    }
                    await activateVirtualMouse(
                        backend: backend,
                        center: center
                    )
                    return true
                }
                mouseLogger.notice(
                    "UHID registration failed; trying uinput fallback"
                )
            }

            // An association is only useful for a UHID device whose `phys`
            // port matches it. Remove it before trying uinput so a failed UHID
            // attempt never leaves stale display routing behind.
            await removeVirtualMouseDisplayAssociation()

            if capability.contains("TVADB_AOSP_UINPUT_AVAILABLE") {
                if await prepareAOSPVirtualMouse(center: center) {
                    return true
                }
                mouseLogger.notice(
                    "AOSP uinput registration failed; trying bundled helper"
                )
            }

            if capability.contains("TVADB_RAW_UINPUT_AVAILABLE"),
               await prepareBundledVirtualMouseHelper(
                    requiredDeviceNode: "/dev/uinput"
               ) {
                let backend = await startVirtualMouseBackend(
                    preferredBackend: .bundledUInput,
                    readerScript:
                        "exec \(remoteVirtualMouseHelperPath.adbShellQuoted)"
                        + " < \(virtualMouseFIFOPath.adbShellQuoted)",
                    registrationEvent: nil
                )
                if let backend {
                    await activateVirtualMouse(
                        backend: backend,
                        center: center
                    )
                    return true
                }
            }

            mouseLogger.error("No usable UHID or uinput mouse backend")
            virtualMouseAvailable = false
            return false
        } catch {
            mouseLogger.error(
                "Virtual mouse preparation failed: \(error.localizedDescription, privacy: .public)"
            )
            await stopVirtualMouse()
            virtualMouseAvailable = false
            return false
        }
    }

    /// PC Android emulators commonly replace Android's pointer sprite with a
    /// host-rendered cursor and only partially implement UHID/uinput events.
    /// Detect them so the caller can use absolute coordinate touches without
    /// leaving an invisible Android hover device active.
    private func isDesktopAndroidEmulator() async -> Bool {
        do {
            let output = try await client.shell(
                "printf '%s\\n' \"$(getprop ro.build.hv.platform)\";"
                    + " if command -v nemuinput >/dev/null 2>&1;"
                    + " then echo nemuinput; fi"
            )
            let normalized = output.lowercased()
            let emulatorMarkers = [
                "vbox",
                "qemu",
                "ranchu",
                "goldfish",
                "nemuinput"
            ]
            let isEmulator = emulatorMarkers.contains {
                normalized.contains($0)
            }
            if isEmulator {
                mouseLogger.notice(
                    "Desktop Android emulator detected"
                )
            }
            return isEmulator
        } catch {
            return false
        }
    }

    private func prepareAOSPVirtualMouse(
        center: (x: Int, y: Int)
    ) async -> Bool {
        let backend = await startVirtualMouseBackend(
            preferredBackend: .aospUInput,
            readerScript:
                "exec uinput - < \(virtualMouseFIFOPath.adbShellQuoted)",
            registrationEvent: Self.virtualMouseRegisterEvent(
                name: virtualMouseName
            )
        )
        guard let backend else { return false }
        await activateVirtualMouse(
            backend: backend,
            center: center
        )
        return true
    }

    /// Android 15 routes independent cursors per display. A UHID mouse whose
    /// `phys` port is not associated may be fully recognized while InputReader
    /// assigns it to display -1, leaving only a clipped shadow at the origin.
    /// Older Android versions use their existing single-pointer routing.
    private func prepareVirtualMouseDisplayAssociation() async -> Bool {
        if virtualMouseDisplayAssociationAvailable == false {
            return false
        }

        do {
            let sdkOutput = try await client.shell(
                "getprop ro.build.version.sdk"
            )
            let sdk = Int(
                sdkOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 0
            guard sdk >= 35 else {
                return true
            }
            guard try await prepareAndroidHelperResource() else {
                mouseLogger.error(
                    "Android display-association helper is missing"
                )
                virtualMouseDisplayAssociationAvailable = false
                return false
            }

            let command =
                "CLASSPATH=\(remoteIconHelperPath.adbShellQuoted) "
                + "app_process / "
                + "com.tvadb.helper.MouseDisplayAssociation add "
                + "\(virtualMouseInputPort.adbShellQuoted) 0"
                + " 2>/dev/null"
            let output = try await client.shell(command)
            guard output.contains("TVADB_MOUSE_ASSOCIATION_READY") else {
                mouseLogger.error(
                    "Android rejected UHID display association: \(output, privacy: .public)"
                )
                virtualMouseDisplayAssociationAvailable = false
                return false
            }
            virtualMouseDisplayAssociationAvailable = true
            virtualMouseDisplayAssociated = true
            mouseLogger.notice(
                "UHID mouse associated with Android display 0"
            )
            return true
        } catch {
            mouseLogger.error(
                "UHID display association failed: \(error.localizedDescription, privacy: .public)"
            )
            virtualMouseDisplayAssociationAvailable = false
            virtualMouseDisplayAssociated = false
            return false
        }
    }

    private func removeVirtualMouseDisplayAssociation() async {
        guard virtualMouseDisplayAssociated else { return }
        defer { virtualMouseDisplayAssociated = false }
        guard androidHelperUploaded else { return }

        let command =
            "CLASSPATH=\(remoteIconHelperPath.adbShellQuoted) "
            + "app_process / "
            + "com.tvadb.helper.MouseDisplayAssociation remove "
            + virtualMouseInputPort.adbShellQuoted
            + " 2>/dev/null"
        do {
            let output = try await client.shell(command)
            if !output.contains("TVADB_MOUSE_ASSOCIATION_REMOVED") {
                mouseLogger.notice(
                    "UHID display association cleanup was not confirmed"
                )
            }
        } catch {
            mouseLogger.notice(
                "UHID display association cleanup failed after disconnect"
            )
        }
    }

    private func prepareBundledVirtualMouseHelper(
        requiredDeviceNode: String
    ) async -> Bool {
        do {
            if !virtualMouseHelperUploaded {
                let output = try await client.shell("getprop ro.product.cpu.abi")
                let abi = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let resourceTag = Self.virtualMouseResourceTag(for: abi),
                      let localURL = Bundle.main.url(
                        forResource: "TVADBVirtualMouse-\(resourceTag)",
                        withExtension: "bin"
                      ) else {
                    mouseLogger.error(
                        "No bundled virtual mouse helper for ABI \(abi, privacy: .public)"
                    )
                    return false
                }

                _ = try await client.push(
                    localURL: localURL,
                    remotePath: remoteVirtualMouseHelperPath
                )
                virtualMouseHelperUploaded = true
            }

            let verifyOutput = try await client.shell(
                "chmod 700 \(remoteVirtualMouseHelperPath.adbShellQuoted)"
                    + " && test -r \(requiredDeviceNode.adbShellQuoted)"
                    + " && test -w \(requiredDeviceNode.adbShellQuoted)"
                    + " && echo TVADB_MOUSE_HELPER_READY"
            )
            guard verifyOutput.contains("TVADB_MOUSE_HELPER_READY") else {
                mouseLogger.error(
                    "Android shell cannot use \(requiredDeviceNode, privacy: .public): \(verifyOutput, privacy: .public)"
                )
                return false
            }

            return true
        } catch {
            mouseLogger.error(
                "Bundled virtual mouse helper upload failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func startVirtualMouseBackend(
        preferredBackend: VirtualMouseBackend,
        readerScript: String,
        registrationEvent: String?
    ) async -> VirtualMouseBackend? {
        do {
            let output = try await startVirtualMouseProcess(
                readerScript: readerScript,
                registrationEvent: registrationEvent
            )
            guard output.contains("TVADB_MOUSE_READY") else {
                mouseLogger.error(
                    "Virtual mouse registration failed: \(output, privacy: .public)"
                )
                await stopVirtualMouse()
                return nil
            }
            if output.contains("TVADB_BACKEND_UHID") {
                return .bundledUHID
            }
            if output.contains("TVADB_BACKEND_UINPUT"),
               preferredBackend == .bundledUHID {
                mouseLogger.notice(
                    "Bundled helper could not create UHID; it registered through uinput"
                )
                return .bundledUInput
            }
            return preferredBackend
        } catch {
            mouseLogger.error(
                "Virtual mouse backend failed: \(error.localizedDescription, privacy: .public)"
            )
            await stopVirtualMouse()
            return nil
        }
    }

    private func activateVirtualMouse(
        backend: VirtualMouseBackend,
        center: (x: Int, y: Int)
    ) async {
        virtualMouseAvailable = true
        virtualMouseActive = true
        virtualMouseBackend = backend
        // A relative mouse starts at the display origin. Keeping only a
        // logical center here makes the first tiny nudge leave Android's
        // actual cursor at (0, 0), which appears as a clipped hover shadow in
        // the status bar. Prime the kernel cursor with real relative reports
        // before treating the two positions as synchronized.
        virtualMousePosition = (x: 0, y: 0)
        switch backend {
        case .bundledUHID:
            mouseLogger.notice(
                "Physical HID mouse registered through Linux UHID"
            )
        case .aospUInput:
            mouseLogger.notice(
                "Virtual mouse registered through AOSP uinput"
            )
        case .bundledUInput:
            mouseLogger.notice(
                "Virtual mouse registered through bundled uinput helper"
            )
        }
        await preparePersistentVirtualMouseStream()
        do {
            try await sendVirtualMouseMove(
                deltaX: center.x,
                deltaY: center.y
            )
            virtualMousePosition = center
            mouseLogger.notice(
                "Virtual mouse cursor initialized at the display center"
            )
        } catch {
            // The caller's first move retries from the origin. Do not discard
            // an otherwise usable backend solely because its initial stream
            // write raced device registration on a slow TV.
            mouseLogger.notice(
                "Virtual mouse center initialization will retry on first move"
            )
        }
    }

    private func preparePersistentVirtualMouseStream() async {
        guard virtualMouseStream == nil,
              virtualMouseStreamAvailable != false else {
            return
        }
        do {
            let session = try await client.openPersistentShell(
                "exec cat > \(virtualMouseFIFOPath.adbShellQuoted)"
            )
            virtualMouseStream = session
            virtualMouseStreamAvailable = true
            mouseLogger.notice(
                "Low-latency persistent mouse control stream is active"
            )
        } catch {
            virtualMouseStream = nil
            virtualMouseStreamAvailable = false
            mouseLogger.notice(
                "Persistent mouse stream unavailable; using shell fallback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func closeVirtualMouseStream() async {
        let stream = virtualMouseStream
        virtualMouseStream = nil
        await stream?.close()
    }

    private func startVirtualMouseProcess(
        readerScript: String,
        registrationEvent: String?
    ) async throws -> String {
        let fifo = virtualMouseFIFOPath.adbShellQuoted
        let processPID = virtualMousePIDPath.adbShellQuoted
        let writerPID = virtualMouseWriterPIDPath.adbShellQuoted
        let log = virtualMouseLogPath.adbShellQuoted
        let writerScript = "exec tail -f /dev/null > \(fifo)"
        let registerCommand: String
        if let registrationEvent {
            registerCommand =
                " sleep 0.15;"
                + " printf '%s\\n' \(registrationEvent.adbShellQuoted)"
                + " > \(fifo);"
        } else {
            registerCommand = ""
        }
        let startCommand =
            virtualMouseCleanupCommand
            + "; mkfifo \(fifo)"
            + " || { echo TVADB_UINPUT_FIFO_FAILED; exit 0; };"
            + " nohup sh -c \(readerScript.adbShellQuoted)"
            + " > \(log) 2>&1 < /dev/null &"
            + " reader_pid=$!;"
            + " printf '%s' \"$reader_pid\" > \(processPID);"
            + " nohup sh -c \(writerScript.adbShellQuoted)"
            + " > /dev/null 2>&1 < /dev/null &"
            + " writer_pid=$!;"
            + " printf '%s' \"$writer_pid\" > \(writerPID);"
            + registerCommand
            + " i=0;"
            + " while [ \"$i\" -lt 16 ]; do"
            + " if dumpsys input 2>/dev/null"
            + " | grep -F \(virtualMouseName.adbShellQuoted)"
            + " >/dev/null 2>&1;"
            + " then echo TVADB_MOUSE_READY;"
            + " if grep -F TVADB_UHID_READY \(log) >/dev/null 2>&1;"
            + " then echo TVADB_BACKEND_UHID;"
            + " elif grep -F TVADB_UINPUT_READY \(log) >/dev/null 2>&1;"
            + " then echo TVADB_BACKEND_UINPUT; fi;"
            + " break; fi;"
            + " if ! kill -0 \"$reader_pid\" 2>/dev/null;"
            + " then break; fi;"
            + " i=$((i + 1)); sleep 0.15;"
            + " done;"
            + " if [ \"$i\" -ge 16 ]"
            + " || ! dumpsys input 2>/dev/null"
            + " | grep -F \(virtualMouseName.adbShellQuoted)"
            + " >/dev/null 2>&1;"
            + " then echo TVADB_MOUSE_FAILED;"
            + " tail -n 8 \(log) 2>/dev/null; fi"
        return try await client.shell(startCommand)
    }

    private nonisolated static func virtualMouseResourceTag(
        for abi: String
    ) -> String? {
        switch abi.lowercased() {
        case "arm64-v8a":
            "arm64"
        case "armeabi-v7a", "armeabi":
            "armv7"
        case "x86":
            "x86"
        case "x86_64":
            "x86_64"
        default:
            nil
        }
    }

    /// Returns `true` when movement was delivered by the kernel virtual
    /// mouse, or `false` when the compatibility `input mouse` path was used.
    func moveMouse(x: Int, y: Int) async throws -> Bool {
        if virtualMouseActive, let previous = virtualMousePosition {
            let deltaX = x - previous.x
            let deltaY = y - previous.y
            if deltaX == 0, deltaY == 0 {
                return true
            }
            do {
                try await sendVirtualMouseMove(
                    deltaX: deltaX,
                    deltaY: deltaY
                )
                virtualMousePosition = (x, y)
                return true
            } catch {
                mouseLogger.error(
                    "Virtual mouse move failed; using compatibility mode"
                )
                await stopVirtualMouse()
            }
        }

        let output = try await client.shell("input mouse motionevent MOVE \(x) \(y) 2>&1")
        try validateInputOutput(output)
        return false
    }

    /// Returns `true` when the click came from the kernel virtual mouse.
    func clickMouse(
        x: Int,
        y: Int,
        useTouchscreenSource: Bool = false
    ) async throws -> Bool {
        if virtualMouseActive {
            do {
                try await sendVirtualMouseClick(.left)
                return true
            } catch {
                mouseLogger.error(
                    "Virtual mouse click failed; using compatibility mode"
                )
                await stopVirtualMouse()
            }
        }

        let source = useTouchscreenSource ? "touchscreen" : "mouse"
        let output = try await client.shell("input \(source) tap \(x) \(y) 2>&1")
        try validateInputOutput(output)
        return false
    }

    /// Sends a non-primary physical mouse click. There is no faithful
    /// coordinate-tap fallback for these buttons, so `false` means the caller
    /// should use an Android navigation-key compatibility action instead.
    func clickMouse(button: AndroidMouseButton) async throws -> Bool {
        guard virtualMouseActive else { return false }
        do {
            try await sendVirtualMouseClick(button)
            return true
        } catch {
            mouseLogger.error(
                "Virtual mouse button click failed"
            )
            await stopVirtualMouse()
            return false
        }
    }

    func setMouseButton(
        _ button: AndroidMouseButton,
        pressed: Bool
    ) async throws -> Bool {
        guard virtualMouseActive else { return false }
        do {
            try await sendVirtualMouseButton(
                button,
                pressed: pressed
            )
            return true
        } catch {
            mouseLogger.error(
                "Virtual mouse button state failed"
            )
            await stopVirtualMouse()
            return false
        }
    }

    func scrollMouse(amount: Int) async throws -> Bool {
        guard virtualMouseActive, amount != 0 else {
            return virtualMouseActive
        }
        do {
            try await sendVirtualMouseWheel(amount: amount)
            return true
        } catch {
            mouseLogger.error("Virtual mouse wheel failed")
            await stopVirtualMouse()
            return false
        }
    }

    func stopVirtualMouse() async {
        await closeVirtualMouseStream()
        _ = try? await client.shell(virtualMouseCleanupCommand)
        await removeVirtualMouseDisplayAssociation()
        virtualMouseActive = false
        virtualMouseBackend = nil
        virtualMousePosition = nil
        coordinateTouchMode = false
    }

    func isUsingPhysicalHIDMouse() -> Bool {
        virtualMouseActive && virtualMouseBackend == .bundledUHID
    }

    func isUsingCoordinateTouchMode() -> Bool {
        coordinateTouchMode
    }

    private func sendVirtualMouseMove(
        deltaX: Int,
        deltaY: Int
    ) async throws {
        let payload: String
        switch virtualMouseBackend {
        case .aospUInput:
            payload =
                Self.virtualMouseUpdateTimeBaseEvent()
                + "\n"
                + Self.virtualMouseInjectEvent([
                    2, 0, deltaX,
                    2, 1, deltaY,
                    0, 0, 0
                ])
        case .bundledUHID, .bundledUInput:
            payload = "M \(deltaX) \(deltaY)"
        case nil:
            throw ADBClientError.remoteFailure(
                "TVADB_MOUSE_DAEMON_STOPPED"
            )
        }
        try await sendVirtualMousePayload(payload)
    }

    private func sendVirtualMouseClick(
        _ button: AndroidMouseButton
    ) async throws {
        let payload: String
        switch virtualMouseBackend {
        case .aospUInput:
            payload =
                Self.virtualMouseUpdateTimeBaseEvent()
                + "\n"
                + Self.virtualMouseInjectEvent([
                    1, button.linuxInputCode, 1,
                    0, 0, 0,
                    1, button.linuxInputCode, 0,
                    0, 0, 0
                ])
        case .bundledUHID, .bundledUInput:
            payload = "C \(button.rawValue)"
        case nil:
            throw ADBClientError.remoteFailure(
                "TVADB_MOUSE_DAEMON_STOPPED"
            )
        }
        try await sendVirtualMousePayload(payload)
    }

    private func sendVirtualMouseButton(
        _ button: AndroidMouseButton,
        pressed: Bool
    ) async throws {
        let payload: String
        switch virtualMouseBackend {
        case .aospUInput:
            payload =
                Self.virtualMouseUpdateTimeBaseEvent()
                + "\n"
                + Self.virtualMouseInjectEvent([
                    1, button.linuxInputCode, pressed ? 1 : 0,
                    0, 0, 0
                ])
        case .bundledUHID, .bundledUInput:
            payload = "\(pressed ? "D" : "U") \(button.rawValue)"
        case nil:
            throw ADBClientError.remoteFailure(
                "TVADB_MOUSE_DAEMON_STOPPED"
            )
        }
        try await sendVirtualMousePayload(payload)
    }

    private func sendVirtualMouseWheel(amount: Int) async throws {
        let payload: String
        switch virtualMouseBackend {
        case .aospUInput:
            payload =
                Self.virtualMouseUpdateTimeBaseEvent()
                + "\n"
                + Self.virtualMouseInjectEvent([
                    2, 8, amount,
                    0, 0, 0
                ])
        case .bundledUHID, .bundledUInput:
            payload = "W \(amount)"
        case nil:
            throw ADBClientError.remoteFailure(
                "TVADB_MOUSE_DAEMON_STOPPED"
            )
        }
        try await sendVirtualMousePayload(payload)
    }

    private func sendVirtualMousePayload(_ payload: String) async throws {
        if let stream = virtualMouseStream {
            do {
                try await stream.write(Data((payload + "\n").utf8))
                return
            } catch {
                mouseLogger.error(
                    "Persistent mouse stream failed; reverting to shell writes"
                )
                await closeVirtualMouseStream()
                virtualMouseStreamAvailable = false
            }
        }

        let fifo = virtualMouseFIFOPath.adbShellQuoted
        let processPID = virtualMousePIDPath.adbShellQuoted
        let command =
            "if [ -f \(processPID) ]"
            + " && kill -0 \"$(cat \(processPID))\" 2>/dev/null;"
            + " then printf '%s\\n' \(payload.adbShellQuoted) > \(fifo)"
            + " && echo TVADB_MOUSE_EVENT_SENT;"
            + " else echo TVADB_MOUSE_DAEMON_STOPPED; fi"
        let output = try await client.shell(command)
        guard output.contains("TVADB_MOUSE_EVENT_SENT") else {
            throw ADBClientError.remoteFailure("TVADB_MOUSE_DAEMON_STOPPED")
        }
    }

    private var virtualMouseCleanupCommand: String {
        let fifo = virtualMouseFIFOPath.adbShellQuoted
        let processPID = virtualMousePIDPath.adbShellQuoted
        let writerPID = virtualMouseWriterPIDPath.adbShellQuoted
        let log = virtualMouseLogPath.adbShellQuoted
        return
            "if [ -f \(processPID) ];"
            + " then kill \"$(cat \(processPID))\" 2>/dev/null || true; fi;"
            + " if [ -f \(writerPID) ];"
            + " then kill \"$(cat \(writerPID))\" 2>/dev/null || true; fi;"
            + " rm -f \(fifo) \(processPID) \(writerPID) \(log)"
    }

    private static func virtualMouseRegisterEvent(name: String) -> String {
        """
        {"id":14121,"command":"register","name":"\(name)","vid":4617,"pid":14121,"bus":"usb","configuration":[{"type":100,"data":[1,2]},{"type":101,"data":[272,273,274]},{"type":102,"data":[0,1,6,8]}]}
        """
    }

    private static func virtualMouseInjectEvent(_ events: [Int]) -> String {
        let values = events.map(String.init).joined(separator: ",")
        return """
        {"id":14121,"command":"inject","events":[\(values)]}
        """
    }

    private static func virtualMouseUpdateTimeBaseEvent() -> String {
        """
        {"id":14121,"command":"updateTimeBase"}
        """
    }

    func setShowTouches(_ enabled: Bool) async throws {
        let output = try await client.shell(
            "settings put system show_touches \(enabled ? 1 : 0) 2>&1"
        )
        try validateInputOutput(output)
    }

    func tapTouchscreen(x: Int, y: Int) async throws {
        let output = try await client.shell(
            "input touchscreen tap \(x) \(y) 2>&1"
        )
        try validateInputOutput(output)
    }

    func swipeTouchscreen(
        from start: CGPoint,
        to end: CGPoint,
        durationMilliseconds: Int
    ) async throws {
        let duration = min(max(durationMilliseconds, 80), 2_000)
        let output = try await client.shell(
            "input touchscreen swipe "
                + "\(Int(start.x.rounded())) \(Int(start.y.rounded())) "
                + "\(Int(end.x.rounded())) \(Int(end.y.rounded())) "
                + "\(duration) 2>&1"
        )
        try validateInputOutput(output)
    }

    func dragTouchscreen(
        from start: CGPoint,
        to end: CGPoint,
        durationMilliseconds: Int
    ) async throws {
        let duration = min(max(durationMilliseconds, 80), 2_000)
        let coordinates =
            "\(Int(start.x.rounded())) \(Int(start.y.rounded())) "
            + "\(Int(end.x.rounded())) \(Int(end.y.rounded()))"
        let output = try await client.shell(
            "input touchscreen draganddrop "
                + "\(coordinates) \(duration) 2>&1"
        )

        do {
            try validateInputOutput(output)
            return
        } catch {
            // `draganddrop` is available on modern Android releases and
            // inserts the platform long-press delay before moving. A few
            // older TV builds omit that subcommand, so keep a slow swipe as
            // a compatibility path rather than dropping the user's gesture.
        }

        let fallbackDuration = min(max(duration + 550, 700), 2_000)
        let fallbackOutput = try await client.shell(
            "input touchscreen swipe "
                + "\(coordinates) \(fallbackDuration) 2>&1"
        )
        try validateInputOutput(fallbackOutput)
    }

    func longPressTouchscreen(
        at point: CGPoint,
        durationMilliseconds: Int
    ) async throws {
        let duration = min(
            max(durationMilliseconds, 550),
            2_000
        )
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        // AOSP's swipe command keeps ACTION_DOWN active for the requested
        // duration even when both coordinates are identical. This is more
        // reliable than `draganddrop x y x y` on vendor Android builds,
        // several of which reduce a zero-distance drag to a normal tap.
        let output = try await client.shell(
            "input touchscreen swipe "
                + "\(x) \(y) \(x) \(y) \(duration) 2>&1"
        )
        try validateInputOutput(output)
    }

    func screenshot() async throws -> Data {
        Self.cleanupStaleScreenshotTemporaryDirectories()

        // exec-out keeps binary output away from shell PTY newline conversion.
        // Some TV firmware still rejects it, so retain the pull-based path as
        // a compatibility fallback.
        if let direct = try? await client.exec("screencap -p"),
           let png = Self.normalizedPNG(from: direct) {
            return png
        }

        let filename = ".tvadb-screenshot-\(UUID().uuidString).png"
        let remotePath = "/data/local/tmp/\(filename)"
        _ = try? await client.shell(
            "rm -f /data/local/tmp/.tvadb-screenshot-*.png"
        )
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVADB-Screenshot-\(UUID().uuidString)", isDirectory: true)
        let localURL = localDirectory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        do {
            let output = try await client.shell("screencap -p \(remotePath.adbShellQuoted) 2>&1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.isEmpty else {
                throw ADBClientError.remoteFailure(L10n.format("text.tv_screenshot_failed_value", output))
            }
            _ = try await client.pull(remotePath: remotePath, localURL: localURL)
            let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
            guard let png = Self.normalizedPNG(from: data) else {
                throw ADBClientError.remoteFailure(L10n.string("text.android_returned_an_invalid_png_screenshot"))
            }
            _ = try? await client.shell("rm -f -- \(remotePath.adbShellQuoted)")
            return png
        } catch {
            _ = try? await client.shell("rm -f -- \(remotePath.adbShellQuoted)")
            throw error
        }
    }

    static func cleanupStaleScreenshotTemporaryDirectories() {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("TVADB-Screenshot-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    static func cleanupStaleRecordingCache() {
        guard let cacheRoot = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return
        }
        let recordings = cacheRoot.appendingPathComponent(
            "TVADBRecordings",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: recordings)
    }

    func openH264ScreenStream() async throws
        -> ADBPersistentShellSession {
        try await client.openPersistentExec(
            "screenrecord --output-format=h264"
                + " --bit-rate 4000000 --time-limit 180 -"
        )
    }

    func recordScreen(
        duration: Int,
        onReady: (@Sendable () async -> Void)? = nil
    ) async throws -> URL {
        let seconds = min(max(duration, 5), 180)
        let identifier = UUID().uuidString
        let remotePath = "/data/local/tmp/.tvadb-recording-\(identifier).mp4"
        let remoteStatusPath = "/data/local/tmp/.tvadb-recording-\(identifier).status"
        let remoteLogPath = "/data/local/tmp/.tvadb-recording-\(identifier).log"
        let remoteBackupDirectory = "/data/local/tmp/.tvadb-recording-\(identifier)-frames"
        let remoteBackupDonePath = "/data/local/tmp/.tvadb-recording-\(identifier)-frames.done"
        let remoteBackupLogPath = "/data/local/tmp/.tvadb-recording-\(identifier)-frames.log"
        let quotedRemotePath = remotePath.adbShellQuoted
        let quotedStatusPath = remoteStatusPath.adbShellQuoted
        let quotedLogPath = remoteLogPath.adbShellQuoted
        let quotedBackupDirectory = remoteBackupDirectory.adbShellQuoted
        let quotedBackupDonePath = remoteBackupDonePath.adbShellQuoted
        let quotedBackupLogPath = remoteBackupLogPath.adbShellQuoted
        let cleanupCommand =
            "rm -f -- \(quotedRemotePath) \(quotedStatusPath) \(quotedLogPath)"
            + " \(quotedBackupDonePath) \(quotedBackupLogPath);"
            + " rm -rf -- \(quotedBackupDirectory)"
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TVADBRecordings", isDirectory: true)
        let exportDirectory = cacheRoot.appendingPathComponent(identifier, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let localURL = exportDirectory.appendingPathComponent(
            "TVADB-\(formatter.string(from: Date())).mp4"
        )
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let backupDirectory = exportDirectory.appendingPathComponent(
            "RecoveryFrames",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        do {
            _ = try? await client.shell(cleanupCommand)
            let recorderScript =
                "screenrecord --time-limit \(seconds) --bit-rate 8000000"
                + " \(quotedRemotePath) > \(quotedLogPath) 2>&1 < /dev/null;"
                + " printf '%s' $? > \(quotedStatusPath)"
            let backupScript =
                "sleep 1;"
                + " i=0;"
                + " while [ ! -f \(quotedStatusPath) ]"
                + " && [ \"$i\" -lt \(seconds * 4 + 8) ]; do"
                + " frame=$(printf '%04d.png' \"$i\");"
                + " screencap -p \(quotedBackupDirectory)/$frame"
                + " > /dev/null 2>&1;"
                + " i=$((i + 1));"
                + " sleep 0.35;"
                + " done;"
                + " : > \(quotedBackupDonePath)"
            let startOutput = try await client.shell(
                "mkdir -p \(quotedBackupDirectory);"
                    + " nohup sh -c \(recorderScript.adbShellQuoted)"
                    + " > /dev/null 2>&1 < /dev/null &"
                    + " recorder_pid=$!;"
                    + " nohup sh -c \(backupScript.adbShellQuoted)"
                    + " > \(quotedBackupLogPath) 2>&1 < /dev/null &"
                    + " echo TVADB_RECORDING_STARTED:$recorder_pid"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard startOutput.contains("TVADB_RECORDING_STARTED") else {
                throw ADBClientError.remoteFailure(
                    String(
                        format: L10n.string("text.tv_screen_recording_failed_value"),
                        startOutput
                    )
                )
            }
            screenRecordingLogger.notice(
                "Remote recorder launcher returned and polling started"
            )

            // Run screenrecord in a detached Android shell process. Polling
            // with short ADB calls leaves the client available for TV remote
            // commands while recording, so those actions appear in the video.
            //
            // A number of vendor builds create a valid multi-frame MP4 while
            // the main SurfaceFlinger layer remains frozen. A detached Android
            // shell process captures a sparse screenshot track in parallel.
            // Keeping that work on the device is important: taking screenshots
            // through this ADB actor would serialize and delay remote commands.
            let recordingStartedAt = Date()
            let deadline = Date().addingTimeInterval(TimeInterval(seconds + 15))
            var exitStatus: Int?
            var isReady = false
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(400))
                let status = try await client.shell(
                    "if [ -f \(quotedStatusPath) ];"
                        + " then printf 'TVADB_RECORDING_DONE:';"
                        + " cat \(quotedStatusPath);"
                        + " else printf 'TVADB_RECORDING_ACTIVE:';"
                        + " if [ -f \(quotedRemotePath) ];"
                        + " then wc -c < \(quotedRemotePath);"
                        + " else printf '0'; fi; fi"
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                if status.hasPrefix("TVADB_RECORDING_ACTIVE:") || status.isEmpty {
                    let elapsed = Date().timeIntervalSince(recordingStartedAt)
                    let remoteBytes = Int(
                        status
                            .replacingOccurrences(
                                of: "TVADB_RECORDING_ACTIVE:",
                                with: ""
                            )
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ) ?? 0
                    let encoderHasStarted = remoteBytes >= 4_096 || elapsed >= 1.6

                    if !isReady, encoderHasStarted {
                        isReady = true
                        screenRecordingLogger.notice(
                            "Remote recorder produced its first frame"
                        )
                        await onReady?()
                    }
                    continue
                }
                if status.hasPrefix("TVADB_RECORDING_DONE:") {
                    let value = status
                        .replacingOccurrences(
                            of: "TVADB_RECORDING_DONE:",
                            with: ""
                        )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    exitStatus = Int(value)
                } else {
                    exitStatus = Int(status)
                }
                break
            }

            guard exitStatus == 0 else {
                let details = (try? await client.shell(
                    "if [ -f \(quotedLogPath) ]; then tail -c 2048 \(quotedLogPath); fi"
                ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ADBClientError.remoteFailure(
                    String(
                        format: L10n.string("text.tv_screen_recording_failed_value"),
                        details.isEmpty ? "TVADB_RECORDING_DID_NOT_COMPLETE" : details
                    )
                )
            }

            let backupFrames = await collectRecordingBackupFrames(
                remoteDirectory: remoteBackupDirectory,
                quotedDonePath: quotedBackupDonePath,
                localDirectory: backupDirectory,
                maximumCount: seconds * 4 + 8
            )
            _ = try await client.pull(remotePath: remotePath, localURL: localURL)
            let header = try Data(contentsOf: localURL, options: [.mappedIfSafe])
                .prefix(64)
            guard header.range(of: Data("ftyp".utf8)) != nil else {
                throw ADBClientError.remoteFailure(L10n.string("text.android_returned_an_invalid_mp4_recording"))
            }

            let backupChanged =
                ScreenRecordingRecovery.backupFramesHaveMeaningfulChange(
                    backupFrames
                )
            let nativeVideoChanged = await ScreenRecordingRecovery
                .videoHasMeaningfulChange(at: localURL)
            if backupChanged, !nativeVideoChanged {
                let recoveredURL = exportDirectory.appendingPathComponent(
                    ".tvadb-recovered.mp4"
                )
                try await ScreenRecordingRecovery.makeFallbackVideo(
                    from: backupFrames,
                    duration: TimeInterval(seconds),
                    at: recoveredURL
                )
                try FileManager.default.removeItem(at: localURL)
                try FileManager.default.moveItem(
                    at: recoveredURL,
                    to: localURL
                )
                screenRecordingLogger.notice(
                    "Replaced a frozen vendor screenrecord result with the verified screenshot track"
                )
            }
            try? FileManager.default.removeItem(at: backupDirectory)
            _ = try? await client.shell(cleanupCommand)
            return localURL
        } catch {
            _ = try? await client.shell(cleanupCommand)
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
    }

    private func collectRecordingBackupFrames(
        remoteDirectory: String,
        quotedDonePath: String,
        localDirectory: URL,
        maximumCount: Int
    ) async -> [ScreenRecordingBackupFrame] {
        for _ in 0..<12 {
            let done = (try? await client.shell(
                "if [ -f \(quotedDonePath) ]; then echo READY; fi"
            ))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if done == "READY" { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard let listing = try? await client.shell(
            "if [ -d \(remoteDirectory.adbShellQuoted) ];"
                + " then ls -1 \(remoteDirectory.adbShellQuoted); fi"
        ) else {
            return []
        }
        let filenames = listing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()
            .prefix(maximumCount)

        var frames: [ScreenRecordingBackupFrame] = []
        for filename in filenames {
            let rawURL = localDirectory.appendingPathComponent(filename)
            let remoteURL = remoteDirectory + "/" + filename
            guard (try? await client.pull(
                remotePath: remoteURL,
                localURL: rawURL
            )) != nil,
                let pngData = try? Data(
                    contentsOf: rawURL,
                    options: [.mappedIfSafe]
                ) else {
                continue
            }
            defer { try? FileManager.default.removeItem(at: rawURL) }
            let indexText = filename.split(separator: ".", maxSplits: 1).first
            let captureIndex = indexText.flatMap { Int($0) } ?? frames.count
            if let frame = ScreenRecordingRecovery.writeBackupFrame(
                pngData: pngData,
                index: captureIndex,
                elapsed: TimeInterval(captureIndex + 1),
                to: localDirectory
            ) {
                frames.append(frame)
            }
        }
        return frames.sorted { $0.elapsed < $1.elapsed }
    }

    func deviceInformation() async throws -> DeviceInformation {
        let propertyKeys = [
            "ro.product.brand", "ro.product.manufacturer", "ro.product.model",
            "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi",
            "ro.serialno", "ro.build.display.id"
        ]
        var values: [(String, String)] = []
        for key in propertyKeys {
            let value = try await client.shell("getprop \(key)").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values.append((Self.label(for: key), value)) }
        }
        let resolution = try await client.shell("wm size").trimmingCharacters(in: .whitespacesAndNewlines)
        let density = try await client.shell("wm density").trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = try await client.shell("cat /proc/meminfo | head -n 1").trimmingCharacters(in: .whitespacesAndNewlines)
        let storage = try await client.shell("df -h /data | tail -n 1").trimmingCharacters(in: .whitespacesAndNewlines)
        let kernel = try await client.shell("uname -a").trimmingCharacters(in: .whitespacesAndNewlines)
        values.append(contentsOf: [
            (L10n.string("text.screen"), resolution),
            (L10n.string("text.dpi"), density),
            (L10n.string("text.memory"), memory),
            (L10n.string("text.storage"), storage),
            (L10n.string("text.kernel"), kernel)
        ])
        if let networkOutput = try? await client.shell(
            "ip -o -4 addr show wlan0 2>/dev/null"
        ), let address = networkOutput
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first(where: { $0.contains(".") && $0.contains("/") })?
            .split(separator: "/")
            .first {
            values.append((L10n.string("text.ip_address"), String(address)))
        }
        if let macAddress = try? await client.shell(
            "cat /sys/class/net/wlan0/address 2>/dev/null"
        ).trimmingCharacters(in: .whitespacesAndNewlines),
           !macAddress.isEmpty {
            values.append((L10n.string("text.mac_address"), macAddress))
        }
        if let batteryOutput = try? await client.shell("dumpsys battery 2>/dev/null"),
           let levelLine = batteryOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("level:")
            }),
           let level = Int(
                levelLine.split(separator: ":", maxSplits: 1)
                    .last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
           ) {
            values.append((L10n.string("text.battery"), "\(level)%"))
        }
        return DeviceInformation(values: values)
    }

    func shell(_ command: String) async throws -> String {
        try await client.shell(command)
    }

    func logcatSnapshot(maxLines: Int = 800) async throws -> String {
        let boundedLines = min(max(maxLines, 100), 2_000)
        return try await client.shell("logcat -d -v threadtime -t \(boundedLines) 2>&1")
    }

    func openLogcatStream() async throws -> ADBPersistentShellSession {
        try await client.openPersistentExec(
            "logcat -v threadtime -T 200 2>&1"
        )
    }

    func clearLogcat() async throws {
        let output = try await client.shell("logcat -c 2>&1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            throw ADBClientError.remoteFailure(output)
        }
    }

    func reboot(target: String = "") async throws {
        try await client.reboot(target: target)
    }

    private func parsePackages(_ output: String, isSystem: Bool) -> [AndroidApp] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("package:") else { return nil }
            let payload = String(value.dropFirst("package:".count))
            let packageName: String
            let baseAPKPath: String?
            if let separator = payload.lastIndex(of: "=") {
                packageName = String(payload[payload.index(after: separator)...])
                baseAPKPath = String(payload[..<separator])
            } else {
                packageName = payload
                baseAPKPath = nil
            }
            guard !packageName.isEmpty else { return nil }
            return AndroidApp(
                packageName: packageName,
                isSystem: isSystem,
                baseAPKPath: baseAPKPath,
                name: nil,
                iconData: nil,
                versionName: nil
            )
        }
    }

    private func validateInputOutput(_ output: String) throws {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.localizedCaseInsensitiveContains("error:")
            || value.localizedCaseInsensitiveContains("exception occurred")
            || value.localizedCaseInsensitiveContains("securityexception")
            || value.localizedCaseInsensitiveContains("permission denial")
            || value.localizedCaseInsensitiveContains("unknown command")
            || value.hasPrefix("Usage:") {
            throw ADBClientError.remoteFailure(value)
        }
    }

    private func validateCommandOutput(_ output: String) throws {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.lowercased()
        if normalized.contains("failure [")
            || normalized.hasPrefix("failure")
            || normalized.contains("error:")
            || normalized.contains("exception")
            || normalized.contains("permission denial")
            || normalized.contains("permission denied")
            || normalized.contains("no activities found")
            || normalized.contains("monkey aborted") {
            throw ADBClientError.remoteFailure(value)
        }
    }

    private nonisolated static func parseScreenRotation(
        _ output: String
    ) -> Int? {
        let markers = [
            "SurfaceOrientation:",
            "surfaceOrientation=",
            "mCurrentRotation=",
            "mRotation=",
        ]
        for marker in markers {
            guard let markerRange = output.range(of: marker) else {
                continue
            }
            var value = output[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("ROTATION_") {
                value.removeFirst("ROTATION_".count)
            }
            guard let first = value.first,
                  let rotation = Int(String(first)),
                  (0...3).contains(rotation) else {
                continue
            }
            return rotation
        }
        return nil
    }

    private static func label(for property: String) -> String {
        switch property {
        case "ro.product.brand": L10n.string("text.brand")
        case "ro.product.manufacturer": L10n.string("text.manufacturer")
        case "ro.product.model": L10n.string("text.model")
        case "ro.build.version.release": L10n.string("text.android")
        case "ro.build.version.sdk": L10n.string("text.sdk")
        case "ro.product.cpu.abi": L10n.string("text.cpu_abi")
        case "ro.serialno": L10n.string("text.serial")
        case "ro.build.display.id": L10n.string("text.build")
        default: property
        }
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let pngEndChunk = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])

    private static func normalizedPNG(from data: Data) -> Data? {
        guard let signatureRange = data.range(of: pngSignature),
              let endRange = data.range(of: pngEndChunk, options: .backwards),
              signatureRange.lowerBound < endRange.upperBound else {
            return nil
        }
        return data.subdata(in: signatureRange.lowerBound..<endRange.upperBound)
    }
}
