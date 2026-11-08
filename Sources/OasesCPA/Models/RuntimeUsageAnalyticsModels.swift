import Foundation

enum RuntimeUsageAnalyticsTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case trends
    case modelRanks
    case apiKeyRanks
    case credentialRanks
    case heatmap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: OasesLocalization.localized("总览")
        case .trends: OasesLocalization.localized("趋势分析")
        case .modelRanks: OasesLocalization.localized("模型分析")
        case .apiKeyRanks: OasesLocalization.localized("客户端 Key 分析")
        case .credentialRanks: OasesLocalization.localized("凭证分析")
        case .heatmap: OasesLocalization.localized("用量热力图")
        }
    }
}

enum RuntimeUsageAnalyticsRange: Equatable, Sendable {
    case recentHour
    case today
    case yesterday
    case last7Days
    case last30Days
    case custom(from: Date, to: Date)

    var presetTitle: String? {
        switch self {
        case .recentHour: OasesLocalization.localized("最近 1 小时")
        case .today: OasesLocalization.localized("今天")
        case .yesterday: OasesLocalization.localized("昨天")
        case .last7Days: OasesLocalization.localized("最近 7 天")
        case .last30Days: OasesLocalization.localized("最近 30 天")
        case .custom: nil
        }
    }

    func bounds(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        switch self {
        case .recentHour:
            return (now.addingTimeInterval(-60 * 60), now)
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return (yesterday, today)
        case .last7Days:
            return (now.addingTimeInterval(-7 * 24 * 60 * 60), now)
        case .last30Days:
            return (now.addingTimeInterval(-30 * 24 * 60 * 60), now)
        case let .custom(from, to):
            return (min(from, to), max(from, to))
        }
    }
}

enum RuntimeUsageAnalyticsGranularity: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case hour
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: OasesLocalization.localized("自动")
        case .hour: OasesLocalization.localized("按小时")
        case .day: OasesLocalization.localized("按天")
        }
    }
}

enum RuntimeUsageAnalyticsStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case success
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: OasesLocalization.localized("全部状态")
        case .success: OasesLocalization.localized("仅成功")
        case .failed: OasesLocalization.localized("仅失败")
        }
    }
}

enum RuntimeUsageAnalyticsCacheStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = ""
    case hit = "hit"
    case miss = "miss"

    var id: String { rawValue.isEmpty ? "all" : rawValue }

    var title: String {
        switch self {
        case .all: OasesLocalization.localized("全部缓存状态")
        case .hit: OasesLocalization.localized("缓存命中")
        case .miss: OasesLocalization.localized("未命中缓存")
        }
    }
}

struct RuntimeUsageAnalyticsRequest: Codable, Equatable, Sendable {
    let fromMs: Int64
    let toMs: Int64
    let nowMs: Int64
    let timeZone: String
    let searchQuery: String?
    let searchAPIKeyHash: String?
    let filters: Filters
    let include: Include

    init(
        tab: RuntimeUsageAnalyticsTab,
        range: RuntimeUsageAnalyticsRange = .today,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        granularity: RuntimeUsageAnalyticsGranularity = .auto,
        searchQuery: String = "",
        searchAPIKeyHash: String? = nil,
        models: [String] = [],
        providers: [String] = [],
        accounts: [String] = [],
        credentialIDs: [String] = [],
        authFiles: [String] = [],
        apiKeyHashes: [String] = [],
        includeFailed: RuntimeUsageAnalyticsStatusFilter = .all,
        minimumLatencyMS: Int64 = 0,
        cacheStatus: RuntimeUsageAnalyticsCacheStatus = .all
    ) {
        let bounds = range.bounds(now: now, calendar: Self.calendar(for: timeZone))
        let from = Int64(bounds.from.timeIntervalSince1970 * 1_000)
        let to = max(from + 1, Int64(bounds.to.timeIntervalSince1970 * 1_000))
        var include = Include.forTab(tab, granularity: granularity)
        if include.drilldownPreview != nil {
            include.drilldownPreview = DrilldownPreview(fromMs: from, toMs: to, limit: 8)
        }

        self.init(
            fromMs: from,
            toMs: to,
            nowMs: Int64(now.timeIntervalSince1970 * 1_000),
            timeZone: timeZone.identifier,
            searchQuery: Self.normalized(searchQuery),
            searchAPIKeyHash: Self.normalized(searchAPIKeyHash),
            filters: Filters(
                models: Self.normalizedList(models),
                providers: Self.normalizedList(providers),
                accounts: Self.normalizedList(accounts),
                credentialIDs: Self.normalizedList(credentialIDs),
                authFiles: Self.normalizedList(authFiles),
                apiKeyHashes: Self.normalizedList(apiKeyHashes),
                includeFailed: includeFailed == .all ? nil : includeFailed == .success,
                failedOnly: includeFailed == .failed,
                minimumLatencyMS: max(0, minimumLatencyMS),
                cacheStatus: cacheStatus.rawValue
            ),
            include: include
        )
    }

    init(
        fromMs: Int64,
        toMs: Int64,
        nowMs: Int64 = 0,
        timeZone: String = TimeZone.current.identifier,
        searchQuery: String? = nil,
        searchAPIKeyHash: String? = nil,
        filters: Filters = Filters(),
        include: Include
    ) {
        self.fromMs = fromMs
        self.toMs = toMs
        self.nowMs = nowMs
        self.timeZone = timeZone
        self.searchQuery = Self.normalized(searchQuery)
        self.searchAPIKeyHash = Self.normalized(searchAPIKeyHash)
        self.filters = filters
        self.include = include
    }

    private enum CodingKeys: String, CodingKey {
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case nowMs = "now_ms"
        case timeZone = "time_zone"
        case searchQuery = "search_query"
        case searchAPIKeyHash = "search_api_key_hash"
        case filters
        case include
    }

    static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalized))).sorted()
    }

    struct Filters: Codable, Equatable, Sendable {
        var models: [String] = []
        var providers: [String] = []
        var accounts: [String] = []
        var credentialIDs: [String] = []
        var authFiles: [String] = []
        var apiKeyHashes: [String] = []
        var includeFailed: Bool? = nil
        var failedOnly = false
        var minimumLatencyMS: Int64 = 0
        var cacheStatus = ""

        private enum CodingKeys: String, CodingKey {
            case models
            case providers
            case accounts
            case credentialIDs = "credential_ids"
            case authFiles = "auth_files"
            case apiKeyHashes = "api_key_hashes"
            case includeFailed = "include_failed"
            case failedOnly = "failed_only"
            case minimumLatencyMS = "min_latency_ms"
            case cacheStatus = "cache_status"
        }
    }

    struct Include: Codable, Equatable, Sendable {
        var summary = false
        var summaryProfile: String? = nil
        var summaryPercentiles = false
        var summaryComparison = false
        var timeline = false
        var modelStats = false
        var credentialStats = false
        var credentialTimeline = false
        var apiKeyTimeline = false
        var apiKeyStats = false
        var filterOptions = false
        var filterSelectors = false
        var heatmap = false
        var anomalyPoints = false
        var recentFailures = 0
        var drilldownPreview: DrilldownPreview? = nil
        var granularity = "auto"

        private enum CodingKeys: String, CodingKey {
            case summary
            case summaryProfile = "summary_profile"
            case summaryPercentiles = "summary_percentiles"
            case summaryComparison = "summary_comparison"
            case timeline
            case modelStats = "model_stats"
            case credentialStats = "credential_stats"
            case credentialTimeline = "credential_timeline"
            case apiKeyTimeline = "api_key_timeline"
            case apiKeyStats = "api_key_stats"
            case filterOptions = "filter_options"
            case filterSelectors = "filter_selectors"
            case heatmap
            case anomalyPoints = "anomaly_points"
            case recentFailures = "recent_failures"
            case drilldownPreview = "drilldown_preview"
            case granularity
        }

        static func forTab(
            _ tab: RuntimeUsageAnalyticsTab,
            granularity: RuntimeUsageAnalyticsGranularity
        ) -> Self {
            var value = Self()
            value.summary = true
            value.summaryComparison = true
            value.filterOptions = true
            value.granularity = granularity.rawValue

            switch tab {
            case .overview:
                value.timeline = true
                value.modelStats = true
                value.anomalyPoints = true
                value.recentFailures = 5
                value.drilldownPreview = DrilldownPreview(limit: 8)
            case .trends:
                value.timeline = true
                value.anomalyPoints = true
                value.drilldownPreview = DrilldownPreview(limit: 8)
            case .modelRanks:
                value.modelStats = true
            case .apiKeyRanks:
                value.apiKeyStats = true
                value.apiKeyTimeline = true
            case .credentialRanks:
                value.credentialStats = true
                value.credentialTimeline = true
            case .heatmap:
                value.heatmap = true
            }
            return value
        }
    }

    struct DrilldownPreview: Codable, Equatable, Sendable {
        var fromMs: Int64? = nil
        var toMs: Int64? = nil
        var limit = 20

        init(fromMs: Int64? = nil, toMs: Int64? = nil, limit: Int = 20) {
            self.fromMs = fromMs
            self.toMs = toMs
            self.limit = min(max(limit, 1), 100)
        }

        private enum CodingKeys: String, CodingKey {
            case fromMs = "from_ms"
            case toMs = "to_ms"
            case limit
        }
    }
}

struct RuntimeUsageAnalyticsResponse: Codable, Equatable, Sendable {
    let generatedAtMs: Int64
    let granularity: String
    let summary: RuntimeUsageAnalyticsSummary?
    let summaryComparison: RuntimeUsageAnalyticsSummaryComparison?
    let timeline: [RuntimeUsageAnalyticsTimelinePoint]
    let modelStats: [RuntimeUsageAnalyticsModelStat]
    let apiKeyStats: [RuntimeUsageAnalyticsAPIKeyStat]
    let credentialStats: [RuntimeUsageAnalyticsCredentialStat]
    let apiKeyTimeline: [RuntimeUsageAnalyticsAPIKeyTimelinePoint]
    let credentialTimeline: [RuntimeUsageAnalyticsCredentialTimelinePoint]
    let filterOptions: RuntimeUsageAnalyticsFilterOptions?
    let heatmap: [RuntimeUsageAnalyticsHeatmapPoint]
    let anomalyPoints: [RuntimeUsageAnalyticsAnomalyPoint]
    let drilldownPreview: RuntimeUsageAnalyticsEventsResponse?
    let recentFailures: [RuntimeUsageAnalyticsFailure]

    init(
        generatedAtMs: Int64,
        granularity: String,
        summary: RuntimeUsageAnalyticsSummary? = nil,
        summaryComparison: RuntimeUsageAnalyticsSummaryComparison? = nil,
        timeline: [RuntimeUsageAnalyticsTimelinePoint] = [],
        modelStats: [RuntimeUsageAnalyticsModelStat] = [],
        apiKeyStats: [RuntimeUsageAnalyticsAPIKeyStat] = [],
        credentialStats: [RuntimeUsageAnalyticsCredentialStat] = [],
        apiKeyTimeline: [RuntimeUsageAnalyticsAPIKeyTimelinePoint] = [],
        credentialTimeline: [RuntimeUsageAnalyticsCredentialTimelinePoint] = [],
        filterOptions: RuntimeUsageAnalyticsFilterOptions? = nil,
        heatmap: [RuntimeUsageAnalyticsHeatmapPoint] = [],
        anomalyPoints: [RuntimeUsageAnalyticsAnomalyPoint] = [],
        drilldownPreview: RuntimeUsageAnalyticsEventsResponse? = nil,
        recentFailures: [RuntimeUsageAnalyticsFailure] = []
    ) {
        self.generatedAtMs = generatedAtMs
        self.granularity = granularity
        self.summary = summary
        self.summaryComparison = summaryComparison
        self.timeline = timeline
        self.modelStats = modelStats
        self.apiKeyStats = apiKeyStats
        self.credentialStats = credentialStats
        self.apiKeyTimeline = apiKeyTimeline
        self.credentialTimeline = credentialTimeline
        self.filterOptions = filterOptions
        self.heatmap = heatmap
        self.anomalyPoints = anomalyPoints
        self.drilldownPreview = drilldownPreview
        self.recentFailures = recentFailures
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAtMs = "generated_at_ms"
        case granularity
        case summary
        case summaryComparison = "summary_comparison"
        case timeline
        case modelStats = "model_stats"
        case apiKeyStats = "api_key_stats"
        case credentialStats = "credential_stats"
        case apiKeyTimeline = "api_key_timeline"
        case credentialTimeline = "credential_timeline"
        case filterOptions = "filter_options"
        case heatmap
        case anomalyPoints = "anomaly_points"
        case drilldownPreview = "drilldown_preview"
        case recentFailures = "recent_failures"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .generatedAtMs) ?? 0
        granularity = try container.decodeIfPresent(String.self, forKey: .granularity) ?? "auto"
        summary = try container.decodeIfPresent(RuntimeUsageAnalyticsSummary.self, forKey: .summary)
        summaryComparison = try container.decodeIfPresent(RuntimeUsageAnalyticsSummaryComparison.self, forKey: .summaryComparison)
        timeline = try container.decodeIfPresent([RuntimeUsageAnalyticsTimelinePoint].self, forKey: .timeline) ?? []
        modelStats = try container.decodeIfPresent([RuntimeUsageAnalyticsModelStat].self, forKey: .modelStats) ?? []
        apiKeyStats = try container.decodeIfPresent([RuntimeUsageAnalyticsAPIKeyStat].self, forKey: .apiKeyStats) ?? []
        credentialStats = try container.decodeIfPresent([RuntimeUsageAnalyticsCredentialStat].self, forKey: .credentialStats) ?? []
        apiKeyTimeline = try container.decodeIfPresent([RuntimeUsageAnalyticsAPIKeyTimelinePoint].self, forKey: .apiKeyTimeline) ?? []
        credentialTimeline = try container.decodeIfPresent([RuntimeUsageAnalyticsCredentialTimelinePoint].self, forKey: .credentialTimeline) ?? []
        filterOptions = try container.decodeIfPresent(RuntimeUsageAnalyticsFilterOptions.self, forKey: .filterOptions)
        heatmap = try container.decodeIfPresent([RuntimeUsageAnalyticsHeatmapPoint].self, forKey: .heatmap) ?? []
        anomalyPoints = try container.decodeIfPresent([RuntimeUsageAnalyticsAnomalyPoint].self, forKey: .anomalyPoints) ?? []
        drilldownPreview = try container.decodeIfPresent(RuntimeUsageAnalyticsEventsResponse.self, forKey: .drilldownPreview)
        recentFailures = try container.decodeIfPresent([RuntimeUsageAnalyticsFailure].self, forKey: .recentFailures) ?? []
    }
}

struct RuntimeUsageAnalyticsSummary: Codable, Equatable, Sendable {
    let totalCalls: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let successRate: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let cacheHitRate: Double
    let reasoningTokens: Int64
    let totalTokens: Int64
    let totalCost: Double
    let averageCostPerCall: Double
    let averageLatencyMS: Double?
    let p95LatencyMS: Double?
    let p95TTFTMS: Double?
    let zeroTokenCalls: Int64
    let rpm30M: Double
    let tpm30M: Double
    let avgDailyRequests: Double
    let avgDailyTokens: Double
    let approxTasks: Int64
    let approxTaskFailures: Int64
    let approxTaskSuccessRate: Double
    let zeroTokenModels: [String]

    private enum CodingKeys: String, CodingKey {
        case totalCalls = "total_calls"
        case successCalls = "success_calls"
        case failureCalls = "failure_calls"
        case successRate = "success_rate"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheHitRate = "cache_hit_rate"
        case reasoningTokens = "reasoning_tokens"
        case totalTokens = "total_tokens"
        case totalCost = "total_cost"
        case averageCostPerCall = "average_cost_per_call"
        case averageLatencyMS = "average_latency_ms"
        case p95LatencyMS = "p95_latency_ms"
        case p95TTFTMS = "p95_ttft_ms"
        case zeroTokenCalls = "zero_token_calls"
        case rpm30M = "rpm_30m"
        case tpm30M = "tpm_30m"
        case avgDailyRequests = "avg_daily_requests"
        case avgDailyTokens = "avg_daily_tokens"
        case approxTasks = "approx_tasks"
        case approxTaskFailures = "approx_task_failures"
        case approxTaskSuccessRate = "approx_task_success_rate"
        case zeroTokenModels = "zero_token_models"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCalls = try container.decodeIfPresent(Int64.self, forKey: .totalCalls) ?? 0
        successCalls = try container.decodeIfPresent(Int64.self, forKey: .successCalls) ?? 0
        failureCalls = try container.decodeIfPresent(Int64.self, forKey: .failureCalls) ?? 0
        successRate = try container.decodeIfPresent(Double.self, forKey: .successRate) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int64.self, forKey: .cachedTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationTokens) ?? 0
        cacheHitRate = try container.decodeIfPresent(Double.self, forKey: .cacheHitRate) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int64.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        averageCostPerCall = try container.decodeIfPresent(Double.self, forKey: .averageCostPerCall) ?? 0
        averageLatencyMS = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMS)
        p95LatencyMS = try container.decodeIfPresent(Double.self, forKey: .p95LatencyMS)
        p95TTFTMS = try container.decodeIfPresent(Double.self, forKey: .p95TTFTMS)
        zeroTokenCalls = try container.decodeIfPresent(Int64.self, forKey: .zeroTokenCalls) ?? 0
        rpm30M = try container.decodeIfPresent(Double.self, forKey: .rpm30M) ?? 0
        tpm30M = try container.decodeIfPresent(Double.self, forKey: .tpm30M) ?? 0
        avgDailyRequests = try container.decodeIfPresent(Double.self, forKey: .avgDailyRequests) ?? 0
        avgDailyTokens = try container.decodeIfPresent(Double.self, forKey: .avgDailyTokens) ?? 0
        approxTasks = try container.decodeIfPresent(Int64.self, forKey: .approxTasks) ?? 0
        approxTaskFailures = try container.decodeIfPresent(Int64.self, forKey: .approxTaskFailures) ?? 0
        approxTaskSuccessRate = try container.decodeIfPresent(Double.self, forKey: .approxTaskSuccessRate) ?? 0
        zeroTokenModels = try container.decodeIfPresent([String].self, forKey: .zeroTokenModels) ?? []
    }
}

struct RuntimeUsageAnalyticsSummaryComparison: Codable, Equatable, Sendable {
    let fromMs: Int64
    let toMs: Int64
    let totalCalls: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let successRate: Double
    let totalTokens: Int64
    let totalCost: Double

    private enum CodingKeys: String, CodingKey {
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case totalCalls = "total_calls"
        case successCalls = "success_calls"
        case failureCalls = "failure_calls"
        case successRate = "success_rate"
        case totalTokens = "total_tokens"
        case totalCost = "total_cost"
    }
}

struct RuntimeUsageAnalyticsTimelinePoint: Codable, Equatable, Identifiable, Sendable {
    let bucketMs: Int64
    let label: String
    let calls: Int64
    let tokens: Int64
    let success: Int64
    let failure: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedTokens: Int64
    let totalTokens: Int64
    let cost: Double
    let averageLatencyMS: Double?
    let p95LatencyMS: Double?
    let successRate: Double
    let failureRate: Double

    var id: Int64 { bucketMs }

    private enum CodingKeys: String, CodingKey {
        case bucketMs = "bucket_ms"
        case label
        case calls
        case tokens
        case success
        case failure
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
        case totalTokens = "total_tokens"
        case cost
        case averageLatencyMS = "average_latency_ms"
        case p95LatencyMS = "p95_latency_ms"
        case successRate = "success_rate"
        case failureRate = "failure_rate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketMs = try container.decode(Int64.self, forKey: .bucketMs)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        tokens = try container.decodeIfPresent(Int64.self, forKey: .tokens) ?? 0
        success = try container.decodeIfPresent(Int64.self, forKey: .success) ?? 0
        failure = try container.decodeIfPresent(Int64.self, forKey: .failure) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int64.self, forKey: .cachedTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? tokens
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        averageLatencyMS = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMS)
        p95LatencyMS = try container.decodeIfPresent(Double.self, forKey: .p95LatencyMS)
        successRate = try container.decodeIfPresent(Double.self, forKey: .successRate)
            ?? (calls > 0 ? Double(success) / Double(calls) : 0)
        failureRate = try container.decodeIfPresent(Double.self, forKey: .failureRate)
            ?? (calls > 0 ? Double(failure) / Double(calls) : 0)
    }
}

struct RuntimeUsageAnalyticsModelStat: Codable, Equatable, Identifiable, Sendable {
    let model: String
    let calls: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let successRate: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedTokens: Int64
    let totalTokens: Int64
    let cost: Double

    var id: String { model }

    private enum CodingKeys: String, CodingKey {
        case model
        case calls
        case successCalls = "success_calls"
        case failureCalls = "failure_calls"
        case successRate = "success_rate"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
        case totalTokens = "total_tokens"
        case cost
    }
}

struct RuntimeUsageAnalyticsAPIKeyStat: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let apiKeyHash: String
    let accountSnapshot: String
    let authLabelSnapshot: String
    let authProviderSnapshot: String
    let calls: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let successRate: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let totalTokens: Int64
    let cost: Double
    let averageLatencyMS: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case apiKeyHash = "api_key_hash"
        case accountSnapshot = "account_snapshot"
        case authLabelSnapshot = "auth_label_snapshot"
        case authProviderSnapshot = "auth_provider_snapshot"
        case calls
        case successCalls = "success_calls"
        case failureCalls = "failure_calls"
        case successRate = "success_rate"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case cost
        case averageLatencyMS = "average_latency_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        apiKeyHash = try container.decodeIfPresent(String.self, forKey: .apiKeyHash) ?? ""
        accountSnapshot = try container.decodeIfPresent(String.self, forKey: .accountSnapshot) ?? ""
        authLabelSnapshot = try container.decodeIfPresent(String.self, forKey: .authLabelSnapshot) ?? ""
        authProviderSnapshot = try container.decodeIfPresent(String.self, forKey: .authProviderSnapshot) ?? ""
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        successCalls = try container.decodeIfPresent(Int64.self, forKey: .successCalls) ?? 0
        failureCalls = try container.decodeIfPresent(Int64.self, forKey: .failureCalls) ?? 0
        successRate = try container.decodeIfPresent(Double.self, forKey: .successRate) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        averageLatencyMS = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMS)
    }
}

struct RuntimeUsageAnalyticsCredentialStat: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let authFileSnapshot: String
    let authIndex: String
    let source: String
    let accountSnapshot: String
    let authLabelSnapshot: String
    let authProviderSnapshot: String
    let calls: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let successRate: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let totalTokens: Int64
    let cost: Double
    let averageLatencyMS: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case authFileSnapshot = "auth_file_snapshot"
        case authIndex = "auth_index"
        case source
        case accountSnapshot = "account_snapshot"
        case authLabelSnapshot = "auth_label_snapshot"
        case authProviderSnapshot = "auth_provider_snapshot"
        case calls
        case successCalls = "success_calls"
        case failureCalls = "failure_calls"
        case successRate = "success_rate"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case cost
        case averageLatencyMS = "average_latency_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        authFileSnapshot = try container.decodeIfPresent(String.self, forKey: .authFileSnapshot) ?? ""
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        accountSnapshot = try container.decodeIfPresent(String.self, forKey: .accountSnapshot) ?? ""
        authLabelSnapshot = try container.decodeIfPresent(String.self, forKey: .authLabelSnapshot) ?? ""
        authProviderSnapshot = try container.decodeIfPresent(String.self, forKey: .authProviderSnapshot) ?? ""
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        successCalls = try container.decodeIfPresent(Int64.self, forKey: .successCalls) ?? 0
        failureCalls = try container.decodeIfPresent(Int64.self, forKey: .failureCalls) ?? 0
        successRate = try container.decodeIfPresent(Double.self, forKey: .successRate) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        averageLatencyMS = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMS)
    }
}

struct RuntimeUsageAnalyticsAPIKeyTimelinePoint: Codable, Equatable, Identifiable, Sendable {
    let apiKeyHash: String
    let bucketMs: Int64
    let bucketLabel: String
    let calls: Int64
    let tokens: Int64
    let success: Int64
    let failure: Int64
    let cost: Double

    var id: String { "\(apiKeyHash)-\(bucketMs)" }

    private enum CodingKeys: String, CodingKey {
        case apiKeyHash = "api_key_hash"
        case bucketMs = "bucket_ms"
        case bucketLabel = "bucket_label"
        case calls
        case tokens
        case success
        case failure
        case cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKeyHash = try container.decodeIfPresent(String.self, forKey: .apiKeyHash) ?? ""
        bucketMs = try container.decode(Int64.self, forKey: .bucketMs)
        bucketLabel = try container.decodeIfPresent(String.self, forKey: .bucketLabel) ?? ""
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        tokens = try container.decodeIfPresent(Int64.self, forKey: .tokens) ?? 0
        success = try container.decodeIfPresent(Int64.self, forKey: .success) ?? 0
        failure = try container.decodeIfPresent(Int64.self, forKey: .failure) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
    }
}

struct RuntimeUsageAnalyticsCredentialTimelinePoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let bucketMs: Int64
    let bucketLabel: String
    let calls: Int64
    let tokens: Int64
    let success: Int64
    let failure: Int64
    let cost: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case bucketMs = "bucket_ms"
        case bucketLabel = "bucket_label"
        case calls
        case tokens
        case success
        case failure
        case cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        bucketMs = try container.decode(Int64.self, forKey: .bucketMs)
        bucketLabel = try container.decodeIfPresent(String.self, forKey: .bucketLabel) ?? ""
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        tokens = try container.decodeIfPresent(Int64.self, forKey: .tokens) ?? 0
        success = try container.decodeIfPresent(Int64.self, forKey: .success) ?? 0
        failure = try container.decodeIfPresent(Int64.self, forKey: .failure) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
    }
}

struct RuntimeUsageAnalyticsFilterOptions: Codable, Equatable, Sendable {
    let models: [String]
    let apiKeyHashes: [String]
    let providers: [String]
    let authFiles: [String]
    let accounts: [String]
    let accountCount: Int
    let apiKeyCount: Int

    private enum CodingKeys: String, CodingKey {
        case models
        case apiKeyHashes = "api_key_hashes"
        case providers
        case authFiles = "auth_files"
        case accounts
        case accountCount = "account_count"
        case apiKeyCount = "api_key_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        apiKeyHashes = try container.decodeIfPresent([String].self, forKey: .apiKeyHashes) ?? []
        providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        authFiles = try container.decodeIfPresent([String].self, forKey: .authFiles) ?? []
        accounts = try container.decodeIfPresent([String].self, forKey: .accounts) ?? []
        accountCount = try container.decodeIfPresent(Int.self, forKey: .accountCount) ?? accounts.count
        apiKeyCount = try container.decodeIfPresent(Int.self, forKey: .apiKeyCount) ?? apiKeyHashes.count
    }
}

struct RuntimeUsageAnalyticsHeatmapPoint: Codable, Equatable, Identifiable, Sendable {
    let weekday: Int
    let hour: Int
    let calls: Int64
    let success: Int64
    let failure: Int64
    let tokens: Int64
    let cost: Double
    let failureRate: Double

    var id: String { "\(weekday)-\(hour)" }

    private enum CodingKeys: String, CodingKey {
        case weekday
        case hour
        case calls
        case success
        case failure
        case tokens
        case cost
        case failureRate = "failure_rate"
    }
}

struct RuntimeUsageAnalyticsAnomalyPoint: Codable, Equatable, Identifiable, Sendable {
    let bucketMs: Int64
    let bucketEndMs: Int64
    let label: String
    let severity: String
    let metricKeys: [String]
    let calls: Int64
    let totalTokens: Int64
    let cost: Double
    let failureRate: Double
    let requestChange: Double
    let costChange: Double
    let tokensPerRequestChange: Double
    let cacheHitRateChange: Double
    let failureRateChange: Double
    let latencyP95Change: Double

    var id: Int64 { bucketMs }

    private enum CodingKeys: String, CodingKey {
        case bucketMs = "bucket_ms"
        case bucketEndMs = "bucket_end_ms"
        case label
        case severity
        case metricKeys = "metric_keys"
        case calls
        case totalTokens = "total_tokens"
        case cost
        case failureRate = "failure_rate"
        case requestChange = "request_change"
        case costChange = "cost_change"
        case tokensPerRequestChange = "tokens_per_request_change"
        case cacheHitRateChange = "cache_hit_rate_change"
        case failureRateChange = "failure_rate_change"
        case latencyP95Change = "latency_p95_change"
    }
}

struct RuntimeUsageAnalyticsEventsResponse: Codable, Equatable, Sendable {
    let items: [RuntimeUsageAnalyticsEvent]
    let nextBeforeMs: Int64
    let nextBeforeId: Int64
    let hasMore: Bool
    let totalCount: Int64

    private enum CodingKeys: String, CodingKey {
        case items
        case nextBeforeMs = "next_before_ms"
        case nextBeforeId = "next_before_id"
        case hasMore = "has_more"
        case totalCount = "total_count"
    }

    init(
        items: [RuntimeUsageAnalyticsEvent],
        nextBeforeMs: Int64,
        nextBeforeId: Int64,
        hasMore: Bool,
        totalCount: Int64
    ) {
        self.items = items
        self.nextBeforeMs = nextBeforeMs
        self.nextBeforeId = nextBeforeId
        self.hasMore = hasMore
        self.totalCount = totalCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([RuntimeUsageAnalyticsEvent].self, forKey: .items) ?? []
        nextBeforeMs = try container.decodeIfPresent(Int64.self, forKey: .nextBeforeMs) ?? 0
        nextBeforeId = try container.decodeIfPresent(Int64.self, forKey: .nextBeforeId) ?? 0
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        totalCount = try container.decodeIfPresent(Int64.self, forKey: .totalCount) ?? Int64(items.count)
    }
}

struct RuntimeUsageAnalyticsFailure: Codable, Equatable, Identifiable, Sendable {
    let timestampMs: Int64
    let model: String
    let apiKeyHash: String
    let source: String
    let authIndex: String
    let endpoint: String
    let durationMs: Int64?
    let failStatusCode: Int64?
    let failSummary: String

    var id: String { "\(timestampMs)-\(model)-\(apiKeyHash)-\(endpoint)" }

    private enum CodingKeys: String, CodingKey {
        case timestampMs = "timestamp_ms"
        case model
        case apiKeyHash = "api_key_hash"
        case source
        case authIndex = "auth_index"
        case endpoint
        case durationMs = "duration_ms"
        case failStatusCode = "fail_status_code"
        case failSummary = "fail_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampMs = try container.decode(Int64.self, forKey: .timestampMs)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKeyHash = try container.decodeIfPresent(String.self, forKey: .apiKeyHash) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs)
        failStatusCode = try container.decodeIfPresent(Int64.self, forKey: .failStatusCode)
        failSummary = try container.decodeIfPresent(String.self, forKey: .failSummary) ?? ""
    }
}

struct RuntimeUsageAnalyticsEvent: Codable, Equatable, Identifiable, Sendable {
    let eventHash: String
    let timestampMs: Int64
    let model: String
    let endpoint: String
    let apiKeyHash: String
    let authIndex: String
    let authProviderSnapshot: String
    let totalTokens: Int64
    let latencyMs: Int64?
    let failed: Bool
    let failSummary: String

    var id: String { eventHash }

    private enum CodingKeys: String, CodingKey {
        case eventHash = "event_hash"
        case timestampMs = "timestamp_ms"
        case model
        case endpoint
        case apiKeyHash = "api_key_hash"
        case authIndex = "auth_index"
        case authProviderSnapshot = "auth_provider_snapshot"
        case totalTokens = "total_tokens"
        case latencyMs = "latency_ms"
        case failed
        case failSummary = "fail_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventHash = try container.decodeIfPresent(String.self, forKey: .eventHash) ?? UUID().uuidString
        timestampMs = try container.decodeIfPresent(Int64.self, forKey: .timestampMs) ?? 0
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        apiKeyHash = try container.decodeIfPresent(String.self, forKey: .apiKeyHash) ?? ""
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex) ?? ""
        authProviderSnapshot = try container.decodeIfPresent(String.self, forKey: .authProviderSnapshot) ?? ""
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        latencyMs = try container.decodeIfPresent(Int64.self, forKey: .latencyMs)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        failSummary = try container.decodeIfPresent(String.self, forKey: .failSummary) ?? ""
    }
}

enum RuntimeUsageAnalyticsPresentation {
    static func sortedModels(_ values: [RuntimeUsageAnalyticsModelStat]) -> [RuntimeUsageAnalyticsModelStat] {
        values.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }

    static func sortedAPIKeys(_ values: [RuntimeUsageAnalyticsAPIKeyStat]) -> [RuntimeUsageAnalyticsAPIKeyStat] {
        values.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    static func sortedCredentials(_ values: [RuntimeUsageAnalyticsCredentialStat]) -> [RuntimeUsageAnalyticsCredentialStat] {
        values.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    static func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

// MARK: - Public model names

extension RuntimeUsageAnalyticsResponse {
    /// Model statistics with internal `pin-x/…` ids folded into their public names (counts and
    /// cost add up; the success rate follows from the summed counts).
    var publicModelStats: [RuntimeUsageAnalyticsModelStat] {
        let renamed = modelStats.map { $0.renamed(InternalModelID.publicName($0.model)) }
        return InternalModelID.mergeByPublicName(renamed, name: \.model) { left, right in
            let calls = left.calls + right.calls
            let success = left.successCalls + right.successCalls
            return RuntimeUsageAnalyticsModelStat(
                model: left.model,
                calls: calls,
                successCalls: success,
                failureCalls: left.failureCalls + right.failureCalls,
                successRate: calls > 0 ? Double(success) / Double(calls) : 0,
                inputTokens: left.inputTokens + right.inputTokens,
                outputTokens: left.outputTokens + right.outputTokens,
                cachedTokens: left.cachedTokens + right.cachedTokens,
                totalTokens: left.totalTokens + right.totalTokens,
                cost: left.cost + right.cost
            )
        }
    }
}

extension RuntimeUsageAnalyticsModelStat {
    fileprivate func renamed(_ name: String) -> RuntimeUsageAnalyticsModelStat {
        RuntimeUsageAnalyticsModelStat(
            model: name, calls: calls, successCalls: successCalls, failureCalls: failureCalls,
            successRate: successRate, inputTokens: inputTokens, outputTokens: outputTokens,
            cachedTokens: cachedTokens, totalTokens: totalTokens, cost: cost
        )
    }
}

extension RuntimeUsageAnalyticsFailure {
    var displayModel: String { InternalModelID.publicName(model) }
    var displayFailSummary: String { InternalModelID.publicText(failSummary) }
}

extension RuntimeUsageAnalyticsEvent {
    var displayModel: String { InternalModelID.publicName(model) }
    var displayFailSummary: String { InternalModelID.publicText(failSummary) }
}

extension RuntimeUsageAnalyticsFilterOptions {
    /// The model filter's choices: public names without duplicates. A chosen name is expanded
    /// back to every raw name it stands for with `InternalModelID.rawNames(matching:in:)`.
    var publicModels: [String] { InternalModelID.publicNames(models) }
}
