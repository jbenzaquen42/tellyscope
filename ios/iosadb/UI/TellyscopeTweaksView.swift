// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct TellyscopeTweaksView: View {
    private enum Confirmation: Identifiable {
        case home(TVLauncherOption)
        case clearCaches
        case accessibility(String)
        var id: String {
            switch self {
            case .home(let option): "home:\(option.packageName)"
            case .clearCaches: "clear-caches"
            case .accessibility(let package): "accessibility:\(package)"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var operations: TVOperations?
    @State private var tweaks: TVTweakSnapshot?
    @State private var launchers: TVLauncherSnapshot?
    @State private var dnsHost = "dns.adguard-dns.com"
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?
    @State private var screenshot: UIImage?
    @State private var isLoading = false

    private var deviceID: String? { tweaks?.deviceID ?? launchers?.deviceID }
    private var animationScale: String? {
        guard let tweaks else { return nil }
        return tweaks.animationScales["window_animation_scale"] ?? nil
    }
    private var fastAnimations: Bool { animationScale == "0.5" }
    private var currentLauncher: String? {
        guard let activity = launchers?.currentActivity else { return nil }
        return String(activity.split(separator: "/", maxSplits: 1).first ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityCard
                    privateDNSCard
                    animationsCard
                    cacheCard
                    launcherCard
                    historyCard
                    screenshotCard
                    if let errorMessage { statusCard(errorMessage, error: true) }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(TellyscopeStyle.background)
            .navigationTitle("Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isBusy || isLoading)
                        .accessibilityLabel("Refresh TV settings and launchers")
                }
            }
            .overlay {
                if model.isSafetyOperationActive {
                    ProgressView(model.operationText.isEmpty ? "Updating the TV" : model.operationText)
                        .padding(20)
                        .background(TellyscopeStyle.card, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .task(id: model.currentDevice?.id) {
                operations = nil
                await load()
            }
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                confirmationButtons
            } message: {
                Text(confirmationMessage)
            }
            .alert("TV operation failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .tint(TellyscopeStyle.accent)
        .disabled(model.isSafetyOperationActive)
    }

    private var identityCard: some View {
        TellyscopeCard {
            HStack(spacing: 12) {
                Image(systemName: "tv.fill").font(.title2).foregroundStyle(TellyscopeStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.currentDevice?.name ?? "Android TV").font(.headline)
                    Text(deviceID ?? (isLoading ? "Reading TV settings…" : "Connect to read TV settings"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if isLoading { ProgressView() }
            }
        }
    }

    private var privateDNSCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Private DNS", systemImage: "lock.shield").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                Text(dnsDescription).font(.subheadline).foregroundStyle(.secondary)
                TextField("DNS provider hostname", text: $dnsHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Private DNS provider hostname")
                HStack(spacing: 10) {
                    Button("Set provider") { Task { await setDNS(dnsHost.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                        .buttonStyle(.borderedProminent).tint(TellyscopeStyle.accent)
                        .disabled(model.isBusy || !dnsSupported || dnsHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Automatic") { Task { await setDNS(nil) } }
                        .buttonStyle(.bordered).tint(TellyscopeStyle.accent)
                        .disabled(model.isBusy || !dnsSupported)
                }
                Text("Private DNS needs Android 9+. A provider that blocks DNS can take the TV offline; Tellyscope checks name resolution and restores the prior setting if it fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var animationsCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Animation speed", systemImage: "speedometer").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                Text("Use 0.5× for faster transitions, or return all three animation scales to 1×. The previous values can be restored from History.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { fastAnimations }, set: { value in Task { await setAnimations(value) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Faster animations")
                        Text(fastAnimations ? "0.5×" : "Default speed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(TellyscopeStyle.accent)
                .disabled(model.isBusy || tweaks == nil)
            }
        }
    }

    private var cacheCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Free app cache", systemImage: "sparkles").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                Text("Android may trim cached files across apps. This keeps app data and sign-ins; it cannot be undone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Clear cached files") { confirmation = .clearCaches }
                    .buttonStyle(.bordered).tint(TellyscopeStyle.accent).disabled(model.isBusy || tweaks == nil)
            }
        }
    }

    private var launcherCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Home screen", systemImage: "house.fill").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                Text(currentLauncher.map { "Current Home: \(launcherName($0))" } ?? "The TV has no default Home app selected.")
                    .font(.subheadline)
                if let launchers, !launchers.options.isEmpty {
                    ForEach(launchers.options) { option in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.name).font(.subheadline.weight(.medium))
                                Text(option.packageName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 4)
                            if currentLauncher == option.packageName {
                                Label("Current", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(TellyscopeStyle.accent)
                            } else {
                                Button("Set Home") { confirmation = .home(option) }
                                    .buttonStyle(.bordered).tint(TellyscopeStyle.accent)
                                    .disabled(model.isBusy)
                            }
                        }
                        .frame(minHeight: 48)
                    }
                } else {
                    Text("No eligible installed Home apps were reported by the TV.").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Tellyscope verifies the new Home before turning off the previous launcher. Both remain installed, and a verified switch can be undone from History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var historyCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Recent changes", systemImage: "clock.arrow.circlepath").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                if let entries = tweaks?.history, !entries.isEmpty {
                    ForEach(entries.prefix(8)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.summary).font(.subheadline)
                                Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.canUndo {
                                Button(entry.kind == .launcher ? "Switch back" : "Undo") { Task { await undo(entry) } }
                                    .buttonStyle(.bordered).tint(TellyscopeStyle.accent).disabled(model.isBusy)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    Text("No changes have been recorded for this TV.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var screenshotCard: some View {
        TellyscopeCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("TV screenshot", systemImage: "rectangle.inset.filled").font(.headline).foregroundStyle(TellyscopeStyle.accent)
                Button { Task { await captureScreenshot() } } label: {
                    Label("Capture screen", systemImage: "camera")
                }
                .buttonStyle(.bordered).tint(TellyscopeStyle.accent).disabled(model.isBusy)
                if let screenshot {
                    Image(uiImage: screenshot).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                    ShareLink(item: Image(uiImage: screenshot), preview: SharePreview("TV screenshot")) {
                        Label("Share screenshot", systemImage: "square.and.arrow.up")
                    }
                    .tint(TellyscopeStyle.accent)
                }
            }
        }
    }

    private var dnsSupported: Bool { (tweaks?.androidSDK ?? 0) >= 28 }
    private var dnsDescription: String {
        guard let tweaks else { return "Read the TV's current DNS setting after connecting." }
        guard dnsSupported else { return "Private DNS is unavailable because this TV is older than Android 9 or its version could not be confirmed." }
        if tweaks.privateDNSMode == "hostname", let host = tweaks.privateDNSHost { return "Using encrypted DNS through \(host)." }
        if tweaks.privateDNSMode == "off" { return "Private DNS is off." }
        return "Private DNS is automatic."
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .home(let option): "Make \(option.name) the Home screen?"
        case .clearCaches: "Clear cached files?"
        case .accessibility(let package): "Enable \(launcherName(package)) accessibility service?"
        case nil: "Confirm TV operation"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .home: "The previous launcher is only turned off after Android confirms the selected Home. You can switch back from Recent changes."
        case .clearCaches: "This trims cached files only. App data and sign-ins are kept."
        case .accessibility: "This reviewed launcher service can receive accessibility events and may control the TV interface. Other enabled services are preserved."
        case nil: ""
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        switch confirmation {
        case .home(let option):
            Button("Set as Home") { confirmation = nil; Task { await makeHome(option) } }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .clearCaches:
            Button("Clear cached files", role: .destructive) { confirmation = nil; Task { await clearCaches() } }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .accessibility(let package):
            Button("Enable with consent") { confirmation = nil; Task { await enableAccessibility(package) } }
            Button("No thanks", role: .cancel) { confirmation = nil }
        case nil: EmptyView()
        }
    }

    private func statusCard(_ text: String, error: Bool) -> some View {
        TellyscopeCard {
            Label(text, systemImage: error ? "exclamationmark.triangle" : "info.circle")
                .font(.subheadline).foregroundStyle(error ? Color.red : TellyscopeStyle.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor private func load() async {
        guard !ProcessInfo.processInfo.arguments.contains("-TVADBSimulateConnectedDevice"), !model.isBusy else { return }
        isLoading = true
        model.isBusy = true
        defer { model.isBusy = false; isLoading = false }
        do {
            let controller: TVOperations
            if let operations { controller = operations }
            else {
                controller = TVOperations(executor: try model.portExecutor(), historyURL: try model.portStorageURL("tv-operations.json"))
                operations = controller
            }
            let snapshot = try await controller.inspectTweaks()
            tweaks = snapshot
            if tweaks?.privateDNSHost != nil { dnsHost = tweaks?.privateDNSHost ?? dnsHost }
            launchers = try await controller.launcherOptions()
            errorMessage = nil
        } catch {
            tweaks = nil
            launchers = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func run(_ title: String, _ operation: @MainActor () async throws -> Void) async {
        guard !model.isBusy else { return }
        model.isBusy = true
        model.isSafetyOperationActive = true
        model.operationText = title
        defer { model.isBusy = false; model.isSafetyOperationActive = false; model.operationText = "" }
        do {
            try await operation()
            model.isSafetyOperationActive = false
            model.isBusy = false
            model.operationText = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
            model.isSafetyOperationActive = false
            model.isBusy = false
            model.operationText = ""
            await load()
        }
    }

    @MainActor private func setDNS(_ host: String?) async {
        guard let operations, let deviceID else { return }
        await run(host == nil ? "Restoring automatic Private DNS" : "Checking Private DNS provider") {
            _ = try await operations.setPrivateDNS(host: host, expectedDeviceID: deviceID)
        }
    }

    @MainActor private func setAnimations(_ fast: Bool) async {
        guard let operations, let deviceID else { return }
        await run("Updating animation speed") { _ = try await operations.setFastAnimations(fast, expectedDeviceID: deviceID) }
    }

    @MainActor private func clearCaches() async {
        guard let operations, let deviceID else { return }
        await run("Trimming app caches") { _ = try await operations.clearCaches(expectedDeviceID: deviceID) }
    }

    @MainActor private func makeHome(_ option: TVLauncherOption) async {
        guard let operations, let deviceID else { return }
        await run("Verifying Home screen") {
            _ = try await operations.makeHome(package: option.packageName, expectedDeviceID: deviceID)
            if option.isReviewed, option.accessibilityService != nil { confirmation = .accessibility(option.packageName) }
        }
    }

    @MainActor private func enableAccessibility(_ package: String) async {
        guard let operations, let deviceID else { return }
        await run("Enabling reviewed accessibility service") {
            _ = try await operations.enableLauncherAccessibility(package: package, consent: true, expectedDeviceID: deviceID)
        }
    }

    @MainActor private func undo(_ entry: TVOperationEntry) async {
        guard let operations, let deviceID else { return }
        await run(entry.kind == .launcher ? "Switching back to the previous Home" : "Restoring previous TV settings") {
            _ = try await operations.undo(entryID: entry.id, expectedDeviceID: deviceID)
        }
    }

    @MainActor private func captureScreenshot() async {
        guard let data = await model.captureScreenshot(), let image = UIImage(data: data) else { return }
        screenshot = image
    }

    private func launcherName(_ package: String) -> String {
        launchers?.options.first(where: { $0.packageName == package })?.name ?? package
    }
}
