import AppKit
import SwiftUI

@main
struct OasesCPAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var deploymentStore = DeploymentStore()
    @StateObject private var runtimeDataStore = RuntimeDataStore()
    #if !APP_STORE
    @StateObject private var appUpdateService = AppUpdateService()
    #endif
    @AppStorage(OasesAppearance.defaultsKey) private var appearanceRaw = OasesAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        (OasesAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    private var preferredLanguage: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    private var preferredLocale: Locale {
        preferredLanguage.locale
    }

    /// A window or menu title in the in-app language. Scene titles given as literals are
    /// resolved by SwiftUI from the macOS language, so they are computed here instead.
    private func title(_ key: String) -> String {
        OasesLocalization.localized(key, language: preferredLanguage)
    }

    var body: some Scene {
        Window("Oases CPA", id: "main") {
            MainWindowRootView()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                #if !APP_STORE
                .environmentObject(appUpdateService)
                #endif
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 880, minHeight: 560)
                .background(AdaptiveWindowConfigurator())
                .onAppear {
                    #if !APP_STORE
                    appUpdateService.startMonitoring()
                    #endif
                    appDelegate.installTerminationHandler { [weak deploymentStore = deploymentStore] in
                        deploymentStore?.prepareForApplicationTermination()
                    }
                }
        }
        .defaultSize(width: 1_280, height: 800)
        .commands {
            OasesCommands(
                store: store,
                deploymentStore: deploymentStore,
                runtimeDataStore: runtimeDataStore
            )
            #if !APP_STORE
            AppUpdateCommands(appUpdateService: appUpdateService)
            #endif
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                #if !APP_STORE
                .environmentObject(appUpdateService)
                #endif
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                // SettingsView keeps the window title (the pane's name) and its size itself.
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                #if !APP_STORE
                .environmentObject(appUpdateService)
                #endif
                .environment(\.locale, preferredLocale)
        } label: {
            MenuBarStatusLabel()
        }
        .menuBarExtraStyle(.menu)

        Window(Text(title("开源许可与致谢")), id: OpenSourceNoticesWindow.id) {
            OpenSourceNoticesView()
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .background(
                    AdaptiveWindowConfigurator(
                        minimumContentSize: NSSize(width: 600, height: 480),
                        title: title("开源许可与致谢")
                    )
                )
        }

        Window(Text(title("编辑 AI 服务")), id: ProviderEditorWindowScene.id) {
            ProviderEditorWindow()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .background(
                    AdaptiveWindowConfigurator(
                        minimumContentSize: NSSize(width: 640, height: 480),
                        title: title("编辑 AI 服务")
                    )
                )
        }
        .defaultSize(width: 900, height: 700)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationHandler: (() -> Void)?

    func installTerminationHandler(_ handler: @escaping () -> Void) {
        terminationHandler = handler
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct OasesCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var deploymentStore: DeploymentStore
    @ObservedObject var runtimeDataStore: RuntimeDataStore
    @Environment(\.openWindow) private var openWindow
    /// Menu titles are built from this (literal titles would follow the macOS language).
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue

    private func title(_ key: String) -> String {
        OasesLocalization.localized(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(title("开源许可与致谢…")) {
                openWindow(id: OpenSourceNoticesWindow.id)
            }
        }

        // Help → 欢迎指南: the welcome gate again (its step follows the deployment state).
        CommandGroup(after: .help) {
            Button(title("欢迎指南")) {
                store.isWelcomeReopened = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        CommandMenu(title("导航")) {
            Button(title("连接与部署")) {
                store.selectSection(.environments)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button(title("模型列表")) {
                store.selectSection(.models)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button(title("仪表盘")) {
                store.selectSection(.dashboard)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(title("请求监控")) {
                store.selectSection(.monitoring)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button(title("账号待办")) {
                store.selectSection(.accountActions)
            }

            Button(title("认证文件")) {
                store.selectSection(.authFiles)
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button(title("刷新当前数据")) {
                WorkspaceRefresh.refreshCurrentSection(
                    store: store,
                    deploymentStore: deploymentStore,
                    runtimeDataStore: runtimeDataStore
                )
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

#if !APP_STORE
/// "检查更新…" in the app menu (HIG: no update button in the toolbar). It checks and opens
/// Settings, where the update section shows the result; when an update exists, a second item
/// downloads or opens it directly.
struct AppUpdateCommands: Commands {
    @ObservedObject var appUpdateService: AppUpdateService
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .system }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if appUpdateService.isEnabled {
                Button(OasesLocalization.localized("检查更新…", language: language)) {
                    Task { await appUpdateService.checkForUpdates() }
                    openSettings()
                }
                .disabled(appUpdateService.status == .checking || appUpdateService.status == .downloading)

                if appUpdateService.isUpdateAvailable, let version = appUpdateService.availableUpdateVersion {
                    Button(updateTitle(version: version)) {
                        if appUpdateService.status == .downloaded {
                            appUpdateService.openDownloadedUpdate()
                        } else {
                            Task { await appUpdateService.downloadAvailableUpdate() }
                        }
                    }
                    .disabled(appUpdateService.status == .downloading)
                }
            }
        }
    }

    private func updateTitle(version: SemanticVersion) -> String {
        switch appUpdateService.status {
        case .downloading:
            OasesLocalization.localized("正在下载", language: language)
        case .downloaded:
            OasesLocalization.localizedFormat("打开更新 v%@", language: language, version.description)
        case .failed:
            OasesLocalization.localizedFormat("重试更新 v%@", language: language, version.description)
        default:
            OasesLocalization.localizedFormat("更新 v%@", language: language, version.description)
        }
    }
}
#endif
