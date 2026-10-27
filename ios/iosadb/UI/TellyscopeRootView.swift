// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import TellyscopeCore

enum TellyscopeStyle {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.50, green: 0.83, blue: 0.84, alpha: 1) : UIColor(red: 0, green: 105 / 255, blue: 107 / 255, alpha: 1) })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 14 / 255, green: 20 / 255, blue: 21 / 255, alpha: 1) : UIColor(red: 244 / 255, green: 251 / 255, blue: 250 / 255, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : UIColor(red: 233 / 255, green: 239 / 255, blue: 238 / 255, alpha: 1) })
    static let tonal = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0, green: 79 / 255, blue: 80 / 255, alpha: 1) : UIColor(red: 204 / 255, green: 232 / 255, blue: 232 / 255, alpha: 1) })
}

struct TellyscopeCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(TellyscopeStyle.card, in: RoundedRectangle(cornerRadius: 24)) }
}

struct TellyscopeRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0
    @State private var showRemote = false
    @State private var showDebloat = false
    @State private var showInstall = false
    @State private var showAdvanced = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var snapshot: TVSnapshot?

    private var preview: Bool { ProcessInfo.processInfo.arguments.contains("-TVADBSimulateConnectedDevice") }
    var body: some View {
        Group {
            if model.connectionState.isConnected {
                TabView(selection: $tab) {
                    NavigationStack { overview }.tag(0).tabItem { Label("Overview", systemImage: "house.fill") }
                    TellyscopeAppsView().tag(1).tabItem { Label("Apps", systemImage: "square.grid.3x3.fill") }
                    TellyscopeFilesView().tag(2).tabItem { Label("Files", systemImage: "folder.fill") }
                    TellyscopeTweaksView().tag(3).tabItem { Label("Tweaks", systemImage: "slider.horizontal.3") }
                }
                .fullScreenCover(isPresented: $showRemote) { TellyscopeRemoteView() }
                .sheet(isPresented: $showDebloat) { TellyscopeDebloatView() }
                .sheet(isPresented: $showInstall) { TellyscopeInstallView() }
                .sheet(isPresented: $showAdvanced) { TellyscopeAdvancedView() }
                .sheet(isPresented: $showHistory) { TellyscopeHistoryView() }
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-TellyscopePreviewRemote") { showRemote = true }
#endif
                }
                .task(id: model.currentDevice?.id) {
                    guard !preview, let executor = try? model.portExecutor() else { return }
                    let reader = TVSnapshotReader(executor: executor)
                    while !Task.isCancelled, model.connectionState.isConnected {
                        if !model.isBusy { snapshot = try? await reader.read() }
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
            } else { TellyscopeConnectView() }
        }
        .tint(TellyscopeStyle.accent)
        .sheet(isPresented: $showSettings) { TellyscopeSettingsView() }
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: 20) {
                if preview { Text("UI preview · no TV connected").font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "tv.fill").font(.system(size: 36)).foregroundStyle(TellyscopeStyle.accent)
                    .frame(width: 88, height: 88).background(TellyscopeStyle.tonal, in: RoundedRectangle(cornerRadius: 28))
                VStack(spacing: 7) {
                    Text(snapshot?.model ?? deviceName).font(.largeTitle).multilineTextAlignment(.center)
                    if let brand = snapshot?.manufacturer { Text(brand).foregroundStyle(.secondary) }
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 9).background(TellyscopeStyle.tonal, in: Capsule())
                }
                deviceChips
                TellyscopeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Internal storage").font(.subheadline)
                            Spacer()
                            if let used = snapshot?.storageUsedBytes, let total = snapshot?.storageTotalBytes {
                                Text("\(bytes(used)) of \(bytes(total)) used").font(.caption)
                            }
                        }
                        Text(freeStorage).font(.title2)
                        ProgressView(value: storageFraction).tint(TellyscopeStyle.accent)
                        HStack(alignment: .top) {
                            metric("CPU", value: snapshot?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                            metric("RAM", value: memoryPercent)
                            metric("Temp", value: snapshot?.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "—")
                            metric("Network", value: snapshot?.networkBytesPerSecond.map { bytes(Int64($0)) + "/s" } ?? "—")
                        }
                    }
                }
                HStack(spacing: 10) {
                    action("Install app", icon: "plus") { showInstall = true }
                    action("Debloat", icon: "sparkles", primary: true) { showDebloat = true }
                    action("Send file", icon: "paperplane.fill") { tab = 2 }
                }
                Button { showRemote = true } label: { Label("Remote", systemImage: "appletvremote.gen4.fill").font(.headline).frame(maxWidth: .infinity).padding(18) }
                    .background(TellyscopeStyle.tonal, in: RoundedRectangle(cornerRadius: 24))
                TellyscopeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Suggested for this TV").font(.headline)
                        Text("Review the model's debloat list. Nothing is deleted, and you can undo changes.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Review suggestions") { showDebloat = true }.frame(minHeight: 44)
                    }
                }
                TellyscopeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(snapshot?.androidVersion.map { "Android \($0)" } ?? "TV software", systemImage: "info.circle.fill")
                        if let patch = snapshot?.securityPatch { Text("Security update \(patch)").font(.caption).foregroundStyle(.secondary) }
                        Button("Check for updates on TV") { Task { _ = await model.executeShell("am start -a android.settings.SYSTEM_UPDATE_SETTINGS") } }
                            .frame(minHeight: 44)
                        Divider()
                        Button("Advanced · CPU, apps and network") { showAdvanced = true }.frame(minHeight: 44)
                        Button("History & undo") { showHistory = true }.frame(minHeight: 44)
                    }
                }
            }.padding(18)
        }
        .background(TellyscopeStyle.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Remote", systemImage: "appletvremote.gen4") { showRemote = true }
                    Button("History & undo", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            }
        }
    }

    private var deviceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.deviceStore.devices) { device in
                    Button { Task { snapshot = nil; await model.connect(device) } } label: {
                        Label(device.name, systemImage: "tv").font(.subheadline).padding(12)
                            .background(TellyscopeStyle.tonal.opacity(model.currentDevice?.id == device.id ? 1 : 0.35), in: Capsule())
                    }.disabled(model.isBusy)
                }
                Button { model.disconnect() } label: { Label("Device", systemImage: "plus").padding(12) }.disabled(model.isBusy)
            }
        }
    }
    private var deviceName: String {
        if case .connected(let name) = model.connectionState { return name }
        return "Your TV"
    }
    private var storageFraction: Double {
        guard let used = snapshot?.storageUsedBytes, let total = snapshot?.storageTotalBytes, total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }
    private var freeStorage: String {
        guard let used = snapshot?.storageUsedBytes, let total = snapshot?.storageTotalBytes else { return "Storage unavailable" }
        return "\(bytes(max(0, total - used))) free"
    }
    private var memoryPercent: String {
        guard let total = snapshot?.memoryTotalBytes, let available = snapshot?.memoryAvailableBytes, total > 0 else { return "—" }
        return "\(Int(100 * Double(total - available) / Double(total)))%"
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption); Text(value).font(.subheadline.bold()).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func action(_ title: String, icon: String, primary: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { VStack(spacing: 14) { Image(systemName: icon).font(.title); Text(title).font(.subheadline.bold()) }.frame(maxWidth: .infinity).frame(minHeight: 108) }
            .foregroundStyle(primary ? TellyscopeStyle.background : Color.primary)
            .background(primary ? TellyscopeStyle.accent : TellyscopeStyle.tonal, in: RoundedRectangle(cornerRadius: 24))
            .disabled(model.isBusy)
    }
}

struct TellyscopeConnectView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var discovery = DeviceDiscovery()
    @State private var add = false
    @State private var host = ""
    @State private var port = "5555"
    @State private var wireless = false
    @State private var pairingPort = ""
    @State private var code = ""
    @State private var brand = "Google TV / Android TV"
    @State private var settings = false
    @AppStorage(TVADBPreferences.autoScanKey) private var autoScan = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "tv.fill").font(.system(size: 52)).foregroundStyle(TellyscopeStyle.accent).padding(.top, 25)
                    Text("Tellyscope").font(.largeTitle.bold())
                    Text("Your TV, without the clutter.").font(.title2)
                    Text("Debloat, install apps, move files and control your TV. Everything stays on your Wi-Fi.").foregroundStyle(.secondary)
                    if !store.devices.isEmpty {
                        Text("Your TVs").font(.headline)
                        ForEach(store.devices) { device in
                            TellyscopeCard { HStack {
                                Button { Task { await model.connect(device) } } label: { Label(device.name, systemImage: "tv").frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44) }
                                Menu { Button("Forget TV", role: .destructive) { store.remove(device) } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            } }
                        }
                    }
                    Text("Add your TV").font(.headline)
                    Picker("TV brand", selection: $brand) {
                        ForEach(["Google TV / Android TV", "TCL", "Amazon Fire TV", "Sony", "Hisense", "NVIDIA Shield", "Other"], id: \.self) { Text($0) }
                    }.pickerStyle(.menu)
                    TellyscopeCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(brand == "Amazon Fire TV" ? "On Fire TV: Settings → My Fire TV → About. Select the device name seven times. Then enable Developer options → ADB debugging." : "On the TV: Settings → System → About. Select Android TV OS build seven times, then enable USB/network debugging or Wireless debugging in Developer options.")
                            Text("Accept the debugging authorization on your TV. Keep the TV and iPhone on the same trusted network.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { add = true } label: { Label("Add by IP or pairing code", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(18) }
                        .background(TellyscopeStyle.tonal, in: Capsule())
                    HStack { Text("Found on your Wi-Fi").font(.headline); Spacer(); Button { discovery.start() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) } }
                    ForEach(discovery.devices) { device in
                        Button {
                            host = device.host
                            port = String(device.connectPort ?? device.legacyPort ?? 5555)
                            pairingPort = device.pairingPort.map(String.init) ?? ""
                            wireless = device.pairingPort != nil
                            add = true
                        } label: { TellyscopeCard { Label("\(device.serviceName) · \(device.host)", systemImage: "tv") } }
                    }
                    if discovery.devices.isEmpty { Text("No TV found yet. You can still add its IP address.").foregroundStyle(.secondary) }
                    if let error = discovery.discoveryError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if model.connectionState.isConnecting {
                        ProgressView(model.operationText)
                        Button("Cancel connection") { model.cancelConnection() }
                    }
                }.padding(22)
            }
            .background(TellyscopeStyle.background)
            .task { if autoScan { discovery.start(additionalHosts: store.devices.map(\.host)) } }
            .onChange(of: autoScan) { _, enabled in if enabled { discovery.start(additionalHosts: store.devices.map(\.host)) } else { discovery.stop() } }
            .onDisappear { discovery.stop() }
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("Settings") }
            .sheet(isPresented: $settings) { TellyscopeSettingsView() }
            .sheet(isPresented: $add) {
                NavigationStack {
                    Form {
                        Section("TV address") {
                            TextField("IP address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Connection port", text: $port).keyboardType(.numberPad)
                            Toggle("Pair with a six-digit code", isOn: $wireless)
                            if wireless {
                                TextField("Pairing port", text: $pairingPort).keyboardType(.numberPad)
                                TextField("Six-digit code", text: $code).keyboardType(.numberPad)
                                Text("Pairing and connection ports are different. Keep the pairing window open on the TV.").font(.caption)
                            }
                        }
                        Button(model.isBusy ? "Connecting…" : "Connect") { Task {
                            if wireless { _ = await model.pairAndConnect(name: brand, host: host, pairingPortText: pairingPort, connectPortText: port, code: code) }
                            else { await model.connect(host: host, portText: port) }
                            if model.connectionState.isConnected { add = false }
                        } }.disabled(model.isBusy || host.isEmpty || UInt16(port) == nil || (wireless && (code.count != 6 || UInt16(pairingPort) == nil)))
                        if model.connectionState.isConnecting { ProgressView(model.operationText); Button("Cancel") { model.cancelConnection() } }
                    }
                    .navigationTitle("Connect your TV")
                    .toolbar { Button("Done") { add = false } }
                }
            }
        }
    }
}

struct TellyscopeInstallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picker = false
    @State private var selected: URL?
    @State private var inspection: APKInspection?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "plus.app").font(.system(size: 50)).foregroundStyle(TellyscopeStyle.accent)
                Text("Install an app on your TV").font(.title2)
                Text("Choose an APK, split APK bundle, APKS, XAPK or APKM from Files. Review the package before installing.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Choose package") { picker = true }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                if model.isBusy { ProgressView(model.operationText); if let progress = model.progress { ProgressView(value: progress) } }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(TellyscopeStyle.background)
                .navigationTitle("Install app").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() }.disabled(model.isBusy) }
                .fullScreenCover(isPresented: $picker) { TVADBInstallPackagePicker { url in
                    picker = false
                    Task { selected = await model.prepareInstallPackage(from: url); if let selected { inspection = await model.inspectAPK(url: selected); confirm = inspection != nil } }
                } onCancel: { picker = false } }
                .sheet(isPresented: $confirm) { if let inspection, let selected { APKInspectionView(inspection: inspection) { confirm = false; Task { if await model.installAPK(url: selected) { dismiss() } } } } }
                .onDisappear { if let selected { AppModel.cleanupPreparedInstallPackage(selected) } }
        }
    }
}

struct TellyscopeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TVADBPreferences.autoConnectLastDeviceKey) private var reconnect = false
    @AppStorage(TVADBPreferences.autoScanKey) private var scan = true
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    var body: some View {
        NavigationStack {
            Form {
                Section("Tellyscope") {
                    Text("Debloat your TV, install apps, transfer files and use your phone as a remote.")
                    Text("No accounts, ads or tracking. TV commands stay on your network; community debloat lists are downloaded from GitHub.").font(.subheadline)
                    Link("Source & licenses", destination: URL(string: "https://github.com/jbenzaquen42/tellyscope/tree/codex/ios-port/ios")!)
                }
                Section("Connection & appearance") {
                    Toggle("Find TVs on Wi-Fi", isOn: $scan)
                    Toggle("Reconnect to last TV", isOn: $reconnect)
                    Picker("Appearance", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) } }
                }
            }.navigationTitle("Settings").toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct TellyscopeHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var packages: DeviceSnapshot?
    @State private var operations: [TVOperationEntry] = []
    @State private var failure: String?
    @State private var restore = false
    @State private var undoEntry: TVOperationEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Everything Tellyscope changed on this TV. Restore enables only apps changed here; apps already off before Tellyscope stay off.")
                    Button("Restore everything disabled here") { restore = true }.disabled(packages?.restorablePackages.isEmpty != false)
                }
                if let packages {
                    Section("Apps") {
                        ForEach(Array(packages.history.reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(entry.action == "disable" ? "Disabled" : "Enabled") \(entry.packageName)")
                                Text(entry.timestamp, style: .date).font(.caption).foregroundStyle(.secondary)
                                if entry.action == "disable", packages.restorablePackages.contains(entry.packageName), packages.history.last(where: { $0.packageName == entry.packageName })?.timestamp == entry.timestamp {
                                    Button("Undo") { Task { await enable(entry.packageName) } }.frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }
                Section("TV settings & home screen") {
                    ForEach(operations) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.summary)
                            Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if entry.canUndo { Button("Undo") { undoEntry = entry }.frame(minHeight: 44) }
                            else if entry.undoneAt != nil { Text("Undone").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if packages?.history.isEmpty != false && operations.isEmpty { Text("No changes recorded on this TV yet.").foregroundStyle(.secondary) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden).background(TellyscopeStyle.background)
            .navigationTitle("History & undo").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(model.isBusy) }
            .task { await load() }.refreshable { await load() }.disabled(model.isBusy)
            .confirmationDialog("Restore these apps?", isPresented: $restore, titleVisibility: .visible) {
                Button("Enable apps again") { Task { await enable(nil) } }
            } message: { Text(packages?.restorablePackages.sorted().joined(separator: "\n") ?? "") }
            .confirmationDialog("Undo this TV change?", isPresented: Binding(get: { undoEntry != nil }, set: { if !$0 { undoEntry = nil } }), titleVisibility: .visible) {
                Button("Undo") { let entry = undoEntry; undoEntry = nil; Task { if let entry { await undo(entry) } } }
            } message: { Text(undoEntry?.summary ?? "") }
        }
    }
    private func controller() throws -> TVOperations { TVOperations(executor: try model.portExecutor(), historyURL: try model.portStorageURL("tv-operations.json")) }
    @MainActor private func load() async {
        do {
            packages = try await model.safePackageController().inspect()
            operations = try await controller().history().filter { $0.deviceID == packages?.deviceID }.sorted { $0.date > $1.date }
        } catch { failure = error.localizedDescription }
    }
    @MainActor private func enable(_ package: String?) async {
        guard !model.isBusy, let expected = packages?.deviceID else { return }
        model.isBusy = true; model.isSafetyOperationActive = true
        do {
            let controller = try model.safePackageController()
            if let package { _ = try await controller.enable(package: package, expectedDeviceID: expected) }
            else { _ = try await controller.restore(expectedDeviceID: expected) }
        } catch { failure = error.localizedDescription }
        await load(); model.isBusy = false; model.isSafetyOperationActive = false
    }
    @MainActor private func undo(_ entry: TVOperationEntry) async {
        guard !model.isBusy, let expected = packages?.deviceID else { return }
        model.isBusy = true; model.isSafetyOperationActive = true
        do { _ = try await controller().undo(entryID: entry.id, expectedDeviceID: expected) } catch { failure = error.localizedDescription }
        await load(); model.isBusy = false; model.isSafetyOperationActive = false
    }
}
