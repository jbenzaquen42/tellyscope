import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    private struct DeleteRequest {
        let targets: [RemoteFile]
    }

    private enum ImportPurpose {
        case upload
        case install
        case syncToTV
    }

    private enum SortOption: CaseIterable {
        case name
        case date
        case size

        var title: LocalizedStringKey {
            switch self {
            case .name: "text.name"
            case .date: "text.date"
            case .size: "text.size"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isEditing = false
    @State private var showImporter = false
    @State private var showUploadPicker = false
    @State private var showInstallPackagePicker = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteRequest: DeleteRequest?
    @State private var exportItem: FileExportItem?
    @State private var exportCleanupURL: URL?
    @State private var query = ""
    @State private var sortOption: SortOption = .name
    @State private var ascending = true
    @State private var selection: Set<String> = []
    @State private var localDirectory = LocalFilePane.rootDirectory
    @State private var localRefreshID = 0
    @State private var selectedInstallPackageURL: URL?
    @State private var installPackageInspection: APKInspection?
    @State private var isPreparingInstallPackage = false
    @State private var isInstallingImportedPackage = false

    var body: some View {
        NavigationStack {
            browserLayout
            .navigationTitle(deviceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "text.search_this_folder")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if model.isBusy {
                    operationBar
                } else if !selection.isEmpty {
                    TVADBPanel {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(TVADBTheme.accent)
                            Text(String(format: L10n.string("text.value_selected"), selection.count))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Menu {
                                Button {
                                    downloadSelection(toLocalPane: false)
                                } label: {
                                    Label(
                                        "text.download_selected",
                                        systemImage: "square.and.arrow.down"
                                    )
                                }
                                if horizontalSizeClass == .regular {
                                    Button {
                                        downloadSelection(toLocalPane: true)
                                    } label: {
                                        Label(
                                            "text.download_selected_to_left_pane",
                                            systemImage: "arrow.left.circle"
                                        )
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    let targets = model.files.filter {
                                        selection.contains($0.id)
                                    }
                                    deleteRequest = DeleteRequest(targets: targets)
                                } label: {
                                    Label("text.delete", systemImage: "trash.fill")
                                }
                            } label: {
                                Label("text.actions", systemImage: "ellipsis.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(TVADBTheme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(12)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
            .overlay {
                if isPreparingInstallPackage || isInstallingImportedPackage {
                    TVADBBlockingProgressOverlay(
                        message: installPackageOperationText,
                        progress: model.progress
                    )
                }
            }
            .refreshable { await model.refresh() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let directory = urls.first else { return }
                    Task {
                        await model.synchronizeLocalDirectoryToTV(directory)
                    }
                case .failure(let error):
                    model.errorMessage = UserFacingFailure.message(
                        .syncDirectory,
                        underlying: error
                    )
                }
            }
            .fullScreenCover(isPresented: $showInstallPackagePicker) {
                TVADBInstallPackagePicker {
                    showInstallPackagePicker = false
                    guard AppModel.isSupportedInstallPackage($0) else {
                        model.errorMessage = L10n.string(
                            "error.select_supported_install_package"
                        )
                        return
                    }
                    selectInstallPackage($0)
                } onCancel: {
                    showInstallPackagePicker = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showUploadPicker) {
                TVADBFileImportPicker(
                    contentTypes: [.item, .folder],
                    allowsMultipleSelection: true,
                    onPick: { urls in
                        showUploadPicker = false
                        Task { await model.upload(urls: urls) }
                    },
                    onCancel: {
                        showUploadPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $installPackageInspection, onDismiss: {
                if !isInstallingImportedPackage {
                    cleanupSelectedInstallPackage()
                }
            }) { inspection in
                APKInspectionView(inspection: inspection) {
                    installSelectedPackage()
                }
            }
            .sheet(item: $exportItem, onDismiss: cleanupExportItem) { item in
                FileExportPicker(url: item.url)
            }
            .alert("text.new_folder", isPresented: $showNewFolder) {
                TextField("text.folder_name", text: $newFolderName)
                Button("text.cancel", role: .cancel) {}
                Button("text.create") { Task { await model.createDirectory(named: newFolderName) } }
            }
            .alert("text.rename", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("text.new_name", text: $renameText)
                Button("text.cancel", role: .cancel) { renameTarget = nil }
                Button("text.save") {
                    guard let target = renameTarget else { return }
                    renameTarget = nil
                    Task { await model.rename(target, to: renameText) }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            )
        ) {
            Button("text.cancel", role: .cancel) {
                deleteRequest = nil
            }
            Button("text.delete", role: .destructive) {
                guard let request = deleteRequest else { return }
                deleteRequest = nil
                selection.subtract(request.targets.map(\.id))
                Task { await model.delete(request.targets) }
            }
        } message: {
            Text("text.this_action_cannot_be_undone")
        }
    }

    @ViewBuilder
    private var browserLayout: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                LocalFilePane(
                    currentDirectory: $localDirectory,
                    refreshID: localRefreshID,
                    upload: { url in
                        Task { await model.upload(url: url) }
                    },
                    install: selectInstallPackage
                )
                .frame(minWidth: 310, idealWidth: 370, maxWidth: 430)

                Divider()
                remoteList
            }
        } else {
            remoteList
        }
    }

    private var remoteList: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    pathHeader
                    fileQuickActions
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if model.files.isEmpty, !model.isBusy {
                    ContentUnavailableView("text.this_folder_is_empty", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedFiles) { file in
                        fileRow(file)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.upload(urls: urls) }
            return true
        }
    }

    private var pathHeader: some View {
        TVADBPanel {
            HStack(spacing: 13) {
                Button { Task { await model.goUp() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.bold())
                        .frame(width: 42, height: 42)
                        .foregroundStyle(model.currentPath == "/" ? Color.secondary : Color.white)
                        .background(
                            model.currentPath == "/" ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(TVADBTheme.accentGradient),
                            in: Circle()
                        )
                }
                .buttonStyle(TVADBPressableStyle())
                .disabled(model.currentPath == "/" || model.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    Text("text.current_location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.currentPath)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
    }

    private var fileQuickActions: some View {
        HStack(spacing: 10) {
            fileQuickAction("text.upload_file", icon: "square.and.arrow.up.fill", tint: TVADBTheme.accent) {
                presentImporter(.upload)
            }
            fileQuickAction("text.install_apk", icon: "shippingbox.fill", tint: TVADBTheme.deepBlue) {
                presentImporter(.install)
            }
            fileQuickAction("text.new_folder", icon: "folder.badge.plus", tint: TVADBTheme.cyan) {
                newFolderName = ""
                showNewFolder = true
            }
        }
    }

    private func fileQuickAction(
        _ title: LocalizedStringKey,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14), in: Circle())
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.12))
            }
        }
        .buttonStyle(TVADBPressableStyle())
        .disabled(model.isBusy)
    }

    private func fileRow(_ file: RemoteFile) -> some View {
        Button {
            if isEditing {
                if selection.contains(file.id) {
                    selection.remove(file.id)
                } else {
                    selection.insert(file.id)
                }
            } else if file.isDirectory {
                Task { await model.open(file) }
            }
        } label: {
            HStack(spacing: 12) {
                if isEditing {
                    Image(systemName: selection.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(file.id) ? TVADBTheme.accent : Color.secondary)
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: file.isDirectory ? "folder.fill" : icon(for: file.name))
                    .font(.title2)
                    .foregroundStyle(file.isDirectory ? TVADBTheme.cyan : TVADBTheme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(file.formattedSize) · \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if file.isDirectory {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selection.contains(file.id) ? TVADBTheme.accent.opacity(0.10) : Color.clear)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: selection.contains(file.id))
        .contextMenuIf(!isEditing) {
            if horizontalSizeClass == .regular {
                Button { downloadToLocal(file) } label: {
                    Label("text.download_to_left_pane", systemImage: "arrow.left.circle")
                }
            }
            Button { download(file) } label: { Label("text.download_to_iphone", systemImage: "square.and.arrow.down") }
            Button {
                renameText = file.name
                renameTarget = file
            } label: { Label("text.rename", systemImage: "pencil") }
            Button(role: .destructive) {
                deleteRequest = DeleteRequest(targets: [file])
            } label: {
                Label("text.delete", systemImage: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        TVADBDisconnectToolbarItem()
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation {
                    isEditing.toggle()
                    if !isEditing { selection.removeAll() }
                }
            } label: {
                if isEditing {
                    Text("text.done")
                } else {
                    Text("text.edit")
                }
            }
            .disabled(model.files.isEmpty || model.isBusy)
            Menu {
                Button { presentImporter(.upload) } label: { Label("text.upload_file", systemImage: "square.and.arrow.up") }
                Button { presentImporter(.install) } label: { Label("text.install_apk", systemImage: "shippingbox") }
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: { Label("text.new_folder", systemImage: "folder.badge.plus") }
                Button { Task { await model.refresh() } } label: { Label("text.refresh", systemImage: "arrow.clockwise") }
                Divider()
                Picker("text.sort", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button {
                    ascending.toggle()
                } label: {
                    if ascending {
                        Label("text.ascending", systemImage: "arrow.up")
                    } else {
                        Label("text.descending", systemImage: "arrow.down")
                    }
                }
                Divider()
                if horizontalSizeClass == .regular {
                    Button {
                        Task {
                            await model
                                .synchronizeLocalDirectoryToTV(
                                    localDirectory
                                )
                        }
                    } label: {
                        Label(
                            "text.sync_left_pane_to_tv",
                            systemImage: "arrow.right.circle"
                        )
                    }
                } else {
                    Button {
                        presentImporter(.syncToTV)
                    } label: {
                        Label(
                            "text.choose_folder_to_sync_to_tv",
                            systemImage: "arrow.right.circle"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(model.isBusy)
        }
    }

    private var operationBar: some View {
        TVADBPanel {
            HStack(spacing: 12) {
                if let progress = model.progress {
                    ProgressView(value: progress)
                        .frame(width: 46)
                } else {
                    ProgressView()
                }
                Text(model.operationText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.isFileTransferActive {
                    Button("text.cancel") {
                        model.cancelActiveFileTransfer()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(14)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var deviceTitle: String {
        if case .connected(let name) = model.connectionState { return name }
        return L10n.string("text.files_b3bd5ac7")
    }

    private func isPackageURL(_ url: URL) -> Bool {
        ["apk", "apks", "xapk", "apkm"].contains(url.pathExtension.lowercased())
    }

    private var deleteConfirmationTitle: String {
        guard let request = deleteRequest else { return "" }
        if request.targets.count == 1, let target = request.targets.first {
            return String(
                format: L10n.string("text.delete_value"),
                target.name
            )
        }
        return String(
            format: L10n.string("text.delete_value_items"),
            request.targets.count
        )
    }

    private var displayedFiles: [RemoteFile] {
        let filtered = query.isEmpty ? model.files : model.files.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch sortOption {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .date:
                comparison = lhs.modifiedAt == rhs.modifiedAt ? lhs.name.localizedStandardCompare(rhs.name) : (lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending)
            case .size:
                comparison = lhs.size == rhs.size ? lhs.name.localizedStandardCompare(rhs.name) : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func icon(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "apk": "shippingbox.fill"
        case "jpg", "jpeg", "png", "gif", "webp": "photo.fill"
        case "mp4", "mkv", "mov": "film.fill"
        case "mp3", "m4a", "wav", "flac": "music.note"
        case "zip", "7z", "rar", "tar", "gz": "archivebox.fill"
        default: "doc.fill"
        }
    }

    private func download(_ file: RemoteFile) {
        Task {
            guard let url = await model.download(file) else { return }
            exportCleanupURL = url.deletingLastPathComponent()
            exportItem = FileExportItem(url: url)
        }
    }

    private func cleanupExportItem() {
        guard let url = exportCleanupURL else { return }
        try? FileManager.default.removeItem(at: url)
        exportCleanupURL = nil
        exportItem = nil
    }

    private func downloadToLocal(_ file: RemoteFile) {
        Task {
            guard let downloadedURL = await model.download(file) else { return }
            let destination = localDirectory.appendingPathComponent(
                file.name,
                isDirectory: file.isDirectory
            )
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: downloadedURL, to: destination)
                try? FileManager.default.removeItem(at: downloadedURL.deletingLastPathComponent())
                localRefreshID += 1
                model.noticeMessage = String(
                    format: L10n.string("text.downloaded_to_the_left_pane_value"),
                    file.name
                )
            } catch {
                model.errorMessage = UserFacingFailure.message(
                    .saveDownloadedFile,
                    underlying: error
                )
            }
        }
    }

    private func downloadSelection(toLocalPane: Bool) {
        let targets = model.files.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        selection.removeAll()
        isEditing = false
        Task {
            if toLocalPane {
                for target in targets {
                    guard let downloadedURL = await model.download(target) else {
                        return
                    }
                    let destination = localDirectory.appendingPathComponent(
                        target.name,
                        isDirectory: target.isDirectory
                    )
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(
                            at: downloadedURL,
                            to: destination
                        )
                        try? FileManager.default.removeItem(
                            at: downloadedURL.deletingLastPathComponent()
                        )
                    } catch {
                        model.errorMessage = UserFacingFailure.message(
                            .saveDownloadedFile,
                            underlying: error
                        )
                        return
                    }
                }
                localRefreshID += 1
                model.noticeMessage = L10n.format(
                    "text.downloaded_value_items_to_left_pane",
                    targets.count
                )
                return
            }

            let exportRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TVADB-Export-\(UUID().uuidString)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: exportRoot,
                    withIntermediateDirectories: true
                )
                for target in targets {
                    guard let downloadedURL = await model.download(target) else {
                        try? FileManager.default.removeItem(at: exportRoot)
                        return
                    }
                    let destination = exportRoot.appendingPathComponent(
                        target.name,
                        isDirectory: target.isDirectory
                    )
                    try FileManager.default.copyItem(
                        at: downloadedURL,
                        to: destination
                    )
                    try? FileManager.default.removeItem(
                        at: downloadedURL.deletingLastPathComponent()
                    )
                }
                exportCleanupURL = exportRoot
                exportItem = FileExportItem(url: exportRoot)
            } catch {
                try? FileManager.default.removeItem(at: exportRoot)
                model.errorMessage = UserFacingFailure.message(
                    .saveDownloadedFile,
                    underlying: error
                )
            }
        }
    }

    private func presentImporter(_ purpose: ImportPurpose) {
        switch purpose {
        case .install:
            showInstallPackagePicker = true
        case .upload:
            showUploadPicker = true
        case .syncToTV:
            showImporter = true
        }
    }

    private func selectInstallPackage(_ sourceURL: URL) {
        guard !isPreparingInstallPackage,
              !isInstallingImportedPackage else {
            return
        }
        cleanupSelectedInstallPackage()
        isPreparingInstallPackage = true
        Task {
            defer {
                isPreparingInstallPackage = false
            }
            guard let stagedURL = await model.prepareInstallPackage(
                from: sourceURL
            ) else {
                return
            }
            selectedInstallPackageURL = stagedURL
            guard let inspection = await model.inspectAPK(url: stagedURL) else {
                cleanupSelectedInstallPackage()
                return
            }
            installPackageInspection = inspection
        }
    }

    private func installSelectedPackage() {
        guard let url = selectedInstallPackageURL else { return }
        isInstallingImportedPackage = true
        installPackageInspection = nil
        Task {
            _ = await model.installAPK(url: url)
            cleanupSelectedInstallPackage()
            isInstallingImportedPackage = false
        }
    }

    private func cleanupSelectedInstallPackage() {
        guard let url = selectedInstallPackageURL else { return }
        AppModel.cleanupPreparedInstallPackage(url)
        selectedInstallPackageURL = nil
    }

    private var installPackageOperationText: String {
        if !model.operationText.isEmpty {
            return model.operationText
        }
        return isInstallingImportedPackage
            ? L10n.string("text.installing_apk")
            : L10n.string("text.preparing_install_package")
    }
}

private struct LocalFileEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: UInt64
    let modifiedAt: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

private struct LocalFilePane: View {
    static var rootDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent(
            TVADBPreferences.defaultDownloadFolder,
            isDirectory: true
        )
    }

    @Binding var currentDirectory: URL
    let refreshID: Int
    let upload: (URL) -> Void
    let install: (URL) -> Void

    @State private var entries: [LocalFileEntry] = []
    @State private var query = ""
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: LocalFileEntry?
    @State private var renameText = ""
    @State private var deleteTarget: LocalFileEntry?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "text.this_local_folder_is_empty",
                    systemImage: "iphone.gen3",
                    description: Text("text.import_files_here_then_upload_them_directly_to_the_tv_3bd1dcb2")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    row(entry)
                }
                .listStyle(.plain)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .task(id: "\(currentDirectory.path)|\(refreshID)") { load() }
        .fullScreenCover(isPresented: $showImporter) {
            TVADBFileImportPicker(
                contentTypes: [.item, .folder],
                allowsMultipleSelection: true,
                onPick: { urls in
                    showImporter = false
                    importItems(urls)
                },
                onCancel: {
                    showImporter = false
                }
            )
            .ignoresSafeArea()
        }
        .alert("text.new_local_folder", isPresented: $showNewFolder) {
            TextField("text.folder_name", text: $newFolderName)
            Button("text.cancel", role: .cancel) {}
            Button("text.create") { createDirectory() }
        }
        .alert(
            "text.rename",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("text.new_name", text: $renameText)
            Button("text.cancel", role: .cancel) { renameTarget = nil }
            Button("text.save") { rename() }
        }
        .alert(
            "text.local_file_operation_failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("text.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            localDeleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("text.cancel", role: .cancel) {
                deleteTarget = nil
            }
            Button("text.delete", role: .destructive, action: delete)
        } message: {
            Text("text.this_action_cannot_be_undone")
        }
    }

    private var localDeleteConfirmationTitle: String {
        guard let target = deleteTarget else { return "" }
        return String(
            format: L10n.string("text.delete_value"),
            target.name
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(TVADBTheme.accentGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("text.on_my_iphone")
                        .font(.headline)
                    Text(displayedPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    goUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 34, height: 34)
                }
                .disabled(!canGoUp)
                Menu {
                    Button { showImporter = true } label: {
                        Label("text.import_files_or_folders", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("text.new_folder", systemImage: "folder.badge.plus")
                    }
                    Button { load() } label: {
                        Label("text.refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
            }
            TextField("text.search_local_files", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding(14)
    }

    private func row(_ entry: LocalFileEntry) -> some View {
        Button {
            if entry.isDirectory {
                currentDirectory = entry.url
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: entry.isDirectory ? "folder.fill" : localIcon(entry.name))
                    .font(.title3)
                    .foregroundStyle(entry.isDirectory ? TVADBTheme.cyan : TVADBTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(entry.isDirectory
                         ? L10n.string("text.folder")
                         : ByteCountFormatter.string(
                            fromByteCount: Int64(min(entry.size, UInt64(Int64.max))),
                            countStyle: .file
                         ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { upload(entry.url) } label: {
                Label("text.upload_to_right_pane", systemImage: "arrow.right.circle")
            }
            if !entry.isDirectory, isPackage(entry.name) {
                Button { install(entry.url) } label: {
                    Label("text.install_apk", systemImage: "shippingbox")
                }
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: {
                Label("text.rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("text.delete", systemImage: "trash")
            }
        }
        .draggable(entry.url)
    }

    private var filteredEntries: [LocalFileEntry] {
        let values = query.isEmpty
            ? entries
            : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var canGoUp: Bool {
        currentDirectory.standardizedFileURL.path != Self.rootDirectory.standardizedFileURL.path
    }

    private var displayedPath: String {
        let root = Self.rootDirectory.standardizedFileURL.path
        let current = currentDirectory.standardizedFileURL.path
        guard current.hasPrefix(root) else { return "TVADB" }
        let suffix = String(current.dropFirst(root.count))
        return suffix.isEmpty ? "TVADB" : "TVADB\(suffix)"
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: Self.rootDirectory,
                withIntermediateDirectories: true
            )
            if !currentDirectory.standardizedFileURL.path.hasPrefix(
                Self.rootDirectory.standardizedFileURL.path
            ) {
                currentDirectory = Self.rootDirectory
            }
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            entries = try FileManager.default.contentsOfDirectory(
                at: currentDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isDirectory != nil else { return nil }
                return LocalFileEntry(
                    url: url,
                    isDirectory: values.isDirectory == true,
                    size: UInt64(max(values.fileSize ?? 0, 0)),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            }
        } catch {
            entries = []
            errorMessage = UserFacingFailure.message(.readLocalFiles, underlying: error)
        }
    }

    private func goUp() {
        guard canGoUp else { return }
        currentDirectory = currentDirectory.deletingLastPathComponent()
    }

    private func importItems(_ urls: [URL]) {
        do {
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let destination = uniqueDestination(for: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination)
            }
            load()
        } catch {
            errorMessage = UserFacingFailure.message(.importFile, underlying: error)
        }
    }

    private func createDirectory() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = UserFacingFailure.text(.invalidFolderName)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: currentDirectory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
            load()
        } catch {
            errorMessage = UserFacingFailure.message(.createFolder, underlying: error)
        }
    }

    private func rename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = UserFacingFailure.text(.invalidFileName)
            return
        }
        do {
            try FileManager.default.moveItem(
                at: target.url,
                to: currentDirectory.appendingPathComponent(name, isDirectory: target.isDirectory)
            )
            load()
        } catch {
            errorMessage = UserFacingFailure.message(.renameFile, underlying: error)
        }
    }

    private func delete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            try FileManager.default.removeItem(at: target.url)
            load()
        } catch {
            errorMessage = UserFacingFailure.message(.deleteFile, underlying: error)
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let proposed = currentDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let base = (name as NSString).deletingPathExtension
        let extensionName = (name as NSString).pathExtension
        for index in 2...999 {
            let candidateName = extensionName.isEmpty
                ? "\(base) \(index)"
                : "\(base) \(index).\(extensionName)"
            let candidate = currentDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return currentDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func isPackage(_ filename: String) -> Bool {
        ["apk", "apks", "xapk", "apkm"].contains((filename as NSString).pathExtension.lowercased())
    }

    private func localIcon(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "apk", "apks", "xapk", "apkm": "shippingbox.fill"
        case "jpg", "jpeg", "png", "gif", "webp": "photo.fill"
        case "mp4", "mkv", "mov": "film.fill"
        case "zip", "7z", "rar": "archivebox.fill"
        default: "doc.fill"
        }
    }
}

private extension View {
    @ViewBuilder
    func contextMenuIf<MenuContent: View>(
        _ isEnabled: Bool,
        @ViewBuilder menuItems: () -> MenuContent
    ) -> some View {
        if isEnabled {
            contextMenu(menuItems: menuItems)
        } else {
            self
        }
    }
}
