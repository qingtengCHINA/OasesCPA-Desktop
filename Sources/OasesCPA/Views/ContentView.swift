import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            DetailWorkspaceView(section: store.selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
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

struct DetailWorkspaceView: View {
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
            UsageAnalyticsView()
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
            AuthFilesView()
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
