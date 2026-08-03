import Foundation
import SwiftUI

enum RuntimeDataStoreError: LocalizedError {
    case targetNotAttached
    case invalidAuthFileName
    case missingAuthIndex
    case invalidAPIKey
    case invalidPluginConfiguration
    case pluginStoreAuthorizationRequired
    case invalidPluginStoreEntry
    case invalidDirectProviderCredential(String)
    case invalidOAuthModelPolicy(String)
    case invalidModelPrice(String)
    case openAICompatibilityProviderAlreadyExists
    case openAICompatibilityProviderDeletionNotConfirmed
    case accountActionCandidateNotPending
    case codexInspectionRunAlreadyActive
    case codexInspectionRunNotCancellable

    var errorDescription: String? {
        switch self {
        case .targetNotAttached:
            OasesLocalization.localized("请先连接一个目标环境。")
        case .invalidAuthFileName:
            OasesLocalization.localized("认证文件名必须是安全的 .json 文件名。")
        case .missingAuthIndex:
            OasesLocalization.localized("该认证文件没有可用于配额操作的 auth_index。")
        case .invalidAPIKey:
            OasesLocalization.localized("API Key 不能为空、不能包含换行，且长度不能超过 512 个字符。")
        case .invalidPluginConfiguration:
            OasesLocalization.localized("插件配置必须是有效的 JSON 顶层对象。")
        case .pluginStoreAuthorizationRequired:
            OasesLocalization.localized("此插件商店条目要求先在目标的插件商店配置中完成来源授权。")
        case .invalidPluginStoreEntry:
            OasesLocalization.localized("插件商店条目缺少可安装的插件标识。")
        case .invalidDirectProviderCredential(let message):
            message
        case .invalidOAuthModelPolicy(let message):
            message
        case .invalidModelPrice(let message):
            message
        case .openAICompatibilityProviderAlreadyExists:
            OasesLocalization.localized("同名 OpenAI-compatible Provider 已存在；请刷新后编辑现有条目。")
        case .openAICompatibilityProviderDeletionNotConfirmed:
            OasesLocalization.localized("目标仍返回该 AI 服务配置；删除尚未生效，请稍后重试。")
        case .accountActionCandidateNotPending:
            OasesLocalization.localized("该账号待办已不处于待处理状态；请刷新后再操作。")
        case .codexInspectionRunAlreadyActive:
            OasesLocalization.localized("当前目标已有正在运行的凭证健康巡检；请等待完成或先取消该任务。")
        case .codexInspectionRunNotCancellable:
            OasesLocalization.localized("该巡检已结束或当前 Manager Server 不允许取消；请刷新后再试。")
        }
    }
}

@MainActor
final class RuntimeDataStore: ObservableObject {
    @Published private(set) var dashboard: RuntimeDashboardSummary?
    @Published private(set) var analyticsDashboard: RuntimeDashboardSummary?
    @Published private(set) var monitoringDashboard: RuntimeDashboardSummary?
    @Published private(set) var monitoringEvents: [RuntimeMonitoringEvent] = []
    @Published private(set) var monitoringEventsTotalCount: Int64?
    @Published private(set) var monitoringEventsHasMore = false
    @Published private(set) var monitoringEventsPaginationWarning: String?
    @Published private(set) var monitoringHeaderSnapshots: [RuntimeMonitoringHeaderSnapshot] = []
    @Published private(set) var hasLoadedMonitoringHeaderSnapshots = false
    @Published private(set) var monitoringAccountHistory: [RuntimeMonitoringAccountHistoryEntry] = []
    @Published private(set) var monitoringAccountHistoryCheckpoint: RuntimeMonitoringAccountHistoryCheckpoint?
    @Published private(set) var hasLoadedMonitoringAccountHistory = false
    @Published private(set) var authFiles: [RuntimeAuthFile] = []
    @Published private(set) var oauthExcludedModels: [String: [String]] = [:]
    @Published private(set) var oauthModelAliases: [String: [RuntimeOAuthModelAliasEntry]] = [:]
    @Published private(set) var modelPrices: [String: RuntimeModelPricePayload] = [:]
    @Published private(set) var modelPriceUsageSummary: RuntimeModelPriceUsageSummary?
    @Published private(set) var lastModelPriceSync: RuntimeModelPriceSyncResponse?
    @Published private(set) var lastAutomaticModelPriceSyncAt: Date?
    @Published private(set) var automaticModelPriceSyncError: String?
    @Published private(set) var lastDashboardRefreshAt: Date?
    @Published private(set) var accountActionCandidates: [RuntimeAccountActionCandidate] = []
    @Published private(set) var accountActionPendingCount = 0
    @Published private(set) var accountActionsFilter: RuntimeAccountActionStatusFilter = .pending
    @Published private(set) var codexInspectionRuns: [RuntimeCodexInspectionRun] = []
    @Published private(set) var selectedCodexInspectionRunID: Int64?
    @Published private(set) var codexInspectionDetail: RuntimeCodexInspectionRunDetail?
    @Published private(set) var apiKeys: [RuntimeAPIKey] = []
    @Published private(set) var gatewayModels: [RuntimeGatewayModel] = []
    @Published private(set) var pluginCatalog: RuntimePluginsResponse?
    @Published private(set) var pluginStoreCatalog: RuntimePluginStoreResponse?
    @Published private(set) var openAICompatibility: [RuntimeOpenAICompatibility] = []
    @Published private(set) var directProviderCredentials: [RuntimeDirectProviderKind: [RuntimeDirectProviderCredential]] = [:]
    @Published private(set) var directProviderErrors: [RuntimeDirectProviderKind: String] = [:]
    @Published private(set) var providerConnectivityResults: [RuntimeProviderConnectivityResult] = []
    @Published private(set) var providerConnectivityErrorMessage: String?
    @Published private(set) var providerConnectivityLastCheckedAt: Date?
    @Published private(set) var logs: RuntimeLogsResponse?
    @Published private(set) var systemStatus: RuntimeSystemStatus?
    @Published private(set) var managerConfiguration: RuntimeManagerConfigResponse?
    @Published private(set) var cpaConfigYAML: String?
    @Published private(set) var quotaCooldowns: [RuntimeQuotaCooldown] = []
    @Published private(set) var quotaEvidence: [String: RuntimeQuotaEvidence] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingManagerConfiguration = false
    @Published private(set) var isSavingManagerConfiguration = false
    @Published private(set) var isLoadingCPAConfig = false
    @Published private(set) var isSavingCPAConfig = false
    @Published private(set) var isLoadingQuota = false
    @Published private(set) var isSavingQuota = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var authFilesErrorMessage: String?
    @Published private(set) var gatewayAccessErrorMessage: String?
    @Published private(set) var gatewayModelsErrorMessage: String?
    @Published private(set) var isLoadingAuthFiles = false
    @Published private(set) var isSavingAuthFiles = false
    @Published private(set) var isLoadingOAuthModelPolicies = false
    @Published private(set) var isSavingOAuthModelPolicies = false
    @Published private(set) var oauthModelPoliciesErrorMessage: String?
    @Published private(set) var isLoadingModelPrices = false
    @Published private(set) var isSavingModelPrices = false
    @Published private(set) var isSyncingModelPrices = false
    @Published private(set) var modelPricesErrorMessage: String?
    @Published private(set) var modelPriceUsageErrorMessage: String?
    @Published private(set) var accountActionsErrorMessage: String?
    @Published private(set) var isLoadingAccountActions = false
    @Published private(set) var isSavingAccountActions = false
    @Published private(set) var accountActionMutatingID: Int64?
    @Published private(set) var codexInspectionErrorMessage: String?
    @Published private(set) var isLoadingCodexInspectionRuns = false
    @Published private(set) var isLoadingCodexInspectionDetail = false
    @Published private(set) var isStartingCodexInspection = false
    @Published private(set) var isCancellingCodexInspection = false
    @Published private(set) var codexInspectionMutatingRunID: Int64?
    @Published private(set) var isLoadingGatewayAccess = false
    @Published private(set) var isSavingGatewayAccess = false
    @Published private(set) var pluginsErrorMessage: String?
    @Published private(set) var isLoadingPlugins = false
    @Published private(set) var isSavingPlugins = false
    @Published private(set) var pluginStoreErrorMessage: String?
    @Published private(set) var isLoadingPluginStore = false
    @Published private(set) var providerErrorMessage: String?
    @Published private(set) var isLoadingProviders = false
    @Published private(set) var isSavingProviders = false
    @Published private(set) var isLoadingDirectProviders = false
    @Published private(set) var isSavingDirectProviders = false
    @Published private(set) var isCheckingProviderConnectivity = false
    @Published private(set) var logsErrorMessage: String?
    @Published private(set) var isLoadingLogs = false
    @Published private(set) var systemStatusErrorMessage: String?
    @Published private(set) var managerConfigurationErrorMessage: String?
    @Published private(set) var cpaConfigErrorMessage: String?
    @Published private(set) var quotaErrorMessage: String?
    @Published private(set) var analyticsErrorMessage: String?
    @Published private(set) var monitoringErrorMessage: String?
    @Published private(set) var monitoringEventsErrorMessage: String?
    @Published private(set) var monitoringHeaderSnapshotsErrorMessage: String?
    @Published private(set) var monitoringAccountHistoryErrorMessage: String?
    @Published private(set) var isLoadingAnalytics = false
    @Published private(set) var isLoadingMonitoring = false
    @Published private(set) var isLoadingMonitoringEvents = false
    @Published private(set) var isLoadingMoreMonitoringEvents = false
    @Published private(set) var isLoadingMonitoringHeaderSnapshots = false
    @Published private(set) var isLoadingMonitoringAccountHistory = false
    @Published private(set) var isCatchingUpMonitoringAccountHistory = false
    private var refreshTask: Task<Void, Never>?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var monitoringEventsTask: Task<Void, Never>?
    private var monitoringHeaderSnapshotsTask: Task<Void, Never>?
    private var monitoringAccountHistoryTask: Task<Void, Never>?
    private var managerConfigurationTask: Task<Void, Never>?
    private var cpaConfigTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private var providerTask: Task<Void, Never>?
    private var directProviderTask: Task<Void, Never>?
    private var providerConnectivityTask: Task<Void, Never>?
    private var authFilesTask: Task<Void, Never>?
    private var oauthModelPoliciesTask: Task<Void, Never>?
    private var modelPricesTask: Task<Void, Never>?
    private var automaticModelPriceSyncTask: Task<Void, Never>?
    private var accountActionsTask: Task<Void, Never>?
    private var codexInspectionRunsTask: Task<Void, Never>?
    private var codexInspectionDetailTask: Task<Void, Never>?
    private var gatewayAccessTask: Task<Void, Never>?
    private var pluginsTask: Task<Void, Never>?
    private var pluginStoreTask: Task<Void, Never>?
    private var codexInspectionMutationRevision = 0
    private var codexInspectionDetailGeneration = 0
    private var monitoringEventsGeneration = 0
    private var monitoringHeaderSnapshotsGeneration = 0
    private var monitoringAccountHistoryGeneration = 0
    private var providerConnectivityGeneration = 0
    private var monitoringEventsCursor: RuntimeMonitoringEventsCursor?
    private var monitoringEventsRequest: RuntimeMonitoringEventsRequest?

    var isLive: Bool { dashboard != nil }

    var canCatchUpMonitoringAccountHistory: Bool {
        !monitoringAccountHistoryTargets().isEmpty
    }

    private static let automaticPriceSyncInterval: TimeInterval = 24 * 60 * 60
    private static let automaticPriceRetryInterval: TimeInterval = 60

    func refresh(using deploymentStore: DeploymentStore) {
        refreshTask?.cancel()
        dashboardRefreshTask?.cancel()
        dashboardRefreshTask = nil
        monitoringEventsTask?.cancel()
        monitoringEventsGeneration += 1
        monitoringHeaderSnapshotsTask?.cancel()
        monitoringHeaderSnapshotsGeneration += 1
        resetMonitoringAccountHistory()
        resetProviderConnectivity()
        authFilesTask?.cancel()
        gatewayAccessTask?.cancel()
        pluginsTask?.cancel()
        pluginStoreTask?.cancel()
        cpaConfigTask?.cancel()
        quotaTask?.cancel()
        accountActionsTask?.cancel()
        codexInspectionRunsTask?.cancel()
        codexInspectionDetailTask?.cancel()
        monitoringEvents = []
        monitoringEventsTotalCount = nil
        monitoringEventsHasMore = false
        monitoringEventsCursor = nil
        monitoringEventsRequest = nil
        monitoringEventsErrorMessage = nil
        monitoringEventsPaginationWarning = nil
        isLoadingMonitoringEvents = false
        isLoadingMoreMonitoringEvents = false
        monitoringHeaderSnapshots = []
        hasLoadedMonitoringHeaderSnapshots = false
        monitoringHeaderSnapshotsErrorMessage = nil
        isLoadingMonitoringHeaderSnapshots = false
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            automaticModelPriceSyncTask?.cancel()
            analyticsTask?.cancel()
            monitoringTask?.cancel()
            providerTask?.cancel()
            directProviderTask?.cancel()
            oauthModelPoliciesTask?.cancel()
            modelPricesTask?.cancel()
            dashboard = nil
            analyticsDashboard = nil
            monitoringDashboard = nil
            authFiles = []
            oauthExcludedModels = [:]
            oauthModelAliases = [:]
            modelPrices = [:]
            modelPriceUsageSummary = nil
            lastModelPriceSync = nil
            lastAutomaticModelPriceSyncAt = nil
            automaticModelPriceSyncError = nil
            lastDashboardRefreshAt = nil
            accountActionCandidates = []
            accountActionPendingCount = 0
            accountActionsFilter = .pending
            codexInspectionRuns = []
            selectedCodexInspectionRunID = nil
            codexInspectionDetail = nil
            apiKeys = []
            gatewayModels = []
            pluginCatalog = nil
            pluginStoreCatalog = nil
            openAICompatibility = []
            directProviderCredentials = [:]
            directProviderErrors = [:]
            logs = nil
            systemStatus = nil
            managerConfiguration = nil
            cpaConfigYAML = nil
            quotaCooldowns = []
            quotaEvidence = [:]
            errorMessage = nil
            authFilesErrorMessage = nil
            gatewayAccessErrorMessage = nil
            gatewayModelsErrorMessage = nil
            isLoadingAuthFiles = false
            isSavingAuthFiles = false
            isLoadingOAuthModelPolicies = false
            isSavingOAuthModelPolicies = false
            oauthModelPoliciesErrorMessage = nil
            isLoadingModelPrices = false
            isSavingModelPrices = false
            isSyncingModelPrices = false
            modelPricesErrorMessage = nil
            modelPriceUsageErrorMessage = nil
            accountActionsErrorMessage = nil
            isLoadingAccountActions = false
            isSavingAccountActions = false
            accountActionMutatingID = nil
            codexInspectionErrorMessage = nil
            isLoadingCodexInspectionRuns = false
            isLoadingCodexInspectionDetail = false
            isStartingCodexInspection = false
            isCancellingCodexInspection = false
            codexInspectionMutatingRunID = nil
            isLoadingGatewayAccess = false
            isSavingGatewayAccess = false
            pluginsErrorMessage = nil
            isLoadingPlugins = false
            isSavingPlugins = false
            pluginStoreErrorMessage = nil
            isLoadingPluginStore = false
            providerErrorMessage = nil
            isLoadingProviders = false
            isSavingProviders = false
            isLoadingDirectProviders = false
            isSavingDirectProviders = false
            logsErrorMessage = nil
            isLoadingLogs = false
            systemStatusErrorMessage = nil
            managerConfigurationErrorMessage = nil
            cpaConfigErrorMessage = nil
            quotaErrorMessage = nil
            isLoadingCPAConfig = false
            isSavingCPAConfig = false
            isLoadingQuota = false
            isSavingQuota = false
            analyticsErrorMessage = nil
            monitoringErrorMessage = nil
            isLoadingAnalytics = false
            isLoadingMonitoring = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        isLoading = true
        errorMessage = nil
        refreshAuthFiles(using: deploymentStore)
        refreshGatewayAccess(using: deploymentStore)

        refreshTask = Task { [weak self] in
            do {
                let summary = try await ManagementAPIClient().dashboardSummary(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled, deploymentStore.stage == .attached, deploymentStore.cpampAdminKey == adminKey else {
                    return
                }
                self?.dashboard = summary
                self?.lastDashboardRefreshAt = Date()
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }

            do {
                let status = try await ManagementAPIClient().systemStatus(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled, deploymentStore.stage == .attached, deploymentStore.cpampAdminKey == adminKey else {
                    return
                }
                self?.systemStatus = status
                self?.systemStatusErrorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.systemStatus = nil
                self?.systemStatusErrorMessage = error.localizedDescription
            }

            if !Task.isCancelled {
                self?.isLoading = false
            }
        }
    }

    /// Refreshes only the lightweight dashboard and service-status endpoints.
    /// Live views use this instead of `refresh(using:)` so a five-second tick
    /// never resets paginated monitoring data or unrelated editor state.
    func refreshDashboard(using deploymentStore: DeploymentStore) {
        guard dashboardRefreshTask == nil else { return }
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            dashboard = nil
            systemStatus = nil
            lastDashboardRefreshAt = nil
            isLoading = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        if dashboard == nil {
            isLoading = true
        }

        dashboardRefreshTask = Task { [weak self] in
            defer { self?.dashboardRefreshTask = nil }
            let client = ManagementAPIClient()
            do {
                let summary = try await client.dashboardSummary(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else { return }
                self?.dashboard = summary
                self?.lastDashboardRefreshAt = Date()
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }

            do {
                let status = try await client.systemStatus(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else { return }
                self?.systemStatus = status
                self?.systemStatusErrorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.systemStatusErrorMessage = error.localizedDescription
            }

            if !Task.isCancelled {
                self?.isLoading = false
            }
        }
    }

    func refreshAuthFiles(using deploymentStore: DeploymentStore) {
        authFilesTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            authFiles = []
            authFilesErrorMessage = nil
            isLoadingAuthFiles = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingAuthFiles = true
        authFilesErrorMessage = nil
        authFilesTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().authFiles(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.authFiles = response.files
                self?.authFilesErrorMessage = nil
                self?.isLoadingAuthFiles = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.authFiles = []
                self?.isLoadingAuthFiles = false
                self?.authFilesErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshGatewayAccess(using deploymentStore: DeploymentStore) {
        gatewayAccessTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            apiKeys = []
            gatewayModels = []
            gatewayAccessErrorMessage = nil
            gatewayModelsErrorMessage = nil
            isLoadingGatewayAccess = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingGatewayAccess = true
        gatewayAccessErrorMessage = nil
        gatewayModelsErrorMessage = nil

        gatewayAccessTask = Task { [weak self] in
            let client = ManagementAPIClient()
            do {
                let response = try await client.apiKeys(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                let fetchedKeys = response.keys.enumerated().map { index, value in
                    RuntimeAPIKey(index: index, value: value)
                }
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }

                self?.apiKeys = fetchedKeys
                self?.gatewayAccessErrorMessage = nil

                do {
                    let catalog = try await client.gatewayModels(
                        baseURL: baseURL,
                        apiKey: fetchedKeys.first?.value
                    )
                    guard !Task.isCancelled,
                          deploymentStore.stage == .attached,
                          deploymentStore.managementKey == managementKey else { return }
                    self?.gatewayModels = catalog.data.sorted {
                        $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
                    }
                    self?.gatewayModelsErrorMessage = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.gatewayModels = []
                    self?.gatewayModelsErrorMessage = error.localizedDescription
                }

                if !Task.isCancelled {
                    self?.isLoadingGatewayAccess = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.apiKeys = []
                self?.gatewayModels = []
                self?.gatewayAccessErrorMessage = error.localizedDescription
                self?.gatewayModelsErrorMessage = nil
                self?.isLoadingGatewayAccess = false
            }
        }
    }

    func addAPIKey(_ value: String, using deploymentStore: DeploymentStore) async throws {
        let value = try normalizedAPIKey(value)
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingGatewayAccess = true
        defer { isSavingGatewayAccess = false }
        try await ManagementAPIClient().addAPIKey(
            value,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshGatewayAccess(using: deploymentStore)
    }

    func replaceAPIKey(
        _ apiKey: RuntimeAPIKey,
        with value: String,
        using deploymentStore: DeploymentStore
    ) async throws {
        let value = try normalizedAPIKey(value)
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingGatewayAccess = true
        defer { isSavingGatewayAccess = false }
        try await ManagementAPIClient().replaceAPIKey(
            at: apiKey.index,
            with: value,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshGatewayAccess(using: deploymentStore)
    }

    func deleteAPIKey(_ apiKey: RuntimeAPIKey, using deploymentStore: DeploymentStore) async throws {
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingGatewayAccess = true
        defer { isSavingGatewayAccess = false }
        try await ManagementAPIClient().deleteAPIKey(
            at: apiKey.index,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshGatewayAccess(using: deploymentStore)
    }

    func refreshPlugins(using deploymentStore: DeploymentStore) {
        pluginsTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            pluginCatalog = nil
            pluginsErrorMessage = nil
            isLoadingPlugins = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingPlugins = true
        pluginsErrorMessage = nil
        pluginsTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().plugins(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.pluginCatalog = response
                self?.pluginsErrorMessage = nil
                self?.isLoadingPlugins = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.pluginCatalog = nil
                self?.isLoadingPlugins = false
                self?.pluginsErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshPluginStore(using deploymentStore: DeploymentStore) {
        pluginStoreTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            pluginStoreCatalog = nil
            pluginStoreErrorMessage = nil
            isLoadingPluginStore = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingPluginStore = true
        pluginStoreErrorMessage = nil
        pluginStoreTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().pluginStore(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.pluginStoreCatalog = response
                self?.pluginStoreErrorMessage = nil
                self?.isLoadingPluginStore = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.pluginStoreCatalog = nil
                self?.isLoadingPluginStore = false
                self?.pluginStoreErrorMessage = error.localizedDescription
            }
        }
    }

    func setPluginEnabled(
        _ plugin: RuntimePlugin,
        enabled: Bool,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingPlugins = true
        pluginsErrorMessage = nil
        defer { isSavingPlugins = false }
        try await ManagementAPIClient().setPluginEnabled(
            plugin.id,
            enabled: enabled,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshPlugins(using: deploymentStore)
        refreshPluginStore(using: deploymentStore)
    }

    func pluginConfigData(
        for plugin: RuntimePlugin,
        using deploymentStore: DeploymentStore
    ) async throws -> Data {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        return try await ManagementAPIClient().pluginConfig(
            for: plugin.id,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    func savePluginConfig(
        _ contents: String,
        for plugin: RuntimePlugin,
        using deploymentStore: DeploymentStore
    ) async throws {
        guard let data = RuntimePluginConfigValidator.canonicalData(from: contents) else {
            throw RuntimeDataStoreError.invalidPluginConfiguration
        }
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingPlugins = true
        pluginsErrorMessage = nil
        defer { isSavingPlugins = false }
        try await ManagementAPIClient().replacePluginConfig(
            data,
            for: plugin.id,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshPlugins(using: deploymentStore)
        refreshPluginStore(using: deploymentStore)
    }

    func installPluginFromStore(
        _ entry: RuntimePluginStoreEntry,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimePluginStoreInstallResult {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw RuntimeDataStoreError.invalidPluginStoreEntry }
        guard !entry.authRequired || entry.authConfigured else {
            throw RuntimeDataStoreError.pluginStoreAuthorizationRequired
        }
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingPlugins = true
        pluginStoreErrorMessage = nil
        defer { isSavingPlugins = false }
        let result = try await ManagementAPIClient().installPluginFromStore(
            pluginID: id,
            sourceID: entry.sourceID,
            version: entry.version,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshPlugins(using: deploymentStore)
        refreshPluginStore(using: deploymentStore)
        return result
    }

    func deletePlugin(
        _ plugin: RuntimePlugin,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimePluginDeleteResult {
        try await deletePlugin(plugin.id, using: deploymentStore)
    }

    func deletePlugin(
        _ pluginID: String,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimePluginDeleteResult {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingPlugins = true
        pluginsErrorMessage = nil
        defer { isSavingPlugins = false }
        let result = try await ManagementAPIClient().deletePlugin(
            pluginID,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshPlugins(using: deploymentStore)
        refreshPluginStore(using: deploymentStore)
        return result
    }

    func refreshQuota(using deploymentStore: DeploymentStore) {
        quotaTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            quotaCooldowns = []
            quotaEvidence = [:]
            quotaErrorMessage = nil
            isLoadingQuota = false
            return
        }

        let cpaBaseURL = deploymentStore.cpaBaseURL
        let cpaManagementKey = deploymentStore.managementKey
        let cpampBaseURL = deploymentStore.cpampBaseURL
        let cpampAdminKey = deploymentStore.cpampAdminKey
        let files = authFiles
        isLoadingQuota = true
        quotaErrorMessage = nil
        quotaTask = Task { [weak self] in
            var errors: [String] = []
            var cooldowns: [RuntimeQuotaCooldown] = []

            if !cpampAdminKey.isEmpty {
                do {
                    cooldowns = try await ManagementAPIClient().activeQuotaCooldowns(
                        baseURL: cpampBaseURL,
                        managementKey: cpampAdminKey
                    ).items
                } catch {
                    errors.append("CPAMP cooldown：\(error.localizedDescription)")
                }
            }

            var evidence: [String: RuntimeQuotaEvidence] = [:]
            for file in files {
                guard !Task.isCancelled,
                      let request = RuntimeQuotaRequestFactory.request(for: file) else { continue }

                do {
                    let response = try await ManagementAPIClient().apiCall(
                        RuntimeAPICallRequest(
                            authIndex: file.authIndex,
                            method: request.method,
                            url: request.url,
                            header: request.headers,
                            data: request.data
                        ),
                        baseURL: cpaBaseURL,
                        managementKey: cpaManagementKey
                    )
                    evidence[file.name] = RuntimeQuotaParser.parse(
                        file: file,
                        request: request,
                        response: response
                    )
                } catch {
                    evidence[file.name] = RuntimeQuotaEvidence(
                        fileName: file.name,
                        provider: request.provider,
                        authIndex: file.authIndex,
                        observedAt: Date(),
                        statusCode: nil,
                        status: .failed,
                        windows: [],
                        plan: nil,
                        message: error.localizedDescription
                    )
                }
            }

            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.managementKey == cpaManagementKey else { return }
            self?.quotaCooldowns = cooldowns
            self?.quotaEvidence = evidence
            self?.quotaErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
            self?.isLoadingQuota = false
        }
    }

    func resetQuota(
        _ cooldown: RuntimeQuotaCooldown,
        using deploymentStore: DeploymentStore
    ) async throws {
        guard let authIndex = cooldown.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authIndex.isEmpty else {
            throw RuntimeDataStoreError.missingAuthIndex
        }
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingQuota = true
        defer { isSavingQuota = false }
        try await ManagementAPIClient().resetQuota(
            authIndex: authIndex,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshAuthFiles(using: deploymentStore)
        refreshQuota(using: deploymentStore)
    }

    func downloadAuthFileData(
        _ file: RuntimeAuthFile,
        using deploymentStore: DeploymentStore
    ) async throws -> Data {
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        return try await ManagementAPIClient().downloadAuthFile(
            name: file.name,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    func uploadAuthFile(
        name: String,
        data: Data,
        using deploymentStore: DeploymentStore
    ) async throws {
        let safeName = try authFileName(name)
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingAuthFiles = true
        defer { isSavingAuthFiles = false }
        try await ManagementAPIClient().uploadAuthFile(
            name: safeName,
            data: data,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshAuthFiles(using: deploymentStore)
    }

    func deleteAuthFile(
        _ file: RuntimeAuthFile,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingAuthFiles = true
        defer { isSavingAuthFiles = false }
        try await ManagementAPIClient().deleteAuthFile(
            name: file.name,
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshAuthFiles(using: deploymentStore)
    }

    func setAuthFileDisabled(
        _ file: RuntimeAuthFile,
        disabled: Bool,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try authManagementContext(using: deploymentStore)
        isSavingAuthFiles = true
        defer { isSavingAuthFiles = false }
        try await ManagementAPIClient().patchAuthFileStatus(
            RuntimeAuthFileStatusPatch(
                name: file.name,
                authIndex: file.authIndex,
                disabled: disabled
            ),
            baseURL: baseURL,
            managementKey: managementKey
        )
        refreshAuthFiles(using: deploymentStore)
    }

    func refreshOAuthModelPolicies(using deploymentStore: DeploymentStore) {
        oauthModelPoliciesTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            oauthExcludedModels = [:]
            oauthModelAliases = [:]
            oauthModelPoliciesErrorMessage = nil
            isLoadingOAuthModelPolicies = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        let previousExcluded = oauthExcludedModels
        let previousAliases = oauthModelAliases
        isLoadingOAuthModelPolicies = true
        oauthModelPoliciesErrorMessage = nil

        oauthModelPoliciesTask = Task { [weak self] in
            let client = ManagementAPIClient()
            var excluded = previousExcluded
            var aliases = previousAliases
            var failures: [String] = []

            do {
                excluded = try await client.oauthExcludedModels(
                    baseURL: baseURL,
                    managementKey: managementKey
                ).rules
            } catch {
                failures.append("模型排除规则：\(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }

            do {
                aliases = try await client.oauthModelAliases(
                    baseURL: baseURL,
                    managementKey: managementKey
                ).aliases
            } catch {
                failures.append("模型别名：\(error.localizedDescription)")
            }

            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.managementKey == managementKey else {
                return
            }
            self?.oauthExcludedModels = excluded
            self?.oauthModelAliases = aliases
            self?.oauthModelPoliciesErrorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            self?.isLoadingOAuthModelPolicies = false
        }
    }

    func saveOAuthExcludedModels(
        channel rawChannel: String,
        rules: [String],
        using deploymentStore: DeploymentStore
    ) async throws {
        guard let channel = RuntimeOAuthModelPolicyValidator.normalizedChannel(rawChannel) else {
            throw RuntimeDataStoreError.invalidOAuthModelPolicy(OasesLocalization.localized("OAuth 渠道标识不能为空，且不能包含空格或换行。"))
        }
        let normalizedRules = RuntimeOAuthModelPolicyValidator.normalizedExcludedRules(rules)
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingOAuthModelPolicies = true
        oauthModelPoliciesErrorMessage = nil
        defer { isSavingOAuthModelPolicies = false }

        do {
            if normalizedRules.isEmpty {
                if oauthExcludedModels[channel] != nil {
                    try await ManagementAPIClient().deleteOAuthExcludedModels(
                        provider: channel,
                        baseURL: baseURL,
                        managementKey: managementKey
                    )
                }
            } else {
                try await ManagementAPIClient().patchOAuthExcludedModels(
                    provider: channel,
                    models: normalizedRules,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
            }
        } catch {
            oauthModelPoliciesErrorMessage = error.localizedDescription
            throw error
        }

        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        refreshOAuthModelPolicies(using: deploymentStore)
    }

    func saveOAuthModelAliases(
        channel rawChannel: String,
        aliases: [RuntimeOAuthModelAliasEntry],
        using deploymentStore: DeploymentStore
    ) async throws {
        guard let channel = RuntimeOAuthModelPolicyValidator.normalizedChannel(rawChannel) else {
            throw RuntimeDataStoreError.invalidOAuthModelPolicy(OasesLocalization.localized("OAuth 渠道标识不能为空，且不能包含空格或换行。"))
        }
        if let message = RuntimeOAuthModelPolicyValidator.validationMessage(for: aliases) {
            throw RuntimeDataStoreError.invalidOAuthModelPolicy(message)
        }

        let normalized = aliases.map { $0.normalized() }
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingOAuthModelPolicies = true
        oauthModelPoliciesErrorMessage = nil
        defer { isSavingOAuthModelPolicies = false }

        do {
            if normalized.isEmpty {
                if oauthModelAliases[channel] != nil {
                    try await ManagementAPIClient().deleteOAuthModelAliases(
                        channel: channel,
                        baseURL: baseURL,
                        managementKey: managementKey
                    )
                }
            } else {
                try await ManagementAPIClient().patchOAuthModelAliases(
                    channel: channel,
                    aliases: normalized,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
            }
        } catch {
            oauthModelPoliciesErrorMessage = error.localizedDescription
            throw error
        }

        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        refreshOAuthModelPolicies(using: deploymentStore)
    }

    func refreshModelPrices(using deploymentStore: DeploymentStore) {
        modelPricesTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            modelPrices = [:]
            modelPriceUsageSummary = nil
            lastModelPriceSync = nil
            modelPricesErrorMessage = nil
            modelPriceUsageErrorMessage = nil
            isLoadingModelPrices = false
            isSavingModelPrices = false
            isSyncingModelPrices = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let previousUsageSummary = modelPriceUsageSummary
        isLoadingModelPrices = true
        modelPricesErrorMessage = nil
        modelPriceUsageErrorMessage = nil

        modelPricesTask = Task { [weak self] in
            let client = ManagementAPIClient()
            let response: RuntimeModelPricesResponse
            do {
                response = try await client.modelPrices(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
            } catch {
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else {
                    return
                }
                self?.modelPricesErrorMessage = error.localizedDescription
                self?.isLoadingModelPrices = false
                return
            }

            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else {
                return
            }

            var usageSummary = previousUsageSummary
            var usageError: String?
            do {
                usageSummary = try await client.modelPriceUsageSummary(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
            } catch {
                usageError = error.localizedDescription
            }

            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else {
                return
            }
            self?.modelPrices = response.prices
            self?.modelPriceUsageSummary = usageSummary
            self?.modelPricesErrorMessage = nil
            self?.modelPriceUsageErrorMessage = usageError
            self?.isLoadingModelPrices = false
        }
    }

    func saveManualModelPrice(
        _ draft: RuntimeModelPriceDraft,
        using deploymentStore: DeploymentStore
    ) async throws {
        if let message = draft.validationMessage {
            throw RuntimeDataStoreError.invalidModelPrice(message)
        }
        let modelID = draft.normalizedModelID
        let payload = draft.manualPayload()
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        isSavingModelPrices = true
        modelPricesErrorMessage = nil
        defer { isSavingModelPrices = false }

        do {
            let client = ManagementAPIClient()
            // CPAMP accepts a full replacement only. Re-read immediately
            // before merging one manual override so unrelated models changed
            // elsewhere are not overwritten by a stale in-memory table.
            let current = try await client.modelPrices(
                baseURL: baseURL,
                managementKey: adminKey
            )
            var merged = current.prices
            merged[modelID] = payload
            let response = try await client.replaceModelPrices(
                merged,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else { return }
            modelPrices = response.prices
            modelPricesErrorMessage = nil
            lastModelPriceSync = nil
        } catch {
            modelPricesErrorMessage = error.localizedDescription
            throw error
        }
    }

    func deleteModelPrice(
        _ record: RuntimeModelPriceRecord,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        isSavingModelPrices = true
        modelPricesErrorMessage = nil
        defer { isSavingModelPrices = false }

        do {
            let client = ManagementAPIClient()
            let current = try await client.modelPrices(
                baseURL: baseURL,
                managementKey: adminKey
            )
            var merged = current.prices
            guard merged.removeValue(forKey: record.modelID) != nil else {
                throw RuntimeDataStoreError.invalidModelPrice(
                    OasesLocalization.localized("该模型价格已被其他会话修改或删除。请刷新后再确认。")
                )
            }
            let response = try await client.replaceModelPrices(
                merged,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else { return }
            modelPrices = response.prices
            modelPricesErrorMessage = nil
            lastModelPriceSync = nil
        } catch {
            modelPricesErrorMessage = error.localizedDescription
            throw error
        }
    }

    func syncModelPrices(
        models: [String],
        using deploymentStore: DeploymentStore
    ) async throws {
        let requestedModels = Array(
            Set<String>(
                models.compactMap { raw -> String? in
                    let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !model.isEmpty, !model.contains(where: { $0.isNewline }) else { return nil }
                    return model
                }
            )
        )
        .sorted()
        guard !requestedModels.isEmpty else {
            throw RuntimeDataStoreError.invalidModelPrice(OasesLocalization.localized("没有可同步的已配置或已调用模型。"))
        }

        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        isSyncingModelPrices = true
        modelPricesErrorMessage = nil
        defer { isSyncingModelPrices = false }

        do {
            let response = try await ManagementAPIClient().syncModelPrices(
                models: requestedModels,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else { return }
            modelPrices = response.prices
            lastModelPriceSync = response
            modelPricesErrorMessage = nil
        } catch {
            modelPricesErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Keeps CPAMP's local price table current without making beginners manage
    /// public catalogs themselves. Discovery is lightweight and throttled; the
    /// public sources are contacted only for a new model or after 24 hours.
    /// CPAMP owns source priority and last-known-good behavior:
    /// models.dev, then LiteLLM, then OpenRouter.
    func automaticallySyncModelPricesIfNeeded(
        using deploymentStore: DeploymentStore,
        force: Bool = false
    ) {
        guard automaticModelPriceSyncTask == nil,
              !isSyncingModelPrices,
              deploymentStore.stage == .attached,
              !deploymentStore.cpampAdminKey.isEmpty else { return }

        let profileID = deploymentStore.activeProfileID?.uuidString ?? "local"
        let successKey = "oases.cpa.model-prices.auto-success.\(profileID)"
        let attemptKey = "oases.cpa.model-prices.auto-attempt.\(profileID)"
        let defaults = UserDefaults.standard
        let now = Date()
        let previousAttempt = Date(timeIntervalSince1970: defaults.double(forKey: attemptKey))
        if !force,
           defaults.object(forKey: attemptKey) != nil,
           now.timeIntervalSince(previousAttempt) < Self.automaticPriceRetryInterval {
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        defaults.set(now.timeIntervalSince1970, forKey: attemptKey)

        automaticModelPriceSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticModelPriceSyncTask = nil }

            let client = ManagementAPIClient()
            do {
                async let pricesRequest = client.modelPrices(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                async let usageRequest = client.modelPriceUsageSummary(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                let (currentPrices, usageSummary) = try await (pricesRequest, usageRequest)

                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else { return }

                self.modelPrices = currentPrices.prices
                self.modelPriceUsageSummary = usageSummary

                var candidates = Set(usageSummary.models.map(\.model))
                candidates.formUnion(self.gatewayModels.map(\.id))
                candidates.formUnion(self.dashboard?.topModelsToday?.map(\.model) ?? [])
                candidates.formUnion(self.dashboard?.modelCostRank?.map(\.model) ?? [])
                candidates = Set(candidates.compactMap { raw in
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty || value.contains(where: { $0.isNewline }) ? nil : value
                })

                guard !candidates.isEmpty else {
                    self.automaticModelPriceSyncError = nil
                    return
                }

                let missingModels = candidates.filter { currentPrices.prices[$0] == nil }
                let lastSuccessValue = defaults.double(forKey: successKey)
                let lastSuccess = Date(timeIntervalSince1970: lastSuccessValue)
                let dailyRefreshDue = defaults.object(forKey: successKey) == nil ||
                    now.timeIntervalSince(lastSuccess) >= Self.automaticPriceSyncInterval
                guard force || dailyRefreshDue || !missingModels.isEmpty else {
                    self.lastAutomaticModelPriceSyncAt = lastSuccess
                    self.automaticModelPriceSyncError = nil
                    return
                }

                self.isSyncingModelPrices = true
                defer { self.isSyncingModelPrices = false }
                let response = try await client.syncModelPrices(
                    models: candidates.sorted(),
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else { return }

                let completedAt = Date()
                defaults.set(completedAt.timeIntervalSince1970, forKey: successKey)
                self.modelPrices = response.prices
                self.lastModelPriceSync = response
                self.lastAutomaticModelPriceSyncAt = completedAt
                self.automaticModelPriceSyncError = nil
                self.refreshDashboard(using: deploymentStore)
            } catch {
                guard !Task.isCancelled else { return }
                self.automaticModelPriceSyncError = error.localizedDescription
            }
        }
    }

    func refreshAccountActionCandidates(
        using deploymentStore: DeploymentStore,
        status: RuntimeAccountActionStatusFilter
    ) {
        accountActionsTask?.cancel()
        accountActionsFilter = status
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            accountActionCandidates = []
            accountActionPendingCount = 0
            accountActionsErrorMessage = nil
            isLoadingAccountActions = false
            isSavingAccountActions = false
            accountActionMutatingID = nil
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        isLoadingAccountActions = true
        accountActionsErrorMessage = nil
        accountActionsTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().accountActionCandidates(
                    status: status,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampAdminKey == adminKey else {
                    return
                }
                self?.accountActionCandidates = response.items
                self?.accountActionPendingCount = response.pendingCount
                self?.accountActionsErrorMessage = nil
                self?.isLoadingAccountActions = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingAccountActions = false
                self?.accountActionsErrorMessage = error.localizedDescription
            }
        }
    }

    func mutateAccountActionCandidate(
        _ candidate: RuntimeAccountActionCandidate,
        operation: RuntimeAccountActionOperation,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimeAccountActionCandidate {
        guard candidate.isPending else {
            throw RuntimeDataStoreError.accountActionCandidateNotPending
        }
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        accountActionsTask?.cancel()
        isSavingAccountActions = true
        accountActionMutatingID = candidate.id
        accountActionsErrorMessage = nil
        defer {
            isSavingAccountActions = false
            accountActionMutatingID = nil
        }

        do {
            let response = try await ManagementAPIClient().mutateAccountActionCandidate(
                candidate.id,
                operation: operation,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampAdminKey == adminKey else {
                return response.item
            }
            accountActionCandidates = accountActionCandidates.map {
                $0.id == response.item.id ? response.item : $0
            }
            if candidate.isPending, !response.item.isPending {
                accountActionPendingCount = max(0, accountActionPendingCount - 1)
            }
            accountActionsErrorMessage = nil
            return response.item
        } catch {
            accountActionsErrorMessage = error.localizedDescription
            throw error
        }
    }

    var hasActiveCodexInspectionRun: Bool {
        if codexInspectionRuns.contains(where: \.isActive) {
            return true
        }
        guard let detail = codexInspectionDetail else { return false }
        return !codexInspectionRuns.contains(where: { $0.id == detail.run.id }) && detail.run.isActive
    }

    func refreshCodexInspectionRuns(
        using deploymentStore: DeploymentStore,
        silently: Bool = false
    ) {
        codexInspectionRunsTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            codexInspectionRuns = []
            selectedCodexInspectionRunID = nil
            codexInspectionDetail = nil
            codexInspectionErrorMessage = nil
            isLoadingCodexInspectionRuns = false
            isLoadingCodexInspectionDetail = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let revision = codexInspectionMutationRevision
        if !silently {
            isLoadingCodexInspectionRuns = true
            codexInspectionErrorMessage = nil
        }

        codexInspectionRunsTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().codexInspectionRuns(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.codexInspectionMutationRevision == revision else {
                    return
                }

                self?.codexInspectionRuns = response.items
                let selectedID = self?.selectedCodexInspectionRunID
                let resolvedSelection = response.items.contains(where: { $0.id == selectedID })
                    ? selectedID
                    : response.items.first?.id
                self?.selectedCodexInspectionRunID = resolvedSelection
                self?.isLoadingCodexInspectionRuns = false
                self?.codexInspectionErrorMessage = nil

                if let resolvedSelection {
                    self?.refreshCodexInspectionRunDetail(
                        resolvedSelection,
                        using: deploymentStore,
                        silently: silently
                    )
                } else {
                    self?.codexInspectionDetailTask?.cancel()
                    self?.codexInspectionDetail = nil
                    self?.isLoadingCodexInspectionDetail = false
                }
            } catch {
                guard !Task.isCancelled,
                      self?.codexInspectionMutationRevision == revision else {
                    return
                }
                self?.isLoadingCodexInspectionRuns = false
                self?.codexInspectionErrorMessage = error.localizedDescription
            }
        }
    }

    func selectCodexInspectionRun(
        _ runID: Int64,
        using deploymentStore: DeploymentStore
    ) {
        guard runID > 0, selectedCodexInspectionRunID != runID else { return }
        codexInspectionDetailGeneration += 1
        selectedCodexInspectionRunID = runID
        codexInspectionDetail = nil
        refreshCodexInspectionRunDetail(runID, using: deploymentStore)
    }

    func refreshCodexInspectionRunDetail(
        _ runID: Int64,
        using deploymentStore: DeploymentStore,
        silently: Bool = false
    ) {
        codexInspectionDetailTask?.cancel()
        guard runID > 0,
              deploymentStore.stage == .attached,
              !deploymentStore.cpampAdminKey.isEmpty else {
            if selectedCodexInspectionRunID == runID {
                codexInspectionDetail = nil
            }
            isLoadingCodexInspectionDetail = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let generation = codexInspectionDetailGeneration + 1
        codexInspectionDetailGeneration = generation
        if !silently {
            isLoadingCodexInspectionDetail = true
        }

        codexInspectionDetailTask = Task { [weak self] in
            do {
                let detail = try await ManagementAPIClient().codexInspectionRun(
                    runID,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.selectedCodexInspectionRunID == runID,
                      self?.codexInspectionDetailGeneration == generation else {
                    return
                }

                self?.codexInspectionDetail = detail
                self?.replaceCodexInspectionRun(detail.run)
                self?.isLoadingCodexInspectionDetail = false
                self?.codexInspectionErrorMessage = nil
            } catch {
                guard !Task.isCancelled,
                      self?.selectedCodexInspectionRunID == runID,
                      self?.codexInspectionDetailGeneration == generation else {
                    return
                }
                self?.isLoadingCodexInspectionDetail = false
                self?.codexInspectionErrorMessage = error.localizedDescription
            }
        }
    }

    func startCodexInspection(
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimeCodexInspectionRunDetail {
        guard !hasActiveCodexInspectionRun else {
            throw RuntimeDataStoreError.codexInspectionRunAlreadyActive
        }
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        codexInspectionRunsTask?.cancel()
        codexInspectionDetailTask?.cancel()
        isStartingCodexInspection = true
        codexInspectionErrorMessage = nil
        defer { isStartingCodexInspection = false }

        do {
            let detail = try await ManagementAPIClient().startCodexInspectionRun(
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampBaseURL == baseURL,
                  deploymentStore.cpampAdminKey == adminKey else {
                return detail
            }

            codexInspectionMutationRevision += 1
            selectedCodexInspectionRunID = detail.run.id
            codexInspectionDetailGeneration += 1
            codexInspectionDetail = detail
            replaceCodexInspectionRun(detail.run)
            codexInspectionErrorMessage = nil
            refreshCodexInspectionRuns(using: deploymentStore, silently: true)
            return detail
        } catch {
            codexInspectionErrorMessage = error.localizedDescription
            throw error
        }
    }

    func cancelCodexInspectionRun(
        _ run: RuntimeCodexInspectionRun,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimeCodexInspectionRunDetail {
        guard run.isCancellable else {
            throw RuntimeDataStoreError.codexInspectionRunNotCancellable
        }
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        codexInspectionRunsTask?.cancel()
        codexInspectionDetailTask?.cancel()
        isCancellingCodexInspection = true
        codexInspectionMutatingRunID = run.id
        codexInspectionErrorMessage = nil
        defer {
            isCancellingCodexInspection = false
            codexInspectionMutatingRunID = nil
        }

        do {
            let detail = try await ManagementAPIClient().cancelCodexInspectionRun(
                run.id,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard deploymentStore.stage == .attached,
                  deploymentStore.cpampBaseURL == baseURL,
                  deploymentStore.cpampAdminKey == adminKey else {
                return detail
            }

            codexInspectionMutationRevision += 1
            replaceCodexInspectionRun(detail.run)
            if selectedCodexInspectionRunID == run.id {
                codexInspectionDetailGeneration += 1
                codexInspectionDetail = detail
            }
            codexInspectionErrorMessage = nil
            refreshCodexInspectionRuns(using: deploymentStore, silently: true)
            return detail
        } catch {
            codexInspectionErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func replaceCodexInspectionRun(_ run: RuntimeCodexInspectionRun) {
        var next = codexInspectionRuns.filter { $0.id != run.id }
        next.append(run)
        codexInspectionRuns = next.sorted {
            if $0.startedAtMs != $1.startedAtMs {
                return $0.startedAtMs > $1.startedAtMs
            }
            return $0.id > $1.id
        }
    }

    private func authManagementContext(using deploymentStore: DeploymentStore) throws -> (URL, String) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            throw RuntimeDataStoreError.targetNotAttached
        }
        return (deploymentStore.cpaBaseURL, deploymentStore.managementKey)
    }

    private func authFileName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased().hasSuffix(".json"),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed != ".",
              trimmed != ".." else {
            throw RuntimeDataStoreError.invalidAuthFileName
        }
        return trimmed
    }

    private func normalizedAPIKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              !trimmed.contains(where: { $0.isNewline }) else {
            throw RuntimeDataStoreError.invalidAPIKey
        }
        return trimmed
    }

    func refreshAnalytics(using deploymentStore: DeploymentStore, range: RuntimeDashboardRange) {
        refreshRangeDashboard(
            using: deploymentStore,
            range: range,
            collection: .analytics
        )
    }

    func refreshMonitoring(using deploymentStore: DeploymentStore, range: RuntimeDashboardRange) {
        refreshRangeDashboard(
            using: deploymentStore,
            range: range,
            collection: .monitoring
        )
    }

    func refreshMonitoringEvents(
        using deploymentStore: DeploymentStore,
        range: RuntimeDashboardRange,
        searchQuery: String,
        failedOnly: Bool,
        silently: Bool = false
    ) {
        monitoringEventsTask?.cancel()
        monitoringEventsGeneration += 1
        let generation = monitoringEventsGeneration

        let previousEvents = silently ? monitoringEvents : []
        let previousCursor = silently ? monitoringEventsCursor : nil
        let previousHasMore = silently ? monitoringEventsHasMore : false
        if !silently {
            monitoringEvents = []
            monitoringEventsTotalCount = nil
            monitoringEventsHasMore = false
            monitoringEventsCursor = nil
            monitoringEventsRequest = nil
        }
        monitoringEventsErrorMessage = nil
        monitoringEventsPaginationWarning = nil
        isLoadingMonitoringEvents = !silently || monitoringEvents.isEmpty
        isLoadingMoreMonitoringEvents = false

        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            monitoringEvents = []
            monitoringEventsTotalCount = nil
            monitoringEventsHasMore = false
            monitoringEventsCursor = nil
            monitoringEventsRequest = nil
            isLoadingMonitoringEvents = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let request = RuntimeMonitoringEventsRequest(
            range: range,
            searchQuery: searchQuery,
            failedOnly: failedOnly
        )
        monitoringEventsRequest = request

        monitoringEventsTask = Task { [weak self] in
            do {
                let page = try await ManagementAPIClient().monitoringEvents(
                    request,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringEventsGeneration == generation else {
                    return
                }
                guard let self else { return }
                self.monitoringEvents = silently
                    ? self.mergedMonitoringEvents(existing: page.items, appending: previousEvents)
                    : self.mergedMonitoringEvents(existing: [], appending: page.items)
                self.monitoringEventsTotalCount = max(
                    Int64(self.monitoringEvents.count),
                    page.totalCount
                )
                if silently, previousEvents.count > page.items.count {
                    self.monitoringEventsCursor = previousCursor
                    self.monitoringEventsHasMore = previousHasMore
                } else {
                    self.monitoringEventsCursor = page.nextCursor
                    self.monitoringEventsPaginationWarning = self.monitoringPaginationWarning(
                        for: page,
                        previousCursor: nil
                    )
                    self.monitoringEventsHasMore = page.hasMore &&
                        self.monitoringEventsPaginationWarning == nil
                }
                self.monitoringEventsErrorMessage = nil
                self.isLoadingMonitoringEvents = false
            } catch {
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringEventsGeneration == generation else {
                    return
                }
                self?.monitoringEventsErrorMessage = error.localizedDescription
                self?.isLoadingMonitoringEvents = false
            }
        }
    }

    func refreshMonitoringHeaderSnapshots(using deploymentStore: DeploymentStore) {
        monitoringHeaderSnapshotsTask?.cancel()
        monitoringHeaderSnapshotsGeneration += 1
        let generation = monitoringHeaderSnapshotsGeneration

        monitoringHeaderSnapshots = []
        hasLoadedMonitoringHeaderSnapshots = false
        monitoringHeaderSnapshotsErrorMessage = nil
        isLoadingMonitoringHeaderSnapshots = false
        resetMonitoringAccountHistory()

        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        isLoadingMonitoringHeaderSnapshots = true

        monitoringHeaderSnapshotsTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().monitoringHeaderSnapshots(
                    days: 30,
                    limit: 200,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringHeaderSnapshotsGeneration == generation else {
                    return
                }
                guard let self else { return }
                self.monitoringHeaderSnapshots = response.items
                self.hasLoadedMonitoringHeaderSnapshots = true
                self.monitoringHeaderSnapshotsErrorMessage = nil
                self.isLoadingMonitoringHeaderSnapshots = false
                self.refreshMonitoringAccountHistory(using: deploymentStore)
            } catch {
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringHeaderSnapshotsGeneration == generation else {
                    return
                }
                self?.monitoringHeaderSnapshotsErrorMessage = error.localizedDescription
                self?.isLoadingMonitoringHeaderSnapshots = false
            }
        }
    }

    /// Loads per-identity lifetime aggregates. The normal refresh path is
    /// read-only; catch-up is only invoked from an explicit user confirmation.
    func refreshMonitoringAccountHistory(
        using deploymentStore: DeploymentStore,
        catchUp: Bool = false
    ) {
        monitoringAccountHistoryTask?.cancel()
        monitoringAccountHistoryGeneration += 1
        let generation = monitoringAccountHistoryGeneration
        let targets = monitoringAccountHistoryTargets()

        monitoringAccountHistory = []
        monitoringAccountHistoryCheckpoint = nil
        hasLoadedMonitoringAccountHistory = false
        monitoringAccountHistoryErrorMessage = nil
        isLoadingMonitoringAccountHistory = false
        isCatchingUpMonitoringAccountHistory = false

        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            return
        }
        guard !targets.isEmpty else {
            hasLoadedMonitoringAccountHistory = hasLoadedMonitoringHeaderSnapshots
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let request = RuntimeMonitoringAccountHistoryRequest(
            accounts: targets,
            catchUp: catchUp
        )
        isLoadingMonitoringAccountHistory = true
        isCatchingUpMonitoringAccountHistory = catchUp

        monitoringAccountHistoryTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().monitoringAccountHistory(
                    request,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringAccountHistoryGeneration == generation else {
                    return
                }
                guard let self else { return }
                self.monitoringAccountHistory = targets.enumerated().map { index, target in
                    RuntimeMonitoringAccountHistoryEntry(
                        target: target,
                        item: index < response.items.count ? response.items[index] : nil
                    )
                }
                self.monitoringAccountHistoryCheckpoint = response.checkpoint
                self.hasLoadedMonitoringAccountHistory = true
                self.monitoringAccountHistoryErrorMessage = nil
                self.isLoadingMonitoringAccountHistory = false
                self.isCatchingUpMonitoringAccountHistory = false
            } catch {
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringAccountHistoryGeneration == generation else {
                    return
                }
                self?.monitoringAccountHistoryErrorMessage = error.localizedDescription
                self?.isLoadingMonitoringAccountHistory = false
                self?.isCatchingUpMonitoringAccountHistory = false
            }
        }
    }

    private func resetMonitoringAccountHistory() {
        monitoringAccountHistoryTask?.cancel()
        monitoringAccountHistoryGeneration += 1
        monitoringAccountHistory = []
        monitoringAccountHistoryCheckpoint = nil
        hasLoadedMonitoringAccountHistory = false
        monitoringAccountHistoryErrorMessage = nil
        isLoadingMonitoringAccountHistory = false
        isCatchingUpMonitoringAccountHistory = false
    }

    private func monitoringAccountHistoryTargets() -> [RuntimeMonitoringAccountHistoryTarget] {
        var seen = Set<RuntimeMonitoringAccountHistoryTarget>()
        var targets: [RuntimeMonitoringAccountHistoryTarget] = []

        for snapshot in monitoringHeaderSnapshots {
            guard let target = RuntimeMonitoringAccountHistoryTarget(snapshot: snapshot),
                  seen.insert(target).inserted else {
                continue
            }
            targets.append(target)
            if targets.count == RuntimeMonitoringAccountHistoryRequest.maximumTargets {
                break
            }
        }
        return targets
    }

    func loadMoreMonitoringEvents(using deploymentStore: DeploymentStore) {
        guard deploymentStore.stage == .attached,
              !deploymentStore.cpampAdminKey.isEmpty,
              monitoringEventsHasMore,
              !isLoadingMonitoringEvents,
              !isLoadingMoreMonitoringEvents,
              let cursor = monitoringEventsCursor,
              cursor.isUsable,
              let initialRequest = monitoringEventsRequest else {
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        let generation = monitoringEventsGeneration
        let request = initialRequest.nextPage(after: cursor)
        isLoadingMoreMonitoringEvents = true
        monitoringEventsErrorMessage = nil

        monitoringEventsTask = Task { [weak self] in
            do {
                let page = try await ManagementAPIClient().monitoringEvents(
                    request,
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringEventsGeneration == generation else {
                    return
                }
                guard let self else { return }
                self.monitoringEvents = self.mergedMonitoringEvents(
                    existing: self.monitoringEvents,
                    appending: page.items
                )
                self.monitoringEventsTotalCount = max(
                    Int64(self.monitoringEvents.count),
                    page.totalCount
                )
                self.monitoringEventsCursor = page.nextCursor
                self.monitoringEventsPaginationWarning = self.monitoringPaginationWarning(
                    for: page,
                    previousCursor: cursor
                )
                self.monitoringEventsHasMore = page.hasMore &&
                    self.monitoringEventsPaginationWarning == nil
                self.monitoringEventsErrorMessage = nil
                self.isLoadingMoreMonitoringEvents = false
            } catch {
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey,
                      self?.monitoringEventsGeneration == generation else {
                    return
                }
                self?.monitoringEventsErrorMessage = error.localizedDescription
                self?.isLoadingMoreMonitoringEvents = false
            }
        }
    }

    private enum DashboardCollection {
        case analytics
        case monitoring
    }

    private func mergedMonitoringEvents(
        existing: [RuntimeMonitoringEvent],
        appending next: [RuntimeMonitoringEvent]
    ) -> [RuntimeMonitoringEvent] {
        var seen = Set<String>()
        return (existing + next).filter { event in
            seen.insert(event.id).inserted
        }
    }

    private func monitoringPaginationWarning(
        for page: RuntimeMonitoringEventsPage,
        previousCursor: RuntimeMonitoringEventsCursor?
    ) -> String? {
        guard page.hasMore else { return nil }
        guard let nextCursor = page.nextCursor else {
            return OasesLocalization.localized("当前 CPAMP 返回了更多事件，但没有提供稳定的双字段分页游标；为避免跳过或重复记录，App 只显示当前批次。请升级目标服务或在 CPAMP 面板中继续查看。")
        }
        guard nextCursor != previousCursor else {
            return OasesLocalization.localized("当前 CPAMP 重复返回了同一分页游标；为避免重复加载，App 已停止继续翻页。请在 CPAMP 面板中查看完整记录。")
        }
        return nil
    }

    private func refreshRangeDashboard(
        using deploymentStore: DeploymentStore,
        range: RuntimeDashboardRange,
        collection: DashboardCollection
    ) {
        switch collection {
        case .analytics:
            analyticsTask?.cancel()
            isLoadingAnalytics = false
            analyticsErrorMessage = nil
        case .monitoring:
            monitoringTask?.cancel()
            isLoadingMonitoring = false
            monitoringErrorMessage = nil
        }

        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            switch collection {
            case .analytics: analyticsDashboard = nil
            case .monitoring: monitoringDashboard = nil
            }
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        switch collection {
        case .analytics: isLoadingAnalytics = analyticsDashboard == nil
        case .monitoring: isLoadingMonitoring = monitoringDashboard == nil
        }

        let task = Task { [weak self] in
            do {
                let summary = try await ManagementAPIClient().dashboardSummary(
                    baseURL: baseURL,
                    managementKey: adminKey,
                    range: range
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey else { return }
                switch collection {
                case .analytics:
                    self?.analyticsDashboard = summary
                    self?.analyticsErrorMessage = nil
                    self?.isLoadingAnalytics = false
                case .monitoring:
                    self?.monitoringDashboard = summary
                    self?.monitoringErrorMessage = nil
                    self?.isLoadingMonitoring = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                switch collection {
                case .analytics:
                    self?.analyticsErrorMessage = error.localizedDescription
                    self?.isLoadingAnalytics = false
                case .monitoring:
                    self?.monitoringErrorMessage = error.localizedDescription
                    self?.isLoadingMonitoring = false
                }
            }
        }

        switch collection {
        case .analytics: analyticsTask = task
        case .monitoring: monitoringTask = task
        }
    }

    func refreshLogs(using deploymentStore: DeploymentStore) {
        logsTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            logs = nil
            logsErrorMessage = nil
            isLoadingLogs = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingLogs = true
        logsErrorMessage = nil

        logsTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().logs(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.logs = response
                self?.logsErrorMessage = nil
                self?.isLoadingLogs = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingLogs = false
                self?.logsErrorMessage = error.localizedDescription
            }
        }
    }

    func providerConnectivityPreview() -> RuntimeProviderConnectivityPreview {
        RuntimeProviderConnectivityFactory.plan(
            directCredentials: directProviderCredentials,
            openAICompatibility: openAICompatibility
        ).preview
    }

    /// Starts only the discovery checks that the user has explicitly
    /// confirmed in the Provider workspace. The request plan is intentionally
    /// transient: published state contains safe summaries only.
    func startProviderConnectivityCheck(using deploymentStore: DeploymentStore) {
        providerConnectivityTask?.cancel()
        providerConnectivityGeneration += 1
        let generation = providerConnectivityGeneration

        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            providerConnectivityResults = []
            providerConnectivityErrorMessage = OasesLocalization.localized("请先连接一个目标环境，再检查上游连通性。")
            providerConnectivityLastCheckedAt = nil
            isCheckingProviderConnectivity = false
            return
        }

        let plan = RuntimeProviderConnectivityFactory.plan(
            directCredentials: directProviderCredentials,
            openAICompatibility: openAICompatibility
        )
        providerConnectivityResults = plan.executions.map { execution in
            if let reason = execution.skipReason {
                return .skipped(for: execution.target, reason: reason)
            }
            return .pending(for: execution.target)
        }
        providerConnectivityErrorMessage = nil
        providerConnectivityLastCheckedAt = nil

        guard !plan.executions.isEmpty else {
            providerConnectivityErrorMessage = OasesLocalization.localized("当前没有已配置的 Provider 或凭证可检查。")
            isCheckingProviderConnectivity = false
            return
        }

        guard plan.preview.outboundRequestUpperBound > 0 else {
            providerConnectivityLastCheckedAt = Date()
            isCheckingProviderConnectivity = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isCheckingProviderConnectivity = true

        providerConnectivityTask = Task { [weak self] in
            let client = ManagementAPIClient()

            for execution in plan.executions {
                guard !Task.isCancelled else { return }
                guard execution.skipReason == nil else { continue }
                guard let self,
                      self.isCurrentProviderConnectivityContext(
                          deploymentStore,
                          baseURL: baseURL,
                          managementKey: managementKey,
                          generation: generation
                      ) else {
                    return
                }

                self.replaceProviderConnectivityResult(
                    .init(
                        target: execution.target,
                        status: .running,
                        message: OasesLocalization.localized("正在检查只读模型发现接口。")
                    )
                )

                let result = await self.executeProviderConnectivity(
                    execution,
                    client: client,
                    baseURL: baseURL,
                    managementKey: managementKey
                )

                guard !Task.isCancelled,
                      self.isCurrentProviderConnectivityContext(
                          deploymentStore,
                          baseURL: baseURL,
                          managementKey: managementKey,
                          generation: generation
                      ) else {
                    return
                }
                self.replaceProviderConnectivityResult(result)
            }

            guard !Task.isCancelled,
                  self?.isCurrentProviderConnectivityContext(
                      deploymentStore,
                      baseURL: baseURL,
                      managementKey: managementKey,
                      generation: generation
                  ) == true else {
                return
            }
            self?.isCheckingProviderConnectivity = false
            self?.providerConnectivityLastCheckedAt = Date()
            self?.providerConnectivityTask = nil
        }
    }

    func cancelProviderConnectivityCheck() {
        guard isCheckingProviderConnectivity else { return }
        providerConnectivityTask?.cancel()
        providerConnectivityTask = nil
        providerConnectivityGeneration += 1
        isCheckingProviderConnectivity = false
        providerConnectivityResults = providerConnectivityResults.map { result in
            switch result.status {
            case .pending, .running:
                RuntimeProviderConnectivityResult(
                    target: result.target,
                    status: .cancelled,
                    message: OasesLocalization.localized("检查已由用户取消。")
                )
            case .success, .failed, .skipped, .cancelled:
                result
            }
        }
    }

    func refreshProviders(using deploymentStore: DeploymentStore) {
        providerTask?.cancel()
        resetProviderConnectivity()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            openAICompatibility = []
            providerErrorMessage = nil
            isLoadingProviders = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingProviders = true
        providerErrorMessage = nil
        providerTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().openAICompatibility(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.openAICompatibility = response.providers
                self?.providerErrorMessage = nil
                self?.isLoadingProviders = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingProviders = false
                self?.providerErrorMessage = error.localizedDescription
            }
        }
    }

    func directCredentials(for kind: RuntimeDirectProviderKind) -> [RuntimeDirectProviderCredential] {
        directProviderCredentials[kind] ?? []
    }

    func directProviderError(for kind: RuntimeDirectProviderKind) -> String? {
        directProviderErrors[kind]
    }

    func refreshDirectProviderCredentials(using deploymentStore: DeploymentStore) {
        directProviderTask?.cancel()
        resetProviderConnectivity()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            directProviderCredentials = [:]
            directProviderErrors = [:]
            isLoadingDirectProviders = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        let previousCredentials = directProviderCredentials
        isLoadingDirectProviders = true
        directProviderErrors = [:]

        directProviderTask = Task { [weak self] in
            let client = ManagementAPIClient()
            var loaded = previousCredentials
            var failures: [RuntimeDirectProviderKind: String] = [:]

            for kind in RuntimeDirectProviderKind.allCases {
                guard !Task.isCancelled else { return }
                do {
                    loaded[kind] = try await client.directProviderCredentials(
                        kind: kind,
                        baseURL: baseURL,
                        managementKey: managementKey
                    )
                } catch {
                    failures[kind] = error.localizedDescription
                }
            }

            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.managementKey == managementKey else {
                return
            }
            self?.directProviderCredentials = loaded
            self?.directProviderErrors = failures
            self?.isLoadingDirectProviders = false
        }
    }

    private func resetProviderConnectivity() {
        providerConnectivityTask?.cancel()
        providerConnectivityTask = nil
        providerConnectivityGeneration += 1
        providerConnectivityResults = []
        providerConnectivityErrorMessage = nil
        providerConnectivityLastCheckedAt = nil
        isCheckingProviderConnectivity = false
    }

    private func isCurrentProviderConnectivityContext(
        _ deploymentStore: DeploymentStore,
        baseURL: URL,
        managementKey: String,
        generation: Int
    ) -> Bool {
        deploymentStore.stage == .attached
            && deploymentStore.cpaBaseURL == baseURL
            && deploymentStore.managementKey == managementKey
            && providerConnectivityGeneration == generation
    }

    private func replaceProviderConnectivityResult(
        _ result: RuntimeProviderConnectivityResult
    ) {
        guard let index = providerConnectivityResults.firstIndex(where: {
            $0.id == result.id
        }) else {
            return
        }
        providerConnectivityResults[index] = result
    }

    private func executeProviderConnectivity(
        _ execution: RuntimeProviderConnectivityExecution,
        client: ManagementAPIClient,
        baseURL: URL,
        managementKey: String
    ) async -> RuntimeProviderConnectivityResult {
        if let reason = execution.skipReason {
            return .skipped(for: execution.target, reason: reason)
        }

        let startedAt = Date()
        var lastStatusCode: Int?
        var receivedUnusableModelPayload = false

        for request in execution.requests {
            if Task.isCancelled {
                return RuntimeProviderConnectivityResult(
                    target: execution.target,
                    status: .cancelled,
                    durationMilliseconds: providerConnectivityDuration(since: startedAt),
                    message: OasesLocalization.localized("检查已取消。")
                )
            }

            do {
                let response = try await client.apiCall(
                    request,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                if Task.isCancelled {
                    return RuntimeProviderConnectivityResult(
                        target: execution.target,
                        status: .cancelled,
                        durationMilliseconds: providerConnectivityDuration(since: startedAt),
                        message: OasesLocalization.localized("检查已取消。")
                    )
                }

                lastStatusCode = response.statusCode
                guard (200..<300).contains(response.statusCode) else {
                    continue
                }

                guard let modelCount = RuntimeProviderConnectivityModelParser.modelCount(
                    from: response.body
                ), modelCount > 0 else {
                    receivedUnusableModelPayload = true
                    continue
                }

                return RuntimeProviderConnectivityResult(
                    target: execution.target,
                    status: .success,
                    modelCount: modelCount,
                    statusCode: response.statusCode,
                    durationMilliseconds: providerConnectivityDuration(since: startedAt),
                    message: "已发现 \(modelCount) 个可用模型。"
                )
            } catch {
                if Task.isCancelled {
                    return RuntimeProviderConnectivityResult(
                        target: execution.target,
                        status: .cancelled,
                        durationMilliseconds: providerConnectivityDuration(since: startedAt),
                        message: OasesLocalization.localized("检查已取消。")
                    )
                }
                // ManagementAPIError may carry a server body. Do not surface it
                // here because an upstream body can echo credential material.
            }
        }

        let duration = providerConnectivityDuration(since: startedAt)
        if receivedUnusableModelPayload {
            return RuntimeProviderConnectivityResult(
                target: execution.target,
                status: .failed,
                statusCode: lastStatusCode,
                durationMilliseconds: duration,
                message: OasesLocalization.localized("上游未返回可识别的可用模型。")
            )
        }
        if let lastStatusCode {
            return RuntimeProviderConnectivityResult(
                target: execution.target,
                status: .failed,
                statusCode: lastStatusCode,
                durationMilliseconds: duration,
                message: "上游返回 HTTP \(lastStatusCode)。"
            )
        }
        return RuntimeProviderConnectivityResult(
            target: execution.target,
            status: .failed,
            durationMilliseconds: duration,
            message: OasesLocalization.localized("无法完成上游请求；请检查网络、Base URL 或凭证。")
        )
    }

    private func providerConnectivityDuration(since startedAt: Date) -> Int {
        let milliseconds = Date().timeIntervalSince(startedAt) * 1_000
        return max(0, min(3_600_000, Int(milliseconds.rounded())))
    }

    func createDirectProviderCredential(
        kind: RuntimeDirectProviderKind,
        draft: RuntimeDirectProviderCredentialDraft,
        using deploymentStore: DeploymentStore
    ) async throws {
        if let message = draft.validationMessage(for: kind, isNew: true) {
            throw RuntimeDataStoreError.invalidDirectProviderCredential(message)
        }

        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingDirectProviders = true
        directProviderErrors[kind] = nil
        defer { isSavingDirectProviders = false }

        do {
            try await ManagementAPIClient().appendDirectProviderCredential(
                draft.newPayload(for: kind),
                kind: kind,
                baseURL: baseURL,
                managementKey: managementKey
            )
        } catch {
            directProviderErrors[kind] = error.localizedDescription
            throw error
        }

        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        refreshDirectProviderCredentials(using: deploymentStore)
    }

    func updateDirectProviderCredential(
        _ credential: RuntimeDirectProviderCredential,
        draft: RuntimeDirectProviderCredentialDraft,
        using deploymentStore: DeploymentStore
    ) async throws {
        if let message = draft.validationMessage(for: credential.kind, isNew: false) {
            throw RuntimeDataStoreError.invalidDirectProviderCredential(message)
        }
        guard let patch = draft.patch(relativeTo: credential) else { return }

        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingDirectProviders = true
        directProviderErrors[credential.kind] = nil
        defer { isSavingDirectProviders = false }

        do {
            try await ManagementAPIClient().patchDirectProviderCredential(
                kind: credential.kind,
                index: credential.index,
                value: patch,
                baseURL: baseURL,
                managementKey: managementKey
            )
        } catch {
            directProviderErrors[credential.kind] = error.localizedDescription
            throw error
        }

        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        refreshDirectProviderCredentials(using: deploymentStore)
    }

    func deleteDirectProviderCredential(
        _ credential: RuntimeDirectProviderCredential,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingDirectProviders = true
        directProviderErrors[credential.kind] = nil
        defer { isSavingDirectProviders = false }

        do {
            try await ManagementAPIClient().deleteDirectProviderCredential(
                kind: credential.kind,
                index: credential.index,
                baseURL: baseURL,
                managementKey: managementKey
            )
        } catch {
            directProviderErrors[credential.kind] = error.localizedDescription
            throw error
        }

        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        refreshDirectProviderCredentials(using: deploymentStore)
    }

    func patchOpenAICompatibility(
        name: String,
        index: Int?,
        value: RuntimeOpenAICompatibilityPatch,
        using deploymentStore: DeploymentStore
    ) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            providerErrorMessage = OasesLocalization.localized("请先连接一个目标环境。")
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isSavingProviders = true
        providerErrorMessage = nil
        Task { [weak self] in
            do {
                try await ManagementAPIClient().patchOpenAICompatibility(
                    name: name,
                    index: index,
                    value: value,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.isSavingProviders = false
                self?.refreshProviders(using: deploymentStore)
            } catch {
                guard !Task.isCancelled else { return }
                self?.isSavingProviders = false
                self?.providerErrorMessage = error.localizedDescription
            }
        }
    }

    /// Saves the dedicated OpenRouter OAuth provider without persisting the
    /// OAuth key in app state. Existing provider fields (including user-edited
    /// headers and routing switches) are retained through CLIProxyAPI PATCH.
    func saveOpenRouterOAuthProvider(
        apiKey: String,
        modelCatalog: RuntimeOpenRouterModelCatalog,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimeOpenRouterProviderSaveResult {
        let apiKey = try normalizedAPIKey(apiKey)
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        let models = modelCatalog.models
        let shouldReplaceModels = modelCatalog.didLoad
        let client = ManagementAPIClient()

        isSavingProviders = true
        providerErrorMessage = nil
        defer { isSavingProviders = false }

        do {
            let current = try await client.openAICompatibility(
                baseURL: baseURL,
                managementKey: managementKey
            )
            let existing = current.providers.enumerated().first { _, provider in
                provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == RuntimeOpenRouterOAuth.providerName
            }

            let result: RuntimeOpenRouterProviderSaveResult
            if let (index, provider) = existing {
                try await client.patchOpenAICompatibility(
                    name: provider.name,
                    index: index,
                    value: RuntimeOpenAICompatibilityPatch(
                        name: nil,
                        prefix: nil,
                        disabled: nil,
                        disableCooling: nil,
                        baseURL: RuntimeOpenRouterOAuth.apiBaseURL.absoluteString,
                        apiKeyEntries: [RuntimeProviderAPIKey(apiKey: apiKey)],
                        models: shouldReplaceModels ? models : nil,
                        headers: nil
                    ),
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                result = RuntimeOpenRouterProviderSaveResult(
                    disposition: .updated,
                    modelCount: models.count,
                    preservedExistingModels: !shouldReplaceModels
                )
            } else {
                let newProvider = RuntimeOpenAICompatibilityWrite(
                    name: RuntimeOpenRouterOAuth.providerName,
                    priority: 0,
                    disabled: false,
                    prefix: "",
                    baseURL: RuntimeOpenRouterOAuth.apiBaseURL.absoluteString,
                    apiKeyEntries: [RuntimeProviderAPIKey(apiKey: apiKey)],
                    models: models,
                    headers: [:],
                    disableCooling: false
                )
                let appendOutcome = try await client.appendOpenAICompatibility(
                    newProvider,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                switch appendOutcome {
                case .appended:
                    result = RuntimeOpenRouterProviderSaveResult(
                        disposition: .created,
                        modelCount: models.count,
                        preservedExistingModels: false
                    )
                case .existing(let index):
                    // A second client added the dedicated provider after our
                    // initial read. Patch that exact current entry rather than
                    // replacing the whole list a second time.
                    try await client.patchOpenAICompatibility(
                        name: nil,
                        index: index,
                        value: RuntimeOpenAICompatibilityPatch(
                            name: nil,
                            prefix: nil,
                            disabled: nil,
                            disableCooling: nil,
                            baseURL: RuntimeOpenRouterOAuth.apiBaseURL.absoluteString,
                            apiKeyEntries: [RuntimeProviderAPIKey(apiKey: apiKey)],
                            models: shouldReplaceModels ? models : nil,
                            headers: nil
                        ),
                        baseURL: baseURL,
                        managementKey: managementKey
                    )
                    result = RuntimeOpenRouterProviderSaveResult(
                        disposition: .updated,
                        modelCount: models.count,
                        preservedExistingModels: !shouldReplaceModels
                    )
                }
            }

            guard deploymentStore.stage == .attached,
                  deploymentStore.cpaBaseURL == baseURL,
                  deploymentStore.managementKey == managementKey else {
                return result
            }
            refreshProviders(using: deploymentStore)
            return result
        } catch {
            providerErrorMessage = error.localizedDescription
            throw error
        }
    }

    func createOpenAICompatibility(
        _ provider: RuntimeOpenAICompatibilityWrite,
        using deploymentStore: DeploymentStore
    ) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            providerErrorMessage = OasesLocalization.localized("请先连接一个目标环境。")
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isSavingProviders = true
        providerErrorMessage = nil
        Task { [weak self] in
            do {
                let outcome = try await ManagementAPIClient().appendOpenAICompatibility(
                    provider,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard case .appended = outcome else {
                    throw RuntimeDataStoreError.openAICompatibilityProviderAlreadyExists
                }
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpaBaseURL == baseURL,
                      deploymentStore.managementKey == managementKey else { return }
                self?.isSavingProviders = false
                self?.refreshProviders(using: deploymentStore)
            } catch {
                guard !Task.isCancelled else { return }
                self?.isSavingProviders = false
                self?.providerErrorMessage = error.localizedDescription
            }
        }
    }

    func deleteOpenAICompatibility(
        _ provider: RuntimeOpenAICompatibility,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        isSavingProviders = true
        providerErrorMessage = nil
        defer { isSavingProviders = false }

        do {
            let client = ManagementAPIClient()
            try await client.deleteOpenAICompatibility(
                name: provider.name,
                index: nil,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let response = try await client.openAICompatibility(
                baseURL: baseURL,
                managementKey: managementKey
            )
            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.cpaBaseURL == baseURL,
                  deploymentStore.managementKey == managementKey else {
                throw CancellationError()
            }
            guard !response.providers.contains(where: { $0.name == provider.name }) else {
                throw RuntimeDataStoreError.openAICompatibilityProviderDeletionNotConfirmed
            }
            openAICompatibility = response.providers
            providerErrorMessage = nil
        } catch {
            if !Task.isCancelled {
                providerErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func clearLogs(using deploymentStore: DeploymentStore) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            logsErrorMessage = OasesLocalization.localized("请先连接一个目标环境。")
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingLogs = true
        logsErrorMessage = nil
        logsTask?.cancel()
        logsTask = Task { [weak self] in
            do {
                try await ManagementAPIClient().clearLogs(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.logs = RuntimeLogsResponse(
                    lines: [],
                    lineCount: 0,
                    latestTimestamp: 0,
                    latestAfter: nil,
                    nextCursor: nil,
                    cursorReset: false
                )
                self?.isLoadingLogs = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingLogs = false
                self?.logsErrorMessage = error.localizedDescription
            }
        }
    }

    func enableFileLogging(using deploymentStore: DeploymentStore) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            logsErrorMessage = OasesLocalization.localized("请先连接一个目标环境。")
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingLogs = true
        logsErrorMessage = nil
        logsTask?.cancel()
        logsTask = Task { [weak self] in
            do {
                try await ManagementAPIClient().setLoggingToFile(
                    true,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.refreshLogs(using: deploymentStore)
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingLogs = false
                self?.logsErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshManagerConfiguration(using deploymentStore: DeploymentStore) {
        managerConfigurationTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            managerConfiguration = nil
            managerConfigurationErrorMessage = nil
            isLoadingManagerConfiguration = false
            return
        }

        let baseURL = deploymentStore.cpampBaseURL
        let adminKey = deploymentStore.cpampAdminKey
        isLoadingManagerConfiguration = true
        managerConfigurationErrorMessage = nil

        managerConfigurationTask = Task { [weak self] in
            do {
                let response = try await ManagementAPIClient().managerConfig(
                    baseURL: baseURL,
                    managementKey: adminKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.cpampBaseURL == baseURL,
                      deploymentStore.cpampAdminKey == adminKey else { return }
                self?.managerConfiguration = response
                self?.managerConfigurationErrorMessage = nil
                self?.isLoadingManagerConfiguration = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingManagerConfiguration = false
                self?.managerConfigurationErrorMessage = error.localizedDescription
            }
        }
    }

    func saveManagerConfiguration(
        _ config: RuntimeManagerConfig,
        using deploymentStore: DeploymentStore
    ) async throws -> RuntimeManagerConfigResponse {
        let (baseURL, adminKey) = try cpampManagementContext(using: deploymentStore)
        isSavingManagerConfiguration = true
        managerConfigurationErrorMessage = nil
        defer { isSavingManagerConfiguration = false }

        do {
            let response = try await ManagementAPIClient().saveManagerConfig(
                config,
                baseURL: baseURL,
                managementKey: adminKey
            )
            guard !Task.isCancelled,
                  deploymentStore.stage == .attached,
                  deploymentStore.cpampBaseURL == baseURL,
                  deploymentStore.cpampAdminKey == adminKey else {
                throw CancellationError()
            }
            managerConfiguration = response
            managerConfigurationErrorMessage = nil
            return response
        } catch {
            if !Task.isCancelled {
                managerConfigurationErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func refreshCPAConfig(using deploymentStore: DeploymentStore) {
        cpaConfigTask?.cancel()
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            cpaConfigYAML = nil
            cpaConfigErrorMessage = nil
            isLoadingCPAConfig = false
            return
        }

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isLoadingCPAConfig = true
        cpaConfigErrorMessage = nil
        cpaConfigTask = Task { [weak self] in
            do {
                let data = try await ManagementAPIClient().configYAML(
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled,
                      deploymentStore.stage == .attached,
                      deploymentStore.managementKey == managementKey else { return }
                self?.cpaConfigYAML = String(decoding: data, as: UTF8.self)
                self?.cpaConfigErrorMessage = nil
                self?.isLoadingCPAConfig = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingCPAConfig = false
                self?.cpaConfigErrorMessage = error.localizedDescription
            }
        }
    }

    func saveCPAConfig(
        _ contents: String,
        using deploymentStore: DeploymentStore
    ) async throws {
        let (baseURL, managementKey) = try cpaManagementContext(using: deploymentStore)
        let normalized = contents.hasSuffix("\n") ? contents : contents + "\n"
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagementAPIError.server(status: 400, message: "config.yaml 不能为空")
        }

        isSavingCPAConfig = true
        cpaConfigErrorMessage = nil
        defer { isSavingCPAConfig = false }
        try await ManagementAPIClient().saveConfigYAML(
            Data(normalized.utf8),
            baseURL: baseURL,
            managementKey: managementKey
        )
        guard deploymentStore.stage == .attached,
              deploymentStore.managementKey == managementKey else { return }
        cpaConfigYAML = normalized
    }

    private func cpaManagementContext(using deploymentStore: DeploymentStore) throws -> (URL, String) {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            throw RuntimeDataStoreError.targetNotAttached
        }
        return (deploymentStore.cpaBaseURL, deploymentStore.managementKey)
    }

    private func cpampManagementContext(using deploymentStore: DeploymentStore) throws -> (URL, String) {
        guard deploymentStore.stage == .attached, !deploymentStore.cpampAdminKey.isEmpty else {
            throw RuntimeDataStoreError.targetNotAttached
        }
        return (deploymentStore.cpampBaseURL, deploymentStore.cpampAdminKey)
    }
}
