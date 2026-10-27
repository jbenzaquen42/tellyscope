import Foundation
import Combine

struct AndroidApp: Identifiable, Hashable, Sendable {
    var id: String { packageName }
    let packageName: String
    let isSystem: Bool
    let baseAPKPath: String?
    var name: String?
    var iconData: Data?
    var versionName: String?

    var displayName: String {
        name ?? packageName.split(separator: ".").last.map(String.init) ?? packageName
    }
}

struct InstalledAppPresentation: Codable, Sendable {
    let name: String
    let iconData: Data?
    let versionName: String
}

enum ApplicationAction: Sendable, Equatable {
    case launch
    case openDetails
    case forceStop
    case clearCache
    case clearData
    case uninstall
}

struct DeviceInformation: Sendable {
    var values: [(String, String)]

    init(values: [(String, String)] = []) {
        self.values = values
    }
}

enum InstallResult: String, Codable, Sendable {
    case success = "text.success"
    case failed = "text.failed"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if L10n.matches(value, key: Self.success.rawValue) {
            self = .success
        } else if L10n.matches(value, key: Self.failed.rawValue) {
            self = .failed
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown installation result."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var localizedTitle: String {
        switch self {
        case .success: L10n.string("text.success")
        case .failed: L10n.string("text.failed")
        }
    }
}

struct InstallHistoryItem: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let filename: String
    let deviceName: String
    let source: String
    let versionName: String?
    let result: InstallResult
    let details: String
}

@MainActor
final class InstallHistoryStore: ObservableObject {
    @Published private(set) var items: [InstallHistoryItem] = [] {
        didSet { persist() }
    }

    private let key = "tvadb.installHistory.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([InstallHistoryItem].self, from: data) {
            items = decoded
        }
    }

    func add(
        filename: String,
        deviceName: String,
        source: String,
        versionName: String? = nil,
        result: InstallResult,
        details: String
    ) {
        items.insert(InstallHistoryItem(
            id: UUID(),
            date: Date(),
            filename: filename,
            deviceName: deviceName,
            source: source,
            versionName: versionName,
            result: result,
            details: details
        ), at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
    }

    func clear() {
        items = []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
