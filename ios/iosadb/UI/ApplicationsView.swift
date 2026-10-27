import SwiftUI

struct ApplicationsView: View {
    private enum Filter: CaseIterable {
        case user
        case system
        case all

        var title: LocalizedStringKey {
            switch self {
            case .user: "text.user"
            case .system: "text.system"
            case .all: "text.all"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var filter: Filter = .user
    @State private var destructiveAction: (AndroidApp, ApplicationAction)?
    @State private var showPackagePicker = false
    @State private var selectedPackageURL: URL?
    @State private var inspection: APKInspection?
    @State private var isPreparingInstallPackage = false
    @State private var isInstallingSelectedPackage = false
    @State private var exportItem: FileExportItem?
    @State private var exportCleanupURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Picker("text.type", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        installBanner
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(filteredApps) { app in
                        HStack(spacing: 12) {
                            appIcon(app)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.displayName).font(.headline)
                                Text(app.packageName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let versionName = app.versionName {
                                    Text("v\(versionName)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer()
                            Menu {
                                Button { Task { await model.applicationAction(app, action: .launch) } } label: { Label("text.launch", systemImage: "play.fill") }
                                Button { Task { await model.applicationAction(app, action: .openDetails) } } label: { Label("text.app_details", systemImage: "info.circle") }
                                Button { Task { await model.applicationAction(app, action: .forceStop) } } label: { Label("text.force_stop", systemImage: "stop.fill") }
                                Button { Task { await model.applicationAction(app, action: .clearCache) } } label: { Label("text.clear_cache", systemImage: "eraser") }
                                Button { export(app) } label: { Label("text.export_apk", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { destructiveAction = (app, .clearData) } label: { Label("text.clear_data", systemImage: "externaldrive.badge.xmark") }
                                if !app.isSystem {
                                    Button(role: .destructive) { destructiveAction = (app, .uninstall) } label: { Label("text.uninstall", systemImage: "trash") }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(Text(L10n.format("text.more_actions_for_value", app.displayName)))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1,
                      let url = urls.first,
                      AppModel.isSupportedInstallPackage(url) else {
                    return false
                }
                selectInstallPackage(url)
                return true
            }
            .contentMargins(.bottom, 72, for: .scrollContent)
            .safeAreaInset(edge: .bottom) {
                if model.isBusy {
                    operationBar
                }
            }
            .overlay {
                if isPreparingInstallPackage
                    || isInstallingSelectedPackage {
                    TVADBBlockingProgressOverlay(
                        message: installPackageOperationText,
                        progress: model.progress
                    )
                } else if filteredApps.isEmpty, !model.isBusy {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("text.apps_ac7fd221")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "text.name_or_package")
            .toolbar {
                TVADBDisconnectToolbarItem()
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.loadApplications() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("text.refresh")
                    .disabled(model.isBusy)
                }
            }
            .fullScreenCover(isPresented: $showPackagePicker) {
                TVADBInstallPackagePicker {
                    showPackagePicker = false
                    guard AppModel.isSupportedInstallPackage($0) else {
                        model.errorMessage = L10n.string(
                            "error.select_supported_install_package"
                        )
                        return
                    }
                    selectInstallPackage($0)
                } onCancel: {
                    showPackagePicker = false
                }
                .ignoresSafeArea()
            }
            .sheet(item: $inspection, onDismiss: {
                if !isInstallingSelectedPackage {
                    cleanupSelectedPackage()
                }
            }) { value in
                APKInspectionView(inspection: value) {
                    installSelectedPackage()
                }
            }
            .sheet(item: $exportItem, onDismiss: cleanupExport) { item in
                FileExportPicker(url: item.url)
            }
            .task { await model.loadApplicationsIfNeeded() }
            .task(id: presentationTaskID) {
                await model.loadApplicationPresentations(
                    for: Array(filteredApps.prefix(40))
                )
            }
            .alert(
                destructiveConfirmationTitle,
                isPresented: Binding(
                    get: { destructiveAction != nil },
                    set: { if !$0 { destructiveAction = nil } }
                )
            ) {
                Button("text.cancel", role: .cancel) {
                    destructiveAction = nil
                }
                Button("text.confirm", role: .destructive) {
                    guard let action = destructiveAction else { return }
                    destructiveAction = nil
                    Task { await model.applicationAction(action.0, action: action.1) }
                }
            } message: {
                Text("text.this_action_cannot_be_undone")
            }
            .animation(
                .easeInOut(duration: 0.18),
                value: isPreparingInstallPackage
            )
            .animation(
                .easeInOut(duration: 0.18),
                value: isInstallingSelectedPackage
            )
        }
    }

    private var installBanner: some View {
        Button { showPackagePicker = true } label: {
            TVADBPanel {
                HStack(spacing: 13) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(TVADBTheme.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("text.install_apk")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("text.supports_apk_apks_xapk_and_apkm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(TVADBTheme.accent)
                }
                .padding(14)
            }
        }
        .buttonStyle(TVADBPressableStyle())
        .disabled(model.isBusy)
    }

    private var filteredApps: [AndroidApp] {
        model.applications.filter { app in
            let matchesType = filter == .all || (filter == .system) == app.isSystem
            let matchesQuery = query.isEmpty || app.packageName.localizedCaseInsensitiveContains(query) || app.displayName.localizedCaseInsensitiveContains(query)
            return matchesType && matchesQuery
        }
    }

    private var presentationTaskID: String {
        let filterID: String
        switch filter {
        case .user: filterID = "user"
        case .system: filterID = "system"
        case .all: filterID = "all"
        }
        return filterID + "|" + query + "|" + filteredApps
            .prefix(40)
            .map {
                "\($0.packageName):\($0.baseAPKPath ?? "")"
            }
            .joined(separator: ",")
    }

    private var destructiveConfirmationTitle: LocalizedStringKey {
        destructiveAction?.1 == .uninstall ? "text.uninstall_this_app" : "text.clear_all_app_data"
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
            }
            .padding(14)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func selectInstallPackage(_ sourceURL: URL) {
        guard !isPreparingInstallPackage,
              !isInstallingSelectedPackage else {
            return
        }
        cleanupSelectedPackage()
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
            selectedPackageURL = stagedURL
            guard let result = await model.inspectAPK(url: stagedURL) else {
                cleanupSelectedPackage()
                return
            }
            inspection = result
        }
    }

    private func installSelectedPackage() {
        guard let url = selectedPackageURL else { return }
        isInstallingSelectedPackage = true
        inspection = nil
        Task {
            if await model.installAPK(url: url) {
                await model.loadApplications()
            }
            cleanupSelectedPackage()
            isInstallingSelectedPackage = false
        }
    }

    private func cleanupSelectedPackage() {
        guard let url = selectedPackageURL else { return }
        AppModel.cleanupPreparedInstallPackage(url)
        selectedPackageURL = nil
    }

    private var installPackageOperationText: String {
        if !model.operationText.isEmpty {
            return model.operationText
        }
        return isInstallingSelectedPackage
            ? L10n.string("text.installing_apk")
            : L10n.string("text.preparing_install_package")
    }

    @ViewBuilder
    private func appIcon(_ app: AndroidApp) -> some View {
        if let data = app.iconData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(app.isSystem ? Color.secondary.opacity(0.15) : TVADBTheme.accent.opacity(0.13))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: app.isSystem ? "gearshape.fill" : "app.fill")
                        .foregroundStyle(app.isSystem ? Color.secondary : TVADBTheme.accent)
                }
                .accessibilityHidden(true)
        }
    }

    private func export(_ app: AndroidApp) {
        Task {
            guard let url = await model.exportApplication(app) else { return }
            exportCleanupURL = url.deletingLastPathComponent()
            exportItem = FileExportItem(url: url)
        }
    }

    private func cleanupExport() {
        if let url = exportCleanupURL {
            try? FileManager.default.removeItem(at: url)
        }
        exportCleanupURL = nil
        exportItem = nil
    }
}

struct APKInspectionView: View {
    @Environment(\.dismiss) private var dismiss
    let inspection: APKInspection
    let install: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let data = inspection.iconData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        } else {
                            Image(systemName: "shippingbox.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(TVADBTheme.accentGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inspection.applicationName)
                                .font(.headline)
                            Text(inspection.packageName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(inspection.filename)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 5)
                }

                Section("text.manifest") {
                    LabeledContent("text.version_name", value: inspection.versionName)
                    LabeledContent("text.version_code", value: inspection.versionCode)
                    LabeledContent("text.min_sdk", value: inspection.minSDK)
                    LabeledContent("text.target_sdk", value: inspection.targetSDK)
                    LabeledContent("text.abi", value: inspection.abis.isEmpty ? "—" : inspection.abis.joined(separator: ", "))
                    LabeledContent(
                        "text.file_size",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(min(inspection.fileSize, UInt64(Int64.max))),
                            countStyle: .file
                        )
                    )
                    if let sharedUserID = inspection.sharedUserID {
                        LabeledContent("text.shared_user_id", value: sharedUserID)
                    }
                }

                Section("text.signature") {
                    LabeledContent(
                        "text.signature_schemes",
                        value: inspection.signatureSchemes.isEmpty
                            ? L10n.string("text.not_detected")
                            : inspection.signatureSchemes.joined(separator: " + ")
                    )
                    if let subject = inspection.certificateSubject {
                        LabeledContent("text.certificate", value: subject)
                    }
                    if let fingerprint = inspection.certificateSHA256 {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("text.certificate_signature_sha_256").font(.caption).foregroundStyle(.secondary)
                            Text(fingerprint)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                detailSection("text.permissions", values: inspection.permissions)
                detailSection("text.activity", values: inspection.activities)
                detailSection("text.service", values: inspection.services)
                detailSection("text.receiver", values: inspection.receivers)
                detailSection("text.provider", values: inspection.providers)
            }
            .navigationTitle("text.apk_information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("text.close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("text.install") { install() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func detailSection(_ title: LocalizedStringKey, values: [String]) -> some View {
        if !values.isEmpty {
            Section {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } header: {
                HStack(spacing: 4) {
                    Text(title)
                    Text("· \(values.count)")
                }
            }
        }
    }
}
