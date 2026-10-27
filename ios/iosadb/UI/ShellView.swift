import SwiftUI

struct ShellView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""
    @State private var output = L10n.string("text.tvadb_shell_is_ready")
    @State private var history: [String] = []
    @State private var favorites: [String] = []
    @FocusState private var commandFieldIsFocused: Bool

    private let commonCommands = [
        "pm list packages -3",
        "dumpsys activity activities | head -n 80",
        "getprop",
        "ip addr show wlan0",
        "dumpsys battery",
        "wm size; wm density",
        "am force-stop com.google.android.tvlauncher",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                commandFieldIsFocused = false
            }
            .background(Color.black)
            .foregroundStyle(TVADBTheme.cyan)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                commandBar
            }
            .navigationTitle("text.adb_shell")
            .toolbar {
                TVADBDisconnectToolbarItem()
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        if favorites.isEmpty {
                            Text("text.no_favorite_commands")
                        } else {
                            Section("text.favorite_commands") {
                                ForEach(favorites, id: \.self) { item in
                                    Button(item) {
                                        command = item
                                    }
                                }
                            }
                        }
                        Section("text.common_commands") {
                            ForEach(commonCommands, id: \.self) { item in
                                Button(item) {
                                    command = item
                                }
                            }
                        }
                    } label: { Image(systemName: "star") }
                    Menu {
                        if history.isEmpty { Text("text.no_history") }
                        ForEach(history, id: \.self) { item in Button(item) { command = item } }
                    } label: { Image(systemName: "clock") }
                    Button { output = "" } label: { Image(systemName: "trash") }
                }
            }
            .onAppear { loadHistory() }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            TextField("text.enter_a_shell_command", text: $command)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($commandFieldIsFocused)
                .onSubmit {
                    commandFieldIsFocused = false
                }
            Button {
                toggleFavorite(command)
            } label: {
                Image(
                    systemName: favorites.contains(
                        command.trimmingCharacters(in: .whitespacesAndNewlines)
                    ) ? "star.fill" : "star"
                )
            }
            .buttonStyle(.bordered)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("text.toggle_command_favorite")
            Button(action: run) { Image(systemName: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func run() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        command = ""
        output += "\n$ \(value)\n"
        history.removeAll { $0 == value }
        history.insert(value, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        UserDefaults.standard.set(history, forKey: "tvadb.shellHistory")
        Task {
            if let response = await model.executeShell(value) {
                output += response
                if !response.hasSuffix("\n") { output += "\n" }
            }
        }
    }

    private func loadHistory() {
        history = UserDefaults.standard.stringArray(forKey: "tvadb.shellHistory") ?? []
        favorites = UserDefaults.standard.stringArray(
            forKey: "tvadb.shellFavorites"
        ) ?? []
    }

    private func toggleFavorite(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if let index = favorites.firstIndex(of: normalized) {
            favorites.remove(at: index)
        } else {
            favorites.insert(normalized, at: 0)
        }
        UserDefaults.standard.set(favorites, forKey: "tvadb.shellFavorites")
    }
}
