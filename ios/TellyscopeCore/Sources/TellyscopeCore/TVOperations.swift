// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum TVOperationsError: Error, LocalizedError, Equatable {
    case command(String)
    case invalidHostname
    case invalidPackage(String)
    case unsupportedPrivateDNS
    case privateDNSUnreachable(String)
    case unknownHome
    case launcherUnavailable(String)
    case protectedLauncher(String)
    case identityUnavailable
    case deviceChanged
    case busy
    case corruptHistory
    case persistence(String)
    case pendingOperation(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .command(let text), .refused(let text), .pendingOperation(let text): return text
        case .invalidHostname: return "Enter a DNS provider hostname, such as dns.adguard-dns.com."
        case .invalidPackage(let value): return "Invalid Android package name: \(value)"
        case .unsupportedPrivateDNS: return "Private DNS requires Android 9 or newer; this TV's version could not be confirmed."
        case .privateDNSUnreachable(let host): return "The TV could not resolve a name through \(host)."
        case .unknownHome: return "Could not confirm the TV's current Home app. No launcher was changed."
        case .launcherUnavailable(let value): return "\(value) is not an enabled, installed Home app on this TV."
        case .protectedLauncher(let value): return "Tellyscope will not turn off \(value); it is a protected TV service."
        case .identityUnavailable: return "The TV did not provide a stable serial number. Reconnect before changing settings."
        case .deviceChanged: return "The connected TV changed during this operation. Inspect the original TV before retrying."
        case .busy: return "Another TV operation is still running."
        case .corruptHistory: return "TV operation history is damaged; inspect the TV before retrying."
        case .persistence(let text): return "Could not save TV operation history; inspect the TV before retrying: \(text)"
        }
    }
}

public struct TVPreviousSetting: Codable, Equatable, Sendable {
    public let value: String?
    public init(_ value: String?) { self.value = value }
}

public enum TVOperationKind: String, Codable, Sendable {
    case privateDNS, animations, clearCaches, launcher, accessibility
}

public struct TVOperationEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: String
    public let date: Date
    public let kind: TVOperationKind
    public let summary: String
    public let previousSettings: [String: TVPreviousSetting]?
    public let fromActivity: String?
    public let toActivity: String?
    public let accessibilityService: String?
    public let addedAccessibilityService: Bool
    public let undoable: Bool
    public var undoneAt: Date?

    public var canUndo: Bool { undoable && undoneAt == nil }
}

public struct TVTweakSnapshot: Sendable {
    public let deviceID: String
    public let androidSDK: Int?
    public let privateDNSMode: String?
    public let privateDNSHost: String?
    public let animationScales: [String: String?]
    public let history: [TVOperationEntry]
}

public struct TVLauncherOption: Equatable, Identifiable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let activity: String
    public let name: String
    public let accessibilityService: String?
    public var isReviewed: Bool { TVOperations.reviewedAccessibilityPackages.contains(packageName) }
}

public struct TVLauncherSnapshot: Sendable {
    public let deviceID: String
    public let currentActivity: String?
    public let options: [TVLauncherOption]
}

public struct TVOperationChange: Sendable {
    public let deviceID: String
    public let entry: TVOperationEntry?
    public let changed: Bool
    public let cacheKilobytesFreed: Int64?
}

/// Reversible TV settings and launcher operations, serialized and journaled per TV identity.
public actor TVOperations {
    private let executor: any ShellExecutor
    private let historyURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var operationInProgress = false

    private static let dnsKeys = ["private_dns_specifier", "private_dns_mode"]
    private static let animationKeys = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
    private static let packagePattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#)
    private static let activityPattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+$"#)
    private static let hostnamePattern = try! NSRegularExpression(pattern: #"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"#)
    static let reviewedNames: [String: String] = [
        "com.spocky.projengmenu": "Projectivy Launcher",
        "com.overdevs.at4k": "AT4K Launcher",
        "com.spauldhaliwal.dispatch": "Dispatch",
        "me.efesser.flauncher": "FLauncher",
        "com.wolf.firelauncher": "Wolf Launcher",
        "ca.dstudio.atvlauncher.free": "ATV Launcher",
        "net.i.akihiro.halauncher": "HALauncher",
        "eu.chainfire.tv.sideloadlauncher": "Sideload Launcher",
    ]
    static let reviewedAccessibilityPackages: Set<String> = [
        "com.spocky.projengmenu", "com.overdevs.at4k", "com.spauldhaliwal.dispatch",
    ]

    public init(executor: any ShellExecutor, historyURL: URL) {
        self.executor = executor
        self.historyURL = historyURL
        encoder.outputFormatting = [.sortedKeys]
    }

    public func inspectTweaks() async throws -> TVTweakSnapshot {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await currentDeviceID()
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        let sdk = try await androidSDK()
        let dns = try await readSettings(Self.dnsKeys)
        let animations = try await readSettings(Self.animationKeys)
        try await confirmDevice(deviceID)
        return TVTweakSnapshot(
            deviceID: deviceID,
            androidSDK: sdk,
            privateDNSMode: dns["private_dns_mode"] ?? nil,
            privateDNSHost: dns["private_dns_specifier"] ?? nil,
            animationScales: animations,
            history: journal.entries.filter { $0.deviceID == deviceID }.sorted { $0.date > $1.date }
        )
    }

    public func history() async throws -> [TVOperationEntry] {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await currentDeviceID()
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        try await confirmDevice(deviceID)
        return journal.entries.filter { $0.deviceID == deviceID }.sorted { $0.date > $1.date }
    }

    public func setPrivateDNS(host: String?, expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        if let host, !Self.matches(host, Self.hostnamePattern) { throw TVOperationsError.invalidHostname }
        if host != nil, (try await androidSDK() ?? 0) < 28 { throw TVOperationsError.unsupportedPrivateDNS }

        var target: [String: String?]
        if let host {
            target = ["private_dns_specifier": host, "private_dns_mode": "hostname"]
        } else {
            // Automatic follows Android's default and preserves the remembered provider.
            target = ["private_dns_mode": "opportunistic"]
        }
        let before = try await readSettings(Array(target.keys))
        if Self.matches(target, current: before) { return TVOperationChange(deviceID: deviceID, entry: nil, changed: false, cacheKilobytesFreed: nil) }
        let pending = PendingOperation(kind: .privateDNS, previousSettings: Self.persist(before), targetSettings: Self.persist(target))
        journal.pending[deviceID] = pending
        try saveJournal(journal)

        do {
            try await writeSettings(target, deviceID: deviceID)
            let current = try await readSettings(Array(target.keys))
            guard Self.matches(target, current: current) else { throw TVOperationsError.refused("The TV did not keep the Private DNS setting.") }
            if let host, !(await resolvesNames()) { throw TVOperationsError.privateDNSUnreachable(host) }
            try await confirmDevice(deviceID)
            let entry = makeEntry(deviceID, kind: .privateDNS, summary: host.map { "Private DNS: \($0)" } ?? "Private DNS: Automatic", previous: before, undoable: true)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            return TVOperationChange(deviceID: deviceID, entry: entry, changed: true, cacheKilobytesFreed: nil)
        } catch {
            let restored = await restoreSettings(before, deviceID: deviceID)
            if restored {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
                if let failure = error as? TVOperationsError, case .privateDNSUnreachable(let host) = failure {
                    throw TVOperationsError.refused("The TV could not resolve a name through \(host); the previous Private DNS settings were restored.")
                }
                throw error
            }
            let entry = makeEntry(deviceID, kind: .privateDNS, summary: "Private DNS change needs review", previous: before, undoable: true)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            throw TVOperationsError.refused("Private DNS could not be verified or restored. Use Undo in operation history to restore the previous settings.")
        }
    }

    public func setFastAnimations(_ fast: Bool, expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        let scale = fast ? "0.5" : "1.0"
        let target = Dictionary(uniqueKeysWithValues: Self.animationKeys.map { ($0, Optional(scale)) })
        let before = try await readSettings(Self.animationKeys)
        if Self.matches(target, current: before) { return TVOperationChange(deviceID: deviceID, entry: nil, changed: false, cacheKilobytesFreed: nil) }
        journal.pending[deviceID] = PendingOperation(kind: .animations, previousSettings: Self.persist(before), targetSettings: Self.persist(target))
        try saveJournal(journal)
        do {
            try await writeSettings(target, deviceID: deviceID)
            let current = try await readSettings(Self.animationKeys)
            guard Self.matches(target, current: current) else { throw TVOperationsError.refused("The TV did not keep the animation setting.") }
            let entry = makeEntry(deviceID, kind: .animations, summary: fast ? "Animations: faster" : "Animations: default speed", previous: before, undoable: true)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            return TVOperationChange(deviceID: deviceID, entry: entry, changed: true, cacheKilobytesFreed: nil)
        } catch {
            if await restoreSettings(before, deviceID: deviceID) {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
                throw error
            }
            let entry = makeEntry(deviceID, kind: .animations, summary: "Animation change needs review", previous: before, undoable: true)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            throw TVOperationsError.refused("Animation settings could not be verified or restored. Use Undo in operation history.")
        }
    }

    public func clearCaches(expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        journal.pending[deviceID] = PendingOperation(kind: .clearCaches)
        try saveJournal(journal)
        do {
            let before = try await freeKilobytes()
            _ = try await checkedRun("pm trim-caches 999G 2>&1", deviceID: deviceID)
            let after = try await freeKilobytes()
            let freed = if let before, let after { max(0, after - before) } else { nil }
            let entry = makeEntry(deviceID, kind: .clearCaches, summary: "Cleared app caches; app data was kept", previous: nil, undoable: false)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            return TVOperationChange(deviceID: deviceID, entry: entry, changed: true, cacheKilobytesFreed: freed)
        } catch {
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            throw error
        }
    }

    public func launcherOptions() async throws -> TVLauncherSnapshot {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await currentDeviceID()
        let current = try await currentHome()
        let output = try await checkedRun("cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1", deviceID: deviceID)
        let components = Self.activities(output.output)
        guard !components.isEmpty else { throw TVOperationsError.unknownHome }
        var options: [TVLauncherOption] = []
        for activity in components {
            let package = Self.package(of: activity)
            guard Self.matches(package, Self.packagePattern), package != "android", !Self.protectedForDisable(package) else { continue }
            let installed = try await checkedRun("pm path \(package) 2>&1", deviceID: deviceID)
            guard installed.output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("package:") }) else { continue }
            let service = try await accessibilityService(package: package, deviceID: deviceID)
            options.append(TVLauncherOption(packageName: package, activity: activity, name: Self.reviewedNames[package] ?? package, accessibilityService: service))
        }
        try await confirmDevice(deviceID)
        return TVLauncherSnapshot(deviceID: deviceID, currentActivity: current, options: options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    public func makeHome(package: String, expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        guard Self.matches(package, Self.packagePattern) else { throw TVOperationsError.invalidPackage(package) }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        let oldActivity = try await currentHome()
        let output = try await checkedRun("cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1", deviceID: deviceID)
        guard let targetActivity = Self.activities(output.output).first(where: { Self.package(of: $0) == package }) else {
            throw TVOperationsError.launcherUnavailable(package)
        }
        let installCheck = try await checkedRun("pm path \(package) 2>&1", deviceID: deviceID)
        guard installCheck.output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("package:") }) else {
            throw TVOperationsError.launcherUnavailable(package)
        }
        guard oldActivity != targetActivity else { return TVOperationChange(deviceID: deviceID, entry: nil, changed: false, cacheKilobytesFreed: nil) }
        let disabled = try await disabledPackages(deviceID)
        guard !disabled.contains(package) else { throw TVOperationsError.launcherUnavailable(package) }
        let oldPackage = oldActivity.map(Self.package(of:))
        if let oldPackage, Self.protectedForDisable(oldPackage) { throw TVOperationsError.protectedLauncher(oldPackage) }
        let oldWasDisabled = oldPackage.map(disabled.contains) ?? false
        journal.pending[deviceID] = PendingOperation(kind: .launcher, fromActivity: oldActivity, toActivity: targetActivity, fromWasDisabled: oldWasDisabled)
        try saveJournal(journal)

        do {
            try await setHome(targetActivity, deviceID: deviceID)
            let afterSet = try await currentHome()
            guard afterSet == targetActivity else {
                await restoreHome(oldActivity, deviceID: deviceID)
                throw TVOperationsError.refused("The TV did not open the selected launcher as Home; the previous Home was restored when possible.")
            }
            if let oldPackage {
                _ = try await checkedRun("pm disable-user --user 0 \(oldPackage) 2>&1", deviceID: deviceID)
                guard try await disabledPackages(deviceID).contains(oldPackage) else { throw TVOperationsError.refused("The previous launcher did not turn off.") }
                guard try await currentHome() == targetActivity else { throw TVOperationsError.refused("The selected launcher stopped resolving as Home after the previous launcher was turned off.") }
            }
            let entry = TVOperationEntry(id: UUID(), deviceID: deviceID, date: Date(), kind: .launcher, summary: "Home: \(Self.reviewedNames[package] ?? package)", previousSettings: nil, fromActivity: oldActivity, toActivity: targetActivity, accessibilityService: nil, addedAccessibilityService: false, undoable: oldActivity != nil, undoneAt: nil)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            return TVOperationChange(deviceID: deviceID, entry: entry, changed: true, cacheKilobytesFreed: nil)
        } catch {
            let rollbackOK = await restoreHome(oldActivity, deviceID: deviceID)
            if rollbackOK {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
                throw error
            }
            throw TVOperationsError.refused("The launcher switch did not finish cleanly. History kept the recovery intent; reconnect and inspect Home before trying again.")
        }
    }

    public func enableLauncherAccessibility(package: String, consent: Bool, expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        guard consent else { throw TVOperationsError.refused("Accessibility service was not enabled because consent was not given.") }
        guard Self.matches(package, Self.packagePattern), Self.reviewedAccessibilityPackages.contains(package) else { throw TVOperationsError.launcherUnavailable(package) }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        guard let service = try await accessibilityService(package: package, deviceID: deviceID) else {
            throw TVOperationsError.refused("No accessibility service for the reviewed launcher was found on this TV.")
        }
        let before = try await readSettings(["enabled_accessibility_services", "accessibility_enabled"])
        let oldServices = Self.serviceEntries(before["enabled_accessibility_services"] ?? nil)
        let serviceWasPresent = oldServices.contains { Self.sameService($0, service) }
        let unrelated = oldServices.filter { !Self.sameService($0, service) }
        let oldMaster = before["accessibility_enabled"] ?? nil
        if oldMaster != "1", !unrelated.isEmpty {
            throw TVOperationsError.refused("Accessibility is off, but other services are configured: \(unrelated.joined(separator: ", ")). Tellyscope will not activate them. Review or remove those services in TV Settings, then retry.")
        }
        let addedService = !serviceWasPresent
        let nextServices = Self.addService(service, to: oldServices)
        var target: [String: String?] = ["accessibility_enabled": "1"]
        if addedService { target["enabled_accessibility_services"] = nextServices.joined(separator: ":") }
        if Self.matches(target, current: before), serviceWasPresent {
            return TVOperationChange(deviceID: deviceID, entry: nil, changed: false, cacheKilobytesFreed: nil)
        }
        let previous: [String: String?] = ["accessibility_enabled": oldMaster]
        journal.pending[deviceID] = PendingOperation(kind: .accessibility, previousSettings: Self.persist(previous), targetSettings: Self.persist(target), accessibilityService: service, accessibilityServiceWasPresent: serviceWasPresent)
        try saveJournal(journal)
        do {
            try await writeSettings(target, deviceID: deviceID)
            let current = try await readSettings(["enabled_accessibility_services", "accessibility_enabled"])
            guard Self.matches(target, current: current), Self.serviceEntries(current["enabled_accessibility_services"] ?? nil).contains(where: { Self.sameService($0, service) }) else {
                throw TVOperationsError.refused("The TV did not keep the reviewed launcher's accessibility service enabled.")
            }
            let entry = makeEntry(deviceID, kind: .accessibility, summary: "Enabled \(Self.reviewedNames[package] ?? package) accessibility service with consent", previous: previous, undoable: true, service: service, addedService: addedService)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            return TVOperationChange(deviceID: deviceID, entry: entry, changed: true, cacheKilobytesFreed: nil)
        } catch {
            if await rollbackAccessibility(service: service, addedService: addedService, previousMaster: oldMaster, deviceID: deviceID) {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
                throw error
            }
            let entry = makeEntry(deviceID, kind: .accessibility, summary: "Accessibility change needs review", previous: previous, undoable: true, service: service, addedService: addedService)
            journal.entries.append(entry)
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
            throw TVOperationsError.refused("The accessibility setting could not be verified or restored. Use Undo to restore the previous service list.")
        }
    }

    public func undo(entryID: UUID, expectedDeviceID: String? = nil) async throws -> TVOperationChange {
        try enter()
        defer { operationInProgress = false }
        let deviceID = try await checkedIdentity(expectedDeviceID)
        var journal = try loadJournal()
        try await reconcilePending(deviceID, journal: &journal)
        guard let index = journal.entries.firstIndex(where: { $0.id == entryID && $0.deviceID == deviceID }), journal.entries[index].canUndo else {
            throw TVOperationsError.refused("This operation is no longer available to undo.")
        }
        let entry = journal.entries[index]
        let reverse: TVOperationEntry
        switch entry.kind {
        case .privateDNS, .animations:
            guard let stored = entry.previousSettings else { throw TVOperationsError.corruptHistory }
            let previous = Self.unpersist(stored)
            let now = try await readSettings(Array(previous.keys))
            journal.pending[deviceID] = PendingOperation(kind: entry.kind, previousSettings: Self.persist(now), targetSettings: Self.persist(previous), undoing: entryID)
            try saveJournal(journal)
            try await writeSettings(previous, deviceID: deviceID)
            let verified = try await readSettings(Array(previous.keys))
            guard Self.matches(previous, current: verified) else { throw TVOperationsError.refused("The TV did not restore the previous settings; the operation remains available to retry.") }
            reverse = makeEntry(deviceID, kind: entry.kind, summary: "Undid: \(entry.summary)", previous: now, undoable: true)
        case .accessibility:
            guard let service = entry.accessibilityService else { throw TVOperationsError.corruptHistory }
            guard let storedMaster = entry.previousSettings?["accessibility_enabled"] else { throw TVOperationsError.corruptHistory }
            let keys = ["enabled_accessibility_services", "accessibility_enabled"]
            let now = try await readSettings(keys)
            var currentServices = Self.serviceEntries(now["enabled_accessibility_services"] ?? nil)
            if entry.addedAccessibilityService { currentServices.removeAll { Self.sameService($0, service) } }
            let remainingServices = currentServices.filter { !Self.sameService($0, service) }
            var target: [String: String?] = [:]
            if entry.addedAccessibilityService {
                target.updateValue(currentServices.isEmpty ? nil : currentServices.joined(separator: ":"), forKey: "enabled_accessibility_services")
            }
            if remainingServices.isEmpty { target.updateValue(storedMaster.value, forKey: "accessibility_enabled") }
            journal.pending[deviceID] = PendingOperation(kind: .accessibility, previousSettings: Self.persist(now), targetSettings: Self.persist(target), accessibilityService: service, accessibilityServiceWasPresent: !entry.addedAccessibilityService, undoing: entryID)
            try saveJournal(journal)
            if !target.isEmpty { try await writeSettings(target, deviceID: deviceID) }
            let verified = try await readSettings(keys)
            let servicePresent = Self.serviceEntries(verified["enabled_accessibility_services"] ?? nil).contains { Self.sameService($0, service) }
            guard servicePresent == !entry.addedAccessibilityService, Self.matches(target, current: verified) else {
                throw TVOperationsError.refused("The TV did not safely restore the accessibility settings; Undo remains available to retry.")
            }
            reverse = makeEntry(deviceID, kind: .accessibility, summary: "Undid: \(entry.summary)", previous: nil, undoable: false, service: service, addedService: false)
        case .launcher:
            guard let from = entry.fromActivity, let to = entry.toActivity else { throw TVOperationsError.refused("This launcher change has no previous Home to restore.") }
            guard try await currentHome() == to else { throw TVOperationsError.refused("Home changed since this operation; no launcher was changed.") }
            let oldPackage = Self.package(of: from)
            guard Self.matches(oldPackage, Self.packagePattern), Self.matches(from, Self.activityPattern) else { throw TVOperationsError.corruptHistory }
            journal.pending[deviceID] = PendingOperation(kind: .launcher, fromActivity: to, toActivity: from, fromWasDisabled: false, undoing: entryID)
            try saveJournal(journal)
            let disabled = try await disabledPackages(deviceID)
            if disabled.contains(oldPackage) {
                _ = try await checkedRun("pm enable --user 0 \(oldPackage) 2>&1", deviceID: deviceID)
                guard !(try await disabledPackages(deviceID)).contains(oldPackage) else { throw TVOperationsError.refused("The previous launcher did not turn back on.") }
            }
            try await setHome(from, deviceID: deviceID)
            guard try await currentHome() == from else {
                await restoreHome(to, deviceID: deviceID)
                throw TVOperationsError.refused("The TV did not switch back to the previous Home.")
            }
            reverse = TVOperationEntry(id: UUID(), deviceID: deviceID, date: Date(), kind: .launcher, summary: "Switched Home back to \(oldPackage)", previousSettings: nil, fromActivity: to, toActivity: from, accessibilityService: nil, addedAccessibilityService: false, undoable: true, undoneAt: nil)
        case .clearCaches:
            throw TVOperationsError.refused("Cache cleanup cannot be undone.")
        }
        journal.entries[index].undoneAt = Date()
        journal.entries.append(reverse)
        journal.pending.removeValue(forKey: deviceID)
        try saveJournal(journal)
        return TVOperationChange(deviceID: deviceID, entry: reverse, changed: true, cacheKilobytesFreed: nil)
    }

    private func enter() throws {
        guard !operationInProgress else { throw TVOperationsError.busy }
        operationInProgress = true
    }

    private func checkedIdentity(_ expected: String?) async throws -> String {
        let id = try await currentDeviceID()
        if let expected, expected != id { throw TVOperationsError.deviceChanged }
        return id
    }

    private func currentDeviceID() async throws -> String {
        let result = try await executor.run("getprop ro.serialno; getprop ro.boot.serialno")
        guard result.exitCode == 0 else { throw TVOperationsError.identityUnavailable }
        let serial = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !["unknown", "null", "0123456789abcdef", "0000000000000000", "123456789"].contains($0.lowercased()) }
        guard let serial else { throw TVOperationsError.identityUnavailable }
        return "serial:\(serial)"
    }

    private func confirmDevice(_ expected: String) async throws {
        guard try await currentDeviceID() == expected else { throw TVOperationsError.deviceChanged }
    }

    private func checkedRun(_ command: String, deviceID: String) async throws -> ShellResult {
        try await confirmDevice(deviceID)
        let result = try await executor.run(command)
        guard result.exitCode == 0, !Self.isShellError(result.output) else {
            throw TVOperationsError.command(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The TV refused the command." : result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await confirmDevice(deviceID)
        return result
    }

    private func readSettings(_ keys: [String]) async throws -> [String: String?] {
        let output = try await executor.run(keys.map { "settings get \(Self.settingsNamespace($0)) \($0)" }.joined(separator: "; "))
        guard output.exitCode == 0, !Self.isShellError(output.output) else { throw TVOperationsError.command(output.output) }
        let lines = output.output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count == keys.count else { throw TVOperationsError.refused("The TV returned an incomplete settings result.") }
        return Dictionary(uniqueKeysWithValues: zip(keys, lines).map { key, value in
            (key, value.isEmpty || value == "null" ? nil : value)
        })
    }

    private func writeSettings(_ values: [String: String?], deviceID: String) async throws {
        let allowed = Set(Self.dnsKeys + Self.animationKeys + ["enabled_accessibility_services", "accessibility_enabled"])
        guard !values.isEmpty, Set(values.keys).isSubset(of: allowed) else { throw TVOperationsError.corruptHistory }
        let order = Self.dnsKeys + Self.animationKeys + ["enabled_accessibility_services", "accessibility_enabled"]
        let secureCommands = order.filter { ["enabled_accessibility_services", "accessibility_enabled"].contains($0) && values.keys.contains($0) }.map { key -> String in
            Self.settingCommand(key, value: values[key] ?? nil)
        }
        let globalCommands = order.filter { !["enabled_accessibility_services", "accessibility_enabled"].contains($0) && values.keys.contains($0) }.map { key in
            Self.settingCommand(key, value: values[key] ?? nil)
        }
        for command in globalCommands + secureCommands {
            _ = try await checkedRun(command + " 2>&1", deviceID: deviceID)
        }
    }

    private func restoreSettings(_ settings: [String: String?], deviceID: String) async -> Bool {
        do {
            try await writeSettings(settings, deviceID: deviceID)
            return Self.matches(settings, current: try await readSettings(Array(settings.keys)))
        } catch { return false }
    }

    private func rollbackAccessibility(service: String, addedService: Bool, previousMaster: String?, deviceID: String) async -> Bool {
        do {
            let keys = ["enabled_accessibility_services", "accessibility_enabled"]
            let current = try await readSettings(keys)
            var services = Self.serviceEntries(current["enabled_accessibility_services"] ?? nil)
            if addedService { services.removeAll { Self.sameService($0, service) } }
            let others = services.filter { !Self.sameService($0, service) }
            var target: [String: String?] = [:]
            if addedService { target.updateValue(services.isEmpty ? nil : services.joined(separator: ":"), forKey: "enabled_accessibility_services") }
            if others.isEmpty { target.updateValue(previousMaster, forKey: "accessibility_enabled") }
            if !target.isEmpty { try await writeSettings(target, deviceID: deviceID) }
            let verified = try await readSettings(keys)
            let present = Self.serviceEntries(verified["enabled_accessibility_services"] ?? nil).contains { Self.sameService($0, service) }
            return present == !addedService && Self.matches(target, current: verified)
        } catch { return false }
    }

    private func androidSDK() async throws -> Int? {
        let result = try await executor.run("getprop ro.build.version.sdk")
        guard result.exitCode == 0 else { return nil }
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolvesNames() async -> Bool {
        for attempt in 0..<3 {
            do {
                let result = try await executor.run("ping -c1 -W3 connectivitycheck.gstatic.com 2>&1")
                if !result.output.lowercased().contains("unknown host") { return true }
            } catch { }
            if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
        }
        return false
    }

    private func freeKilobytes() async throws -> Int64? {
        let result = try await executor.run("df -k /data")
        guard result.exitCode == 0 else { return nil }
        let numbers = result.output.split(whereSeparator: \.isNewline).dropFirst().joined(separator: " ").split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        guard numbers.count >= 2 else { return nil }
        return max(0, numbers[0] - numbers[1])
    }

    private func disabledPackages(_ deviceID: String) async throws -> Set<String> {
        let result = try await checkedRun("pm list packages -d --user 0", deviceID: deviceID)
        let lines = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.allSatisfy({ $0.hasPrefix("package:") && Self.matches(String($0.dropFirst(8)), Self.packagePattern) }) else {
            throw TVOperationsError.refused("The TV returned an unreadable disabled-package list.")
        }
        return Set(lines.map { String($0.dropFirst(8)) })
    }

    private func currentHome() async throws -> String? {
        let result = try await executor.run("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        guard result.exitCode == 0 else { throw TVOperationsError.unknownHome }
        let components = Self.activities(result.output)
        guard components.count <= 1 else { throw TVOperationsError.unknownHome }
        guard let component = components.first, Self.package(of: component) != "android" else { return nil }
        return component
    }

    private func setHome(_ activity: String, deviceID: String) async throws {
        guard Self.matches(activity, Self.activityPattern) else { throw TVOperationsError.corruptHistory }
        _ = try await checkedRun("cmd package set-home-activity --user 0 '\(activity)' 2>&1", deviceID: deviceID)
    }

    private func restoreHome(_ activity: String?, deviceID: String) async -> Bool {
        do {
            if let activity {
                let package = Self.package(of: activity)
            let disabledBeforeRollback = try await disabledPackages(deviceID)
            if disabledBeforeRollback.contains(package) {
                    _ = try await checkedRun("pm enable --user 0 \(package) 2>&1", deviceID: deviceID)
                let disabledAfterRollback = try await disabledPackages(deviceID)
                guard !disabledAfterRollback.contains(package) else { return false }
                }
                try await setHome(activity, deviceID: deviceID)
            }
            let current = try await currentHome()
            if current == activity { return true }
            // No prior default existed, so don't invent a preferred Home while rolling back.
            return false
        } catch { return false }
    }

    private func accessibilityService(package: String, deviceID: String) async throws -> String? {
        guard Self.reviewedAccessibilityPackages.contains(package) else { return nil }
        let result = try await checkedRun("cmd package query-services --brief -a android.accessibilityservice.AccessibilityService 2>&1", deviceID: deviceID)
        return Self.activities(result.output).first { Self.package(of: $0) == package }
    }

    private func reconcilePending(_ deviceID: String, journal: inout TVOperationJournal) async throws {
        guard let pending = journal.pending[deviceID] else { return }
        switch pending.kind {
        case .privateDNS, .animations:
            let target = Self.unpersist(pending.targetSettings ?? [:])
            let previous = Self.unpersist(pending.previousSettings ?? [:])
            let current = try await readSettings(Array(target.keys))
            if Self.matches(target, current: current) {
                if let undoing = pending.undoing, let index = journal.entries.firstIndex(where: { $0.id == undoing && $0.deviceID == deviceID }) {
                    journal.entries[index].undoneAt = Date()
                    journal.entries.append(makeEntry(deviceID, kind: pending.kind, summary: "Recovered undo: \(journal.entries[index].summary)", previous: previous, undoable: true))
                } else {
                    journal.entries.append(makeEntry(deviceID, kind: pending.kind, summary: "Recovered interrupted \(pending.kind.rawValue) change", previous: previous, undoable: true))
                }
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else if Self.matches(previous, current: current) {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else {
                throw TVOperationsError.pendingOperation("A previous TV setting change stopped midway. Its result is unclear; inspect the TV settings before making another change.")
            }
        case .accessibility:
            guard let service = pending.accessibilityService else { throw TVOperationsError.corruptHistory }
            let current = try await readSettings(["enabled_accessibility_services", "accessibility_enabled"])
            let services = Self.serviceEntries(current["enabled_accessibility_services"] ?? nil)
            let servicePresent = services.contains { Self.sameService($0, service) }
            let master = current["accessibility_enabled"] ?? nil
            let previousMaster = Self.unpersist(pending.previousSettings ?? [:])["accessibility_enabled"] ?? nil
            let target = Self.unpersist(pending.targetSettings ?? [:])
            if let undoing = pending.undoing {
                let desiredPresence = pending.accessibilityServiceWasPresent
                if servicePresent == desiredPresence && Self.matches(target, current: current) {
                    guard let index = journal.entries.firstIndex(where: { $0.id == undoing && $0.deviceID == deviceID }) else { throw TVOperationsError.corruptHistory }
                    journal.entries[index].undoneAt = Date()
                    journal.entries.append(makeEntry(deviceID, kind: .accessibility, summary: "Recovered accessibility undo", previous: nil, undoable: false, service: service))
                    journal.pending.removeValue(forKey: deviceID)
                    try saveJournal(journal)
                } else if master == previousMaster && servicePresent {
                    journal.pending.removeValue(forKey: deviceID)
                    try saveJournal(journal)
                } else {
                    throw TVOperationsError.pendingOperation("An accessibility change stopped midway. Its service list or master switch is unclear; inspect TV Settings before retrying.")
                }
            } else if servicePresent && master == "1" {
                let previous: [String: String?] = ["accessibility_enabled": previousMaster]
                journal.entries.append(makeEntry(deviceID, kind: .accessibility, summary: "Recovered interrupted accessibility change", previous: previous, undoable: true, service: service, addedService: !pending.accessibilityServiceWasPresent))
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else if servicePresent == pending.accessibilityServiceWasPresent && master == previousMaster {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else {
                throw TVOperationsError.pendingOperation("An accessibility change stopped midway. Its service list or master switch is unclear; inspect TV Settings before retrying.")
            }
        case .launcher:
            let home = try await currentHome()
            let oldPackage = pending.fromActivity.map(Self.package(of:))
            let disabled = try await disabledPackages(deviceID)
            let isOldDisabled = oldPackage.map(disabled.contains) ?? false
            if pending.undoing != nil, home == pending.toActivity {
                if let undoing = pending.undoing, let index = journal.entries.firstIndex(where: { $0.id == undoing && $0.deviceID == deviceID }) {
                    journal.entries[index].undoneAt = Date()
                    journal.entries.append(TVOperationEntry(id: UUID(), deviceID: deviceID, date: Date(), kind: .launcher, summary: "Recovered Home switchback", previousSettings: nil, fromActivity: pending.fromActivity, toActivity: pending.toActivity, accessibilityService: nil, addedAccessibilityService: false, undoable: true, undoneAt: nil))
                }
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else if pending.undoing != nil, home == pending.fromActivity {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else if home == pending.toActivity {
                journal.entries.append(TVOperationEntry(id: UUID(), deviceID: deviceID, date: Date(), kind: .launcher, summary: "Recovered interrupted Home switch", previousSettings: nil, fromActivity: pending.fromActivity, toActivity: pending.toActivity, accessibilityService: nil, addedAccessibilityService: false, undoable: pending.fromActivity != nil, undoneAt: nil))
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else if home == pending.fromActivity, !isOldDisabled {
                journal.pending.removeValue(forKey: deviceID)
                try saveJournal(journal)
            } else {
                throw TVOperationsError.pendingOperation("A launcher switch stopped midway. Home or launcher state is unclear; reconnect and inspect the TV before changing it again.")
            }
        case .clearCaches:
            journal.entries.append(makeEntry(deviceID, kind: .clearCaches, summary: "Cache cleanup interrupted; app data was not cleared", previous: nil, undoable: false))
            journal.pending.removeValue(forKey: deviceID)
            try saveJournal(journal)
        }
    }

    private func makeEntry(_ deviceID: String, kind: TVOperationKind, summary: String, previous: [String: String?]?, undoable: Bool, service: String? = nil, addedService: Bool = false) -> TVOperationEntry {
        TVOperationEntry(id: UUID(), deviceID: deviceID, date: Date(), kind: kind, summary: summary, previousSettings: previous.map(Self.persist), fromActivity: nil, toActivity: nil, accessibilityService: service, addedAccessibilityService: addedService, undoable: undoable, undoneAt: nil)
    }

    private func loadJournal() throws -> TVOperationJournal {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return TVOperationJournal() }
        do { return try decoder.decode(TVOperationJournal.self, from: Data(contentsOf: historyURL)) }
        catch { throw TVOperationsError.corruptHistory }
    }

    private func saveJournal(_ journal: TVOperationJournal) throws {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(journal).write(to: historyURL, options: .atomic)
        } catch { throw TVOperationsError.persistence(error.localizedDescription) }
    }

    private static func matches(_ value: String, _ regex: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    private static func matches(_ expected: [String: String?], current: [String: String?]) -> Bool {
        expected.allSatisfy { key, value in (current[key] ?? nil) == value }
    }

    private static func persist(_ values: [String: String?]) -> [String: TVPreviousSetting] {
        values.mapValues(TVPreviousSetting.init)
    }

    private static func unpersist(_ values: [String: TVPreviousSetting]) -> [String: String?] {
        values.mapValues(\.value)
    }

    private static func activities(_ output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { matches($0, activityPattern) })).sorted()
    }

    private static func package(of activity: String) -> String { String(activity.prefix { $0 != "/" }) }

    private static func serviceEntries(_ value: String?) -> [String] {
        guard let value, value != "null" else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func fullService(_ value: String) -> String {
        let package = package(of: value)
        let name = String(value.dropFirst(package.count + 1))
        return package + "/" + (name.hasPrefix(".") ? package + name : name)
    }

    private static func sameService(_ lhs: String, _ rhs: String) -> Bool { fullService(lhs) == fullService(rhs) }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func settingsNamespace(_ key: String) -> String {
        ["enabled_accessibility_services", "accessibility_enabled"].contains(key) ? "secure" : "global"
    }

    private static func settingCommand(_ key: String, value: String?) -> String {
        guard let value else { return "settings delete \(settingsNamespace(key)) \(key)" }
        return "settings put \(settingsNamespace(key)) \(key) \(shellQuote(value))"
    }

    private static func addService(_ service: String, to values: [String]) -> [String] {
        values.contains(where: { sameService($0, service) }) ? values : values + [service]
    }

    private static func isShellError(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.hasPrefix("error:") || value.hasPrefix("exception:") || value.hasPrefix("failure[") || value.contains("securityexception")
        }
    }

    private static func protectedForDisable(_ package: String) -> Bool {
        let lower = package.lowercased()
        let exact: Set<String> = ["android", "com.android.settings", "com.android.tv.settings", "com.amazon.tv.settings.v2", "com.android.systemui", "com.android.shell", "com.android.phone", "com.android.vending", "com.google.android.gms", "com.google.android.gsf", "com.google.android.webview", "com.android.webview"]
        let fragments = ["networkstack", "com.android.wifi", "com.google.android.wifi", "wifi.resources", "connectivity", "trichromelibrary", "inputmethod", "keyboard", ".ime", "inputdevices", "tvinput", "tv.input", "hdmi", "tuner", "bluetooth", "remote", "rcu", "setupwizard", "setupwraith", "bootwizard", "provision", "updat", "upgrad"]
        return exact.contains(lower) || lower.hasPrefix("com.android.providers.") && !["com.android.providers.calendar", "com.android.providers.contacts", "com.android.providers.userdictionary", "com.android.providers.blockednumber"].contains(lower) || fragments.contains(where: { lower.contains($0) }) || lower.range(of: #"(^|\.)(f|usb|remote|auth)?ota(\.|$)"#, options: .regularExpression) != nil
    }
}

private struct TVOperationJournal: Codable {
    var entries: [TVOperationEntry] = []
    var pending: [String: PendingOperation] = [:]
}

private struct PendingOperation: Codable {
    let kind: TVOperationKind
    var previousSettings: [String: TVPreviousSetting]?
    var targetSettings: [String: TVPreviousSetting]?
    var fromActivity: String?
    var toActivity: String?
    var accessibilityService: String?
    var accessibilityServiceWasPresent: Bool
    var fromWasDisabled: Bool
    var undoing: UUID?

    init(kind: TVOperationKind, previousSettings: [String: TVPreviousSetting]? = nil, targetSettings: [String: TVPreviousSetting]? = nil, fromActivity: String? = nil, toActivity: String? = nil, accessibilityService: String? = nil, accessibilityServiceWasPresent: Bool = false, fromWasDisabled: Bool = false, undoing: UUID? = nil) {
        self.kind = kind
        self.previousSettings = previousSettings
        self.targetSettings = targetSettings
        self.fromActivity = fromActivity
        self.toActivity = toActivity
        self.accessibilityService = accessibilityService
        self.accessibilityServiceWasPresent = accessibilityServiceWasPresent
        self.fromWasDisabled = fromWasDisabled
        self.undoing = undoing
    }
}
