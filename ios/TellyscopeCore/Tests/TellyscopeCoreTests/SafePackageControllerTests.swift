// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import TellyscopeCore

final class SafePackageControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDisablePersistsBaselineAndRestoreOwnershipAcrossReload() async throws {
        let shell = FakeShell()
        shell.disabled = ["com.example.preexisting"]
        let file = tempURL()
        let first = SafePackageController(executor: shell, historyURL: file)
        let result = try await first.disable(package: "com.example.video")
        XCTAssertTrue(result.changed)

        let reloaded = SafePackageController(executor: shell, historyURL: file)
        let snapshot = try await reloaded.inspect()
        XCTAssertEqual(snapshot.deviceID, "serial:TV-123")
        XCTAssertEqual(snapshot.restorablePackages, ["com.example.video"])
        XCTAssertEqual(snapshot.history.map(\.action), ["disable"])
        let restored = try await reloaded.restore()
        XCTAssertEqual(restored.map(\.packageName), ["com.example.video"])
        XCTAssertTrue(shell.disabled.contains("com.example.preexisting"))
        XCTAssertFalse(shell.disabled.contains("com.example.video"))
    }

    func testPersistenceFailurePreventsMutation() async throws {
        let shell = FakeShell()
        let parent = tempURL()
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("file blocks directory creation".utf8).write(to: parent)
        let controller = SafePackageController(executor: shell, historyURL: parent.appendingPathComponent("history.json"))
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected persistence failure")
        } catch let error as SafePackageError {
            guard case .persistence = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(shell.disabled.contains("com.example.video"))
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    func testCurrentHomeAndProtectedPackagesCannotBeDisabled() async throws {
        let shell = FakeShell()
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        for package in ["com.example.home", "com.android.settings"] {
            do {
                _ = try await controller.disable(package: package)
                XCTFail("expected refusal for \(package)")
            } catch let error as SafePackageError {
                guard case .protectedPackage = error else { return XCTFail("unexpected error: \(error)") }
            }
        }
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    func testUnknownHomeFailsClosed() async throws {
        let shell = FakeShell()
        shell.homeOutput = "android/android.content.IntentResolver"
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected unknown Home refusal")
        } catch let error as SafePackageError {
            XCTAssertEqual(error, .unknownHome)
        }
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    func testMalformedDisabledPackageListFailsClosed() async throws {
        let shell = FakeShell()
        shell.disabledOutput = "warning: package service unavailable"
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected unreadable package list refusal")
        } catch let error as SafePackageError {
            guard case .commandFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    func testHomeChangeImmediatelyBeforeDisableFailsClosed() async throws {
        let shell = FakeShell()
        shell.changeHomeOnSecondResolve = "com.example.video/.Home"
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected changed Home refusal")
        } catch let error as SafePackageError {
            guard case .protectedPackage = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    func testExpectedDeviceIdentityIsCheckedBeforeAllMutations() async throws {
        let shell = FakeShell()
        shell.serial = "TV-456"
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        do { _ = try await controller.disable(package: "com.example.video", expectedDeviceID: "serial:TV-123"); XCTFail("expected stale identity") }
        catch let error as SafePackageError { XCTAssertEqual(error, .deviceChanged) }
        do { _ = try await controller.enable(package: "com.example.video", expectedDeviceID: "serial:TV-123"); XCTFail("expected stale identity") }
        catch let error as SafePackageError { XCTAssertEqual(error, .deviceChanged) }
        do { _ = try await controller.restore(expectedDeviceID: "serial:TV-123"); XCTFail("expected stale identity") }
        catch let error as SafePackageError { XCTAssertEqual(error, .deviceChanged) }
        XCTAssertTrue(shell.commands.allSatisfy { $0.hasPrefix("getprop") })
    }

    func testNonzeroMutationResultClearsIntentAndFails() async throws {
        let shell = FakeShell()
        shell.disableExitCode = 1
        let file = tempURL()
        let controller = SafePackageController(executor: shell, historyURL: file)
        do { _ = try await controller.disable(package: "com.example.video"); XCTFail("expected command failure") }
        catch let error as SafePackageError {
            guard case .commandFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let snapshot = try await SafePackageController(executor: shell, historyURL: file).inspect()
        XCTAssertNil(snapshot.pendingAction)
        XCTAssertFalse(snapshot.restorablePackages.contains("com.example.video"))
    }

    func testInterruptedMutationIsReconciledFromDeviceState() async throws {
        let shell = FakeShell()
        shell.throwAfterDisable = true
        let file = tempURL()
        let controller = SafePackageController(executor: shell, historyURL: file)
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected interrupted shell call")
        } catch { }

        let recovered = SafePackageController(executor: shell, historyURL: file)
        let snapshot = try await recovered.inspect()
        XCTAssertNil(snapshot.pendingAction)
        XCTAssertEqual(snapshot.restorablePackages, ["com.example.video"])
        XCTAssertEqual(snapshot.history.map(\.action), ["disable"])
    }

    func testDeviceSwitchDuringMutationIsRejectedAndPendingRecordSurvives() async throws {
        let shell = FakeShell()
        shell.switchAfterDisable = true
        let file = tempURL()
        let controller = SafePackageController(executor: shell, historyURL: file)
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected device change refusal")
        } catch let error as SafePackageError {
            XCTAssertEqual(error, .deviceChanged)
        }
        shell.serial = "TV-123"
        let recovered = try await SafePackageController(executor: shell, historyURL: file).inspect()
        XCTAssertEqual(recovered.restorablePackages, ["com.example.video"])
    }

    func testInvalidPackageNeverReachesShell() async throws {
        let shell = FakeShell()
        let controller = SafePackageController(executor: shell, historyURL: tempURL())
        do {
            _ = try await controller.disable(package: "x; reboot")
            XCTFail("expected package validation")
        } catch let error as SafePackageError {
            guard case .invalidPackage = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertTrue(shell.commands.isEmpty)
    }

    func testCorruptHistoryFailsClosed() async throws {
        let file = tempURL()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: file)
        let shell = FakeShell()
        let controller = SafePackageController(executor: shell, historyURL: file)
        do {
            _ = try await controller.disable(package: "com.example.video")
            XCTFail("expected corrupt history refusal")
        } catch let error as SafePackageError {
            XCTAssertEqual(error, .corruptHistory)
        }
        XCTAssertFalse(shell.commands.contains(where: { $0.hasPrefix("pm disable-user") }))
    }

    private func tempURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("history.json")
    }
}

private final class FakeShell: ShellExecutor {
    var disabled: Set<String> = []
    var homeOutput = "com.example.home/.Home"
    var commands: [String] = []
    var throwAfterDisable = false
    var switchAfterDisable = false
    var serial = "TV-123"
    var disabledOutput: String?
    var changeHomeOnSecondResolve: String?
    var homeResolveCount = 0
    var disableExitCode: Int32 = 0

    func run(_ command: String) async throws -> ShellResult {
        commands.append(command)
        if command.hasPrefix("getprop") { return ShellResult(output: "\(serial)\n\n", exitCode: 0) }
        if command.hasPrefix("cmd package resolve-activity") {
            homeResolveCount += 1
            return ShellResult(output: homeResolveCount == 2 ? (changeHomeOnSecondResolve ?? homeOutput) : homeOutput, exitCode: 0)
        }
        if command.hasPrefix("pm list packages -d") {
            return ShellResult(output: disabledOutput ?? disabled.sorted().map { "package:\($0)" }.joined(separator: "\n"), exitCode: 0)
        }
        if command.hasPrefix("pm disable-user") {
            let package = command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last.map(String.init) ?? ""
            disabled.insert(package)
            if switchAfterDisable { serial = "TV-456" }
            if throwAfterDisable { throw FakeError.interrupted }
            return ShellResult(output: "disabled-user", exitCode: disableExitCode)
        }
        if command.hasPrefix("pm enable") {
            let package = command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last.map(String.init) ?? ""
            disabled.remove(package)
            return ShellResult(output: "enabled", exitCode: 0)
        }
        return ShellResult(output: "", exitCode: 0)
    }
}

private enum FakeError: Error { case interrupted }
