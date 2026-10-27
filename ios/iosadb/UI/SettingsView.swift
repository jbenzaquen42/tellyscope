import SwiftUI

struct TVADBSettingsForm: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(TVADBPreferences.autoConnectLastDeviceKey)
    private var autoConnectLastDevice = false
    @AppStorage(TVADBPreferences.autoScanKey)
    private var autoScan = true
    @AppStorage(AppLanguage.storageKey)
    private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey)
    private var appAppearance = AppAppearance.system.rawValue
    @AppStorage(AppInstallMode.storageKey)
    private var installMode = AppInstallMode.replace.rawValue
    @AppStorage(TVADBPreferences.openRemoteWhenRecordingKey)
    private var openRemoteWhenRecording = false
    @AppStorage(TVADBPreferences.loadApplicationIconsKey)
    private var loadApplicationIcons = true
    @AppStorage(TVADBPreferences.liveScreenControlModeKey)
    private var liveScreenControlMode = LiveScreenControlMode.mouse.rawValue

    var body: some View {
        Form {
            Section("text.general") {
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                } label: {
                    Label("text.app_language", systemImage: "globe")
                }

                Picker(selection: $appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                } label: {
                    Label("text.appearance", systemImage: "circle.lefthalf.filled")
                }
            }

            Section {
                Toggle(isOn: $autoConnectLastDevice) {
                    Label(
                        "text.auto_connect_last_device",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
                Toggle(isOn: $autoScan) {
                    Label("text.auto_scan", systemImage: "dot.radiowaves.left.and.right")
                }
            } header: {
                Text("text.connect")
            } footer: {
                Text("text.auto_connect_last_device_footer")
            }

            Section {
                Toggle(isOn: $openRemoteWhenRecording) {
                    Label(
                        "text.open_remote_when_recording",
                        systemImage: "appletvremote.gen4"
                    )
                }
            } header: {
                Text("text.screen_recording")
            } footer: {
                Text("text.open_remote_when_recording_footer")
            }

            Section {
                Picker(
                    "text.default_live_screen_control",
                    selection: $liveScreenControlMode
                ) {
                    ForEach(LiveScreenControlMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                NavigationLink {
                    RemoteControlOrderView()
                } label: {
                    Label(
                        "text.control_order",
                        systemImage: "slider.horizontal.3"
                    )
                }
            } header: {
                Text("text.remote_preferences")
            } footer: {
                Text("text.remote_preferences_footer")
            }

            Section {
                Toggle(isOn: $loadApplicationIcons) {
                    Label(
                        "text.load_application_icons",
                        systemImage: "square.grid.2x2"
                    )
                }
                Picker("text.default_installation_method", selection: $installMode) {
                    ForEach(AppInstallMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("text.apps_ac7fd221")
            } footer: {
                Text("text.load_application_icons_footer")
            }

            Section("text.about") {
                Text("text.dark_mode_follows_ios_root_recovery_bootloader_and_and_7724bac9")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: loadApplicationIcons) { _, isEnabled in
            Task {
                await model.applicationIconLoadingDidChange(
                    isEnabled: isEnabled
                )
            }
        }
    }
}

private struct RemoteControlOrderView: View {
    @AppStorage(TVADBPreferences.remoteControlOrderKey)
    private var rawValue = TVADBPreferences.defaultRemoteControlOrderRawValue

    private var modes: [RemoteControlMode] {
        TVADBPreferences.remoteControlOrder(from: rawValue)
    }

    var body: some View {
        List {
            Section {
                ForEach(modes) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                }
                .onMove { source, destination in
                    var reorderedModes = modes
                    reorderedModes.move(
                        fromOffsets: source,
                        toOffset: destination
                    )
                    rawValue = TVADBPreferences.remoteControlOrderRawValue(
                        for: reorderedModes
                    )
                }
            } footer: {
                Text("text.drag_remote_modes_to_reorder")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(L10n.string("text.remote_preferences"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("text.reset") {
                    rawValue =
                        TVADBPreferences.defaultRemoteControlOrderRawValue
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey)
    private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            TVADBSettingsForm()
                .navigationTitle(L10n.string("text.settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("text.done") { dismiss() }
                    }
                }
        }
        .id(appLanguage)
    }
}
