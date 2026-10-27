// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TellyscopeCore

struct TellyscopeRemoteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dock: [String] = []
    @State private var dockKey: String?
    @State private var chooseDock = false
    @State private var restart = false
    @State private var pictureOn = true
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    GeometryReader { geometry in
                        let size = min(geometry.size.width, 340.0)
                        ZStack {
                            Circle().fill(TellyscopeStyle.card)
                            remoteKey(19, "chevron.up", "Up").offset(y: -size * 0.34)
                            remoteKey(20, "chevron.down", "Down").offset(y: size * 0.34)
                            remoteKey(21, "chevron.left", "Left").offset(x: -size * 0.34)
                            remoteKey(22, "chevron.right", "Right").offset(x: size * 0.34)
                            remoteKey(23, "circle.fill", "OK", size: size * 0.37, primary: true)
                        }.frame(width: size, height: size).frame(maxWidth: .infinity)
                    }.frame(height: min(UIScreen.main.bounds.width - 36, 340))
                    HStack { remoteKey(4, "arrow.left", "Back"); Spacer(); remoteKey(3, "house", "Home"); Spacer(); remoteKey(82, "line.3.horizontal", "Menu") }
                    HStack { remoteKey(164, "speaker.slash", "Mute"); Spacer(); remoteKey(25, "speaker.fill", "Volume down", size: 95); remoteKey(24, "speaker.wave.2.fill", "Volume up", size: 95) }
                    HStack(alignment: .top) {
                        ForEach(dock, id: \.self) { package in
                            if let app = model.applications.first(where: { $0.packageName == package }) {
                                Button { Task { await model.applicationAction(app, action: .launch) } } label: {
                                    VStack(spacing: 6) {
                                        if let data = app.iconData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                        else { Image(systemName: "app.fill").font(.largeTitle).frame(width: 48, height: 48) }
                                        Text(app.displayName).font(.caption).lineLimit(2)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        if dock.count < 4 { Button { chooseDock = true } label: { Image(systemName: "plus.app").font(.title).frame(minWidth: 44, minHeight: 54) }.accessibilityLabel("Add app to remote dock") }
                    }
                    HStack {
                        TextField("Type on the TV", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { sendText() }
                        Button { Task { await press(67) } } label: { Image(systemName: "delete.left.fill").frame(width: 44, height: 44) }.accessibilityLabel("Backspace on TV")
                        Button(action: sendText) { Image(systemName: "paperplane.fill").frame(width: 44, height: 44) }.accessibilityLabel("Send text to TV").disabled(text.isEmpty)
                    }.padding(8).background(TellyscopeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    Text("Select a text box on the TV, like a search box, then type here.").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }.background(TellyscopeStyle.background)
            .navigationTitle("Remote").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { repeatTask?.cancel(); Task { await close() } } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Close remote").disabled(model.isBusy) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { if await model.portScreen(on: !pictureOn) { pictureOn.toggle() } } } label: { Image(systemName: pictureOn ? "tv.slash" : "tv").frame(width: 44, height: 44) }.accessibilityLabel(pictureOn ? "Turn TV picture off" : "Turn TV picture on")
                    Menu {
                        Button("Edit app dock") { chooseDock = true }
                        Button("Restart TV", role: .destructive) { restart = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                }
            }
            .onDisappear { repeatTask?.cancel(); if !pictureOn { Task { _ = await model.portScreen(on: true) } } }
            .task {
                guard !ProcessInfo.processInfo.arguments.contains("-TVADBSimulateConnectedDevice") else { return }
                await model.loadApplicationsIfNeeded()
                if let snapshot = try? await model.safePackageController().inspect() {
                    let key = "tellyscope.dock.\(snapshot.deviceID)"; dockKey = key
                    dock = Array((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { p in model.applications.contains { $0.packageName == p } }.prefix(4))
                }
            }
            .sheet(isPresented: $chooseDock) {
                NavigationStack {
                    List(model.applications) { app in
                        Button {
                            if dock.contains(app.packageName) { dock.removeAll { $0 == app.packageName } }
                            else if dock.count < 4 { dock.append(app.packageName) }
                            if let dockKey { UserDefaults.standard.set(dock, forKey: dockKey) }
                        } label: { HStack { Text(app.displayName); Spacer(); if dock.contains(app.packageName) { Image(systemName: "checkmark") } } }
                    }.navigationTitle("Dock up to four apps").toolbar { Button("Done") { chooseDock = false } }
                }
            }
            .confirmationDialog("Restart the TV?", isPresented: $restart, titleVisibility: .visible) { Button("Restart", role: .destructive) { Task { await model.reboot() } } } message: { Text("The TV will disconnect while it restarts.") }
            .alert("Remote action failed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        }
    }
    private func remoteKey(_ code: Int, _ icon: String, _ label: String, size: CGFloat = 68, primary: Bool = false) -> some View {
        Button { Task { await press(code) } } label: {
            Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(primary ? TellyscopeStyle.background : Color.primary)
                .frame(width: size, height: size).background(primary ? TellyscopeStyle.accent : TellyscopeStyle.tonal, in: Circle())
        }
        .accessibilityLabel(label)
        .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressed in
            repeatTask?.cancel()
            if pressed { repeatTask = Task {
                do { try await Task.sleep(for: .milliseconds(400)); while !Task.isCancelled { await press(code); try await Task.sleep(for: .milliseconds(120)) } } catch { }
            } }
        })
    }
    @MainActor private func press(_ code: Int) async {
        if !pictureOn { pictureOn = await model.portScreen(on: true); return }
        await model.sendRemoteKey(code)
    }
    @MainActor private func close() async {
        if !pictureOn { pictureOn = await model.portScreen(on: true) }
        if pictureOn { dismiss() }
    }
    private func sendText() { let sending = text; Task { if await model.sendRemoteText(sending) { text = "" } } }
}
