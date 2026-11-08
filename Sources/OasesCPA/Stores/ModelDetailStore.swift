import Foundation

/// The last 7 days of one model, summed over every name its usage is recorded under.
struct ModelDetailSummary: Equatable, Sendable {
    let calls: Int
    /// 0…1; nil without calls.
    let successRate: Double?
    let totalCost: Double
    /// False when the price table has no entry for the model: the cost is then not an estimate.
    let hasPrice: Bool
}

/// Readable messages of the model detail page.
enum ModelDetailError: LocalizedError, Equatable {
    /// The gateway refused the order; the text is the server's reason, masked.
    case orderRejected(String)
    case statisticsUnavailable

    var errorDescription: String? {
        switch self {
        case .orderRejected(let reason): reason
        case .statisticsUnavailable: OasesLocalization.localized("CPA Manager Plus 不可用，暂时无法显示调用统计。")
        }
    }
}

/// One model's providers (in the engine's order, reorderable), 7-day statistics and recent calls.
///
/// A new order always runs as a dry run first. When the plan changes other models too
/// (`affected`), it waits in `pendingPlan` for the user; otherwise it is applied at once with
/// the same order. A refused order restores the server's order and shows the server's reason.
@MainActor
final class ModelDetailStore: GatewayWorkbenchStore {
    let modelID: String

    @Published private(set) var providers: [GatewayModelProvider] = []
    @Published private(set) var summary: ModelDetailSummary?
    @Published private(set) var recentCalls: [RuntimeMonitoringEvent] = []
    @Published private(set) var pendingPlan: GatewayReorderPlan?
    /// A dry run or a change of the order is running: the list is not draggable meanwhile.
    @Published private(set) var isReordering = false
    /// CPA Manager Plus could not be read; the providers still show.
    @Published private(set) var statisticsError: String?
    /// The latest single-provider test per provider name.
    @Published private(set) var providerTests: [String: GatewayHealthResult] = [:]

    static let recentCallLimit = 20

    private let cpamp: @MainActor () -> (URL, String)?
    private let client: ManagementAPIClient
    /// The order the server reported last (restored when a new order is refused or discarded).
    private var serverProviders: [GatewayModelProvider] = []
    private var pendingOrder: [String]?

    init(
        modelID: String,
        provider: GatewayClientProviding,
        cpamp: @escaping @MainActor () -> (URL, String)?,
        client: ManagementAPIClient = .init()
    ) {
        self.modelID = modelID
        self.cpamp = cpamp
        self.client = client
        super.init(provider: provider, section: .models)
    }

    // MARK: - Load

    override func load(using gateway: GatewayAdminClient) async throws {
        let response = try await gateway.modelProviders(model: modelID)
        try ensureCurrentLoad()
        serverProviders = response.providers
        if pendingPlan == nil && !isReordering {
            providers = response.providers
        }
        let prefixes = Self.routingPrefixes(of: response.providers)
        await loadStatistics(prefixes: prefixes)
    }

    /// The non-empty prefixes of the compat providers: usage of a pinned request is recorded as
    /// `<prefix>/<model>`.
    static func routingPrefixes(of providers: [GatewayModelProvider]) -> [String] {
        var result: [String] = []
        for provider in providers where provider.kind == .compat {
            let prefix = (provider.prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty && !result.contains(prefix) { result.append(prefix) }
        }
        return result
    }

    /// Overview of the last 7 days filtered to every name the model's usage is recorded under;
    /// CPA Manager Plus sums the filtered events into one `summary`.
    static func analyticsRequest(modelID: String, prefixes: [String], now: Date, timeZone: TimeZone) -> RuntimeUsageAnalyticsRequest {
        RuntimeUsageAnalyticsRequest(
            tab: .overview,
            range: .last7Days,
            now: now,
            timeZone: timeZone,
            models: InternalModelID.queryVariants(for: modelID, prefixes: prefixes)
        )
    }

    /// The newest calls of the model under any of its names.
    static func recentCallsRequest(modelID: String, prefixes: [String], now: Date) -> RuntimeMonitoringEventsRequest {
        var filters = RuntimeMonitoringEventsRequest.Filters()
        filters.models = InternalModelID.queryVariants(for: modelID, prefixes: prefixes)
        return RuntimeMonitoringEventsRequest(
            range: .sevenDays,
            now: now,
            searchQuery: "",
            failedOnly: false,
            filters: filters,
            limit: recentCallLimit
        )
    }

    private func loadStatistics(prefixes: [String]) async {
        guard let (baseURL, adminKey) = cpamp(), !adminKey.isEmpty else {
            summary = nil
            recentCalls = []
            statisticsError = ModelDetailError.statisticsUnavailable.errorDescription
            return
        }
        let client = client
        let now = Date()
        let analytics = Self.analyticsRequest(modelID: modelID, prefixes: prefixes, now: now, timeZone: .current)
        let events = Self.recentCallsRequest(modelID: modelID, prefixes: prefixes, now: now)
        do {
            async let analyticsResponse = client.usageAnalytics(analytics, baseURL: baseURL, managementKey: adminKey)
            async let eventsPage = client.monitoringEvents(events, baseURL: baseURL, managementKey: adminKey)
            async let prices = client.modelPrices(baseURL: baseURL, managementKey: adminKey)
            let (response, page, table) = try await (analyticsResponse, eventsPage, prices)
            try ensureCurrentLoad()
            summary = Self.summary(of: response, prices: table, modelID: modelID)
            recentCalls = Array(page.items.prefix(Self.recentCallLimit))
            statisticsError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statisticsError = SecretRedactor.redact(error.localizedDescription, secrets: [adminKey])
        }
    }

    static func summary(of response: RuntimeUsageAnalyticsResponse, prices: RuntimeModelPricesResponse, modelID: String) -> ModelDetailSummary {
        let calls = Int(response.summary?.totalCalls ?? 0)
        let successes = Int(response.summary?.successCalls ?? 0)
        let hasPrice = prices.prices.keys.contains { InternalModelID.publicName($0) == modelID }
        return ModelDetailSummary(
            calls: calls,
            successRate: calls > 0 ? Double(successes) / Double(calls) : nil,
            totalCost: response.summary?.totalCost ?? 0,
            hasPrice: hasPrice
        )
    }

    // MARK: - Order

    /// Shows `ids` at once, runs the dry run, and applies the order when it changes no other
    /// model; with side effects it waits in `pendingPlan`. A refused order restores the
    /// server's order.
    func proposeOrder(_ ids: [String]) async {
        guard pendingPlan == nil, !isReordering, !isMutating else { return }
        let original = serverProviders.isEmpty ? providers : serverProviders
        guard ids != providers.map(\.id), Set(ids) == Set(providers.map(\.id)), ids.count == providers.count else { return }
        providers = ids.compactMap { id in providers.first { $0.id == id } }
        isReordering = true
        var committed = false
        let model = modelID
        let succeeded = await mutate(reloadAfter: false) { [weak self] gateway in
            let (_, plan) = try await gateway.reorder(GatewayReorderRequest(model: model, order: ids, dryRun: true))
            if let reason = plan.rejected {
                throw ModelDetailError.orderRejected(Self.serverText(reason, key: gateway.managementKey))
            }
            if plan.hasSideEffects {
                self?.pendingOrder = ids
                self?.pendingPlan = plan
                return
            }
            try await Self.commit(model: model, order: ids, with: gateway)
            committed = true
        }
        isReordering = false
        if !succeeded {
            providers = original
        } else if committed {
            await reload()
        }
    }

    /// Applies the pending order (the same order the dry run checked).
    func confirmPendingPlan() async {
        guard let order = pendingOrder, pendingPlan != nil, !isMutating else { return }
        let original = serverProviders
        pendingPlan = nil
        pendingOrder = nil
        isReordering = true
        let model = modelID
        let succeeded = await mutate(reloadAfter: false) { gateway in
            try await Self.commit(model: model, order: order, with: gateway)
        }
        isReordering = false
        if succeeded {
            await reload()
        } else {
            providers = original
        }
    }

    /// Drops the pending order and shows the server's order again.
    func discardPendingPlan() {
        pendingPlan = nil
        pendingOrder = nil
        providers = serverProviders
    }

    private static func commit(model: String, order: [String], with gateway: GatewayAdminClient) async throws {
        let (status, plan) = try await gateway.reorder(GatewayReorderRequest(model: model, order: order))
        if status == 409 || plan.rejected != nil || plan.ok == false {
            let reason = plan.rejected ?? OasesLocalization.localized("网关拒绝了这个顺序，请刷新后再试。")
            throw ModelDetailError.orderRejected(serverText(reason, key: gateway.managementKey))
        }
    }

    /// Server text as shown: internal model ids reduced to public names, secrets and key shapes
    /// masked, length limited.
    static func serverText(_ text: String, key: String) -> String {
        GatewayAdminError.sanitized(InternalModelID.publicText(text), secrets: [key])
    }

    /// The affected models of a plan as shown (public names, each once).
    static func displayModels(_ models: [String]) -> [String] {
        InternalModelID.publicNames(models)
    }

    // MARK: - Single provider test

    /// One real upstream request through `provider` only.
    func testProvider(_ name: String) async {
        let model = modelID
        await mutate(reloadAfter: false) { [weak self] gateway in
            let response = try await gateway.testModel(model, provider: name)
            self?.providerTests[name] = response.result
        }
    }
}
