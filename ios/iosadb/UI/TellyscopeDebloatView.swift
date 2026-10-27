// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct TellyscopeDebloatView: View {
    private enum Confirmation: Identifiable {
        case disable([SuggestedDevicePackage])
        case enable([String])
        var id: String {
            switch self {
            case .disable(let rows): return "disable:" + rows.map(\.package).joined(separator: ",")
            case .enable(let packages): return "enable:" + packages.joined(separator: ",")
            }
        }
        var packages: [String] {
            switch self {
            case .disable(let rows): return rows.map(\.package)
            case .enable(let packages): return packages
            }
        }
        var title: String {
            switch self {
            case .disable(let rows): return "Disable \(rows.count) app\(rows.count == 1 ? "" : "s")?"
            case .enable(let packages): return "Enable \(packages.count) app\(packages.count == 1 ? "" : "s")?"
            }
        }
        var isDisable: Bool {
            if case .disable = self { return true }
            return false
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var lists: TellyscopeDeviceLists?
    @State private var controller: SafePackageController?
    @State private var suggestions: DeviceListSuggestions?
    @State private var snapshot: DeviceSnapshot?
    @State private var selectedPackages = Set<String>()
    @State private var showListPicker = false
    @State private var showManual = false
    @State private var showHistory = false
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?
    @State private var serial: String?

    private var teal: Color { TellyscopeStyle.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introCard
                    if let suggestions { curatedContent(suggestions) }
                    if let snapshot { historyContent(snapshot) }
                    if let errorMessage { statusCard(errorMessage, isError: true) }
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .background(TellyscopeStyle.background.ignoresSafeArea())
            .navigationTitle("Safe debloat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(model.isSafetyOperationActive) }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isBusy)
                        .accessibilityLabel("Refresh device lists and app state")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Manual apps") { showManual = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || manualRows.isEmpty)
                    Button {
                        confirmation = .disable(selectedRows)
                    } label: {
                        Label("Disable \(selectedPackages.count)", systemImage: "shield.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(teal)
                    .disabled(model.isBusy || selectedRows.isEmpty)
                }
                .padding(14)
                .background(TellyscopeStyle.background.opacity(0.96))
            }
            .overlay {
                if model.isSafetyOperationActive {
                    ProgressView(model.operationText).padding(20).background(TellyscopeStyle.card, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .task { await load() }
            .sheet(isPresented: $showListPicker) {
                if let suggestions {
                    DeviceListPicker(entries: suggestions.entries, selectedID: suggestions.selectedListID) { id in
                        showListPicker = false
                        Task { await chooseList(id) }
                    }
                }
            }
            .sheet(isPresented: $showManual) {
                ManualPackagePicker(apps: manualRows, selected: selectedPackages) { next in
                    selectedPackages = next
                    showManual = false
                }
            }
            .sheet(isPresented: $showHistory) {
                SafeDebloatView().environmentObject(model)
            }
            .sheet(item: $confirmation) { action in
                PackageConfirmationSheet(
                    title: action.title,
                    rows: confirmationRows(action),
                    actionLabel: action.isDisable ? "Yes, disable them" : "Enable again",
                    destructive: action.isDisable,
                    onCancel: { confirmation = nil },
                    onConfirm: { confirmation = nil; Task { await apply(action) } }
                )
            }
        }
        .tint(teal)
    }

    private var introCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "tv.and.hifispeaker.fill").font(.title2).foregroundStyle(teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.currentDevice?.name ?? "Android TV").font(.headline)
                        Text(serial ?? "Reading this TV's identity…").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
                Text("Review the apps on this TV. Nothing is uninstalled. You can turn back on only apps disabled here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let suggestions, suggestions.offline {
                    Label("Using bundled or validated cached profiles offline.", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(teal)
                }
            }
        }
    }

    @ViewBuilder private func curatedContent(_ result: DeviceListSuggestions) -> some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.list?.name ?? "Choose a TV list").font(.headline)
                        Text(matchDescription(result)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showListPicker = true } label: {
                        Label(result.selectedListID == nil ? "Choose" : "Change", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .tint(teal)
                    .disabled(model.isBusy || result.entries.isEmpty)
                }
                if case .picked = result.match {
                    Button("Use automatic model match") { Task { await clearListPick() } }
                        .font(.caption.weight(.semibold)).foregroundStyle(teal).disabled(model.isBusy)
                }
                if let list = result.list {
                    Text(testDescription(list, sdk: deviceSDK))
                        .font(.caption).foregroundStyle(.secondary)
                    if result.groups.isEmpty {
                        Label("This validated list has no enabled, installed apps that are safe to suggest.", systemImage: "checkmark.shield")
                            .font(.subheadline).foregroundStyle(teal)
                    }
                    ForEach(result.groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(teal)
                            ForEach(group.packages) { row in
                                packageRow(row)
                            }
                        }
                        .padding(.top, 5)
                    }
                    if let commit = result.commit {
                        Text("List source commit \(commit.prefix(12))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if case .maker(let maker) = result.match {
                    Text("No single model list matched. Choose a specific \(maker) TV list, or pick apps manually.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(result.entries.isEmpty ? "The list index is unavailable. You can still choose installed apps manually." : "No exact model list matched. Choose a list for this TV or review apps manually.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func packageRow(_ row: SuggestedDevicePackage) -> some View {
        Button {
            if selectedPackages.contains(row.package) { selectedPackages.remove(row.package) }
            else { selectedPackages.insert(row.package) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedPackages.contains(row.package) ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(selectedPackages.contains(row.package) ? teal : Color.gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text([row.package, row.note, row.optional ? "Optional" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityLabel("\(selectedPackages.contains(row.package) ? "Selected" : "Not selected"): \(row.name), \(row.package)")
    }

    private func historyContent(_ snapshot: DeviceSnapshot) -> some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Changes on this TV").font(.headline)
                    Spacer()
                    Button("History & manual") { showHistory = true }.font(.caption.weight(.semibold)).foregroundStyle(teal)
                }
                if snapshot.restorablePackages.isEmpty {
                    Text("No apps disabled here need restoring.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.restorablePackages.sorted(), id: \.self) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appName(package)).font(.subheadline.weight(.medium))
                                Text(package).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Enable") { confirmation = .enable([package]) }
                                .buttonStyle(.bordered).tint(teal).disabled(model.isBusy)
                        }
                        .frame(minHeight: 48)
                    }
                    Button("Restore all \(snapshot.restorablePackages.count) apps") {
                        confirmation = .enable(snapshot.restorablePackages.sorted())
                    }
                    .buttonStyle(.borderedProminent).tint(teal).disabled(model.isBusy)
                }
                if !snapshot.history.isEmpty {
                    Divider()
                    ForEach(Array(snapshot.history.suffix(4).reversed().enumerated()), id: \.offset) { _, entry in
                        Text("\(["disable": "Disabled", "enable": "Enabled", "stop": "Stopped", "uninstall": "Uninstalled"][entry.action] ?? entry.action.capitalized) \(appName(entry.packageName)) · \(entry.timestamp, style: .date)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusCard(_ text: String, isError: Bool) -> some View {
        TellyscopeCard {
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.subheadline).foregroundStyle(isError ? Color.red : teal).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manualRows: [SuggestedDevicePackage] {
        guard let snapshot else { return [] }
        return model.applications.filter { app in
            !snapshot.disabledPackages.contains(app.packageName)
                && SafePackageController.protectedReason(app.packageName) == nil
                && !(suggestions?.protectedKeep.contains(app.packageName) ?? false)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { SuggestedDevicePackage(package: $0.packageName, name: $0.displayName, note: nil, optional: false, selected: false) }
    }

    private var selectedRows: [SuggestedDevicePackage] {
        let visible = (suggestions?.groups ?? []).flatMap(\.packages) + manualRows
        var seen = Set<String>()
        return visible.filter { selectedPackages.contains($0.package) && seen.insert($0.package).inserted }
    }

    private var deviceSDK: Int? { currentProperties["sdk"].flatMap(Int.init) }
    @State private var currentProperties: [String: String] = [:]

    private func matchDescription(_ result: DeviceListSuggestions) -> String {
        switch result.match {
        case .model: "Model match · review every package before applying"
        case .picked: "Manually selected TV list · review every package before applying"
        case .maker(let maker): "Maker match only for \(maker) · choose an exact list before applying"
        case .manual: "No automatic model match · choose a list or apps manually"
        }
    }

    private func testDescription(_ list: CuratedDeviceList, sdk: Int?) -> String {
        guard let listSDK = list.sdk, let sdk else { return (list.testedOS ?? "Android version not verified for this list") + " · nothing preselected" }
        return sdk == listSDK ? "Tested on Android SDK \(listSDK)" : "Tested on SDK \(listSDK); this TV reports SDK \(sdk) · nothing preselected"
    }

    private func confirmationRows(_ action: Confirmation) -> [SuggestedDevicePackage] {
        action.packages.map { package in
            SuggestedDevicePackage(package: package, name: appName(package), note: nil, optional: false, selected: true)
        }
    }

    private func appName(_ package: String) -> String {
        model.applications.first(where: { $0.packageName == package })?.displayName ?? package
    }

    @MainActor private func load() async {
        await model.loadApplicationsIfNeeded()
        await refresh()
    }

    @MainActor private func refresh() async {
        guard !model.isBusy else { return }
        model.isBusy = true
        model.operationText = "Reading TV and curated lists"
        defer { model.isBusy = false; model.operationText = "" }
        do {
            let activeController = try controller ?? model.safePackageController()
            let executor = try model.portExecutor()
            let activeLists = try lists ?? TellyscopeDeviceLists(cacheDirectory: model.portStorageURL("device-lists"))
            controller = activeController
            lists = activeLists
            let current = try await activeController.inspect()
            let props = try await readProperties(executor)
            let home = try await readHome(executor)
            serial = current.deviceID
            snapshot = current
            currentProperties = props
            var keep = current.disabledPackages
            keep.insert(home)
            let appInfos = model.applications.map {
                DeviceListApp(package: $0.packageName, name: $0.displayName,
                              enabled: !current.disabledPackages.contains($0.packageName),
                              protected: SafePackageController.protectedReason($0.packageName) != nil || $0.packageName == home)
            }
            let result = await activeLists.suggestions(
                serial: current.deviceID, properties: props, sdk: props["sdk"].flatMap(Int.init),
                apps: appInfos, protectedKeep: keep
            )
            suggestions = result
            selectedPackages = Set(result.groups.flatMap(\.packages).filter(\.selected).map(\.package))
            errorMessage = nil
        } catch {
            suggestions = nil
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func chooseList(_ id: String) async {
        guard let lists, let serial else { return }
        do { try await lists.pick(id, for: serial); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func clearListPick() async {
        guard let lists, let serial else { return }
        do { try await lists.clearPick(for: serial); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func apply(_ action: Confirmation) async {
        guard !model.isBusy, let expected = snapshot?.deviceID, let controller else { return }
        let packages = action.packages
        guard !packages.isEmpty else { return }
        model.isBusy = true
        model.isSafetyOperationActive = true
        model.operationText = action.isDisable ? "Disabling selected apps" : "Restoring selected apps"
        defer { model.isBusy = false; model.isSafetyOperationActive = false; model.operationText = "" }
        var completed = 0
        do {
            for package in packages {
                let result: MutationResult
                if action.isDisable { result = try await controller.disable(package: package, expectedDeviceID: expected) }
                else { result = try await controller.enable(package: package, expectedDeviceID: expected) }
                if result.changed { completed += 1 }
            }
            snapshot = try await controller.inspect()
            selectedPackages.subtract(packages)
            errorMessage = nil
        } catch {
            snapshot = try? await controller.inspect()
            errorMessage = "Confirmed changes to \(completed) of \(packages.count) apps. The current app may be uncertain; later apps were not attempted. \(error.localizedDescription)"
        }
    }

    private func readProperties(_ executor: ShellExecutor) async throws -> [String: String] {
        var result: [String: String] = [:]
        for key in ["manufacturer", "brand", "model", "device", "name"] {
            let response = try await executor.run("getprop ro.product.\(key)")
            guard response.exitCode == 0 else { throw SafePackageError.commandFailed(response.output) }
            let value = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[key] = value }
        }
        let sdk = try await executor.run("getprop ro.build.version.sdk")
        guard sdk.exitCode == 0 else { throw SafePackageError.commandFailed(sdk.output) }
        let sdkValue = sdk.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(sdkValue) != nil { result["sdk"] = sdkValue }
        let incremental = try await executor.run("getprop ro.build.version.incremental")
        guard incremental.exitCode == 0 else { throw SafePackageError.commandFailed(incremental.output) }
        let build = incremental.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !build.isEmpty { result["incremental"] = build }
        return result
    }

    private func readHome(_ executor: ShellExecutor) async throws -> String {
        let response = try await executor.run("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        guard response.exitCode == 0 else { throw SafePackageError.unknownHome }
        let packages = Set(response.output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let part = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").first.map(String.init)
            guard let part, part != "android", part.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil else { return nil }
            return part
        })
        guard packages.count == 1, let home = packages.first else { throw SafePackageError.unknownHome }
        return home
    }

}

private struct DeviceListPicker: View {
    let entries: [DeviceListEntry]
    let selectedID: String?
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { entry in
                Button { choose(entry.id); dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).foregroundStyle(.primary)
                            Text([entry.id, entry.sdk.map { "SDK \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedID == entry.id { Image(systemName: "checkmark").foregroundStyle(TellyscopeStyle.accent) }
                    }
                    .frame(minHeight: 48)
                }.buttonStyle(.plain)
            }
            .navigationTitle("Choose a TV list")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Brand or model")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var filtered: [DeviceListEntry] {
        guard !query.isEmpty else { return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
}

private struct ManualPackagePicker: View {
    let apps: [SuggestedDevicePackage]
    let selected: Set<String>
    let save: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = Set<String>()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered, id: \.package) { row in
                Button {
                    if current.contains(row.package) { current.remove(row.package) } else { current.insert(row.package) }
                } label: {
                    HStack {
                        Image(systemName: current.contains(row.package) ? "checkmark.square.fill" : "square")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).foregroundStyle(.primary)
                            Text(row.package).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.frame(minHeight: 48)
                }.buttonStyle(.plain)
            }
            .navigationTitle("Pick installed apps")
            .searchable(text: $query, prompt: "App name or package")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(current); dismiss() } }
            }
            .onAppear { current = selected }
        }
    }

    private var filtered: [SuggestedDevicePackage] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.package.localizedCaseInsensitiveContains(query) }
    }
}

private struct PackageConfirmationSheet: View {
    let title: String
    let rows: [SuggestedDevicePackage]
    let actionLabel: String
    let destructive: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(destructive ? "Each selected app stays installed. The operation stops if the TV refuses a change; completed changes remain in History." : "Only apps disabled by Tellyscope on this TV can be restored.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Apps included") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.body.weight(.medium))
                            Text(row.package).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionLabel, role: destructive ? .destructive : nil) { onConfirm(); dismiss() }
                        .disabled(rows.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
