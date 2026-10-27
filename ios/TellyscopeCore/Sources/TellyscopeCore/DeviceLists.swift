// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CryptoKit
import Foundation

public let tellyscopeDeviceListsBase = URL(string: "https://raw.githubusercontent.com/man15h/tellyscope-devices/main/")!

public struct DeviceListEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let match: [String: [String]]?
    public let sdk: Int?
    public let file: String
    public let sha256: String
}

public struct DeviceListIndex: Equatable, Sendable {
    public let commit: String?
    public let devices: [DeviceListEntry]
}

public struct DeviceListPackage: Codable, Equatable, Sendable {
    public let package: String
    public let note: String?
    public let optional: Bool
}

public struct DeviceListGroup: Codable, Equatable, Sendable {
    public let title: String
    public let packages: [DeviceListPackage]
}

public struct CuratedDeviceList: Equatable, Sendable {
    public let id: String
    public let name: String
    public let testedOS: String?
    public let sdk: Int?
    public let keep: Set<String>
    public let groups: [DeviceListGroup]
}

public struct DeviceListApp: Equatable, Sendable {
    public let package: String
    public let name: String
    public let enabled: Bool
    public let protected: Bool

    public init(package: String, name: String, enabled: Bool, protected: Bool = false) {
        self.package = package
        self.name = name
        self.enabled = enabled
        self.protected = protected
    }
}

public struct SuggestedDevicePackage: Equatable, Identifiable, Sendable {
    public var id: String { package }
    public let package: String
    public let name: String
    public let note: String?
    public let optional: Bool
    public let selected: Bool
}

public struct SuggestedDeviceGroup: Equatable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let packages: [SuggestedDevicePackage]
}

public enum DeviceListMatchKind: Equatable, Sendable {
    case model
    case picked
    case maker(String)
    case manual
}

public struct DeviceListSuggestions: Equatable, Sendable {
    public let commit: String?
    public let list: CuratedDeviceList?
    public let entries: [DeviceListEntry]
    public let groups: [SuggestedDeviceGroup]
    public let match: DeviceListMatchKind
    public let selectedListID: String?
    public let offline: Bool
    public let protectedKeep: Set<String>

    public var hasInstalledSuggestions: Bool { groups.contains { !$0.packages.isEmpty } }
}

public enum DeviceListError: Error, LocalizedError, Equatable {
    case invalidSerial
    case unknownList
    case cacheWrite(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSerial: "A stable TV serial number is required to remember a list."
        case .unknownList: "That TV list is not in the validated index."
        case .cacheWrite(let reason): "Could not save the TV list selection: \(reason)"
        }
    }
}

private let packagePattern = #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#
private let listIDPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
private let listFilePattern = #"^devices/[A-Za-z0-9][A-Za-z0-9._-]*\.json$"#
private let checksumPattern = #"^[0-9a-f]{64}$"#
private let maxDocumentBytes = 2 * 1024 * 1024

public func parseDeviceListIndex(_ data: Data) -> DeviceListIndex? {
    guard let object = jsonObject(data), let root = object as? [String: Any],
          integer(root["schema"]) == 1, let raw = root["devices"] as? [Any] else { return nil }
    let entries = raw.compactMap { value -> DeviceListEntry? in
        guard let item = value as? [String: Any], let id = item["id"] as? String,
              id.range(of: listIDPattern, options: .regularExpression) != nil,
              let name = item["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let file = item["file"] as? String, file.range(of: listFilePattern, options: .regularExpression) != nil,
              let sha = item["sha256"] as? String, sha.range(of: checksumPattern, options: .regularExpression) != nil else { return nil }
        var match: [String: [String]]?
        if let rawMatch = item["match"] as? [String: Any] {
            guard rawMatch.values.allSatisfy({ ($0 as? [String])?.isEmpty == false }) else { return nil }
            var parsed: [String: [String]] = [:]
            for (key, value) in rawMatch {
                guard let values = value as? [String] else { return nil }
                parsed[key] = values
            }
            match = parsed.isEmpty ? nil : parsed
        }
        return DeviceListEntry(id: id, name: name, match: match, sdk: integer(item["sdk"]), file: file, sha256: sha)
    }
    let counts = Dictionary(grouping: entries, by: \.id).mapValues(\.count)
    let uniqueEntries = entries.filter { counts[$0.id] == 1 }
    let source = root["source"] as? [String: Any]
    return DeviceListIndex(commit: source?["commit"] as? String, devices: uniqueEntries)
}

public func parseCuratedDeviceList(_ data: Data, expectedID: String) -> CuratedDeviceList? {
    guard let object = jsonObject(data), let root = object as? [String: Any],
          integer(root["schema"]) == 1, root["id"] as? String == expectedID,
          let name = root["name"] as? String, let rawGroups = root["groups"] as? [Any] else { return nil }
    func packages(_ raw: Any?) -> [DeviceListPackage] {
        (raw as? [Any] ?? []).compactMap { value in
            guard let item = value as? [String: Any], let pkg = item["pkg"] as? String,
                  pkg.range(of: packagePattern, options: .regularExpression) != nil else { return nil }
            return DeviceListPackage(package: pkg, note: item["note"] as? String, optional: boolean(item["optional"]))
        }
    }
    let groups = rawGroups.compactMap { value -> DeviceListGroup? in
        guard let group = value as? [String: Any], let title = group["title"] as? String else { return nil }
        let apps = packages(group["packages"])
        return apps.isEmpty ? nil : DeviceListGroup(title: title, packages: apps)
    }
    let keep = Set(packages(root["keep"]).map(\.package))
    let tested = root["tested"] as? [String: Any]
    return CuratedDeviceList(id: expectedID, name: name, testedOS: tested?["os"] as? String, sdk: integer(tested?["sdk"]), keep: keep, groups: groups)
}

public func deviceListSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func normalizeDeviceListSource(_ address: String) -> URL? {
    var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasSuffix("index.json") { value.removeLast("index.json".count) }
    guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
          parts.query == nil, parts.fragment == nil else { return nil }
    if !parts.path.hasSuffix("/") { parts.path += "/" }
    return parts.url
}

public func matchDeviceList(_ entries: [DeviceListEntry], serial: String, properties: [String: String]) -> (entry: DeviceListEntry?, makerEntries: [DeviceListEntry], maker: String?) {
    guard validSerial(serial) else { return (nil, [], nil) }
    if let ruleMatch = entries.filter({ matchesRule($0.match, properties) }).only {
        return (ruleMatch, [], nil)
    }
    let makerNames = [properties["manufacturer"], properties["brand"]].compactMap { $0 }.map(squash).filter { !$0.isEmpty }
    if let model = properties["model"].map(squash).flatMap({ $0.count >= 3 ? $0 : nil }) {
        let modelMatches = entries.filter { wordsFit(model, $0.name) || wordsFit(model, $0.id.replacingOccurrences(of: "-", with: " ")) }
        if let entry = modelMatches.only, let listMaker = listMaker(for: entry, among: entries), makerNames.contains(squash(listMaker)) {
            return (entry, [], nil)
        }
    }
    let makers = listMakers(entries)
    for makerName in [properties["manufacturer"], properties["brand"]].compactMap({ $0 }) {
        let found = entries.filter { squash(makers[$0.id] ?? "") == squash(makerName) }
        if !found.isEmpty { return (nil, found, makers[found[0].id]) }
    }
    return (nil, [], nil)
}

public actor TellyscopeDeviceLists {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let cacheDirectory: URL
    private let fetch: Fetch
    private var cachedIndex: DeviceListIndex?
    private var cachedSourceFailed = false

    public init(cacheDirectory: URL, fetch: Fetch? = nil) {
        self.cacheDirectory = cacheDirectory
        self.fetch = fetch ?? Self.download
    }

    public func suggestions(
        serial: String,
        properties: [String: String],
        sdk: Int?,
        apps: [DeviceListApp],
        protectedKeep: Set<String> = []
    ) async -> DeviceListSuggestions {
        guard validSerial(serial) else {
            return DeviceListSuggestions(commit: nil, list: nil, entries: [], groups: [], match: .manual, selectedListID: nil, offline: false, protectedKeep: protectedKeep)
        }
        guard let index = await loadIndex() else {
            return DeviceListSuggestions(commit: nil, list: nil, entries: [], groups: [], match: .manual, selectedListID: nil, offline: cachedSourceFailed, protectedKeep: protectedKeep)
        }
        let picked = readPicks()[serial]
        let selectedEntry = picked.flatMap { id in index.devices.first { $0.id == id } }
        let automatic = selectedEntry == nil ? matchDeviceList(index.devices, serial: serial, properties: properties) : (entry: selectedEntry, makerEntries: [], maker: nil)
        var list: CuratedDeviceList?
        var kind: DeviceListMatchKind = .manual
        var selectedID: String?
        if let entry = automatic.entry, let loaded = await loadList(entry, base: tellyscopeDeviceListsBase) {
            list = loaded
            kind = selectedEntry == nil ? .model : .picked
            selectedID = entry.id
        } else if let maker = automatic.maker, !automatic.makerEntries.isEmpty {
            // Maker-only matches are shown as picker context and never become an applied suggestion.
            kind = .maker(maker)
        }
        let keep = protectedKeep.union(list?.keep ?? [])
        let groups = list.map { suggestedGroups($0, apps: apps, sdk: sdk, protectedKeep: keep, allowTicks: kind == .model || kind == .picked) } ?? []
        return DeviceListSuggestions(
            commit: index.commit, list: list, entries: index.devices, groups: groups,
            match: kind, selectedListID: selectedID, offline: cachedSourceFailed, protectedKeep: keep
        )
    }

    public func pick(_ id: String, for serial: String) async throws {
        guard validSerial(serial) else { throw DeviceListError.invalidSerial }
        guard let index = await loadIndex(), index.devices.contains(where: { $0.id == id }) else {
            throw DeviceListError.unknownList
        }
        var picks = readPicks()
        picks[serial] = id
        try writePicks(picks)
    }

    public func clearPick(for serial: String) throws {
        var picks = readPicks()
        picks.removeValue(forKey: serial)
        try writePicks(picks)
    }

    private func loadIndex() async -> DeviceListIndex? {
        if let cachedIndex { return cachedIndex }
        cachedSourceFailed = false
        let cache = cacheDirectory.appendingPathComponent("index.json")
        do {
            let data = try await fetch(tellyscopeDeviceListsBase.appendingPathComponent("index.json"))
            guard let index = parseDeviceListIndex(data) else { throw CacheError.invalidIndex }
            try save(data, to: cache)
            cachedIndex = index
            return index
        } catch {
            cachedSourceFailed = true
            guard let data = try? Data(contentsOf: cache), let index = parseDeviceListIndex(data) else { return nil }
            cachedIndex = index
            return index
        }
    }

    private func loadList(_ entry: DeviceListEntry, base: URL) async -> CuratedDeviceList? {
        let fileURL = cacheDirectory.appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(String(entry.file.dropFirst("devices/".count)))
        if let cached = try? Data(contentsOf: fileURL), deviceListSHA256(cached) == entry.sha256,
           let list = parseCuratedDeviceList(cached, expectedID: entry.id) { return list }
        do {
            let remote = try await fetch(base.appendingPathComponent(entry.file))
            guard deviceListSHA256(remote) == entry.sha256,
                  let list = parseCuratedDeviceList(remote, expectedID: entry.id) else { return nil }
            try save(remote, to: fileURL)
            return list
        } catch { cachedSourceFailed = true; return nil }
    }

    private func readPicks() -> [String: String] {
        let url = cacheDirectory.appendingPathComponent("picks.json")
        guard let data = try? Data(contentsOf: url), let picks = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return picks
    }

    private func writePicks(_ picks: [String: String]) throws {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(picks).write(to: cacheDirectory.appendingPathComponent("picks.json"), options: .atomic)
        } catch { throw DeviceListError.cacheWrite(error.localizedDescription) }
    }

    private func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CacheError.download }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maxDocumentBytes else { throw CacheError.download }
        }
        return data
    }
}

private enum CacheError: Error { case invalidIndex, download }

private func jsonObject(_ data: Data) -> Any? {
    guard !data.isEmpty, data.count <= maxDocumentBytes, let text = String(data: data, encoding: .utf8), jsonDepth(text) <= 32 else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    return double.isFinite && double.rounded() == double ? number.intValue : nil
}

private func boolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
}

private func validSerial(_ serial: String) -> Bool {
    let value = serial.hasPrefix("serial:") ? String(serial.dropFirst("serial:".count)) : serial
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil
        && !["unknown", "null", "0123456789abcdef", "0000000000000000", "123456789"].contains(value.lowercased())
}

private func jsonDepth(_ text: String) -> Int {
    var depth = 0, maximum = 0, inString = false, escaped = false
    for character in text {
        if escaped { escaped = false; continue }
        if inString {
            if character == "\\" { escaped = true } else if character == "\"" { inString = false }
        } else if character == "\"" { inString = true }
        else if character == "{" || character == "[" { depth += 1; maximum = max(maximum, depth) }
        else if character == "}" || character == "]" { depth -= 1 }
    }
    return maximum
}

private func squash(_ value: String) -> String { String(value.lowercased().filter { $0.isLetter || $0.isNumber }) }

private func wordsFit(_ needle: String, _ source: String) -> Bool {
    let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    for start in words.indices {
        var run = ""
        for word in words[start...] {
            run += squash(word)
            if run == needle { return true }
            if !needle.hasPrefix(run) { break }
        }
    }
    return false
}

private func matchesRule(_ rule: [String: [String]]?, _ properties: [String: String]) -> Bool {
    guard let rule, !rule.isEmpty else { return false }
    return rule.allSatisfy { key, values in
        guard let actual = properties[key], !values.isEmpty else { return false }
        return values.contains { $0.caseInsensitiveCompare(actual) == .orderedSame }
    }
}

private func listMakers(_ entries: [DeviceListEntry]) -> [String: String] {
    let prefixes = Set(entries.map { String($0.id.split(separator: "-").first ?? "") }.map(squash))
    var makers: [String: String] = [:]
    for entry in entries {
        let words = entry.name.split(separator: " ").map(String.init)
        let prefix = String(entry.id.split(separator: "-").first ?? "")
        let first = words.first ?? prefix
        let maker = prefixes.contains(squash(first)) ? first : (words.first(where: { squash($0) == squash(prefix) }) ?? first)
        makers[entry.id] = maker
    }
    return makers
}

private func listMaker(for entry: DeviceListEntry, among entries: [DeviceListEntry]) -> String? { listMakers(entries)[entry.id] }

private func suggestedGroups(_ list: CuratedDeviceList, apps: [DeviceListApp], sdk: Int?, protectedKeep: Set<String>, allowTicks: Bool) -> [SuggestedDeviceGroup] {
    let installed = Dictionary(apps.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
    let tick = allowTicks && sdk != nil && sdk == list.sdk
    var seen = Set<String>()
    var titles: [String] = []
    var packagesByTitle: [String: [SuggestedDevicePackage]] = [:]
    for group in list.groups {
        if packagesByTitle[group.title] == nil { titles.append(group.title); packagesByTitle[group.title] = [] }
        let packages = group.packages.compactMap { item -> SuggestedDevicePackage? in
            guard seen.insert(item.package).inserted, let app = installed[item.package], app.enabled, !app.protected,
                  !protectedKeep.contains(item.package) else { return nil }
            return SuggestedDevicePackage(package: item.package, name: app.name, note: item.note, optional: item.optional, selected: tick && !item.optional)
        }
        packagesByTitle[group.title, default: []].append(contentsOf: packages)
    }
    return titles.compactMap { title in
        guard let packages = packagesByTitle[title], !packages.isEmpty else { return nil }
        return SuggestedDeviceGroup(title: title, packages: packages)
    }
}

private extension Array where Element == DeviceListEntry {
    var only: DeviceListEntry? {
        guard count == 1 else { return nil }
        return first
    }
}
