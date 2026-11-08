import Foundation

/// The opaque keyset cursor returned by CPAMP's monitoring analytics endpoint.
/// Both fields are required: timestamps are not unique, so timestamp-only
/// pagination can skip events that were recorded in the same millisecond.
struct RuntimeMonitoringEventsCursor: Equatable, Sendable {
    let beforeMs: Int64
    let beforeId: Int64

    var isUsable: Bool {
        beforeMs > 0 && beforeId > 0
    }
}

/// A deliberately-small request for the native request-event stream. The
/// complete CPAMP analytics surface remains available as a compatibility
/// fallback; this request avoids requesting aggregates, metadata, or bodies
/// that the native event list does not need to render.
struct RuntimeMonitoringEventsRequest: Encodable, Sendable {
    static let pageSize = 50

    let fromMs: Int64
    let toMs: Int64
    let searchQuery: String?
    let filters: Filters
    let include: Include

    /// `filters` narrows the stream; its `failedOnly` is replaced by `failedOnly`.
    init(
        range: RuntimeDashboardRange,
        now: Date = Date(),
        searchQuery: String,
        failedOnly: Bool,
        filters: Filters = Filters(),
        cursor: RuntimeMonitoringEventsCursor? = nil,
        limit: Int = Self.pageSize
    ) {
        let calendar = Calendar(identifier: .gregorian)
        let start = range.startDate(relativeTo: now, calendar: calendar)
        let rangeStartMs = Int64(start.timeIntervalSince1970 * 1_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        var filters = filters
        filters.failedOnly = failedOnly

        self.init(
            fromMs: rangeStartMs,
            toMs: max(rangeStartMs + 1, nowMs),
            searchQuery: Self.normalizedSearchQuery(searchQuery),
            filters: filters,
            cursor: cursor,
            limit: limit
        )
    }

    func nextPage(after cursor: RuntimeMonitoringEventsCursor) -> Self {
        Self(
            fromMs: fromMs,
            toMs: toMs,
            searchQuery: searchQuery,
            filters: filters,
            cursor: cursor,
            limit: include.eventsPage.limit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case searchQuery = "search_query"
        case filters
        case include
    }

    /// The filters of CPA Manager Plus's analytics request (`monitoring/service.go`, `Filters`).
    /// Empty lists, a zero latency and an empty cache status are not encoded; `failed_only` always is.
    struct Filters: Encodable, Equatable, Sendable {
        var models: [String] = []
        var providers: [String] = []
        var accounts: [String] = []
        var apiKeyHashes: [String] = []
        var requestTypes: [String] = []
        var headerErrorKinds: [String] = []
        var failedOnly = false
        var minLatencyMS: Int64 = 0
        var cacheStatus: String?

        private enum CodingKeys: String, CodingKey {
            case models
            case providers
            case accounts
            case apiKeyHashes = "api_key_hashes"
            case requestTypes = "request_types"
            case headerErrorKinds = "header_error_kinds"
            case failedOnly = "failed_only"
            case minLatencyMS = "min_latency_ms"
            case cacheStatus = "cache_status"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            for (key, values) in [(CodingKeys.models, models), (.providers, providers), (.accounts, accounts),
                                  (.apiKeyHashes, apiKeyHashes), (.requestTypes, requestTypes),
                                  (.headerErrorKinds, headerErrorKinds)] where !values.isEmpty {
                try container.encode(values, forKey: key)
            }
            try container.encode(failedOnly, forKey: .failedOnly)
            if minLatencyMS > 0 {
                try container.encode(minLatencyMS, forKey: .minLatencyMS)
            }
            if let cacheStatus, !cacheStatus.isEmpty {
                try container.encode(cacheStatus, forKey: .cacheStatus)
            }
        }
    }

    struct Include: Encodable, Sendable {
        let eventsPage: EventsPage

        private enum CodingKeys: String, CodingKey {
            case eventsPage = "events_page"
        }
    }

    struct EventsPage: Encodable, Sendable {
        let limit: Int
        let beforeMs: Int64?
        let beforeId: Int64?

        private enum CodingKeys: String, CodingKey {
            case limit
            case beforeMs = "before_ms"
            case beforeId = "before_id"
        }
    }

    private static func normalizedSearchQuery(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A native text field cannot submit newlines, and bounding the query
        // keeps an accidental paste from turning a read-only filter into a
        // disproportionately expensive server request.
        return String(trimmed.prefix(256))
    }

    private init(
        fromMs: Int64,
        toMs: Int64,
        searchQuery: String?,
        filters: Filters,
        cursor: RuntimeMonitoringEventsCursor?,
        limit: Int
    ) {
        self.fromMs = fromMs
        self.toMs = toMs
        self.searchQuery = searchQuery
        self.filters = filters
        include = Include(
            eventsPage: EventsPage(
                limit: max(1, limit),
                beforeMs: cursor?.beforeMs,
                beforeId: cursor?.beforeId
            )
        )
    }
}

/// CPAMP returns an analytics envelope. It is decoded as raw JSON so a target
/// running a nearby server version can safely add fields or use either
/// snake_case or camelCase without breaking the event workspace.
struct RuntimeMonitoringEventsAnalyticsResponse: Decodable, Sendable {
    let events: RuntimeMonitoringEventsPage?

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        events = RuntimeMonitoringEventsPage(
            value: root["events"] ?? root["Events"]
        )
    }
}

struct RuntimeMonitoringEventsPage: Sendable {
    let items: [RuntimeMonitoringEvent]
    let nextCursor: RuntimeMonitoringEventsCursor?
    let hasMore: Bool
    let totalCount: Int64

    init?(value: RuntimeJSONValue?) {
        guard case .some(.object(let values)) = value else { return nil }

        if case .some(.array(let rawItems)) = Self.value(in: values, keys: ["items"]) {
            items = rawItems.compactMap(RuntimeMonitoringEvent.init(value:))
        } else {
            items = []
        }

        let nextBeforeMs = Self.integer(
            Self.value(in: values, keys: ["next_before_ms", "nextBeforeMs"])
        )
        let nextBeforeId = Self.integer(
            Self.value(in: values, keys: ["next_before_id", "nextBeforeId"])
        )
        let cursor = RuntimeMonitoringEventsCursor(
            beforeMs: nextBeforeMs,
            beforeId: nextBeforeId
        )
        nextCursor = cursor.isUsable ? cursor : nil
        hasMore = Self.bool(Self.value(in: values, keys: ["has_more", "hasMore"]))
        totalCount = max(
            0,
            Self.integer(Self.value(in: values, keys: ["total_count", "totalCount"]))
        )
    }

    private static func value(
        in values: [String: RuntimeJSONValue],
        keys: [String]
    ) -> RuntimeJSONValue? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int64 {
        switch value {
        case .some(.number(let number)) where number.isFinite:
            return safeInteger(number) ?? 0
        case .some(.string(let value)):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    private static func safeInteger(_ number: Double) -> Int64? {
        let rounded = number.rounded(.towardZero)
        let lowerBound = -9_223_372_036_854_775_808.0
        let upperBound = 9_223_372_036_854_775_808.0
        guard rounded >= lowerBound, rounded < upperBound else { return nil }
        return Int64(rounded)
    }

    private static func bool(_ value: RuntimeJSONValue?) -> Bool {
        switch value {
        case .some(.boolean(let value)):
            return value
        case .some(.number(let value)):
            return value != 0
        case .some(.string(let value)):
            return ["1", "true", "yes"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        default:
            return false
        }
    }
}

/// Known-safe, display-oriented fields of one CPAMP request event, plus every field the
/// server sent as `rawFields` (credential-bearing keys dropped, values redacted, internal
/// model heads removed) for the event detail's raw section.
struct RuntimeMonitoringEvent: Identifiable, Equatable, Sendable {
    /// One field of the event as CPA Manager Plus sent it; nested objects are flattened to
    /// dotted keys (`response_headers.x-request-id`).
    struct RawField: Identifiable, Equatable, Sendable {
        let key: String
        let value: String
        var id: String { key }
    }

    let eventHash: String
    let requestId: String
    let timestampMs: Int64
    let model: String
    let resolvedModel: String
    let endpoint: String
    let method: String
    let path: String
    let authIndex: String
    let source: String
    let sourceHash: String
    let apiKeyHash: String
    let accountSnapshot: String
    let authLabelSnapshot: String
    let authFileSnapshot: String
    let authProviderSnapshot: String
    let authProjectIdSnapshot: String
    let reasoningEffort: String
    let serviceTier: String
    let executorType: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64
    let latencyMs: Int64?
    let ttftMs: Int64?
    let failed: Bool
    let failStatusCode: Int64?
    let failSummary: String
    let headerQuotaRecoverAtMs: Int64?
    let headerQuotaUsedPercent: Double?
    let headerQuotaPlanType: String
    let headerErrorKind: String
    let headerErrorCode: String
    let headerTraceId: String
    let rawFields: [RawField]

    var id: String { eventHash }

    /// The requested model as shown: internal `pin-x/…` heads removed.
    var displayModel: String { InternalModelID.publicName(model) }
    /// The model the engine resolved, as shown.
    var displayResolvedModel: String { InternalModelID.publicName(resolvedModel) }
    var displayFailSummary: String { InternalModelID.publicText(failSummary) }

    init?(value: RuntimeJSONValue) {
        guard case .object(let values) = value else { return nil }
        let eventHash = Self.string(
            Self.value(in: values, keys: ["event_hash", "eventHash"])
        )
        guard !eventHash.isEmpty else { return nil }

        self.eventHash = eventHash
        requestId = Self.string(Self.value(in: values, keys: ["request_id", "requestId"]))
        timestampMs = Self.integer(Self.value(in: values, keys: ["timestamp_ms", "timestampMs"]))
        model = Self.string(Self.value(in: values, keys: ["model"]))
        resolvedModel = Self.string(Self.value(in: values, keys: ["resolved_model", "resolvedModel"]))
        endpoint = Self.string(Self.value(in: values, keys: ["endpoint"]))
        method = Self.string(Self.value(in: values, keys: ["method"]))
        path = Self.string(Self.value(in: values, keys: ["path"]))
        authIndex = Self.string(Self.value(in: values, keys: ["auth_index", "authIndex"]))
        source = Self.string(Self.value(in: values, keys: ["source"]))
        sourceHash = Self.string(Self.value(in: values, keys: ["source_hash", "sourceHash"]))
        apiKeyHash = Self.string(Self.value(in: values, keys: ["api_key_hash", "apiKeyHash"]))
        accountSnapshot = Self.string(
            Self.value(in: values, keys: ["account_snapshot", "accountSnapshot"])
        )
        authLabelSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_label_snapshot", "authLabelSnapshot"])
        )
        authFileSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_file_snapshot", "authFileSnapshot"])
        )
        authProviderSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_provider_snapshot", "authProviderSnapshot"])
        )
        authProjectIdSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_project_id_snapshot", "authProjectIdSnapshot"])
        )
        reasoningEffort = Self.string(
            Self.value(in: values, keys: ["reasoning_effort", "reasoningEffort"])
        )
        serviceTier = Self.string(Self.value(in: values, keys: ["service_tier", "serviceTier"]))
        executorType = Self.string(Self.value(in: values, keys: ["executor_type", "executorType"]))
        inputTokens = Self.integer(Self.value(in: values, keys: ["input_tokens", "inputTokens"]))
        outputTokens = Self.integer(Self.value(in: values, keys: ["output_tokens", "outputTokens"]))
        cachedTokens = Self.integer(Self.value(in: values, keys: ["cached_tokens", "cachedTokens"]))
        cacheReadTokens = Self.integer(
            Self.value(in: values, keys: ["cache_read_tokens", "cacheReadTokens"])
        )
        cacheCreationTokens = Self.integer(
            Self.value(in: values, keys: ["cache_creation_tokens", "cacheCreationTokens"])
        )
        reasoningTokens = Self.integer(
            Self.value(in: values, keys: ["reasoning_tokens", "reasoningTokens"])
        )
        totalTokens = Self.integer(Self.value(in: values, keys: ["total_tokens", "totalTokens"]))
        latencyMs = Self.optionalInteger(Self.value(in: values, keys: ["latency_ms", "latencyMs"]))
        ttftMs = Self.optionalInteger(Self.value(in: values, keys: ["ttft_ms", "ttftMs"]))
        failed = Self.bool(Self.value(in: values, keys: ["failed"]))
        failStatusCode = Self.optionalInteger(
            Self.value(in: values, keys: ["fail_status_code", "failStatusCode"])
        )
        failSummary = Self.string(Self.value(in: values, keys: ["fail_summary", "failSummary"]))
        headerQuotaRecoverAtMs = Self.optionalInteger(
            Self.value(
                in: values,
                keys: ["header_quota_recover_at_ms", "headerQuotaRecoverAtMs"]
            )
        )
        headerQuotaUsedPercent = Self.optionalDouble(
            Self.value(
                in: values,
                keys: ["header_quota_used_percent", "headerQuotaUsedPercent"]
            )
        )
        headerQuotaPlanType = Self.string(
            Self.value(in: values, keys: ["header_quota_plan_type", "headerQuotaPlanType"])
        )
        headerErrorKind = Self.string(
            Self.value(in: values, keys: ["header_error_kind", "headerErrorKind"])
        )
        headerErrorCode = Self.string(
            Self.value(in: values, keys: ["header_error_code", "headerErrorCode"])
        )
        headerTraceId = Self.string(
            Self.value(in: values, keys: ["header_trace_id", "headerTraceId"])
        )
        rawFields = Self.rawFields(from: values)
    }

    /// Keys whose values are credentials (headers such as `Authorization`, `X-Api-Key`,
    /// `Cookie`, `X-Management-Key`, and secret or token fields): never shown, at any depth.
    /// Token counts (`input_tokens`) are not credentials.
    static func isCredentialKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let exact: Set<String> = [
            "api_key", "apikey", "x_api_key", "x_goog_api_key", "management_key", "x_management_key",
            "secret_key", "client_secret", "password", "passwd", "token", "access_token",
            "refresh_token", "id_token", "session_token", "bearer", "credential", "credentials"
        ]
        if exact.contains(normalized) { return true }
        return normalized.contains("authorization")
            || normalized.contains("cookie")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.hasSuffix("_api_key")
            || normalized.hasSuffix("_token")
    }

    static let rawFieldLimit = 400

    static func rawFields(from values: [String: RuntimeJSONValue]) -> [RawField] {
        var fields: [RawField] = []
        func visit(_ value: RuntimeJSONValue, path: String, depth: Int) {
            guard fields.count < rawFieldLimit else { return }
            switch value {
            case .object(let children) where depth < 4:
                for key in children.keys.sorted() where !isCredentialKey(key) {
                    if let child = children[key] {
                        visit(child, path: path.isEmpty ? key : "\(path).\(key)", depth: depth + 1)
                    }
                }
            default:
                let text = InternalModelID.publicText(SecretRedactor.redact(rawText(value), secrets: []))
                fields.append(RawField(key: path, value: String(text.prefix(4_000))))
            }
        }
        for key in values.keys.sorted() where !isCredentialKey(key) {
            if let value = values[key] { visit(value, path: key, depth: 0) }
        }
        return fields.sorted { $0.key < $1.key }
    }

    /// `value` with every credential-bearing key removed at any depth.
    private static func withoutCredentials(_ value: RuntimeJSONValue) -> RuntimeJSONValue {
        switch value {
        case .object(let children):
            return .object(children.filter { !isCredentialKey($0.key) }.mapValues(withoutCredentials))
        case .array(let items):
            return .array(items.map(withoutCredentials))
        default:
            return value
        }
    }

    private static func rawText(_ value: RuntimeJSONValue) -> String {
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            if number.isFinite, number.rounded(.towardZero) == number, abs(number) < 9.0e15 {
                return String(Int64(number))
            }
            return String(number)
        case .boolean(let flag):
            return String(flag)
        case .null:
            return "null"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(withoutCredentials(value)),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    var sourceTitle: String {
        [
            authLabelSnapshot,
            accountSnapshot,
            authFileSnapshot,
            source,
            authIndex
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? OasesLocalization.localized("未知来源")
    }

    var statusTitle: String {
        guard failed else { return OasesLocalization.localized("成功") }
        if let failStatusCode {
            return "HTTP \(failStatusCode)"
        }
        return OasesLocalization.localized("失败")
    }

    var safeFailureSummary: String? {
        let normalized = InternalModelID.publicText(failSummary)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(480))
    }

    private static func value(
        in values: [String: RuntimeJSONValue],
        keys: [String]
    ) -> RuntimeJSONValue? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func string(_ value: RuntimeJSONValue?) -> String {
        switch value {
        case .some(.string(let value)):
            return value
        case .some(.number(let value)) where value.isFinite:
            guard let integer = safeInteger(value) else { return "" }
            return String(integer)
        case .some(.boolean(let value)):
            return String(value)
        default:
            return ""
        }
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int64 {
        switch value {
        case .some(.number(let value)) where value.isFinite:
            return safeInteger(value) ?? 0
        case .some(.string(let value)):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    private static func optionalInteger(_ value: RuntimeJSONValue?) -> Int64? {
        switch value {
        case .some(.number(let value)) where value.isFinite:
            return safeInteger(value)
        case .some(.string(let value)):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func optionalDouble(_ value: RuntimeJSONValue?) -> Double? {
        switch value {
        case .some(.number(let value)) where value.isFinite:
            return value
        case .some(.string(let value)):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func bool(_ value: RuntimeJSONValue?) -> Bool {
        switch value {
        case .some(.boolean(let value)):
            return value
        case .some(.number(let value)):
            return value != 0
        case .some(.string(let value)):
            return ["1", "true", "yes"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        default:
            return false
        }
    }

    private static func safeInteger(_ number: Double) -> Int64? {
        let rounded = number.rounded(.towardZero)
        let lowerBound = -9_223_372_036_854_775_808.0
        let upperBound = 9_223_372_036_854_775_808.0
        guard rounded >= lowerBound, rounded < upperBound else { return nil }
        return Int64(rounded)
    }
}

/// The monitoring page's advanced filter bar. Each text field takes one value or several
/// separated by commas; a model is entered by its public name and queries every spelling it
/// is recorded under (`pin-…/` routing prefixes). Values map one to one onto CPA Manager
/// Plus's analytics `Filters` (`monitoring/service.go`).
struct RuntimeMonitoringFilterDraft: Equatable, Sendable {
    /// `cache_status` as CPA Manager Plus understands it (`usageevent/analytics.go`).
    enum CacheStatus: String, CaseIterable, Identifiable, Sendable {
        case any = ""
        case hit
        case miss
        case read
        case creation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: OasesLocalization.localized("全部缓存状态")
            case .hit: OasesLocalization.localized("命中缓存")
            case .miss: OasesLocalization.localized("未命中缓存")
            case .read: OasesLocalization.localized("读取缓存")
            case .creation: OasesLocalization.localized("写入缓存")
            }
        }
    }

    var model = ""
    var provider = ""
    var account = ""
    var apiKeyHash = ""
    var requestType = ""
    var headerErrorKind = ""
    var minLatencyText = ""
    var cacheStatus: CacheStatus = .any

    /// Whole milliseconds, nil when the field is empty or not a non-negative whole number.
    var minLatencyMS: Int64? {
        let trimmed = minLatencyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(trimmed)
    }

    var isValid: Bool {
        minLatencyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || minLatencyMS != nil
    }

    /// How many filters are set (shown on the filter button).
    var activeCount: Int {
        [model, provider, account, apiKeyHash, requestType, headerErrorKind]
            .filter { !Self.values($0).isEmpty }.count
            + ((minLatencyMS ?? 0) > 0 ? 1 : 0)
            + (cacheStatus == .any ? 0 : 1)
    }

    func filters(prefixes: [String]) -> RuntimeMonitoringEventsRequest.Filters {
        var filters = RuntimeMonitoringEventsRequest.Filters()
        var models: [String] = []
        for value in Self.values(model) {
            for variant in InternalModelID.queryVariants(for: InternalModelID.publicName(value), prefixes: prefixes)
            where !models.contains(variant) {
                models.append(variant)
            }
        }
        filters.models = models
        filters.providers = Self.values(provider)
        filters.accounts = Self.values(account)
        filters.apiKeyHashes = Self.values(apiKeyHash)
        filters.requestTypes = Self.values(requestType)
        filters.headerErrorKinds = Self.values(headerErrorKind)
        filters.minLatencyMS = minLatencyMS ?? 0
        filters.cacheStatus = cacheStatus == .any ? nil : cacheStatus.rawValue
        return filters
    }

    /// The comma-separated values of one field, trimmed, without empty or repeated ones.
    static func values(_ text: String) -> [String] {
        var result: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0.isNewline }) {
            let value = String(String(part).trimmingCharacters(in: .whitespaces).prefix(256))
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
        return Array(result.prefix(20))
    }
}
