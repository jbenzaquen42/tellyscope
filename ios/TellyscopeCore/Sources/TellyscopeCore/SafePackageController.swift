import Foundation

public struct ShellResult: Sendable {
    public let output: String
    public let exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public protocol ShellExecutor {
    func run(_ command: String) async throws -> ShellResult
}

public enum SafePackageError: Error, LocalizedError, Equatable {
    case invalidPackage(String)
    case missingStableDeviceIdentity
    case deviceChanged
    case commandFailed(String)
    case unknownHome
    case operationInProgress
    case protectedPackage(String)
    case persistence(String)
    case corruptHistory

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let value): return "Invalid Android package name: \(value)"
        case .missingStableDeviceIdentity: return "The TV did not provide a stable serial number; no change was made."
        case .deviceChanged: return "The connected TV changed during this operation; reconnect to the original TV and inspect its state."
        case .commandFailed(let output): return output.isEmpty ? "The TV command failed." : output
        case .unknownHome: return "Could not identify the TV's current Home app; no package was disabled."
        case .protectedPackage(let value): return "This TV package is protected: \(value)"
        case .persistence(let detail): return "Could not save TV history, so no package change was made: \(detail)"
        case .corruptHistory: return "TV history is damaged; repair or remove it before changing packages."
        case .operationInProgress: return "Another TV package operation is still in progress."
    }
}
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let action: String
    public let packageName: String
}

public struct DeviceSnapshot: Sendable {
    public let deviceID: String
    public let disabledPackages: Set<String>
    public let restorablePackages: Set<String>
    public let history: [HistoryEntry]
    public let pendingPackage: String?
    public let pendingAction: String?
}

public struct MutationResult: Sendable {
    public let deviceID: String
    public let packageName: String
    public let changed: Bool
}

/// Safely disables packages and restores only packages disabled by this app.
public actor SafePackageController {
    private let executor: ShellExecutor
    private let historyURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var mutationInProgress = false

    public init(executor: ShellExecutor, historyURL: URL) {
        self.executor = executor
        self.historyURL = historyURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func inspect() async throws -> DeviceSnapshot {
        guard !mutationInProgress else { throw SafePackageError.operationInProgress }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let deviceID = try await currentDeviceID()
        let disabled = try await disabledPackages()
        try await confirmDevice(deviceID)
        var state = try loadState()
        reconcile(deviceID, disabled: disabled, state: &state)
        try saveState(state)
        let device = state.devices[deviceID] ?? DeviceHistory()
        return DeviceSnapshot(
            deviceID: deviceID,
            disabledPackages: disabled,
            restorablePackages: device.appDisabled.intersection(disabled).subtracting(device.baseline ?? []),
            history: device.history,
            pendingPackage: device.pending?.package,
            pendingAction: device.pending?.action
        )
    }

    public func disable(package: String) async throws -> MutationResult {
        guard !mutationInProgress else { throw SafePackageError.operationInProgress }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try validate(package)
        let deviceID = try await currentDeviceID()
        var state = try loadState()
        var disabled = try await disabledPackages()
        reconcile(deviceID, disabled: disabled, state: &state)
        try saveState(state)
        var device = state.devices[deviceID] ?? DeviceHistory()
        let home = try await resolvedHome()
        guard home != package else { throw SafePackageError.protectedPackage(package) }
        if let why = protectedReason(package) { throw SafePackageError.protectedPackage("\(package): \(why)") }
        disabled = try await disabledPackages()
        try await confirmDevice(deviceID)
        if device.baseline == nil {
            device.baseline = disabled
            state.devices[deviceID] = device
            try saveState(state)
        }
        guard !disabled.contains(package) else {
            return MutationResult(deviceID: deviceID, packageName: package, changed: false)
        }
        device.pending = PendingMutation(action: "disable", package: package)
        state.devices[deviceID] = device
        try saveState(state)
        try await confirmDevice(deviceID)
        _ = try await executor.run("pm disable-user --user 0 \(package) 2>&1")
        try await confirmDevice(deviceID)
        disabled = try await disabledPackages()
        state = try loadState()
        reconcile(deviceID, disabled: disabled, state: &state)
        try saveState(state)
        guard disabled.contains(package) else { throw SafePackageError.commandFailed("package remained enabled: \(package)") }
        return MutationResult(deviceID: deviceID, packageName: package, changed: true)
    }

    public func enable(package: String) async throws -> MutationResult {
        guard !mutationInProgress else { throw SafePackageError.operationInProgress }
        mutationInProgress = true
        defer { mutationInProgress = false }
        return try await enablePackage(package, expectedDeviceID: nil)
    }

    private func enablePackage(_ package: String, expectedDeviceID: String?) async throws -> MutationResult {
        try validate(package)
        let deviceID = try await currentDeviceID()
        if let expectedDeviceID, deviceID != expectedDeviceID { throw SafePackageError.deviceChanged }
        var disabled = try await disabledPackages()
        var state = try loadState()
        reconcile(deviceID, disabled: disabled, state: &state)
        var device = state.devices[deviceID] ?? DeviceHistory()
        try saveState(state)
        guard device.baseline?.contains(package) != true,
              device.appDisabled.contains(package), disabled.contains(package) else {
            return MutationResult(deviceID: deviceID, packageName: package, changed: false)
        }
        device.pending = PendingMutation(action: "enable", package: package)
        state.devices[deviceID] = device
        try saveState(state)
        try await confirmDevice(deviceID)
        _ = try await executor.run("pm enable --user 0 \(package) 2>&1")
        try await confirmDevice(deviceID)
        disabled = try await disabledPackages()
        state = try loadState()
        reconcile(deviceID, disabled: disabled, state: &state)
        try saveState(state)
        guard !disabled.contains(package) else { throw SafePackageError.commandFailed("package remained disabled: \(package)") }
        return MutationResult(deviceID: deviceID, packageName: package, changed: true)
    }

    /// Restores all currently disabled packages this controller can prove it disabled.
    public func restore() async throws -> [MutationResult] {
        let snapshot = try await inspect()
        guard !mutationInProgress else { throw SafePackageError.operationInProgress }
        mutationInProgress = true
        defer { mutationInProgress = false }
        var results: [MutationResult] = []
        for package in snapshot.restorablePackages.sorted() {
            let result = try await enablePackage(package, expectedDeviceID: snapshot.deviceID)
            if result.changed { results.append(result) }
        }
        return results
    }

    private func validate(_ package: String) throws {
        guard isValidPackage(package) else {
            throw SafePackageError.invalidPackage(package)
        }
    }

    private func isValidPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil
    }

    private func currentDeviceID() async throws -> String {
        let result = try await executor.run("getprop ro.serialno; getprop ro.boot.serialno")
        guard result.exitCode == 0 else { throw SafePackageError.commandFailed(result.output) }
        let values = result.output.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let serial = values.first(where: { !$0.isEmpty && !["unknown", "null", "0123456789abcdef", "0000000000000000", "123456789"].contains($0.lowercased()) }) else {
            throw SafePackageError.missingStableDeviceIdentity
        }
        return "serial:\(serial)"
    }

    private func confirmDevice(_ expected: String) async throws {
        guard try await currentDeviceID() == expected else { throw SafePackageError.deviceChanged }
    }

    private func resolvedHome() async throws -> String {
        let result = try await executor.run("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        guard result.exitCode == 0 else { throw SafePackageError.unknownHome }
        let packages = Set(result.output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let slash = value.firstIndex(of: "/") else { return nil }
            let package = String(value[..<slash])
            return package == "android" || !isValidPackage(package) ? nil : package
        })
        guard packages.count == 1, let home = packages.first else { throw SafePackageError.unknownHome }
        return home
    }

    private func disabledPackages() async throws -> Set<String> {
        let result = try await executor.run("pm list packages -d --user 0")
        guard result.exitCode == 0 else { throw SafePackageError.commandFailed(result.output) }
        let lines = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.allSatisfy({ $0.hasPrefix("package:") && isValidPackage(String($0.dropFirst("package:".count))) }) else {
            throw SafePackageError.commandFailed("TV returned an unreadable disabled-package list.")
        }
        return Set(lines.map { String($0.dropFirst("package:".count)) })
    }

    private func protectedReason(_ package: String) -> String? {
        let lower = package.lowercased()
        let exact: Set<String> = [
            "android", "com.android.settings", "com.android.tv.settings", "com.amazon.tv.settings.v2",
            "com.android.systemui", "com.android.shell", "com.android.phone", "com.android.vending",
            "com.google.android.gms", "com.google.android.gsf", "com.google.android.webview", "com.android.webview",
        ]
        if exact.contains(lower) || lower == "com.google.android.permissioncontroller" || lower == "com.android.permissioncontroller" || lower.hasPrefix("com.android.ext.services") || lower.hasPrefix("com.android.ext.shared") || lower.hasPrefix("com.google.android.ext.services") || lower.hasPrefix("com.google.android.ext.shared") || lower == "com.android.modulemetadata" || lower == "com.google.android.modulemetadata" || lower.hasPrefix("com.google.android.overlay.modules.") || lower.hasPrefix("com.google.android.providers.") || (lower.hasPrefix("com.android.providers.") && !["com.android.providers.calendar", "com.android.providers.contacts", "com.android.providers.userdictionary", "com.android.providers.blockednumber"].contains(lower)) {
            return "system or settings package"
        }
        let fragments = ["launcher", "networkstack", "com.android.wifi", "com.google.android.wifi", "wifi.resources", "connectivity", "trichromelibrary", "inputmethod", "keyboard", ".ime", "inputdevices", "tvinput", "tv.input", "hdmi", "tuner", "bluetooth", "remote", "rcu", "setupwizard", "setupwraith", "bootwizard", "provision"]
        if fragments.contains(where: { lower.contains($0) }) { return "protected TV service" }
        if lower.range(of: #"updat|upgrad|(^|\.)(f|usb|remote|auth)?ota(\.|$)|otaupdat"#, options: .regularExpression) != nil { return "system updater" }
        return nil
    }

    private func loadState() throws -> HistoryState {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return HistoryState() }
        do { return try decoder.decode(HistoryState.self, from: Data(contentsOf: historyURL)) }
        catch { throw SafePackageError.corruptHistory }
    }

    private func saveState(_ state: HistoryState) throws {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: historyURL, options: .atomic)
        } catch { throw SafePackageError.persistence(error.localizedDescription) }
    }

    private func reconcile(_ deviceID: String, disabled: Set<String>, state: inout HistoryState) {
        guard var device = state.devices[deviceID] else { return }
        if let pending = device.pending {
            if pending.action == "disable", disabled.contains(pending.package), device.baseline?.contains(pending.package) != true {
                device.appDisabled.insert(pending.package)
                device.history.append(HistoryEntry(timestamp: Date(), action: "disable", packageName: pending.package))
            } else if pending.action == "enable", !disabled.contains(pending.package) {
                device.appDisabled.remove(pending.package)
                device.history.append(HistoryEntry(timestamp: Date(), action: "enable", packageName: pending.package))
            }
            device.pending = nil
        }
        device.appDisabled.formIntersection(disabled)
        state.devices[deviceID] = device
    }
}

private struct HistoryState: Codable {
    var devices: [String: DeviceHistory] = [:]
}

private struct DeviceHistory: Codable {
    var baseline: Set<String>?
    var appDisabled: Set<String> = []
    var history: [HistoryEntry] = []
    var pending: PendingMutation?
}

private struct PendingMutation: Codable {
    let action: String
    let package: String
}
