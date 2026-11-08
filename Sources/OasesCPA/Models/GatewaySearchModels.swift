import Foundation

// Web search providers (`gateway/search.mjs` admin part, `handleSearchAdmin` in `server.mjs`).
// The third-party API keys live only on the gateway: the app sends a new key once and afterwards
// only sees `key_hint` ("…abcd").

/// Today's counters of one provider (UTC day).
struct GatewaySearchCounts: Codable, Equatable, Sendable {
    var requests: Int
    var ok: Int
    var failed: Int

    init(requests: Int = 0, ok: Int = 0, failed: Int = 0) {
        self.requests = requests
        self.ok = ok
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        ok = try container.decodeIfPresent(Int.self, forKey: .ok) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case requests, ok, failed
    }
}

/// The latest key test of a provider (`adminTest`'s record; kept in the gateway's memory only).
struct GatewaySearchTestResult: Codable, Equatable, Sendable {
    var ok: Bool
    var status: Int?
    var code: String?
    /// The gateway's or provider's message (masked before it is shown).
    var message: String
    var testedAt: Date?
    var keyHint: String?
    var extra: [String: RuntimeJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, status, code, message
        case testedAt = "tested_at"
        case keyHint = "key_hint"
    }

    /// `detail` is provider-specific (credits, plans); it is kept, never shown.
    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        testedAt = try container.decodeIfPresent(String.self, forKey: .testedAt).flatMap(GatewayDates.date(from:))
        keyHint = try container.decodeIfPresent(String.self, forKey: .keyHint)
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(status, forKey: .status)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(testedAt.map(GatewayDates.string(from:)), forKey: .testedAt)
        try container.encode(keyHint, forKey: .keyHint)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }
}

/// One provider of `GET /cpa-admin/search/providers` (`adminEntry`). Unknown fields are kept in
/// `extra` and written back when re-encoded.
struct GatewaySearchProvider: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// "results" (a result list) or "summary" (an answer text, X Search).
    var kind: String
    var site: String
    var docs: String
    var enabled: Bool
    var configured: Bool
    var keyHint: String?
    /// nil: no daily limit.
    var dailyLimit: Int?
    var defaultDailyLimit: Int
    var updatedAt: Date?
    var today: GatewaySearchCounts
    var lastTest: GatewaySearchTestResult?
    var extra: [String: RuntimeJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, kind, site, docs, enabled, configured
        case keyHint = "key_hint"
        case dailyLimit = "daily_limit"
        case defaultDailyLimit = "default_daily_limit"
        case updatedAt = "updated_at"
        case today
        case lastTest = "last_test"
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "results"
        site = try container.decodeIfPresent(String.self, forKey: .site) ?? ""
        docs = try container.decodeIfPresent(String.self, forKey: .docs) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        keyHint = try container.decodeIfPresent(String.self, forKey: .keyHint)
        dailyLimit = try container.decodeIfPresent(Int.self, forKey: .dailyLimit)
        defaultDailyLimit = try container.decodeIfPresent(Int.self, forKey: .defaultDailyLimit) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(GatewayDates.date(from:))
        today = try container.decodeIfPresent(GatewaySearchCounts.self, forKey: .today) ?? GatewaySearchCounts()
        lastTest = try container.decodeIfPresent(GatewaySearchTestResult.self, forKey: .lastTest)
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(site, forKey: .site)
        try container.encode(docs, forKey: .docs)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(configured, forKey: .configured)
        try container.encode(keyHint, forKey: .keyHint)
        try container.encode(dailyLimit, forKey: .dailyLimit)
        try container.encode(defaultDailyLimit, forKey: .defaultDailyLimit)
        try container.encode(updatedAt.map(GatewayDates.string(from:)), forKey: .updatedAt)
        try container.encode(today, forKey: .today)
        try container.encode(lastTest, forKey: .lastTest)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }
}

struct GatewaySearchProvidersResponse: Decodable, Sendable {
    let providers: [GatewaySearchProvider]
}

/// `POST /cpa-admin/search/providers/save`: `{provider, enabled?, api_key?, daily_limit?}`.
/// An untouched key is not written; `apiKey: .clear` writes "" (the gateway's "remove the key");
/// `dailyLimit: .clear` writes null (no limit).
struct GatewaySearchProviderSave: Encodable, Sendable {
    static let maximumDailyLimit = 10_000_000
    static let maximumKeyLength = 512

    let provider: String
    var enabled: Bool?
    var apiKey: PatchField<String>
    var dailyLimit: PatchField<Int>

    init(provider: String, enabled: Bool? = nil, apiKey: PatchField<String> = .keep, dailyLimit: PatchField<Int> = .keep) {
        self.provider = provider
        self.enabled = enabled
        self.apiKey = apiKey
        self.dailyLimit = dailyLimit
    }

    private enum CodingKeys: String, CodingKey {
        case provider, enabled
        case apiKey = "api_key"
        case dailyLimit = "daily_limit"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        switch apiKey {
        case .keep: break
        case .set(let key): try container.encode(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .apiKey)
        case .clear: try container.encode("", forKey: .apiKey)
        }
        switch dailyLimit {
        case .keep: break
        case .set(let limit): try container.encode(limit, forKey: .dailyLimit)
        case .clear: try container.encodeNil(forKey: .dailyLimit)
        }
    }

    /// The gateway's rules (`adminSave`), checked before sending.
    func validationErrors() -> [String] {
        var errors: [String] = []
        if case .set(let key) = apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.utf16.count > Self.maximumKeyLength || trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) {
                errors.append(OasesLocalization.localizedFormat("API Key 不能为空、不能含空白，最多 %lld 个字符。", Self.maximumKeyLength))
            }
        }
        if case .set(let limit) = dailyLimit, limit < 1 || limit > Self.maximumDailyLimit {
            errors.append(OasesLocalization.localizedFormat("每日上限必须在 1 到 %lld 之间，或留空表示不限。", Self.maximumDailyLimit))
        }
        return errors
    }
}

struct GatewaySearchProviderSaveResponse: Decodable, Sendable {
    let provider: GatewaySearchProvider
}

struct GatewaySearchTestResponse: Decodable, Sendable {
    let result: GatewaySearchTestResult
}

/// `POST /cpa-admin/search/providers/test`: `{provider, api_key?}` (no key: the saved one).
struct GatewaySearchTestBody: Encodable, Sendable {
    let provider: String
    let apiKey: String?

    private enum CodingKeys: String, CodingKey {
        case provider
        case apiKey = "api_key"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .apiKey)
        }
    }
}

/// `GET /cpa-admin/search/usage?days=`: one entry per UTC day, oldest first.
struct GatewaySearchUsage: Decodable, Equatable, Sendable {
    struct Day: Decodable, Equatable, Sendable {
        let date: String
        let providers: [String: GatewaySearchCounts]
    }

    let days: [Day]

    /// Requests per day of one provider, oldest first.
    func requests(of provider: String) -> [Int] {
        days.map { $0.providers[provider]?.requests ?? 0 }
    }
}

/// One line of `GET /cpa-admin/search/logs` (`pushLog` in search.mjs), newest first. `ts` is in
/// SECONDS. `status` is the HTTP status the gateway answered (a number). `key_fp` (a fingerprint
/// of the client key) is kept but never shown.
struct GatewaySearchLogEntry: Decodable, Equatable, Identifiable, Sendable {
    let ts: Date
    let provider: String
    let keyLabel: String
    let keyFp: String?
    let status: Int?
    let code: String?
    let upstreamStatus: Int?
    let results: Int?
    let latencyMs: Int?
    let upstreamCalled: Bool?

    var id: String { "\(ts.timeIntervalSince1970)|\(provider)|\(keyFp ?? "")|\(status ?? 0)|\(latencyMs ?? -1)" }
    var succeeded: Bool { (200..<300).contains(status ?? 0) }

    private enum CodingKeys: String, CodingKey {
        case ts, provider, status, code, results
        case keyLabel = "key_label"
        case keyFp = "key_fp"
        case upstreamStatus = "upstream_status"
        case latencyMs = "latency_ms"
        case upstreamCalled = "upstream_called"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = Date(timeIntervalSince1970: try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        keyLabel = try container.decodeIfPresent(String.self, forKey: .keyLabel) ?? ""
        keyFp = try container.decodeIfPresent(String.self, forKey: .keyFp)
        if let number = try? container.decodeIfPresent(Int.self, forKey: .status) {
            status = number
        } else {
            status = (try? container.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(Int.init) }
        }
        code = try container.decodeIfPresent(String.self, forKey: .code)
        upstreamStatus = try container.decodeIfPresent(Int.self, forKey: .upstreamStatus)
        results = try container.decodeIfPresent(Int.self, forKey: .results)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        upstreamCalled = try container.decodeIfPresent(Bool.self, forKey: .upstreamCalled)
    }
}

struct GatewaySearchLogsResponse: Decodable, Sendable {
    let logs: [GatewaySearchLogEntry]
}
