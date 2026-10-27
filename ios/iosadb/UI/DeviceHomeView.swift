import SwiftUI

struct DeviceHomeView: View {
    private enum HomeTab: Hashable {
        case home
        case settings
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: DeviceStore
    @AppStorage("tvadb.autoScan") private var autoScan = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @StateObject private var discovery = DeviceDiscovery()
    @State private var selectedTab: HomeTab = .home
    @State private var showManualAdd = false
    @State private var pairingTarget: DiscoveredDevice?
    @State private var editingDevice: SavedDevice?

    var body: some View {
        TabView(selection: $selectedTab) {
            homePage
                .tag(HomeTab.home)
                .tabItem {
                    Label(
                        "text.home",
                        systemImage: selectedTab == .home
                            ? "house.fill"
                            : "house"
                    )
                }

            NavigationStack {
                TVADBSettingsForm()
                    .navigationTitle(L10n.string("text.settings"))
                    .navigationBarTitleDisplayMode(.large)
            }
            .tag(HomeTab.settings)
            .tabItem {
                Label(
                    "text.settings",
                    systemImage: selectedTab == .settings
                        ? "gearshape.fill"
                        : "gearshape"
                )
            }
        }
        .tint(TVADBTheme.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onChange(of: selectedTab) { _, tab in
            if tab == .home, autoScan {
                startDiscovery()
            } else {
                discovery.stop()
            }
        }
        .onChange(of: appLanguage) {
            model.errorMessage = nil
            model.noticeMessage = nil
            if selectedTab == .home, autoScan {
                discovery.stop()
                startDiscovery()
            }
        }
    }

    private var homePage: some View {
        NavigationStack {
            List {
                if discovery.isScanning || !discovery.devices.isEmpty || !discovery.statusText.isEmpty || discovery.discoveryError != nil {
                    Section("text.local_network_devices") {
                        if discovery.isScanning {
                            HStack(spacing: 12) {
                                if let progress = discovery.scanProgress {
                                    ProgressView(value: progress)
                                        .frame(width: 42)
                                } else {
                                    ProgressView()
                                }
                                Text(discovery.statusText)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !discovery.devices.isEmpty {
                            ForEach(discovery.devices) { device in
                                discoveredRow(device)
                            }
                        }
                        if !discovery.isScanning && discovery.devices.isEmpty {
                            HStack(spacing: 12) {
                                Label("text.no_devices_found", systemImage: "wifi.slash")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Button {
                                    startDiscovery()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("text.retry")
                                    }
                                    .fixedSize()
                                }
                                .buttonStyle(.borderless)
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        if let error = discovery.discoveryError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("text.my_tvs") {
                    if store.devices.isEmpty {
                        ContentUnavailableView(
                            "text.no_devices_yet",
                            systemImage: "tv",
                            description: Text("text.scan_automatically_or_add_the_tv_ip_address_and_adb_po_2c2bad29")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(store.devices) { device in
                            savedRow(device)
                        }
                        .onDelete { indexes in
                            indexes.map { store.devices[$0] }.forEach(store.remove)
                        }
                    }
                }

                Section {
                    Label("text.the_device_and_iphone_must_be_on_the_same_trusted_netw_2df5216b", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .navigationTitle("TVADB")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        discovery.isScanning
                            ? discovery.stop()
                            : startDiscovery()
                    } label: {
                        Image(systemName: discovery.isScanning ? "stop.circle" : "arrow.clockwise")
                    }
                    Menu {
                        Button {
                            showManualAdd = true
                        } label: {
                            Label("text.add_adb_tcp_device", systemImage: "network")
                        }
                        Button {
                            pairingTarget = DiscoveredDevice(serviceName: "Android TV", host: "")
                        } label: {
                            Label("text.pair_wirelessly", systemImage: "lock.shield")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if model.isBusy {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(model.operationText).font(.subheadline)
                        if model.connectionState.isConnecting {
                            Button("text.cancel_connection") {
                                model.cancelConnection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .sheet(isPresented: $showManualAdd) { ManualDeviceSheet() }
            .sheet(item: $pairingTarget) { PairingSheet(device: $0) }
            .sheet(item: $editingDevice) { EditDeviceSheet(device: $0) }
            .onAppear {
                if autoScan {
                    startDiscovery()
                }
            }
            .onDisappear { discovery.stop() }
        }
    }

    private func startDiscovery() {
        discovery.start(
            additionalHosts: store.devices.map(\.host)
        )
    }

    private func savedRow(_ device: SavedDevice) -> some View {
        Button { Task { await model.connect(device) } } label: {
            HStack(spacing: 12) {
                Image(systemName: device.isFavorite ? "star.circle.fill" : "tv.circle.fill")
                    .font(.title2)
                    .foregroundStyle(device.isFavorite ? Color.yellow : TVADBTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.headline).foregroundStyle(.primary)
                    Text(verbatim: "\(device.host):\(String(device.port)) · \(device.kind.title) · \(localizedGroup(device.group))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !device.brand.isEmpty || !device.androidVersion.isEmpty {
                        Text([device.brand, device.androidVersion.isEmpty ? "" : "Android \(device.androidVersion)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !device.note.isEmpty {
                        Text(device.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingDevice = device
            } label: {
                Label("text.edit_device", systemImage: "pencil")
            }
            Button { store.toggleFavorite(device) } label: {
                Label(
                    device.isFavorite ? L10n.string("text.remove_favorite") : L10n.string("text.favorite"),
                    systemImage: device.isFavorite ? "star.slash" : "star"
                )
            }
            Button(role: .destructive) { store.remove(device) } label: { Label("text.delete", systemImage: "trash") }
        }
    }

    private func discoveredRow(_ device: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.needsPairing ? "tv.badge.wifi" : "tv")
                .font(.title2).foregroundStyle(TVADBTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.serviceName).font(.headline)
                Text("\(device.host):\(device.preferredPort.map { String($0) } ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(device.needsPairing ? L10n.string("text.pair") : L10n.string("text.connect")) {
                if device.needsPairing {
                    pairingTarget = device
                } else if let port = device.connectPort ?? device.legacyPort {
                    let kind: ADBConnectionKind = device.connectPort == nil ? .tcp : .wirelessTLS
                    let saved = SavedDevice(name: device.serviceName, host: device.host, port: port, kind: kind)
                    store.upsert(saved)
                    Task { await model.connect(saved) }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func localizedGroup(_ group: String) -> String {
        for key in ["text.ungrouped", "text.living_room", "text.bedroom", "text.office"] {
            if L10n.matches(group, key: key) {
                return L10n.string(key)
            }
        }
        return group
    }
}

private struct ManualDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: DeviceStore
    @State private var name = L10n.string("text.living_room_tv")
    @State private var host = ""
    @State private var port = "5555"
    @State private var group = L10n.string("text.living_room")
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("text.device") {
                    TextField("text.name", text: $name)
                    TextField("text.ip_address_or_hostname", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("text.adb_port", text: $port).keyboardType(.numberPad)
                    TextField("text.group", text: $group)
                    TextField("text.note", text: $note, axis: .vertical)
                }
                Section {
                    Text("text.the_usual_adb_tcpip_port_is_5555_android_11_wireless_d_14255726")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("text.add_device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("text.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("text.save_and_connect") {
                        guard let value = UInt16(port), !host.isEmpty else {
                            model.errorMessage = UserFacingFailure.text(.invalidAddress)
                            return
                        }
                        let device = SavedDevice(
                            name: name.isEmpty ? "Android TV" : name,
                            host: host,
                            port: value,
                            note: note,
                            group: group.isEmpty ? "text.ungrouped" : group
                        )
                        store.upsert(device)
                        dismiss()
                        Task { await model.connect(device) }
                    }
                }
            }
        }
    }
}

private struct EditDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceStore
    let device: SavedDevice

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var group: String
    @State private var note: String

    init(device: SavedDevice) {
        self.device = device
        _name = State(initialValue: device.name)
        _host = State(initialValue: device.host)
        _port = State(initialValue: String(device.port))
        _group = State(initialValue: device.group)
        _note = State(initialValue: device.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("text.device") {
                    TextField("text.name", text: $name)
                    TextField("text.ip_address_or_hostname", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("text.adb_port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("text.group", text: $group)
                    TextField("text.note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("text.edit_device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("text.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("text.save") {
                        save()
                    }
                    .disabled(
                        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || UInt16(port) == nil
                    )
                }
            }
        }
    }

    private func save() {
        guard let resolvedPort = UInt16(port) else { return }
        var updated = device
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Android TV"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.port = resolvedPort
        updated.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "text.ungrouped"
            : group.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsert(updated)
        dismiss()
    }
}

private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let device: DiscoveredDevice
    @State private var name = ""
    @State private var host = ""
    @State private var code = ""
    @State private var pairingPort = ""
    @State private var connectPort = ""
    @State private var isPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("text.android_11_wireless_debugging") {
                    TextField("text.device_name", text: $name)
                    TextField("text.ip_address_or_hostname", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("text.pairing_port", text: $pairingPort).keyboardType(.numberPad)
                    TextField("text.connection_port", text: $connectPort).keyboardType(.numberPad)
                    TextField("text.6_digit_pairing_code", text: $code).keyboardType(.numberPad)
                }
                Section {
                    Text("text.keep_the_tv_s_pair_device_with_pairing_code_window_ope_acf6fde1")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        isPairing = true
                        Task {
                            let connected = await model.pairAndConnect(
                                name: name,
                                host: host,
                                pairingPortText: pairingPort,
                                connectPortText: connectPort,
                                code: code
                            )
                            isPairing = false
                            if connected { dismiss() }
                        }
                    } label: {
                        HStack {
                            if isPairing { ProgressView() }
                            Text(
                                isPairing
                                    ? L10n.string("text.pairing_with_spake2_tls")
                                    : L10n.string("text.pair_securely_and_connect")
                            )
                        }
                    }
                    .disabled(isPairing || host.isEmpty || code.count != 6 || UInt16(pairingPort) == nil || UInt16(connectPort) == nil)
                }
            }
            .navigationTitle("text.wireless_pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("text.close") { dismiss() } } }
            .onAppear {
                name = device.serviceName
                host = device.host
                pairingPort = device.pairingPort.map { String($0) } ?? ""
                connectPort = device.connectPort.map { String($0) } ?? ""
            }
        }
    }
}
