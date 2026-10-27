import Foundation
import Combine

enum ADBConnectionKind: String, Codable, CaseIterable, Sendable {
    case tcp
    case wirelessTLS

    var title: String {
        switch self {
        case .tcp: "ADB TCP"
        case .wirelessTLS: L10n.string("text.wireless_debugging")
        }
    }
}

struct SavedDevice: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var pairingPort: UInt16?
    var kind: ADBConnectionKind
    var brand: String
    var androidVersion: String
    var note: String
    var group: String
    var isFavorite: Bool
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "Android TV",
        host: String,
        port: UInt16,
        pairingPort: UInt16? = nil,
        kind: ADBConnectionKind = .tcp,
        brand: String = "",
        androidVersion: String = "",
        note: String = "",
        group: String = "text.ungrouped",
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.pairingPort = pairingPort
        self.kind = kind
        self.brand = brand
        self.androidVersion = androidVersion
        self.note = note
        self.group = group
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
    }
}

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    var id: String { host }
    var serviceName: String
    var host: String
    var legacyPort: UInt16?
    var pairingPort: UInt16?
    var connectPort: UInt16?

    var preferredPort: UInt16? { connectPort ?? legacyPort ?? pairingPort }
    var needsPairing: Bool { pairingPort != nil }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [SavedDevice] = [] {
        didSet { save() }
    }

    private let defaultsKey = "tvadb.savedDevices.v1"

    init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return }
        devices = decoded
    }

    func upsert(_ device: SavedDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id || ($0.host == device.host && $0.port == device.port) }) {
            var updated = device
            updated.id = devices[index].id
            devices[index] = updated
        } else {
            devices.append(device)
        }
        sort()
    }

    func remove(_ device: SavedDevice) {
        devices.removeAll { $0.id == device.id }
    }

    func toggleFavorite(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].isFavorite.toggle()
        sort()
    }

    func markConnected(_ device: SavedDevice, name: String? = nil, brand: String? = nil, androidVersion: String? = nil) {
        var updated = device
        updated.lastConnectedAt = Date()
        if let name, !name.isEmpty { updated.name = name }
        if let brand, !brand.isEmpty { updated.brand = brand }
        if let androidVersion, !androidVersion.isEmpty { updated.androidVersion = androidVersion }
        upsert(updated)
    }

    private func sort() {
        devices.sort {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
