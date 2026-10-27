// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import TellyscopeCore

final class DeviceListsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSchemaAndPackageValidationDropsBadEntries() throws {
        let data = indexData([
            entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: String(repeating: "a", count: 64)),
            entry(id: "bad", name: "Bad", file: "devices/../../private.json", sha: String(repeating: "b", count: 64)),
        ])
        let parsed = try XCTUnwrap(parseDeviceListIndex(data))
        XCTAssertEqual(parsed.devices.map(\.id), ["acme-55"])
        XCTAssertNil(parseDeviceListIndex(Data(#"{"schema":2,"devices":[]}"#.utf8)))
        XCTAssertNil(parseDeviceListIndex(Data(repeating: 0, count: 20)))

        let listData = Data(#"{"schema":1,"id":"acme-55","name":"Acme 55","keep":[{"pkg":"com.acme.keep"}],"groups":[{"title":"Apps","packages":[{"pkg":"com.acme.good"},{"pkg":"bad; reboot"}]}]}"#.utf8)
        let list = try XCTUnwrap(parseCuratedDeviceList(listData, expectedID: "acme-55"))
        XCTAssertEqual(list.keep, ["com.acme.keep"])
        XCTAssertEqual(list.groups.flatMap(\.packages).map(\.package), ["com.acme.good"])
        XCTAssertNil(parseCuratedDeviceList(listData, expectedID: "other"))
    }

    func testMatchingIsWholeModelAndRejectsAmbiguousMakerOnlyMatch() throws {
        let entries = [
            DeviceListEntry(id: "tcl-p7-2021", name: "TCL P7 2021", match: nil, sdk: 30, file: "devices/a.json", sha256: String(repeating: "a", count: 64)),
            DeviceListEntry(id: "tcl-p7-2023", name: "TCL P7 2023", match: nil, sdk: 31, file: "devices/b.json", sha256: String(repeating: "b", count: 64)),
            DeviceListEntry(id: "tcl-x100", name: "TCL X100", match: nil, sdk: 32, file: "devices/c.json", sha256: String(repeating: "c", count: 64)),
            DeviceListEntry(id: "xgimi-mogo-2", name: "XGIMI MoGo 2", match: nil, sdk: 30, file: "devices/d.json", sha256: String(repeating: "d", count: 64)),
        ]
        let ambiguous = matchDeviceList(entries, serial: "serial:one", properties: ["manufacturer": "TCL", "model": "P7"])
        XCTAssertNil(ambiguous.entry)
        XCTAssertEqual(ambiguous.makerEntries.map(\.id), ["tcl-p7-2021", "tcl-p7-2023", "tcl-x100"])
        XCTAssertEqual(ambiguous.maker, "TCL")

        let model = matchDeviceList(entries, serial: "serial:one", properties: ["manufacturer": "TCL", "model": "X100"])
        XCTAssertEqual(model.entry?.id, "tcl-x100")
        let partial = matchDeviceList(entries, serial: "serial:one", properties: ["manufacturer": "TCL", "model": "X10"])
        XCTAssertNil(partial.entry)
        XCTAssertEqual(partial.makerEntries.count, 3)
        let brand = matchDeviceList(entries, serial: "serial:one", properties: ["manufacturer": "TPV", "brand": "XGIMI", "model": "MoGo 2"])
        XCTAssertEqual(brand.entry?.id, "xgimi-mogo-2")
    }

    func testExplicitRulesCannotDowngradeToGenericNameMatching() {
        let guarded = DeviceListEntry(
            id: "tcl-g05-us-ar71", name: "G05_4K_US", match: ["model": ["Smart TV Pro"], "incremental": ["AR71"]],
            sdk: nil, file: "devices/tcl-g05-us-ar71.json", sha256: String(repeating: "a", count: 64)
        )
        for properties in [
            ["manufacturer": "TCL", "model": "Wrong TV", "incremental": "AR71"],
            ["manufacturer": "TCL", "model": "Smart TV Pro", "incremental": "WRONG"],
            ["manufacturer": "TCL", "model": "Smart TV Pro"],
            ["manufacturer": "TCL", "model": "G05_4K_US", "incremental": "AR71"],
        ] {
            XCTAssertNil(matchDeviceList([guarded], serial: "serial:one", properties: properties).entry)
        }
        let ambiguous = [guarded, DeviceListEntry(
            id: "tcl-g05-us-ar72", name: "G05_4K_US", match: ["model": ["Smart TV Pro"]],
            sdk: nil, file: "devices/tcl-g05-us-ar72.json", sha256: String(repeating: "b", count: 64)
        )]
        XCTAssertNil(matchDeviceList(ambiguous, serial: "serial:one", properties: ["model": "Smart TV Pro", "incremental": "AR71"]).entry)
    }

    func testBundledTCLProfileMatchesOfflineAndKeepsEveryPackageUnselected() async throws {
        let indexURL = try XCTUnwrap(Bundle.module.url(forResource: "index", withExtension: "json", subdirectory: "DeviceProfiles"))
        let bundledIndex = try XCTUnwrap(parseDeviceListIndex(Data(contentsOf: indexURL)))
        let entry = try XCTUnwrap(bundledIndex.devices.first { $0.id == "tcl-g05-us-ar71" })
        XCTAssertNil(entry.sdk)
        XCTAssertEqual(entry.match?["manufacturer"], ["TCL"])
        XCTAssertEqual(entry.match?["model"], ["Smart TV Pro"])
        XCTAssertEqual(entry.match?["device"], ["G05"])
        XCTAssertEqual(entry.match?["name"], ["G05_4K_US"])
        XCTAssertEqual(entry.match?["incremental"], ["AR71"])
        for (key, wrongValue) in [("manufacturer", "Other"), ("device", "Other"), ("model", "Wrong TV"), ("name", "Wrong_Product"), ("incremental", "WRONG"), ("sdk", "31")] {
            var mismatched = ["manufacturer": "TCL", "model": "Smart TV Pro", "device": "G05", "name": "G05_4K_US", "incremental": "AR71", "sdk": "30"]
            mismatched[key] = wrongValue
            XCTAssertNil(matchDeviceList([entry], serial: "serial:TCL-1", properties: mismatched).entry, "Unexpected automatic match with \(key)=\(wrongValue)")
        }
        let missingBuild = ["manufacturer": "TCL", "model": "Smart TV Pro", "device": "G05", "name": "G05_4K_US", "sdk": "30"]
        XCTAssertNil(matchDeviceList([entry], serial: "serial:TCL-1", properties: missingBuild).entry)
        let listURL = try XCTUnwrap(Bundle.module.url(forResource: "tcl-g05-us-ar71", withExtension: "json", subdirectory: "DeviceProfiles/devices"))
        let listData = try Data(contentsOf: listURL)
        XCTAssertEqual(deviceListSHA256(listData), entry.sha256)
        let bundledList = try XCTUnwrap(parseCuratedDeviceList(listData, expectedID: entry.id))
        XCTAssertEqual(TellyscopeDeviceLists.verifiedBundledKeepPackages, bundledList.keep)
        for package in bundledList.keep { XCTAssertNotNil(SafePackageController.protectedReason(package), package) }
        XCTAssertTrue(TellyscopeDeviceLists.verifiedBundledKeepPackages.contains("com.tcl.ttvs"))
        XCTAssertTrue(TellyscopeDeviceLists.verifiedBundledKeepPackages.contains("com.tcl.suspension"))
        XCTAssertFalse(bundledList.groups.flatMap(\.packages).isEmpty)
        XCTAssertTrue(bundledList.groups.flatMap(\.packages).allSatisfy(\.optional))

        let store = TellyscopeDeviceLists(cacheDirectory: tempDirectory()) { _ in throw URLError(.notConnectedToInternet) }
        let properties = ["manufacturer": "TCL", "model": "Smart TV Pro", "device": "G05", "name": "G05_4K_US", "incremental": "AR71", "sdk": "30"]
        let installed = bundledList.groups.flatMap(\.packages).map(\.package)
        let apps = installed.map { DeviceListApp(package: $0, name: $0, enabled: true) }
        let keep = bundledList.keep.first
        let state = await store.suggestions(serial: "serial:TCL-1", properties: properties, sdk: 30, apps: apps, protectedKeep: keep.map { [$0] } ?? [])
        XCTAssertTrue(state.offline)
        XCTAssertEqual(state.match, .model)
        XCTAssertEqual(state.list?.id, entry.id)
        XCTAssertTrue(state.groups.flatMap(\.packages).allSatisfy { !$0.selected })
        try await store.pick(entry.id, for: "serial:TCL-1")
        var changedFirmware = properties
        changedFirmware["incremental"] = "AR68"
        let stalePick = await store.suggestions(serial: "serial:TCL-1", properties: changedFirmware, sdk: 30, apps: apps)
        XCTAssertNil(stalePick.list)
        XCTAssertNotEqual(stalePick.match, .picked)
        if let keep {
            XCTAssertTrue(state.protectedKeep.contains(keep))
            XCTAssertFalse(state.groups.flatMap(\.packages).contains { $0.package == keep })
        }
    }

    func testChecksumValidatedCacheSurvivesOfflineReload() async throws {
        let folder = tempDirectory()
        let list = deviceJSON(id: "acme-55", package: "com.acme.reporter")
        let index = indexData([entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: deviceListSHA256(list))])
        let online = TellyscopeDeviceLists(cacheDirectory: folder) { url in
            if url.lastPathComponent == "index.json" { return index }
            return list
        }
        let apps = [DeviceListApp(package: "com.acme.reporter", name: "Reporter", enabled: true)]
        let first = await online.suggestions(serial: "serial:TV-1", properties: ["manufacturer": "Acme", "model": "Acme 55"], sdk: 30, apps: apps)
        XCTAssertEqual(first.list?.id, "acme-55")
        XCTAssertEqual(first.groups.flatMap(\.packages).map(\.package), ["com.acme.reporter"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices/acme-55.json").path))

        let offline = TellyscopeDeviceLists(cacheDirectory: folder) { _ in throw URLError(.notConnectedToInternet) }
        let cached = await offline.suggestions(serial: "serial:TV-1", properties: ["manufacturer": "Acme", "model": "Acme 55"], sdk: 30, apps: apps)
        XCTAssertTrue(cached.offline)
        XCTAssertEqual(cached.list?.id, "acme-55")
        XCTAssertTrue(cached.hasInstalledSuggestions)
    }

    func testBadChecksumNeverUsesOrCachesRemoteList() async throws {
        let folder = tempDirectory()
        let actual = deviceJSON(id: "acme-55", package: "com.acme.reporter")
        let index = indexData([entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: String(repeating: "0", count: 64))])
        let store = TellyscopeDeviceLists(cacheDirectory: folder) { url in url.lastPathComponent == "index.json" ? index : actual }
        let state = await store.suggestions(
            serial: "serial:TV-1", properties: ["manufacturer": "Acme", "model": "Acme 55"], sdk: 30,
            apps: [DeviceListApp(package: "com.acme.reporter", name: "Reporter", enabled: true)]
        )
        XCTAssertNil(state.list)
        XCTAssertFalse(state.hasInstalledSuggestions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices/acme-55.json").path))
    }

    func testProtectedKeepUnionAndOptionalSelectionRules() async throws {
        let folder = tempDirectory()
        let list = Data(#"{"schema":1,"id":"acme-55","name":"Acme 55","tested":{"sdk":30},"keep":[{"pkg":"com.acme.keep"}],"groups":[{"title":"Apps","packages":[{"pkg":"com.acme.one","note":"usage reporter"},{"pkg":"com.acme.two","optional":true},{"pkg":"com.acme.keep"},{"pkg":"com.acme.external"}]}]}"#.utf8)
        let index = indexData([entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: deviceListSHA256(list))])
        let store = TellyscopeDeviceLists(cacheDirectory: folder) { url in url.lastPathComponent == "index.json" ? index : list }
        let apps = ["one", "two", "keep", "external"].map {
            DeviceListApp(package: "com.acme.\($0)", name: $0, enabled: true)
        }
        let properties = ["manufacturer": "Acme", "model": "Acme 55"]
        let safeSDK = await store.suggestions(serial: "serial:TV-1", properties: properties, sdk: 30, apps: apps, protectedKeep: ["com.acme.external"])
        XCTAssertEqual(safeSDK.groups.flatMap(\.packages).map(\.package), ["com.acme.one", "com.acme.two"])
        XCTAssertEqual(safeSDK.groups.flatMap(\.packages).map(\.selected), [true, false])
        let otherSDK = await store.suggestions(serial: "serial:TV-1", properties: properties, sdk: 31, apps: apps, protectedKeep: ["com.acme.external"])
        XCTAssertEqual(otherSDK.groups.flatMap(\.packages).map(\.selected), [false, false])
    }

    func testSystemDebloatTargetRemainsAvailableWhileEssentialPackageIsProtected() async throws {
        let folder = tempDirectory()
        let list = Data(#"{"schema":1,"id":"acme-55","name":"Acme 55","tested":{"sdk":30},"groups":[{"title":"System apps","packages":[{"pkg":"com.google.android.katniss"},{"pkg":"com.android.settings"}]}]}"#.utf8)
        let index = indexData([entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: deviceListSHA256(list))])
        let store = TellyscopeDeviceLists(cacheDirectory: folder) { url in url.lastPathComponent == "index.json" ? index : list }
        let apps = ["com.google.android.katniss", "com.android.settings"].map { package in
            DeviceListApp(package: package, name: package, enabled: true, protected: SafePackageController.protectedReason(package) != nil)
        }
        let state = await store.suggestions(
            serial: "serial:TV-1", properties: ["manufacturer": "Acme", "model": "Acme 55"], sdk: 30, apps: apps
        )
        XCTAssertNil(SafePackageController.protectedReason("com.google.android.katniss"))
        XCTAssertNotNil(SafePackageController.protectedReason("com.android.settings"))
        XCTAssertEqual(state.groups.flatMap(\.packages).map(\.package), ["com.google.android.katniss"])
    }

    func testManualPickIsRememberedPerStableSerial() async throws {
        let folder = tempDirectory()
        let firstList = deviceJSON(id: "acme-55", package: "com.acme.one")
        let secondList = deviceJSON(id: "other-1", package: "com.other.one")
        let index = indexData([
            entry(id: "acme-55", name: "Acme 55", file: "devices/acme-55.json", sha: deviceListSHA256(firstList)),
            entry(id: "other-1", name: "Other 1", file: "devices/other-1.json", sha: deviceListSHA256(secondList)),
        ])
        let store = TellyscopeDeviceLists(cacheDirectory: folder) { url in
            if url.lastPathComponent == "index.json" { return index }
            return url.lastPathComponent == "acme-55.json" ? firstList : secondList
        }
        let props = ["manufacturer": "Acme", "model": "Acme 55"]
        let apps = [DeviceListApp(package: "com.other.one", name: "Other", enabled: true)]
        try await store.pick("other-1", for: "serial:TV-1")
        let picked = await store.suggestions(serial: "serial:TV-1", properties: props, sdk: 30, apps: apps)
        XCTAssertEqual(picked.selectedListID, "other-1")
        XCTAssertEqual(picked.list?.id, "other-1")
        let another = await store.suggestions(serial: "serial:TV-2", properties: props, sdk: 30, apps: apps)
        XCTAssertEqual(another.list?.id, "acme-55")
    }

    func testHTTPSAddressValidation() {
        XCTAssertNotNil(normalizeDeviceListSource(" https://example.com/lists/index.json "))
        XCTAssertNil(normalizeDeviceListSource("http://example.com/lists"))
        XCTAssertNil(normalizeDeviceListSource("https://user:token@example.com/lists"))
        XCTAssertNil(normalizeDeviceListSource("https://example.com/lists?token=x"))
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectories.append(url)
        return url
    }

    private func deviceJSON(id: String, package: String) -> Data {
        Data(#"{"schema":1,"id":"\#(id)","name":"Device","tested":{"sdk":30},"keep":[],"groups":[{"title":"Apps","packages":[{"pkg":"\#(package)"}]}]}"#.utf8)
    }

    private func entry(id: String, name: String, file: String, sha: String) -> String {
        return "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"file\":\"\(file)\",\"sha256\":\"\(sha)\"}"
    }

    private func indexData(_ entries: [String]) -> Data {
        Data("{\"schema\":1,\"source\":{\"commit\":\"abc123\"},\"devices\":[\(entries.joined(separator: ","))]}".utf8)
    }
}
