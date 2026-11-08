import Foundation

// Per-key policies of the gateway (Server `gateway/server.mjs`: normalizePolicyInput,
// projectEffectivePolicy, apiKeyUsageSnapshot, the `/cpa-admin/permissions/api/*` routes).

enum GatewayPolicyMode: String, Codable, Sendable {
    /// Only the models in `allowed_models` (an empty list: see `legacy_default_allow`).
    case allowlist
    /// Every model except `denied_models`.
    case denylist
}

enum GatewayPinMode: String, Codable, Sendable {
    /// Only the pinned provider serves the model for this key.
    case only
    /// The pinned provider first, the others after it.
    case prefer
}

/// One entry of `model_provider_pins` (keyed by canonical model id). A missing mode means `only`,
/// the gateway's safe default.
struct GatewayProviderPin: Codable, Equatable, Sendable {
    var provider: String
    var mode: GatewayPinMode

    init(provider: String, mode: GatewayPinMode) {
        self.provider = provider
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case provider, mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        mode = (try? container.decodeIfPresent(GatewayPinMode.self, forKey: .mode)) ?? .only
    }
}

/// The five capability switches; all five are always written.
struct GatewayCapabilities: Codable, Equatable, Sendable {
    var chatCompletions: Bool
    var responses: Bool
    var messages: Bool
    var imageGeneration: Bool
    /// Spends third-party search money, so it is opt-in.
    var webSearch: Bool

    private enum CodingKeys: String, CodingKey {
        case chatCompletions = "chat_completions"
        case responses
        case messages
        case imageGeneration = "image_generation"
        case webSearch = "web_search"
    }

    init(chatCompletions: Bool = true, responses: Bool = true, messages: Bool = true, imageGeneration: Bool = true, webSearch: Bool = false) {
        self.chatCompletions = chatCompletions
        self.responses = responses
        self.messages = messages
        self.imageGeneration = imageGeneration
        self.webSearch = webSearch
    }

    /// Missing fields take the gateway's effective values (`projectEffectivePolicy`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatCompletions = try container.decodeIfPresent(Bool.self, forKey: .chatCompletions) ?? true
        responses = try container.decodeIfPresent(Bool.self, forKey: .responses) ?? true
        messages = try container.decodeIfPresent(Bool.self, forKey: .messages) ?? true
        imageGeneration = try container.decodeIfPresent(Bool.self, forKey: .imageGeneration) ?? true
        webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch) ?? false
    }
}

/// `rate_limit`: positive integers or null (no limit). Nil is written as null.
struct GatewayRateLimit: Codable, Equatable, Sendable {
    var requestsPerMinute: Int?
    var tokensPerDay: Int?

    private enum CodingKeys: String, CodingKey {
        case requestsPerMinute = "requests_per_minute"
        case tokensPerDay = "tokens_per_day"
    }

    init(requestsPerMinute: Int? = nil, tokensPerDay: Int? = nil) {
        self.requestsPerMinute = requestsPerMinute
        self.tokensPerDay = tokensPerDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute)
        tokensPerDay = try container.decodeIfPresent(Int.self, forKey: .tokensPerDay)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestsPerMinute, forKey: .requestsPerMinute)
        try container.encode(tokensPerDay, forKey: .tokensPerDay)
    }
}

/// One key's policy, as `permissions/api/data` projects it and `save_policy` takes it.
///
/// Unknown fields are kept in `extra` and written back. `usage` (a read-only snapshot the gateway
/// adds) and `attestation` (kept by the gateway when a save omits it) are never read into `extra`
/// and never written.
struct GatewayKeyPolicy: Codable, Equatable, Sendable {
    var label: String
    var enabled: Bool
    var mode: GatewayPolicyMode
    var allowedModels: [String]
    var deniedModels: [String]
    var providerAllowlist: [String]
    var capabilities: GatewayCapabilities
    var rateLimit: GatewayRateLimit
    var expiresAt: Date?
    var notes: String
    /// An empty allowlist allows every model unless this is false (`server.mjs`, model check).
    /// Nil only when the stored policy has no marker; always written as true or false.
    var legacyDefaultAllow: Bool?
    /// Web search providers this key may use; empty = every provider the gateway enables.
    var searchProviders: [String]
    /// Provider pins by canonical model id; only for allowlist keys, only for allowed models.
    var modelProviderPins: [String: GatewayProviderPin]
    var extra: [String: RuntimeJSONValue]

    static let maximumLabelLength = 100
    static let maximumNotesLength = 1000

    /// What the gateway stores for notes: control characters (U+0000–U+001F, newlines included)
    /// removed (`server.mjs`, policy normalization). Lengths are counted in UTF-16 code units.
    static func normalizedNotes(_ notes: String) -> String {
        String(String.UnicodeScalarView(notes.unicodeScalars.filter { $0.value > 0x1F }))
    }

    /// What the gateway stores for a label: `<`, `>` and control characters removed, trimmed,
    /// at most `maximumLabelLength` UTF-16 code units (cut at a character boundary, where the
    /// gateway's `slice` could split a surrogate pair).
    static func normalizedLabel(_ label: String) -> String {
        let cleaned = String(String.UnicodeScalarView(label.unicodeScalars.filter { $0.value > 0x1F && $0 != "<" && $0 != ">" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var units = 0
        for character in cleaned {
            let size = String(character).utf16.count
            guard units + size <= maximumLabelLength else { break }
            result.append(character)
            units += size
        }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case label, enabled, mode
        case allowedModels = "allowed_models"
        case deniedModels = "denied_models"
        case providerAllowlist = "provider_allowlist"
        case capabilities
        case rateLimit = "rate_limit"
        case expiresAt = "expires_at"
        case notes
        case legacyDefaultAllow = "legacy_default_allow"
        case searchProviders = "search_providers"
        case modelProviderPins = "model_provider_pins"
    }

    /// Fields that are neither modelled nor kept.
    private static let dropped: Set<String> = ["usage", "attestation"]
    private static let known = Set(CodingKeys.allCases.map(\.rawValue)).union(dropped)

    init(
        label: String = "",
        enabled: Bool = true,
        mode: GatewayPolicyMode = .allowlist,
        allowedModels: [String] = [],
        deniedModels: [String] = [],
        providerAllowlist: [String] = [],
        capabilities: GatewayCapabilities = GatewayCapabilities(),
        rateLimit: GatewayRateLimit = GatewayRateLimit(),
        expiresAt: Date? = nil,
        notes: String = "",
        legacyDefaultAllow: Bool? = nil,
        searchProviders: [String] = [],
        modelProviderPins: [String: GatewayProviderPin] = [:],
        extra: [String: RuntimeJSONValue] = [:]
    ) {
        self.label = label
        self.enabled = enabled
        self.mode = mode
        self.allowedModels = allowedModels
        self.deniedModels = deniedModels
        self.providerAllowlist = providerAllowlist
        self.capabilities = capabilities
        self.rateLimit = rateLimit
        self.expiresAt = expiresAt
        self.notes = notes
        self.legacyDefaultAllow = legacyDefaultAllow
        self.searchProviders = searchProviders
        self.modelProviderPins = modelProviderPins
        self.extra = extra
    }

    /// The gateway's effective policy for a key without a stored one (`projectEffectivePolicy(undefined)`).
    static let projectedDefault = GatewayKeyPolicy(legacyDefaultAllow: true)

    /// A new key: every model, no web search, no image generation (the gateway's defaults for a
    /// newly authored policy).
    static let newKeyDefault = GatewayKeyPolicy(
        capabilities: GatewayCapabilities(imageGeneration: false, webSearch: false),
        legacyDefaultAllow: true
    )

    /// Missing fields take the gateway's effective values, so a legacy (schema 1) entry decodes too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = (try? container.decodeIfPresent(GatewayPolicyMode.self, forKey: .mode)) ?? .allowlist
        allowedModels = try container.decodeIfPresent([String].self, forKey: .allowedModels) ?? []
        deniedModels = try container.decodeIfPresent([String].self, forKey: .deniedModels) ?? []
        providerAllowlist = try container.decodeIfPresent([String].self, forKey: .providerAllowlist) ?? []
        capabilities = try container.decodeIfPresent(GatewayCapabilities.self, forKey: .capabilities) ?? GatewayCapabilities()
        rateLimit = try container.decodeIfPresent(GatewayRateLimit.self, forKey: .rateLimit) ?? GatewayRateLimit()
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt).flatMap(GatewayDates.date(from:))
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        legacyDefaultAllow = try container.decodeIfPresent(Bool.self, forKey: .legacyDefaultAllow)
        searchProviders = try container.decodeIfPresent([String].self, forKey: .searchProviders) ?? []
        modelProviderPins = try container.decodeIfPresent([String: GatewayProviderPin].self, forKey: .modelProviderPins) ?? [:]
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    /// Every field is written explicitly: `capabilities` with all five switches, `rate_limit` with
    /// nulls, `expires_at` as an ISO string with milliseconds or null, `legacy_default_allow` as
    /// true or false, `model_provider_pins` and `search_providers` even when empty.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mode, forKey: .mode)
        try container.encode(allowedModels, forKey: .allowedModels)
        try container.encode(deniedModels, forKey: .deniedModels)
        try container.encode(providerAllowlist, forKey: .providerAllowlist)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(rateLimit, forKey: .rateLimit)
        try container.encode(expiresAt.map(GatewayDates.string(from:)), forKey: .expiresAt)
        try container.encode(notes, forKey: .notes)
        try container.encode(effectiveLegacyDefaultAllow, forKey: .legacyDefaultAllow)
        try container.encode(searchProviders, forKey: .searchProviders)
        try container.encode(modelProviderPins, forKey: .modelProviderPins)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }

    /// The marker as the gateway reads it: a missing one is true exactly for an empty allowlist.
    var effectiveLegacyDefaultAllow: Bool {
        legacyDefaultAllow ?? (mode == .allowlist && allowedModels.isEmpty)
    }

    /// The same policy for every modelled field (`extra` is ignored): what "the server's policy
    /// did not change" means before a save.
    func hasSameKnownFields(as other: GatewayKeyPolicy) -> Bool {
        var left = self
        var right = other
        left.extra = [:]
        right.extra = [:]
        left.legacyDefaultAllow = left.effectiveLegacyDefaultAllow
        right.legacyDefaultAllow = right.effectiveLegacyDefaultAllow
        return left == right
    }

    func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Model ids as the gateway compares them in policies (`canonicalModelId` in `server.mjs`):
/// trimmed, lower case, without "cc-", the part after the last "/".
enum GatewayPolicyModelID {
    static func canonical(_ model: String) -> String {
        var value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("cc-") { value.removeFirst(3) }
        if let slash = value.lastIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        return value
    }
}

/// `usage` of one key today (UTC day).
struct GatewayKeyUsage: Codable, Equatable, Sendable {
    var day: String
    var requests: Int
    var requestsLastMinute: Int
    var tokens: Int
    var tokensPerDay: Int?
    var requestsPerMinute: Int?

    private enum CodingKeys: String, CodingKey {
        case day, requests
        case requestsLastMinute = "requests_last_minute"
        case tokens
        case tokensPerDay = "tokens_per_day"
        case requestsPerMinute = "requests_per_minute"
    }

    init(day: String, requests: Int, requestsLastMinute: Int, tokens: Int, tokensPerDay: Int?, requestsPerMinute: Int?) {
        self.day = day
        self.requests = requests
        self.requestsLastMinute = requestsLastMinute
        self.tokens = tokens
        self.tokensPerDay = tokensPerDay
        self.requestsPerMinute = requestsPerMinute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        requestsLastMinute = try container.decodeIfPresent(Int.self, forKey: .requestsLastMinute) ?? 0
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        tokensPerDay = try container.decodeIfPresent(Int.self, forKey: .tokensPerDay)
        requestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute)
    }
}

/// `GET /cpa-admin/permissions/api/data`: `{ keys, permissions, groupedModels, disabledProviders,
/// schema_version, usage }`.
///
/// `keys` are the configured client keys (the gateway hides its internal engine key, so the list
/// may be empty while the engine still has a key); `permissions` (here `policies`) is the
/// effective policy of each key, each with a read-only `usage` snapshot that goes to `usage`.
struct GatewayPermissionsData: Decodable, Sendable {
    let keys: [String]
    let policies: [String: GatewayKeyPolicy]
    let usage: [String: GatewayKeyUsage]
    /// Model ids by group: an openai-compatibility provider's name, or "认证文件 / 引擎模型" for the
    /// engine's other models. Contains internal `pin-x/…` ids, which callers must drop.
    let groupedModels: [String: [String]]
    let disabledProviders: [String]
    let schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case keys
        case policies = "permissions"
        case usage
        case groupedModels
        case disabledProviders
        case schemaVersion = "schema_version"
    }

    private struct PolicyUsage: Decodable {
        let usage: GatewayKeyUsage?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
        policies = try container.decodeIfPresent([String: GatewayKeyPolicy].self, forKey: .policies) ?? [:]
        var usage = try container.decodeIfPresent([String: GatewayKeyUsage].self, forKey: .usage) ?? [:]
        // Keys without a top-level entry keep the snapshot carried inside their policy.
        let embedded = (try? container.decodeIfPresent([String: PolicyUsage].self, forKey: .policies)) ?? nil
        for (key, entry) in embedded ?? [:] where usage[key] == nil {
            if let snapshot = entry.usage { usage[key] = snapshot }
        }
        self.usage = usage
        groupedModels = try container.decodeIfPresent([String: [String]].self, forKey: .groupedModels) ?? [:]
        disabledProviders = try container.decodeIfPresent([String].self, forKey: .disabledProviders) ?? []
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

/// `POST /cpa-admin/permissions/api/save` bodies. `assign_key` does not exist in the open edition.
enum GatewayKeysSaveAction: Encodable, Sendable {
    case addKey(key: String, policy: GatewayKeyPolicy)
    case deleteKey(key: String)
    case setLabel(key: String, label: String)
    case savePolicy(key: String, policy: GatewayKeyPolicy)

    private enum CodingKeys: String, CodingKey {
        case action, key, policy, label
    }

    var name: String {
        switch self {
        case .addKey: "add_key"
        case .deleteKey: "delete_key"
        case .setLabel: "set_label"
        case .savePolicy: "save_policy"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .action)
        switch self {
        case .addKey(let key, let policy), .savePolicy(let key, let policy):
            try container.encode(key, forKey: .key)
            try container.encode(policy, forKey: .policy)
        case .deleteKey(let key):
            try container.encode(key, forKey: .key)
        case .setLabel(let key, let label):
            try container.encode(key, forKey: .key)
            try container.encode(label, forKey: .label)
        }
    }
}

/// An edit of one key's policy, from the copy the editor was opened with (`baseline`).
struct GatewayKeyPolicyDraft: Equatable, Sendable {
    let baseline: GatewayKeyPolicy
    var policy: GatewayKeyPolicy

    /// A policy without the marker gets the effective value written in, so that emptying the
    /// allowlist later can never silently widen it to every model.
    init(baseline: GatewayKeyPolicy) {
        self.baseline = baseline
        var policy = baseline
        policy.legacyDefaultAllow = baseline.effectiveLegacyDefaultAllow
        self.policy = policy
    }

    /// Localized problems that block a save.
    func validationErrors() -> [String] {
        var errors: [String] = []
        // Counted like the gateway (JavaScript `length`: UTF-16 code units), after the characters
        // it removes.
        let label = policy.label.unicodeScalars.filter { $0.value > 0x1F && $0 != "<" && $0 != ">" }
        if String(String.UnicodeScalarView(label)).trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > GatewayKeyPolicy.maximumLabelLength {
            errors.append(OasesLocalization.localizedFormat("名称最多 %lld 个字符。", GatewayKeyPolicy.maximumLabelLength))
        }
        if GatewayKeyPolicy.normalizedNotes(policy.notes).utf16.count > GatewayKeyPolicy.maximumNotesLength {
            errors.append(OasesLocalization.localizedFormat("备注最多 %lld 个字符。", GatewayKeyPolicy.maximumNotesLength))
        }
        if let value = policy.rateLimit.requestsPerMinute, value <= 0 {
            errors.append(OasesLocalization.localized("每分钟请求数必须是正整数，或留空表示不限。"))
        }
        if let value = policy.rateLimit.tokensPerDay, value <= 0 {
            errors.append(OasesLocalization.localized("每日 Token 上限必须是正整数，或留空表示不限。"))
        }
        if policy.mode == .denylist && !policy.modelProviderPins.isEmpty {
            errors.append(OasesLocalization.localized("拒绝列表模式不能指定供应商；请先清除这把 Key 的供应商指定。"))
        }
        return errors
    }

    /// Models whose provider pin the gateway would drop on save: every pin in denylist mode,
    /// otherwise the pins of models that are not (or no longer) in `allowed_models` (an empty list,
    /// "every model", has room for no pin). Sorted. A pin the user removed is not listed.
    func pinsThatWouldBeDropped() -> [String] {
        guard !policy.modelProviderPins.isEmpty else { return [] }
        guard policy.mode == .allowlist else { return policy.modelProviderPins.keys.sorted() }
        let allowed = Set(policy.allowedModels.map(GatewayPolicyModelID.canonical))
        return policy.modelProviderPins.keys
            .filter { !allowed.contains(GatewayPolicyModelID.canonical($0)) }
            .sorted()
    }

    /// Removes the pins `pinsThatWouldBeDropped()` lists (after the user confirmed it).
    mutating func dropUnreachablePins() {
        for model in pinsThatWouldBeDropped() {
            policy.modelProviderPins.removeValue(forKey: model)
        }
    }

    /// The editor's "every model" switch. On: an empty allowlist with `legacy_default_allow` true.
    /// Off: `legacy_default_allow` false, so an empty list allows nothing.
    var allowsAllModels: Bool {
        get { policy.mode == .allowlist && policy.allowedModels.isEmpty && policy.legacyDefaultAllow != false }
        set {
            if newValue {
                policy.mode = .allowlist
                policy.allowedModels = []
                policy.legacyDefaultAllow = true
            } else {
                policy.legacyDefaultAllow = false
            }
        }
    }

    /// The rule picker (panel `withModelScope`): choosing allow- or denylist explicitly makes an
    /// empty list mean "no model", never "every model" (`legacy_default_allow` false).
    var policyMode: GatewayPolicyMode {
        get { policy.mode }
        set {
            policy.mode = newValue
            policy.legacyDefaultAllow = false
        }
    }

    /// The allowlist as the model picker edits it (panel `withScopedModels`): every edit sets
    /// `legacy_default_allow` false, so unticking the last model of a list that still carries an
    /// explicit `true` (an older client's marker) can never widen the key to every model. Pins of
    /// models taken out stay until the save, where the editor asks before dropping them.
    var scopedAllowedModels: [String] {
        get { policy.allowedModels }
        set {
            policy.allowedModels = newValue
            policy.legacyDefaultAllow = false
        }
    }

    /// The denylist as the model picker edits it (panel `withScopedModels`, denylist branch).
    var scopedDeniedModels: [String] {
        get { policy.deniedModels }
        set {
            policy.deniedModels = newValue
            policy.legacyDefaultAllow = false
        }
    }

    /// Sets or removes (nil) the pin of `model`, keyed by its canonical id. Only for allowlist keys.
    mutating func setPin(_ pin: GatewayProviderPin?, for model: String) {
        guard policy.mode == .allowlist else { return }
        let id = GatewayPolicyModelID.canonical(model)
        guard !id.isEmpty else { return }
        policy.modelProviderPins[id] = pin
    }

    func pin(for model: String) -> GatewayProviderPin? {
        policy.modelProviderPins[GatewayPolicyModelID.canonical(model)]
    }

    var hasChanges: Bool { !policy.hasSameKnownFields(as: baseline) }
}
