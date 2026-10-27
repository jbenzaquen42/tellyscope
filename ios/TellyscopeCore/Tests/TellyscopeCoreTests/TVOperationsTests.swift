// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import TellyscopeCore

final class TVOperationsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSettingsUndoRestoresUnsetProviderAndPriorMode() async throws {
        let shell = FakeTVShell(settings: ["private_dns_mode": "off"])
        let file = historyURL()
        let operations = TVOperations(executor: shell, historyURL: file)
        let change = try await operations.setPrivateDNS(host: "dns.example")
        XCTAssertTrue(change.changed)
        let appliedHost = await shell.setting("private_dns_specifier")
        XCTAssertEqual(appliedHost, "dns.example")
        let history = try await operations.history()
        XCTAssertEqual(history.first?.previousSettings?["private_dns_specifier"], TVPreviousSetting(nil))
        _ = try await operations.undo(entryID: try XCTUnwrap(change.entry?.id), expectedDeviceID: "serial:TV-123")
        let restoredHost = await shell.setting("private_dns_specifier")
        let restoredMode = await shell.setting("private_dns_mode")
        XCTAssertNil(restoredHost)
        XCTAssertEqual(restoredMode, "off")
    }

    func testIdentityMismatchAndUnknownSerialNeverMutate() async throws {
        let shell = FakeTVShell()
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.setFastAnimations(true, expectedDeviceID: "serial:OTHER"); XCTFail("expected identity mismatch") }
        catch let error as TVOperationsError { XCTAssertEqual(error, .deviceChanged) }
        await shell.setSerial("unknown")
        do { _ = try await operations.setFastAnimations(true); XCTFail("expected missing identity") }
        catch let error as TVOperationsError { XCTAssertEqual(error, .identityUnavailable) }
        let commands = await shell.commands()
        XCTAssertFalse(commands.contains { $0.hasPrefix("settings put") })
    }

    func testUnreachablePrivateDNSProviderRestoresPriorSettings() async throws {
        let shell = FakeTVShell(settings: ["private_dns_specifier": "old.dns.example", "private_dns_mode": "hostname"])
        await shell.setDNSFails(true)
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.setPrivateDNS(host: "dns.blocked.example"); XCTFail("expected DNS rollback") }
        catch let error as TVOperationsError { XCTAssertTrue(error.localizedDescription.contains("restored")) }
        let host = await shell.setting("private_dns_specifier")
        let mode = await shell.setting("private_dns_mode")
        let history = try await operations.history()
        XCTAssertEqual(host, "old.dns.example")
        XCTAssertEqual(mode, "hostname")
        XCTAssertTrue(history.isEmpty)
    }

    func testHomeResolutionFailureRollsBackWithoutDisablingOldLauncher() async throws {
        let shell = FakeTVShell()
        await shell.setAcceptHome(false)
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.makeHome(package: "com.spocky.projengmenu"); XCTFail("expected Home verification failure") }
        catch let error as TVOperationsError { XCTAssertTrue(error.localizedDescription.contains("did not open")) }
        let commands = await shell.commands()
        let currentHome = await shell.home()
        let history = try await operations.history()
        XCTAssertFalse(commands.contains { $0.hasPrefix("pm disable-user") })
        XCTAssertEqual(currentHome, "com.google.android.tvlauncher/.MainActivity")
        XCTAssertTrue(history.isEmpty)
    }

    func testVerifiedHomeSwitchCanBeUndone() async throws {
        let shell = FakeTVShell()
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        let change = try await operations.makeHome(package: "com.spocky.projengmenu")
        let switchedHome = await shell.home()
        let oldDisabled = await shell.isDisabled("com.google.android.tvlauncher")
        XCTAssertEqual(switchedHome, "com.spocky.projengmenu/.ui.home.MainActivity")
        XCTAssertTrue(oldDisabled)
        _ = try await operations.undo(entryID: try XCTUnwrap(change.entry?.id), expectedDeviceID: "serial:TV-123")
        let restoredHome = await shell.home()
        let oldDisabledAfterUndo = await shell.isDisabled("com.google.android.tvlauncher")
        let targetDisabledAfterUndo = await shell.isDisabled("com.spocky.projengmenu")
        XCTAssertEqual(restoredHome, "com.google.android.tvlauncher/.MainActivity")
        XCTAssertFalse(oldDisabledAfterUndo)
        XCTAssertFalse(targetDisabledAfterUndo)
    }

    func testAccessibilityNeedsSeparateConsentAndKeepsOtherServices() async throws {
        let original = "com.talkback/.Talk"
        let shell = FakeTVShell(settings: ["enabled_accessibility_services": original, "accessibility_enabled": "1"])
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.enableLauncherAccessibility(package: "com.spocky.projengmenu", consent: false); XCTFail("expected separate consent") }
        catch let error as TVOperationsError { XCTAssertTrue(error.localizedDescription.contains("consent")) }
        let unchangedServices = await shell.setting("enabled_accessibility_services")
        XCTAssertEqual(unchangedServices, original)
        let change = try await operations.enableLauncherAccessibility(package: "com.spocky.projengmenu", consent: true)
        let services = await shell.setting("enabled_accessibility_services") ?? ""
        XCTAssertTrue(services.contains(original))
        XCTAssertTrue(services.contains("com.spocky.projengmenu/.HomeService"))
        XCTAssertTrue(change.changed)
    }

    func testAccessibilityRefusesToActivateUnrelatedDormantServices() async throws {
        let unrelated = "com.talkback/.Talk"
        let shell = FakeTVShell(settings: ["enabled_accessibility_services": unrelated, "accessibility_enabled": "0"])
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.enableLauncherAccessibility(package: "com.spocky.projengmenu", consent: true); XCTFail("expected dormant service refusal") }
        catch let error as TVOperationsError { XCTAssertTrue(error.localizedDescription.contains(unrelated)) }
        let services = await shell.setting("enabled_accessibility_services")
        let master = await shell.setting("accessibility_enabled")
        let history = try await operations.history()
        XCTAssertEqual(services, unrelated)
        XCTAssertEqual(master, "0")
        XCTAssertTrue(history.isEmpty)
    }

    func testAccessibilityOnlyAllowsLaunchersReviewedForAccessibility() async throws {
        let shell = FakeTVShell(settings: ["accessibility_enabled": "1"])
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        do { _ = try await operations.enableLauncherAccessibility(package: "me.efesser.flauncher", consent: true); XCTFail("expected unreviewed service refusal") }
        catch let error as TVOperationsError { XCTAssertTrue(error.localizedDescription.contains("not an enabled, installed Home app")) }
        let commands = await shell.commands()
        XCTAssertFalse(commands.contains { $0.hasPrefix("settings put") })
    }

    func testAccessibilityUndoPreservesServicesAddedLater() async throws {
        let later = "com.reader/.Reader"
        let shell = FakeTVShell(settings: ["accessibility_enabled": "0"])
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        let change = try await operations.enableLauncherAccessibility(package: "com.spocky.projengmenu", consent: true)
        await shell.setSetting("enabled_accessibility_services", "\(later):com.spocky.projengmenu/.HomeService")
        _ = try await operations.undo(entryID: try XCTUnwrap(change.entry?.id), expectedDeviceID: "serial:TV-123")
        let services = await shell.setting("enabled_accessibility_services") ?? ""
        let master = await shell.setting("accessibility_enabled")
        XCTAssertTrue(services.contains(later))
        XCTAssertFalse(services.contains("com.spocky.projengmenu/.HomeService"))
        XCTAssertEqual(master, "1")
    }

    func testCacheCleanupDoesNotClearAppDataAndCannotBeUndone() async throws {
        let shell = FakeTVShell()
        let operations = TVOperations(executor: shell, historyURL: historyURL())
        let change = try await operations.clearCaches()
        XCTAssertTrue(change.changed)
        XCTAssertEqual(change.cacheKilobytesFreed, 300)
        let commands = await shell.commands()
        XCTAssertFalse(commands.contains { $0.contains("pm clear") })
        XCTAssertFalse(try XCTUnwrap(change.entry).canUndo)
    }

    func testPersistenceFailureStopsBeforeSettingsWrite() async throws {
        let blocked = historyURL()
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked)
        let shell = FakeTVShell()
        let operations = TVOperations(executor: shell, historyURL: blocked.appendingPathComponent("history.json"))
        do { _ = try await operations.setFastAnimations(true); XCTFail("expected persistence error") }
        catch let error as TVOperationsError { if case .persistence(_) = error {} else { XCTFail("unexpected error: \(error)") } }
        let commands = await shell.commands()
        XCTAssertFalse(commands.contains { $0.hasPrefix("settings put") })
    }

    private func historyURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("history.json")
    }
}

private actor FakeTVShell: ShellExecutor {
    private var serial = "TV-123"
    private var values: [String: String]
    private var installed: Set<String> = ["com.google.android.tvlauncher", "com.spocky.projengmenu"]
    private var disabled = Set<String>()
    private var currentHome = "com.google.android.tvlauncher/.MainActivity"
    private var acceptsHome = true
    private var dnsFails = false
    private var ran: [String] = []
    private var availableKB: Int64 = 100

    init(settings: [String: String] = [:]) { values = settings }

    func run(_ command: String) async throws -> ShellResult {
        ran.append(command)
        if command == "getprop ro.serialno; getprop ro.boot.serialno" { return result("\(serial)\n\n") }
        if command == "getprop ro.build.version.sdk" { return result("35\n") }
        if command.hasPrefix("settings get ") {
            let values = command.components(separatedBy: "; ").map { one -> String in
                let key = String(one.split(separator: " ").last ?? "")
                return self.values[key] ?? "null"
            }
            return result(values.joined(separator: "\n") + "\n")
        }
        if command.hasPrefix("settings put ") {
            let parts = command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4 else { return result("Error: malformed setting", 1) }
            let setting = parts[3].split(separator: " ", maxSplits: 1).map(String.init)
            guard setting.count == 2 else { return result("Error: malformed setting", 1) }
            values[setting[0]] = unquote(setting[1])
            return result("")
        }
        if command.hasPrefix("settings delete ") {
            let key = String(command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last ?? "")
            values.removeValue(forKey: key)
            return result("")
        }
        if command.hasPrefix("ping ") { return dnsFails ? result("ping: unknown host connectivitycheck.gstatic.com\n", 2) : result("1 packets transmitted, 0 received, 100% packet loss\n", 1) }
        if command.hasPrefix("cmd package resolve-activity") { return result("priority=0\n\(currentHome)\n") }
        if command.hasPrefix("cmd package query-activities") { return result("com.google.android.tvlauncher/.MainActivity\ncom.spocky.projengmenu/.ui.home.MainActivity\n") }
        if command.hasPrefix("cmd package query-services") { return result("com.spocky.projengmenu/.HomeService\n") }
        if command.hasPrefix("cmd package set-home-activity") {
            if acceptsHome, let component = command.split(separator: "'").dropFirst().first { currentHome = String(component) }
            return result("Success\n")
        }
        if command.hasPrefix("pm path ") {
            let package = String(command.split(separator: " ").dropFirst(2).first ?? "")
            return installed.contains(package) ? result("package:/data/app/\(package)/base.apk\n") : result("")
        }
        if command.hasPrefix("pm list packages -d") { return result(disabled.sorted().map { "package:\($0)" }.joined(separator: "\n") + (disabled.isEmpty ? "" : "\n")) }
        if command.hasPrefix("pm disable-user --user 0 ") {
            let package = String(command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last ?? "")
            disabled.insert(package)
            return result("Package \(package) new state: disabled-user\n")
        }
        if command.hasPrefix("pm enable --user 0 ") {
            let package = String(command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last ?? "")
            disabled.remove(package)
            return result("Package \(package) new state: enabled\n")
        }
        if command == "df -k /data" {
            let used = 900 - (availableKB - 100)
            return result("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/dm-0 1000 \(used) \(availableKB) 90% /data\n")
        }
        if command.hasPrefix("pm trim-caches") { availableKB = 400; return result("") }
        return result("")
    }

    func setSerial(_ value: String) { serial = value }
    func setAcceptHome(_ value: Bool) { acceptsHome = value }
    func setDNSFails(_ value: Bool) { dnsFails = value }
    func setting(_ key: String) -> String? { values[key] }
    func setSetting(_ key: String, _ value: String?) { values[key] = value }
    func home() -> String { currentHome }
    func isDisabled(_ package: String) -> Bool { disabled.contains(package) }
    func commands() -> [String] { ran }

    private func unquote(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
    private func result(_ output: String, _ code: Int32 = 0) -> ShellResult { ShellResult(output: output, exitCode: code) }
}
