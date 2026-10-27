import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "tvadb.appLanguage"

    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "text.follow_system"
        case .simplifiedChinese: "text.simplified_chinese"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }

    static var selected: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "tvadb.appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "text.follow_system"
        case .light: "text.light"
        case .dark: "text.dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppInstallMode: String, CaseIterable, Identifiable {
    static let storageKey = "tvadb.installMode"

    case replace
    case standard

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .replace: "text.replace_installation"
        case .standard: "text.standard_installation"
        }
    }
}

enum RemoteControlMode: String, CaseIterable, Identifiable {
    case gestures
    case screen
    case mouse
    case buttons

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .gestures: "text.gestures"
        case .screen: "text.screen"
        case .mouse: "text.mouse"
        case .buttons: "text.buttons"
        }
    }

    var systemImage: String {
        switch self {
        case .gestures: "hand.draw.fill"
        case .screen: "display"
        case .mouse: "cursorarrow.motionlines"
        case .buttons: "circle.grid.cross.fill"
        }
    }
}

enum LiveScreenControlMode: String, CaseIterable, Identifiable {
    case mouse
    case touch

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mouse: "text.mouse"
        case .touch: "text.touch"
        }
    }

    var systemImage: String {
        switch self {
        case .mouse: "cursorarrow.motionlines"
        case .touch: "hand.point.up.left.fill"
        }
    }
}

enum LiveScreenOrientationPreference: String, CaseIterable, Identifiable {
    case automatic
    case portrait
    case landscapeLeft
    case landscapeRight

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "text.orientation_automatic"
        case .portrait: "text.orientation_portrait"
        case .landscapeLeft: "text.orientation_landscape_left"
        case .landscapeRight: "text.orientation_landscape_right"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "rectangle.landscape.rotate"
        case .portrait: "rectangle.portrait"
        case .landscapeLeft: "rotate.left"
        case .landscapeRight: "rotate.right"
        }
    }
}

enum TVADBPreferences {
    static let autoConnectLastDeviceKey = "tvadb.autoConnectLastDevice"
    static let autoScanKey = "tvadb.autoScan"
    static let defaultDownloadFolderKey = "tvadb.defaultDownloadFolder"
    static let logLevelKey = "tvadb.logLevel"
    static let openRemoteWhenRecordingKey = "tvadb.openRemoteWhenRecording"
    static let loadApplicationIconsKey = "tvadb.loadApplicationIcons"
    static let remoteControlOrderKey = "tvadb.remoteControlOrder"
    static let liveScreenControlModeKey = "tvadb.liveScreenControlMode"
    static let defaultRemoteControlOrder: [RemoteControlMode] = [
        .gestures,
        .screen,
        .mouse,
        .buttons
    ]
    static let defaultRemoteControlOrderRawValue = defaultRemoteControlOrder
        .map(\.rawValue)
        .joined(separator: ",")

    static var autoConnectLastDevice: Bool {
        UserDefaults.standard.bool(forKey: autoConnectLastDeviceKey)
    }

    static var openRemoteWhenRecording: Bool {
        UserDefaults.standard.bool(forKey: openRemoteWhenRecordingKey)
    }

    static var loadApplicationIcons: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: loadApplicationIconsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: loadApplicationIconsKey)
    }

    static var remoteControlOrder: [RemoteControlMode] {
        remoteControlOrder(
            from: UserDefaults.standard.string(forKey: remoteControlOrderKey)
        )
    }

    static var liveScreenControlMode: LiveScreenControlMode {
        let rawValue = UserDefaults.standard.string(
            forKey: liveScreenControlModeKey
        ) ?? LiveScreenControlMode.mouse.rawValue
        return LiveScreenControlMode(rawValue: rawValue) ?? .mouse
    }

    static func remoteControlOrder(from rawValue: String?) -> [RemoteControlMode] {
        var result: [RemoteControlMode] = []
        for component in (rawValue ?? "")
            .split(separator: ",")
            .map(String.init) {
            guard let mode = RemoteControlMode(rawValue: component),
                  !result.contains(mode) else {
                continue
            }
            result.append(mode)
        }
        for mode in defaultRemoteControlOrder where !result.contains(mode) {
            let defaultIndex =
                defaultRemoteControlOrder.firstIndex(of: mode) ?? 0
            let insertionIndex = result.firstIndex { existingMode in
                guard let existingDefaultIndex =
                    defaultRemoteControlOrder.firstIndex(of: existingMode) else {
                    return false
                }
                return existingDefaultIndex > defaultIndex
            } ?? result.endIndex
            result.insert(mode, at: insertionIndex)
        }
        return result
    }

    static func remoteControlOrderRawValue(
        for modes: [RemoteControlMode]
    ) -> String {
        modes.map(\.rawValue).joined(separator: ",")
    }

    static var defaultDownloadFolder: String {
        let value = UserDefaults.standard.string(forKey: defaultDownloadFolderKey)
            ?? "TVADB"
        let components = value
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return components.isEmpty ? "TVADB" : components.joined(separator: "/")
    }

    static var replaceExistingApps: Bool {
        let rawValue = UserDefaults.standard.string(forKey: AppInstallMode.storageKey)
            ?? AppInstallMode.replace.rawValue
        return AppInstallMode(rawValue: rawValue) != .standard
    }
}

enum L10n {
    static var locale: Locale { AppLanguage.selected.locale }

    private static var bundle: Bundle {
        switch AppLanguage.selected {
        case .system:
            return .main
        case .simplifiedChinese, .english:
            let localization = AppLanguage.selected.rawValue
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return .main
            }
            return bundle
        }
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    static func allLocalizedValues(for key: String) -> Set<String> {
        var values: Set<String> = [key]
        for localization in ["zh-Hans", "en"] {
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else {
                continue
            }
            values.insert(localizedBundle.localizedString(forKey: key, value: key, table: nil))
        }
        return values
    }

    static func matches(_ value: String, key: String) -> Bool {
        allLocalizedValues(for: key).contains(value)
    }
}

enum UserFacingFailure {
    enum Operation: String {
        case generic = "error.generic"
        case invalidAddress = "error.invalid_address"
        case invalidPairingParameters = "error.invalid_pairing_parameters"
        case connectDevice = "error.connect_device"
        case connectAuthorization = "error.connect_device.authorization"
        case connectTimeout = "error.connect_device.timeout"
        case connectPairingRequired = "error.connect_device.pairing_required"
        case wirelessPairing = "error.wireless_pairing"
        case readFileList = "error.read_file_list"
        case uploadFile = "error.upload_file"
        case uploadInsufficientStorage = "error.upload_file.insufficient_storage"
        case uploadPermission = "error.upload_file.permission"
        case installAPK = "error.install_apk"
        case installInsufficientStorage = "error.install_apk.insufficient_storage"
        case installVersionDowngrade = "error.install_apk.version_downgrade"
        case installSignatureMismatch = "error.install_apk.signature_mismatch"
        case installUnsupportedABI = "error.install_apk.unsupported_abi"
        case installAndroidTooOld = "error.install_apk.android_too_old"
        case installMissingSplit = "error.install_apk.missing_split"
        case installRestricted = "error.install_apk.restricted"
        case installTestOnly = "error.install_apk.test_only"
        case installAlreadyExists = "error.install_apk.already_exists"
        case installInvalidPackage = "error.install_apk.invalid_package"
        case installVerificationFailed = "error.install_apk.verification_failed"
        case readAppList = "error.read_app_list"
        case inspectAPK = "error.inspect_apk"
        case exportAPK = "error.export_apk"
        case launchApp = "error.launch_app"
        case forceStopApp = "error.force_stop_app"
        case clearCache = "error.clear_cache"
        case clearCacheUnsupported = "error.clear_cache.unsupported"
        case clearData = "error.clear_data"
        case uninstallApp = "error.uninstall_app"
        case openAppDetails = "error.open_app_details"
        case remoteControl = "error.remote_control"
        case keyboardInput = "error.keyboard_input"
        case readScreenSize = "error.read_screen_size"
        case changeTapFeedback = "error.change_tap_feedback"
        case executeCommand = "error.execute_command"
        case readLogcat = "error.read_logcat"
        case clearLogcat = "error.clear_logcat"
        case screenshot = "error.screenshot"
        case screenshotNotAllowed = "error.screenshot.not_allowed"
        case screenRecording = "error.screen_recording"
        case readDeviceInfo = "error.read_device_info"
        case reboot = "error.reboot"
        case downloadFile = "error.download_file"
        case syncDirectory = "error.sync_directory"
        case invalidFolderName = "error.invalid_folder_name"
        case invalidFileName = "error.invalid_file_name"
        case createFolder = "error.create_folder"
        case deleteFile = "error.delete_file"
        case renameFile = "error.rename_file"
        case selectUploadFile = "error.select_upload_file"
        case selectInstallPackage = "error.select_install_package"
        case saveDownloadedFile = "error.save_downloaded_file"
        case selectFile = "error.select_file"
        case readLocalFiles = "error.read_local_files"
        case importFile = "error.import_file"
        case exportLog = "error.export_log"
        case deviceScan = "error.device_scan"
        case resolveDeviceAddress = "error.resolve_device_address"
        case wifiUnavailable = "error.wifi_unavailable"
    }

    static func text(_ operation: Operation) -> String {
        L10n.string(operation.rawValue)
    }

    static func message(_ operation: Operation, underlying error: Error) -> String {
        log(operation, underlying: error)
        return resolvedMessage(for: operation, underlying: error)
    }

    static func log(_ operation: Operation, underlying error: Error) {
#if DEBUG
        print("[TVADB][\(operation.rawValue)] \(error.localizedDescription)")
#endif
    }

    static func sanitized(_ message: String) -> String {
        let normalized = message.lowercased()
        let technicalMarkers = [
            "exception",
            "java.",
            "com.android.",
            "error domain=",
            "nscocoaerrordomain",
            "nsposixerrordomain",
            "nwerror",
            "install_failed_",
            "securityexception",
            "permission denial",
            "stack trace",
            "usage: input"
        ]
        guard technicalMarkers.contains(where: normalized.contains) else {
            return message
        }
        return text(.generic)
    }

    private static func resolvedMessage(for operation: Operation, underlying error: Error) -> String {
        if operation == .connectDevice, let adbError = error as? ADBClientError {
            switch adbError {
            case .invalidAddress:
                return text(.invalidAddress)
            case .authorizationRejected:
                return text(.connectAuthorization)
            case .connectionTimedOut:
                return text(.connectTimeout)
            case .wirelessPairingRequired:
                return text(.connectPairingRequired)
            default:
                break
            }
        }

        let details = error.localizedDescription.uppercased()
        switch operation {
        case .installAPK:
            if details.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                return text(.installInsufficientStorage)
            }
            if details.contains("INSTALL_FAILED_VERSION_DOWNGRADE") {
                return text(.installVersionDowngrade)
            }
            if details.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                return text(.installSignatureMismatch)
            }
            if details.contains("INSTALL_FAILED_NO_MATCHING_ABIS") {
                return text(.installUnsupportedABI)
            }
            if details.contains("INSTALL_FAILED_OLDER_SDK") {
                return text(.installAndroidTooOld)
            }
            if details.contains("INSTALL_FAILED_MISSING_SPLIT") {
                return text(.installMissingSplit)
            }
            if details.contains("INSTALL_FAILED_USER_RESTRICTED")
                || details.contains("INSTALL_FAILED_BLOCKED_BY_POLICY") {
                return text(.installRestricted)
            }
            if details.contains("INSTALL_FAILED_TEST_ONLY") {
                return text(.installTestOnly)
            }
            if details.contains("INSTALL_FAILED_ALREADY_EXISTS") {
                return text(.installAlreadyExists)
            }
            if details.contains("INSTALL_FAILED_INVALID_APK")
                || details.contains("INSTALL_PARSE_FAILED")
                || details.contains("INVALID APK") {
                return text(.installInvalidPackage)
            }
            if details.contains("TVADB_INSTALL_VERIFICATION_FAILED") {
                return text(.installVerificationFailed)
            }
        case .uploadFile:
            if details.contains("NO SPACE LEFT")
                || details.contains("ENOSPC")
                || details.contains("INSUFFICIENT_STORAGE") {
                return text(.uploadInsufficientStorage)
            }
            if details.contains("PERMISSION DENIED")
                || details.contains("READ-ONLY FILE SYSTEM") {
                return text(.uploadPermission)
            }
        case .clearCache:
            if details.contains("TVADB_CACHE_CLEAR_UNSUPPORTED")
                || details.contains("UNKNOWN OPTION --CACHE-ONLY")
                || details.contains("UNKNOWN OPTION: --CACHE-ONLY") {
                return text(.clearCacheUnsupported)
            }
        case .screenshot:
            if details.contains("SECURITYEXCEPTION")
                || details.contains("PERMISSION DENIAL")
                || details.contains("NOT ALLOWED") {
                return text(.screenshotNotAllowed)
            }
        default:
            break
        }
        return text(operation)
    }
}

@MainActor
final class TVADBAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedInterfaceOrientations: UIInterfaceOrientationMask =
        .all

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedInterfaceOrientations
    }
}

@main
struct IOSADBApp: App {
    @UIApplicationDelegateAdaptor(TVADBAppDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var deviceStore: DeviceStore
    @StateObject private var installHistory: InstallHistoryStore
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let devices = DeviceStore()
        let history = InstallHistoryStore()
        _deviceStore = StateObject(wrappedValue: devices)
        _installHistory = StateObject(wrappedValue: history)
        _model = StateObject(wrappedValue: AppModel(deviceStore: devices, installHistory: history))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(deviceStore)
                .environmentObject(installHistory)
                .environment(
                    \.locale,
                    AppLanguage(rawValue: appLanguage)?.locale ?? AppLanguage.system.locale
                )
                .tint(TVADBTheme.accent)
                .preferredColorScheme(
                    AppAppearance(rawValue: appAppearance)?.colorScheme
                )
                .onOpenURL { url in
                    Task {
                        await model.handleIncomingPackage(url)
                    }
                }
                .task {
                    await model.autoConnectLastDeviceIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await model.autoConnectLastDeviceIfNeeded(force: true)
                    }
                }
        }
    }
}
