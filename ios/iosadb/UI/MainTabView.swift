import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case files
        case apps
        case remote
        case shell
        case tools
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage(TVADBPreferences.openRemoteWhenRecordingKey)
    private var openRemoteWhenRecording = false
    @State private var selectedTab: Tab = .files

    var body: some View {
        TabView(selection: $selectedTab) {
            FileBrowserView()
                .tag(Tab.files)
                .tabItem {
                    Label("text.files", systemImage: selectedTab == .files ? "folder.fill" : "folder")
                }
            ApplicationsView()
                .tag(Tab.apps)
                .tabItem {
                    Label("text.apps", systemImage: selectedTab == .apps ? "square.grid.2x2.fill" : "square.grid.2x2")
                }
            RemoteControlView()
                .tag(Tab.remote)
                .tabItem {
                    Label("text.remote", systemImage: selectedTab == .remote ? "appletvremote.gen4.fill" : "appletvremote.gen4")
                }
            ShellView()
                .tag(Tab.shell)
                .tabItem {
                    Label("text.shell", systemImage: selectedTab == .shell ? "terminal.fill" : "terminal")
                }
            ToolsView()
                .tag(Tab.tools)
                .tabItem {
                    Label("text.tools", systemImage: selectedTab == .tools ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                }
        }
        .tint(TVADBTheme.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onChange(of: model.isScreenRecording) { _, isRecording in
            if isRecording, openRemoteWhenRecording {
                selectedTab = .remote
            }
        }
    }
}
