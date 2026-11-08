import Combine
import Foundation

@MainActor
final class UsageAnalyticsWorkbenchStore: ObservableObject {
    @Published var selectedTab: RuntimeUsageAnalyticsTab = .overview
    @Published var range: RuntimeUsageAnalyticsRange = .today
    @Published var granularity: RuntimeUsageAnalyticsGranularity = .auto
    @Published var searchQuery = ""
    @Published var selectedModels: Set<String> = []
    @Published var selectedProviders: Set<String> = []
    @Published var selectedCredentials: Set<String> = []
    @Published var selectedAPIKeys: Set<String> = []
    @Published var status: RuntimeUsageAnalyticsStatusFilter = .all
    @Published var minimumLatencyMS: Int64 = 0
    @Published var cacheStatus: RuntimeUsageAnalyticsCacheStatus = .all
    @Published private(set) var response: RuntimeUsageAnalyticsResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isActive = false

    private let client: ManagementAPIClient
    private weak var deploymentStore: DeploymentStore?
    private let configuredBaseURL: URL?
    private let configuredManagementKey: String?
    private var refreshTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var generation = 0

    init(
        deploymentStore: DeploymentStore? = nil,
        baseURL: URL? = nil,
        managementKey: String? = nil,
        client: ManagementAPIClient = ManagementAPIClient()
    ) {
        self.deploymentStore = deploymentStore
        configuredBaseURL = baseURL
        configuredManagementKey = managementKey
        self.client = client
    }

    deinit {
        refreshTask?.cancel()
        requestTask?.cancel()
    }

    /// Usage analytics is served by CPA Manager Plus, so it needs the CPAMP admin key.
    var isAttached: Bool {
        if let deploymentStore {
            return deploymentStore.stage == .attached && !deploymentStore.cpampAdminKey.isEmpty
        }
        return configuredBaseURL != nil && !(configuredManagementKey ?? "").isEmpty
    }

    var filterOptions: RuntimeUsageAnalyticsFilterOptions? { response?.filterOptions }

    func activate() {
        isActive = true
        startRefreshLoop()
        refresh()
    }

    func deactivate() {
        isActive = false
        refreshTask?.cancel()
        refreshTask = nil
        requestTask?.cancel()
        requestTask = nil
    }

    func refresh() {
        guard isAttached else {
            errorMessage = nil
            response = nil
            return
        }
        guard requestTask == nil else { return }

        generation += 1
        let currentGeneration = generation
        let payload = makeRequest(now: Date())
        let endpoint = targetEndpoint()
        isLoading = true
        errorMessage = nil

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.usageAnalytics(
                    payload,
                    baseURL: endpoint.baseURL,
                    managementKey: endpoint.managementKey
                )
                guard !Task.isCancelled else { return }
                guard currentGeneration == generation else { return }
                response = result
                lastUpdated = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard currentGeneration == generation else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
            requestTask = nil
        }
    }

    func refreshNow() {
        requestTask?.cancel()
        requestTask = nil
        if isActive {
            startRefreshLoop()
        }
        refresh()
    }

    func makeRequest(now: Date) -> RuntimeUsageAnalyticsRequest {
        let timeZone = TimeZone.current
        return RuntimeUsageAnalyticsRequest(
            tab: selectedTab,
            range: range,
            now: now,
            timeZone: timeZone,
            granularity: granularity,
            searchQuery: searchQuery,
            models: selectedModels.sorted(),
            providers: selectedProviders.sorted(),
            credentialIDs: selectedCredentials.sorted(),
            apiKeyHashes: selectedAPIKeys.sorted(),
            includeFailed: status,
            minimumLatencyMS: minimumLatencyMS,
            cacheStatus: cacheStatus
        )
    }

    func resetFilters() {
        searchQuery = ""
        selectedModels.removeAll()
        selectedProviders.removeAll()
        selectedCredentials.removeAll()
        selectedAPIKeys.removeAll()
        status = .all
        minimumLatencyMS = 0
        cacheStatus = .all
        refresh()
    }

    func toggle(_ value: String, in selection: inout Set<String>) {
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let self, isActive, isAttached else { return }
                refresh()
            }
        }
    }

    /// CPA Manager Plus and its admin key; never the engine and its management key.
    private func targetEndpoint() -> (baseURL: URL, managementKey: String) {
        if let deploymentStore {
            return (deploymentStore.endpoints.cpampBaseURL, deploymentStore.cpampAdminKey)
        }
        return (configuredBaseURL ?? URL(string: "http://127.0.0.1:18317")!, configuredManagementKey ?? "")
    }
}
