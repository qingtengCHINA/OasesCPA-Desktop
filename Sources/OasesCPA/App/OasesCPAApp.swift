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
    @AppStorage(OnboardingState.completionVersionKey) private var completedOnboardingVersion = 0

    private var preferredColorScheme: ColorScheme? {
        (OasesAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    private var preferredLocale: Locale {
        (AppLanguage(rawValue: languageRaw) ?? .system).locale
    }

    var body: some Scene {
        Window("Oases CPA", id: "main") {
            Group {
                if completedOnboardingVersion >= OnboardingState.currentVersion {
                    ContentView()
                } else {
                    WelcomeFlowView {
                        store.selectSection(.dashboard)
                        completedOnboardingVersion = OnboardingState.currentVersion
                    }
                }
            }
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                #if !APP_STORE
                .environmentObject(appUpdateService)
                #endif
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 720, minHeight: 520)
                .background(AdaptiveWindowConfigurator())
                .onAppear {
                    #if !APP_STORE
                    appUpdateService.startMonitoring()
                    #endif
                    appDelegate.installTerminationHandler { [weak deploymentStore] in
                        deploymentStore?.prepareForApplicationTermination()
                    }
                }
        }
        .defaultSize(width: 1_280, height: 800)
        .commands {
            OasesCommands(
                store: store,
                deploymentStore: deploymentStore,
                runtimeDataStore: runtimeDataStore,
                completedOnboardingVersion: $completedOnboardingVersion
            )
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
                .background(
                    AdaptiveWindowConfigurator(
                        minimumContentSize: NSSize(width: 520, height: 520)
                    )
                )
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

        Window("开源许可与致谢", id: OpenSourceNoticesWindow.id) {
            OpenSourceNoticesView()
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .background(
                    AdaptiveWindowConfigurator(
                        minimumContentSize: NSSize(width: 600, height: 480)
                    )
                )
        }

        Window("编辑 AI 服务", id: ProviderEditorWindowScene.id) {
            ProviderEditorWindow()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                .environment(\.locale, preferredLocale)
                .preferredColorScheme(preferredColorScheme)
                .background(
                    AdaptiveWindowConfigurator(
                        minimumContentSize: NSSize(width: 640, height: 480)
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
    @Binding var completedOnboardingVersion: Int
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("开源许可与致谢…") {
                openWindow(id: OpenSourceNoticesWindow.id)
            }

            Button("重新查看欢迎引导…") {
                store.selectSection(.dashboard)
                completedOnboardingVersion = 0
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        CommandMenu("导航") {
            Button("连接与部署") {
                store.selectSection(.environments)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("CPAMP 面板") {
                store.selectSection(.panel)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("仪表盘") {
                store.selectSection(.dashboard)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("请求监控") {
                store.selectSection(.monitoring)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("账号待办") {
                store.selectSection(.accountActions)
            }

            Button("认证文件") {
                store.selectSection(.authFiles)
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("刷新当前数据") {
                store.refresh()
                runtimeDataStore.refresh(using: deploymentStore)
                if store.selectedSection == .aiProviders {
                    runtimeDataStore.refreshProviders(using: deploymentStore)
                    runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
                }
                if store.selectedSection == .authFiles {
                    runtimeDataStore.refreshOAuthModelPolicies(using: deploymentStore)
                }
                if store.selectedSection == .modelPrices {
                    runtimeDataStore.refreshModelPrices(using: deploymentStore)
                }
                if store.selectedSection == .accountActions {
                    runtimeDataStore.refreshAccountActionCandidates(
                        using: deploymentStore,
                        status: runtimeDataStore.accountActionsFilter
                    )
                }
                if store.selectedSection == .plugins {
                    runtimeDataStore.refreshPlugins(using: deploymentStore)
                    runtimeDataStore.refreshPluginStore(using: deploymentStore)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
