// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct TellyscopeAppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var category = "Installed"
    @State private var search = ""
    @State private var snapshot: DeviceSnapshot?
    @State private var running: Set<String> = []
    @State private var systemExpanded = false
    @State private var install = false
    @State private var selected: AndroidApp?
    @State private var requestedAction: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Apps", selection: $category) { ForEach(["Running", "Installed", "Disabled"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                    Button { install = true } label: { Label("Install app", systemImage: "plus").frame(maxWidth: .infinity).padding(16) }.background(TellyscopeStyle.tonal, in: Capsule())
                    ForEach(filtered.filter { !$0.isSystem }) { app in row(app) }
                    if !filtered.filter(\.isSystem).isEmpty {
                        DisclosureGroup("System apps", isExpanded: $systemExpanded) { VStack(spacing: 12) { ForEach(filtered.filter(\.isSystem)) { app in row(app) } } }
                    }
                    if filtered.isEmpty { ContentUnavailableView("No apps here", systemImage: "square.grid.3x3", description: Text("Pull to refresh or choose another tab.")) }
                }.padding(18)
            }
            .background(TellyscopeStyle.background)
            .navigationTitle("Apps").navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }.task { await load() }
            .sheet(isPresented: $install) { TellyscopeInstallView() }
            .confirmationDialog(requestedAction.map { "\($0) \(selected?.displayName ?? "app")?" } ?? "App action", isPresented: Binding(get: { requestedAction != nil }, set: { if !$0 { requestedAction = nil } }), titleVisibility: .visible) {
                Button(requestedAction ?? "Confirm", role: .destructive) { let action = requestedAction; requestedAction = nil; Task { await act(action) } }
                Button("Cancel", role: .cancel) { requestedAction = nil }
            } message: { Text((selected?.packageName ?? "") + (requestedAction == "Uninstall" ? "\nThis deletes the app and its data. It cannot be undone." : "\nDisable keeps the app installed and can be undone in History.")) }
            .alert("App change failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
            .disabled(model.isBusy)
        }
    }
    private var filtered: [AndroidApp] {
        model.applications.filter { app in
            (search.isEmpty || app.displayName.localizedCaseInsensitiveContains(search) || app.packageName.localizedCaseInsensitiveContains(search)) &&
            (category == "Installed" || (category == "Disabled" ? snapshot?.disabledPackages.contains(app.packageName) == true : running.contains(app.packageName)))
        }
    }
    private func row(_ app: AndroidApp) -> some View {
        TellyscopeCard {
            HStack(spacing: 12) {
                if let data = app.iconData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 10)) }
                else { Image(systemName: "app.fill").font(.title).foregroundStyle(TellyscopeStyle.accent).frame(width: 42) }
                VStack(alignment: .leading, spacing: 4) { Text(app.displayName).font(.headline); Text(app.packageName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer(minLength: 0)
                Menu {
                    Button("Open") { Task { await model.applicationAction(app, action: .launch) } }
                    if snapshot?.disabledPackages.contains(app.packageName) == true { Button("Enable again") { selected = app; requestedAction = "Enable" } }
                    else if snapshot?.disabledPackages.contains(app.packageName) != true { Button("Disable") { selected = app; requestedAction = "Disable" } }
                    Button("Stop") { selected = app; requestedAction = "Stop" }
                    if !app.isSystem { Button("Uninstall", role: .destructive) { selected = app; requestedAction = "Uninstall" } }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.disabled(snapshot == nil)
            }
        }
    }
    @MainActor private func load() async {
        guard !ProcessInfo.processInfo.arguments.contains("-TVADBSimulateConnectedDevice") else { return }
        await model.loadApplications()
        do {
            snapshot = try await model.safePackageController().inspect()
            let result = try await model.portExecutor().run("ps -A -o NAME")
            if result.exitCode == 0 { running = Set(result.output.split(whereSeparator: \.isNewline).map { String($0.split(separator: ":").first ?? $0) }) }
        } catch { snapshot = nil; failure = error.localizedDescription }
    }
    @MainActor private func act(_ action: String?) async {
        guard let app = selected, let expected = snapshot?.deviceID, !model.isBusy else { return }
        if action == "Stop" || action == "Uninstall" { await model.portAppAction(app, action: action == "Stop" ? .forceStop : .uninstall, expectedDeviceID: expected) }
        else {
            model.isBusy = true; model.isSafetyOperationActive = true
            do {
                let controller = try model.safePackageController()
                if action == "Enable" { _ = try await controller.enableManually(package: app.packageName, expectedDeviceID: expected) }
                else { _ = try await controller.disable(package: app.packageName, expectedDeviceID: expected) }
            } catch { failure = error.localizedDescription }
            model.isBusy = false; model.isSafetyOperationActive = false
        }
        await load()
    }
}

struct TellyscopeFilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var folder = "Download"
    @State private var importer = false
    @State private var export: FileExportItem?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Folder", selection: $folder) { Text("Downloads").tag("Download"); Text("Movies").tag("Movies") }.pickerStyle(.segmented)
                    Button { importer = true } label: { Label("Send file to \(folder)", systemImage: "paperplane.fill").frame(maxWidth: .infinity).padding(18) }.background(TellyscopeStyle.tonal, in: Capsule())
                    if model.isBusy { ProgressView(model.operationText); if let progress = model.progress { ProgressView(value: progress) }; Button("Cancel transfer") { model.cancelActiveFileTransfer() } }
                    ForEach(model.files.filter { !$0.isDirectory }) { file in
                        TellyscopeCard { HStack {
                            Image(systemName: folder == "Movies" ? "film" : "doc").foregroundStyle(TellyscopeStyle.accent)
                            VStack(alignment: .leading, spacing: 5) { Text(file.name); Text(file.formattedSize).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button { Task { if let url = await model.download(file) { export = FileExportItem(url: url) } } } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Save \(file.name)")
                        } }
                    }
                    if model.files.isEmpty && !model.isBusy { ContentUnavailableView("No files here yet", systemImage: "folder", description: Text("Send a file from your iPhone to this TV folder.")) }
                }.padding(18)
            }.background(TellyscopeStyle.background)
            .navigationTitle("Files").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }.onChange(of: folder) { _, _ in Task { await refresh() } }.refreshable { await refresh() }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in if case .success(let urls) = result { Task { await model.upload(urls: urls) } } else if case .failure(let error) = result { model.errorMessage = error.localizedDescription } }
            .sheet(item: $export) { FileExportPicker(url: $0.url) }
        }
    }
    @MainActor private func refresh() async { guard !model.isBusy else { return }; model.currentPath = "/sdcard/\(folder)"; await model.refresh() }
}
