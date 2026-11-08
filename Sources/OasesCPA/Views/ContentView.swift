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
                .oasesCanvas()
                .navigationTitle(store.selectedSection.title)
                .navigationSubtitle(deploymentStore.stage == .attached
                    ? OasesLocalization.localizedFormat("已接入 · %@", deploymentStore.targetTitle)
                    : store.connectionLabel)
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
                    WorkspaceRefresh.refreshCurrentSection(
                        store: store,
                        deploymentStore: deploymentStore,
                        runtimeDataStore: runtimeDataStore
                    )
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
        .background(Oases.Color.background)
        .tint(Oases.Color.accent)
        .task {
            runtimeDataStore.refresh(using: deploymentStore, includingGatewayModels: refreshesDirectoryNow)
        }
        .task(id: deploymentStore.stage) {
            guard deploymentStore.stage == .attached else { return }
            while !Task.isCancelled, deploymentStore.stage == .attached {
                runtimeDataStore.automaticallySyncModelPricesIfNeeded(using: deploymentStore)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: deploymentStore.stage) { _, _ in
            runtimeDataStore.refresh(using: deploymentStore, includingGatewayModels: refreshesDirectoryNow)
            if deploymentStore.stage == .attached {
                runtimeDataStore.automaticallySyncModelPricesIfNeeded(using: deploymentStore)
            }
        }
    }
}

extension ContentView {
    /// A gateway page reads the gateway itself: the directory read would be a second request.
    fileprivate var refreshesDirectoryNow: Bool {
        WorkspaceRefresh.refreshesGatewayDirectory(section: store.selectedSection, topology: deploymentStore.topology)
    }
}

/// ⌘R, shared by the toolbar button and the 导航 menu: refreshes the runtime data the current
/// section shows and tells the gateway pages (`GatewayWorkbenchStore`) to read again.
@MainActor
enum WorkspaceRefresh {
    static func refreshCurrentSection(
        store: AppStore,
        deploymentStore: DeploymentStore,
        runtimeDataStore: RuntimeDataStore
    ) {
        let section = store.selectedSection
        store.refresh()
        runtimeDataStore.refresh(
            using: deploymentStore,
            includingGatewayModels: refreshesGatewayDirectory(section: section, topology: deploymentStore.topology)
        )
        switch section {
        case .aiProviders:
            runtimeDataStore.refreshProviders(using: deploymentStore)
            runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
        case .authFiles:
            runtimeDataStore.refreshOAuthModelPolicies(using: deploymentStore)
        case .modelPrices:
            runtimeDataStore.refreshModelPrices(using: deploymentStore)
        case .accountActions:
            runtimeDataStore.refreshAccountActionCandidates(
                using: deploymentStore,
                status: runtimeDataStore.accountActionsFilter
            )
        case .codexInspection:
            runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
            runtimeDataStore.refreshCodexInspectionRuns(using: deploymentStore)
        case .plugins:
            runtimeDataStore.refreshPlugins(using: deploymentStore)
            runtimeDataStore.refreshPluginStore(using: deploymentStore)
        default:
            break
        }
        NotificationCenter.default.post(
            name: .oasesRefreshCurrentSection,
            object: nil,
            userInfo: ["section": section.rawValue]
        )
    }

    /// The pages whose own store reads the gateway's `permissions/api/data` (or another
    /// `/cpa-admin` read) on ⌘R.
    static let gatewayPageSections: Set<AppSection> = [.dashboard, .accessKeys, .models, .modelPacks, .webSearch]

    /// Whether ⌘R also reads the model directory. Not on a gateway page of a gateway deployment:
    /// that page's store reads the gateway itself, and with a stale key a second `/cpa-admin`
    /// request in the same wave only lengthens the gateway's global back-off.
    static func refreshesGatewayDirectory(section: AppSection, topology: DeploymentTopology) -> Bool {
        topology != .gateway || !gatewayPageSections.contains(section)
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
            AccessKeysView(deploymentStore: deploymentStore)
        case .models:
            ModelsView(deploymentStore: deploymentStore)
        case .modelPacks:
            ModelPacksView(deploymentStore: deploymentStore)
        case .webSearch:
            SearchProvidersView(deploymentStore: deploymentStore)
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
