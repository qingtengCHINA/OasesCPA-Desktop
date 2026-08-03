import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    #if !APP_STORE
    @EnvironmentObject private var appUpdateService: AppUpdateService
    #endif
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            DetailWorkspaceView(section: store.selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            #if !APP_STORE
            ToolbarItem(placement: .navigation) {
                AppUpdateToolbarButton()
            }
            #endif

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
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
                    if store.selectedSection == .codexInspection {
                        runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
                        runtimeDataStore.refreshCodexInspectionRuns(using: deploymentStore)
                    }
                    if store.selectedSection == .plugins {
                        runtimeDataStore.refreshPlugins(using: deploymentStore)
                        runtimeDataStore.refreshPluginStore(using: deploymentStore)
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新当前工作区（⌘R）")
                .keyboardShortcut("r", modifiers: .command)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("连接与外观设置")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            runtimeDataStore.refresh(using: deploymentStore)
        }
        .task(id: deploymentStore.stage) {
            guard deploymentStore.stage == .attached else { return }
            while !Task.isCancelled, deploymentStore.stage == .attached {
                runtimeDataStore.automaticallySyncModelPricesIfNeeded(using: deploymentStore)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: deploymentStore.stage) { _, _ in
            runtimeDataStore.refresh(using: deploymentStore)
            if deploymentStore.stage == .attached {
                runtimeDataStore.automaticallySyncModelPricesIfNeeded(using: deploymentStore)
            }
        }
    }
}

#if !APP_STORE
private struct AppUpdateToolbarButton: View {
    @EnvironmentObject private var appUpdateService: AppUpdateService

    var body: some View {
        if appUpdateService.isUpdateAvailable,
           let version = appUpdateService.availableUpdateVersion {
            Button {
                if appUpdateService.status == .downloaded {
                    appUpdateService.openDownloadedUpdate()
                } else {
                    Task { await appUpdateService.downloadAvailableUpdate() }
                }
            } label: {
                switch appUpdateService.status {
                case .downloading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在下载")
                    }
                case .downloaded:
                    versionLabel("打开更新 v%@", version: version, systemImage: "arrow.down.circle.fill")
                case .failed:
                    versionLabel("重试更新 v%@", version: version, systemImage: "exclamationmark.arrow.circlepath")
                default:
                    versionLabel("更新 v%@", version: version, systemImage: "arrow.down.circle.fill")
                }
            }
            .disabled(appUpdateService.status == .downloading)
            .help("下载 GitHub Releases 中的最新 DMG 安装包")
            .accessibilityLabel("发现新版本 v\(version.description)")
        }
    }

    private func versionLabel(
        _ format: String,
        version: SemanticVersion,
        systemImage: String
    ) -> some View {
        Label {
            Text(OasesLocalization.localizedFormat(format, version.description))
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
#endif

struct DetailWorkspaceView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    let section: AppSection

    @ViewBuilder
    var body: some View {
        switch section {
        case .environments:
            ConnectionCenterView()
        case .panel:
            PanelView()
        case .dashboard:
            DashboardView()
        case .usageAnalytics:
            UsageAnalyticsWorkbenchView(deploymentStore: deploymentStore)
        case .monitoring:
            MonitoringView()
        case .accountActions:
            AccountActionsView()
        case .modelPrices:
            ModelPricesView()
        case .config:
            ConfigurationView()
        case .accessKeys:
            AccessKeysView()
        case .aiProviders:
            ProvidersView()
        case .authFiles:
            AuthFilesWorkbenchView()
        case .quota:
            QuotaView()
        case .codexInspection:
            InspectionView()
        case .plugins:
            PluginsView()
        case .oauth:
            OAuthView()
        case .logs:
            LogsView()
        case .system:
            SystemInfoView()
        }
    }
}
