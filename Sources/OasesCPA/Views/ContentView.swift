import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 260)
        } detail: {
            DetailWorkspaceView(section: store.selectedSection)
                .navigationTitle(store.selectedSection.title)
                .navigationSubtitle(ShellStatus.subtitle(deploymentStore))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            // Settings (⌘,) and "Check for Updates…" live in the app menu (HIG); the toolbar
            // keeps the page's refresh, which is also in the Navigation menu.
            ToolbarItem(placement: .primaryAction) {
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
            }
        }
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

/// The window's state line (toolbar subtitle) and the sidebar badges, from the deployment state.
/// One phrase, with the client endpoint when the gateway is reachable.
enum ShellStatus {
    /// The client endpoint as `host:port` (for example `127.0.0.1:8317`).
    static func endpointLabel(_ endpoints: DeploymentEndpoints) -> String {
        let url = endpoints.clientAPIBaseURL
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func subtitle(
        stage: DeploymentStage,
        topology: DeploymentTopology,
        method: DeploymentMethod,
        hasInstalledDeployment: Bool,
        endpoint: String,
        language: AppLanguage? = nil
    ) -> String {
        if MaintenanceLabels.showsUpgradeCallout(method: method, topology: topology, hasInstalledDeployment: hasInstalledDeployment) {
            return OasesLocalization.localized("需要升级", language: language)
        }
        switch stage {
        case .installing:
            return OasesLocalization.localized("部署中", language: language)
        case .connecting:
            return OasesLocalization.localized("正在连接…", language: language)
        case .attached:
            return topology == .gateway
                ? OasesLocalization.localizedFormat("网关运行中 · %@", language: language, endpoint)
                : OasesLocalization.localizedFormat("已接入 · %@", language: language, endpoint)
        case .failed:
            return OasesLocalization.localized("需要处理", language: language)
        case .idle, .ready, .cancelled:
            return hasInstalledDeployment
                ? OasesLocalization.localized("未连接", language: language)
                : OasesLocalization.localized("未部署", language: language)
        }
    }

    @MainActor
    static func subtitle(_ deploymentStore: DeploymentStore) -> String {
        subtitle(
            stage: deploymentStore.stage,
            topology: deploymentStore.topology,
            method: deploymentStore.deploymentMethod,
            hasInstalledDeployment: deploymentStore.hasInstalledDeployment,
            endpoint: endpointLabel(deploymentStore.endpoints)
        )
    }

    /// 连接与部署 needs the user: an installed legacy deployment waits for its upgrade.
    @MainActor
    static func deploymentNeedsUpgrade(_ deploymentStore: DeploymentStore) -> Bool {
        MaintenanceLabels.showsUpgradeCallout(
            method: deploymentStore.deploymentMethod,
            topology: deploymentStore.topology,
            hasInstalledDeployment: deploymentStore.hasInstalledDeployment
        )
    }

    /// Badges only where something waits for the user: the pending account actions, and the
    /// upgrade of a legacy deployment.
    static func sidebarBadge(
        for section: AppSection,
        pendingAccountActions: Int,
        deploymentNeedsUpgrade: Bool,
        language: AppLanguage? = nil
    ) -> Text? {
        switch section {
        case .accountActions where pendingAccountActions > 0:
            return Text(verbatim: "\(pendingAccountActions)")
        case .environments where deploymentNeedsUpgrade:
            return Text(verbatim: OasesLocalization.localized("升级", language: language))
        default:
            return nil
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
        case .logs:
            runtimeDataStore.refreshLogs(using: deploymentStore)
        case .quota:
            runtimeDataStore.refreshQuota(using: deploymentStore)
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


struct DetailWorkspaceView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    let section: AppSection

    @ViewBuilder
    var body: some View {
        switch section {
        case .environments:
            ConnectionCenterView()
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
