import Foundation
import XCTest
@testable import TellyscopeCore

final class SafePackageControllerTests: XCTestCase {
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
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
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

    func run(_ command: String) async throws -> ShellResult {
        commands.append(command)
        if command.hasPrefix("getprop") { return ShellResult(output: "\(serial)\n\n", exitCode: 0) }
        if command.hasPrefix("cmd package resolve-activity") { return ShellResult(output: homeOutput, exitCode: 0) }
        if command.hasPrefix("pm list packages -d") {
            return ShellResult(output: disabledOutput ?? disabled.sorted().map { "package:\($0)" }.joined(separator: "\n"), exitCode: 0)
        }
        if command.hasPrefix("pm disable-user") {
            let package = command.replacingOccurrences(of: " 2>&1", with: "").split(separator: " ").last.map(String.init) ?? ""
            disabled.insert(package)
            if switchAfterDisable { serial = "TV-456" }
            if throwAfterDisable { throw FakeError.interrupted }
            return ShellResult(output: "disabled-user", exitCode: 0)
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
