// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct BoundDeviceShell: ShellExecutor {
    let client: ADBMobileClient
    let host: String
    let port: UInt16

    func run(_ command: String) async throws -> TellyscopeCore.ShellResult {
        let result = try await client.checkedShell(command, host: host, port: port)
        return TellyscopeCore.ShellResult(output: result.output, exitCode: Int32(result.exitCode))
    }
}

struct SafeDebloatView: View {
    private enum Confirmation: Identifiable {
        case disable(AndroidApp)
        case restore(String)
        case restoreAll

        var id: String {
            switch self {
            case .disable(let app): "disable:\(app.packageName)"
            case .restore(let package): "restore:\(package)"
            case .restoreAll: "restore-all"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var controller: SafePackageController?
    @State private var snapshot: DeviceSnapshot?
    @State private var search = ""
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Review apps individually. Essential apps and your current Home screen are protected. Undo restores only changes made here.")
                    if let snapshot {
                        Text("TV identity: \(snapshot.deviceID)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("History belongs to this TV. Restore skips apps that were already disabled before Tellyscope changed anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let snapshot, !snapshot.restorablePackages.isEmpty {
                    Section("Undo changes") {
                        ForEach(snapshot.restorablePackages.sorted(), id: \.self) { package in
                            Button { confirmation = .restore(package) } label: {
                                Label(package, systemImage: "arrow.uturn.backward")
                                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityLabel("Enable \(package)")
                            .frame(minHeight: 44)
                        }
                        Button("Restore everything changed here") { confirmation = .restoreAll }
                            .frame(minHeight: 44)
                    }
                }

                Section("Installed apps") {
                    if snapshot == nil {
                        Text("Load the TV's identity and app state before making changes.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredApps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.displayName).font(.body)
                                Text(app.packageName).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            if snapshot?.disabledPackages.contains(app.packageName) == true {
                                Text("Disabled").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Disable") { confirmation = .disable(app) }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("Disable \(app.displayName)")
                                    .frame(minHeight: 44)
                                    .disabled(snapshot == nil)
                            }
                        }
                    }
                }

                if let history = snapshot?.history, !history.isEmpty {
                    Section("History on this TV") {
                        ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.action == "disable" ? "Disabled" : "Enabled") \(entry.packageName)")
                                    .font(.subheadline)
                                Text(entry.timestamp, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(model.isBusy)
            .searchable(text: $search, prompt: "App name or package")
            .scrollContentBackground(.hidden)
            .background(TellyscopeStyle.background)
            .navigationTitle("History & undo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(model.isSafetyOperationActive)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh app state")
                    .disabled(model.isBusy)
                }
            }
            .overlay { if model.isSafetyOperationActive { ProgressView(model.operationText).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .interactiveDismissDisabled(model.isSafetyOperationActive)
            .task {
                await model.loadApplicationsIfNeeded()
                await refresh()
            }
            .alert("Could not complete the change", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog(confirmationTitle, isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            ), titleVisibility: .visible) {
                if let selected = confirmation {
                    Button(confirmButton(selected), role: isDisable(selected) ? .destructive : nil) {
                        confirmation = nil
                        Task { await change(selected) }
                    }
                }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { Text(confirmationMessage) }
        }
    }

    private var filteredApps: [AndroidApp] {
        model.applications.filter {
            search.isEmpty || $0.packageName.localizedCaseInsensitiveContains(search)
                || $0.displayName.localizedCaseInsensitiveContains(search)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .disable(let app): "Disable \(app.displayName)?"
        case .restore(let package): "Enable \(package)?"
        case .restoreAll: "Restore these apps?"
        case nil: "Review change"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .disable(let app): "\(app.packageName)\nThe app stays installed. You can enable it again here."
        case .restore(let package): package
        case .restoreAll: snapshot?.restorablePackages.sorted().joined(separator: "\n") ?? ""
        case nil: ""
        }
    }

    private func confirmButton(_ selected: Confirmation) -> String {
        isDisable(selected) ? "Disable app" : "Enable again"
    }

    private func isDisable(_ selected: Confirmation) -> Bool {
        if case .disable = selected { return true }
        return false
    }

    @MainActor private func refresh() async {
        await perform("Reading app state") { _ in }
    }

    @MainActor private func change(_ selected: Confirmation) async {
        guard let expectedDeviceID = snapshot?.deviceID else { return }
        await perform("Verifying app change") { controller in
            switch selected {
            case .disable(let app): _ = try await controller.disable(package: app.packageName, expectedDeviceID: expectedDeviceID)
            case .restore(let package): _ = try await controller.enable(package: package, expectedDeviceID: expectedDeviceID)
            case .restoreAll: _ = try await controller.restore(expectedDeviceID: expectedDeviceID)
            }
        }
    }

    @MainActor private func perform(_ text: String, operation: (SafePackageController) async throws -> Void) async {
        guard !model.isBusy else { return }
        model.isBusy = true
        model.isSafetyOperationActive = true
        model.operationText = text
        defer {
            model.isBusy = false
            model.isSafetyOperationActive = false
            model.operationText = ""
        }
        do {
            let active = try controller ?? model.safePackageController()
            controller = active
            try await operation(active)
            snapshot = try await active.inspect()
        } catch {
            // Never offer actions based on a snapshot that may predate an interrupted change.
            snapshot = nil
            errorMessage = error.localizedDescription + " Refresh to reconcile the TV's current state."
        }
    }
}
