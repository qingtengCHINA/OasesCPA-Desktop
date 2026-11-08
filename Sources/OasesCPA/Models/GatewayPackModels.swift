import Foundation

// Model packs (`gateway/packs.mjs`, `handlePackAdmin` in `server.mjs`): several real models behind
// one public model id, with their own keys (`sk-pk-…`), token/cost limits, expiry and scheduled
// quota restores. The open edition has no `assign_key` (binding to an external account): a key's
// binding is only shown and can be removed (`unbind_key`).

enum GatewayPackMode: String, Codable, CaseIterable, Sendable {
    case roundRobin = "round_robin"
    case random
    case primaryBackup = "primary_backup"

    var title: String {
        switch self {
        case .roundRobin: OasesLocalization.localized("轮询")
        case .random: OasesLocalization.localized("随机")
        case .primaryBackup: OasesLocalization.localized("主备")
        }
    }
}

/// A member model and its prices in USD per million tokens (nil: no price).
struct GatewayPackMember: Codable, Equatable, Sendable {
    var model: String
    var inputUSDPer1M: Decimal?
    var outputUSDPer1M: Decimal?

    init(model: String, inputUSDPer1M: Decimal? = nil, outputUSDPer1M: Decimal? = nil) {
        self.model = model
        self.inputUSDPer1M = inputUSDPer1M
        self.outputUSDPer1M = outputUSDPer1M
    }

    var isPriced: Bool { inputUSDPer1M != nil && outputUSDPer1M != nil }

    private enum CodingKeys: String, CodingKey {
        case model
        case inputUSDPer1M = "input_usd_per_1m"
        case outputUSDPer1M = "output_usd_per_1m"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        inputUSDPer1M = try container.decodeIfPresent(Decimal.self, forKey: .inputUSDPer1M)
        outputUSDPer1M = try container.decodeIfPresent(Decimal.self, forKey: .outputUSDPer1M)
    }

    /// Prices are always written; null means "no price".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(inputUSDPer1M, forKey: .inputUSDPer1M)
        try container.encode(outputUSDPer1M, forKey: .outputUSDPer1M)
    }
}

struct GatewayPackFailover: Codable, Equatable, Sendable {
    var firstByteTimeoutMs: Int
    var maxAttempts: Int

    static let timeoutRange = 1_000...120_000
    static let defaultTimeoutMs = 30_000

    /// The gateway's defaults for `memberCount` members.
    static func defaults(memberCount: Int) -> GatewayPackFailover {
        GatewayPackFailover(firstByteTimeoutMs: defaultTimeoutMs, maxAttempts: max(1, min(3, memberCount)))
    }

    private enum CodingKeys: String, CodingKey {
        case firstByteTimeoutMs = "first_byte_timeout_ms"
        case maxAttempts = "max_attempts"
    }
}

/// `PackView` of `GET /cpa-admin/packs/data` (`listPacks`). Unknown fields are kept in `extra`.
struct GatewayPack: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var modelID: String
    var enabled: Bool
    var identity: Bool
    var mode: GatewayPackMode
    var members: [GatewayPackMember]
    var failover: GatewayPackFailover
    var createdAt: Date?
    var updatedAt: Date?
    var keyCount: Int
    var activeKeyCount: Int
    var extra: [String: RuntimeJSONValue] = [:]

    var isPriced: Bool { members.allSatisfy(\.isPriced) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
        case modelID = "model_id"
        case enabled, identity, mode, members, failover
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case keyCount = "key_count"
        case activeKeyCount = "active_key_count"
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    init(id: String, name: String, modelID: String, enabled: Bool = true, identity: Bool = true, mode: GatewayPackMode, members: [GatewayPackMember],
         failover: GatewayPackFailover, createdAt: Date? = nil, updatedAt: Date? = nil, keyCount: Int = 0, activeKeyCount: Int = 0, extra: [String: RuntimeJSONValue] = [:]) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.enabled = enabled
        self.identity = identity
        self.mode = mode
        self.members = members
        self.failover = failover
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.keyCount = keyCount
        self.activeKeyCount = activeKeyCount
        self.extra = extra
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? modelID
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        identity = try container.decodeIfPresent(Bool.self, forKey: .identity) ?? true
        mode = (try? container.decodeIfPresent(GatewayPackMode.self, forKey: .mode)) ?? .roundRobin
        members = try container.decodeIfPresent([GatewayPackMember].self, forKey: .members) ?? []
        failover = try container.decodeIfPresent(GatewayPackFailover.self, forKey: .failover) ?? .defaults(memberCount: members.count)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt).flatMap(GatewayDates.date(from:))
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(GatewayDates.date(from:))
        keyCount = try container.decodeIfPresent(Int.self, forKey: .keyCount) ?? 0
        activeKeyCount = try container.decodeIfPresent(Int.self, forKey: .activeKeyCount) ?? 0
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(identity, forKey: .identity)
        try container.encode(mode, forKey: .mode)
        try container.encode(members, forKey: .members)
        try container.encode(failover, forKey: .failover)
        try container.encodeIfPresent(createdAt.map(GatewayDates.string(from:)), forKey: .createdAt)
        try container.encodeIfPresent(updatedAt.map(GatewayDates.string(from:)), forKey: .updatedAt)
        try container.encode(keyCount, forKey: .keyCount)
        try container.encode(activeKeyCount, forKey: .activeKeyCount)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }
}

/// What `upsert_pack` takes: `{id?, name, model_id, mode, members, failover, enabled, identity}`
/// (no id: a new pack). The gateway builds the stored pack from these fields only.
struct GatewayPackDraft: Encodable, Equatable, Sendable {
    var id: String?
    var name: String
    var modelID: String
    var mode: GatewayPackMode
    var members: [GatewayPackMember]
    var failover: GatewayPackFailover
    var enabled: Bool
    var identity: Bool

    init(id: String? = nil, name: String = "", modelID: String = "", mode: GatewayPackMode = .roundRobin, members: [GatewayPackMember] = [],
         failover: GatewayPackFailover = .defaults(memberCount: 1), enabled: Bool = true, identity: Bool = true) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.mode = mode
        self.members = members
        self.failover = failover
        self.enabled = enabled
        self.identity = identity
    }

    init(pack: GatewayPack) {
        self.init(id: pack.id, name: pack.name, modelID: pack.modelID, mode: pack.mode, members: pack.members,
                  failover: pack.failover, enabled: pack.enabled, identity: pack.identity)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case modelID = "model_id"
        case mode, members, failover, enabled, identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .name)
        try container.encode(modelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .modelID)
        try container.encode(mode, forKey: .mode)
        try container.encode(members.map { GatewayPackMember(model: $0.model.trimmingCharacters(in: .whitespacesAndNewlines), inputUSDPer1M: $0.inputUSDPer1M, outputUSDPer1M: $0.outputUSDPer1M) }, forKey: .members)
        try container.encode(failover, forKey: .failover)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(identity, forKey: .identity)
    }
}

enum GatewayResetUnit: String, Codable, CaseIterable, Sendable {
    case day, week, month

    /// The largest `every` the gateway accepts (`RESET_MAX_EVERY`).
    var maximumEvery: Int {
        switch self {
        case .day: 366
        case .week: 52
        case .month: 24
        }
    }
}

/// A scheduled quota restore: every `every` units from `anchorAt`. Only `unit`, `every` and
/// `anchor_at` are written (no anchor: the gateway takes the current time); `next_reset_at` and
/// `last_reset_at` are the gateway's.
struct GatewayResetSchedule: Codable, Equatable, Sendable {
    var unit: GatewayResetUnit
    var every: Int
    var anchorAt: Date?
    let nextResetAt: Date?
    let lastResetAt: Date?

    init(unit: GatewayResetUnit, every: Int, anchorAt: Date? = nil, nextResetAt: Date? = nil, lastResetAt: Date? = nil) {
        self.unit = unit
        self.every = every
        self.anchorAt = anchorAt
        self.nextResetAt = nextResetAt
        self.lastResetAt = lastResetAt
    }

    private enum CodingKeys: String, CodingKey {
        case unit, every
        case anchorAt = "anchor_at"
        case nextResetAt = "next_reset_at"
        case lastResetAt = "last_reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = try container.decode(GatewayResetUnit.self, forKey: .unit)
        every = try container.decodeIfPresent(Int.self, forKey: .every) ?? 1
        anchorAt = try container.decodeIfPresent(String.self, forKey: .anchorAt).flatMap(GatewayDates.date(from:))
        nextResetAt = try container.decodeIfPresent(String.self, forKey: .nextResetAt).flatMap(GatewayDates.date(from:))
        lastResetAt = try container.decodeIfPresent(String.self, forKey: .lastResetAt).flatMap(GatewayDates.date(from:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unit, forKey: .unit)
        try container.encode(every, forKey: .every)
        try container.encodeIfPresent(anchorAt.map(GatewayDates.string(from:)), forKey: .anchorAt)
    }
}

enum GatewayPackKeyStatus: Equatable, Sendable {
    case active, disabled, expired, exhausted
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "disabled": self = .disabled
        case "expired": self = .expired
        case "exhausted": self = .exhausted
        default: self = .other(rawValue)
        }
    }

    var title: String {
        switch self {
        case .active: OasesLocalization.localized("可用")
        case .disabled: OasesLocalization.localized("已停用")
        case .expired: OasesLocalization.localized("已过期")
        case .exhausted: OasesLocalization.localized("额度用完")
        case .other(let value): value
        }
    }
}

/// A pack key as `GET /cpa-admin/packs/keys` returns it (`keyView`): never the key itself, only
/// its last four characters. `usage` is the current period; `lifetime` the earlier ones.
struct GatewayPackKey: Decodable, Equatable, Identifiable, Sendable {
    struct Limits: Decodable, Equatable, Sendable {
        var totalTokens: Int?
        var totalCostUSD: Decimal?

        private enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
            case totalCostUSD = "total_cost_usd"
        }
    }

    struct Usage: Decodable, Equatable, Sendable {
        var promptTokens: Int
        var completionTokens: Int
        var tokens: Int
        var costUSD: Decimal
        var requests: Int
        var lastUsedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case tokens
            case costUSD = "cost_usd"
            case requests
            case lastUsedAt = "last_used_at"
        }

        init(promptTokens: Int = 0, completionTokens: Int = 0, tokens: Int = 0, costUSD: Decimal = 0, requests: Int = 0, lastUsedAt: Date? = nil) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.tokens = tokens
            self.costUSD = costUSD
            self.requests = requests
            self.lastUsedAt = lastUsedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
            completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
            tokens = try container.decodeIfPresent(Int.self, forKey: .tokens) ?? (promptTokens + completionTokens)
            costUSD = try container.decodeIfPresent(Decimal.self, forKey: .costUSD) ?? 0
            requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
            lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt).flatMap(GatewayDates.date(from:))
        }
    }

    var id: String
    var packID: String
    var label: String
    var tail: String
    var enabled: Bool
    var status: GatewayPackKeyStatus
    var expiresAt: Date?
    var limits: Limits
    var usage: Usage
    var reset: GatewayResetSchedule?
    var lifetime: Usage
    var bound: Bool
    /// An external account id (production only): kept, never shown.
    var ownerID: String?
    var boundAt: Date?
    var createdAt: Date?
    var extra: [String: RuntimeJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case packID = "pack_id"
        case label, tail, enabled, status
        case expiresAt = "expires_at"
        case limits, usage, reset, lifetime, bound
        case ownerID = "owner_id"
        case boundAt = "bound_at"
        case createdAt = "created_at"
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        packID = try container.decodeIfPresent(String.self, forKey: .packID) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        tail = try container.decodeIfPresent(String.self, forKey: .tail) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        status = GatewayPackKeyStatus(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "")
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt).flatMap(GatewayDates.date(from:))
        limits = try container.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage) ?? Usage()
        reset = try container.decodeIfPresent(GatewayResetSchedule.self, forKey: .reset)
        lifetime = try container.decodeIfPresent(Usage.self, forKey: .lifetime) ?? Usage()
        bound = try container.decodeIfPresent(Bool.self, forKey: .bound) ?? false
        ownerID = try container.decodeIfPresent(String.self, forKey: .ownerID)
        boundAt = try container.decodeIfPresent(String.self, forKey: .boundAt).flatMap(GatewayDates.date(from:))
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt).flatMap(GatewayDates.date(from:))
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    /// "sk-pk-…" plus the last four characters: what may be shown of a pack key.
    var maskedKey: String { "sk-pk-••••\(tail)" }
}

/// `GET /cpa-admin/packs/data`.
struct GatewayPacksData: Decodable, Sendable {
    let storeAvailable: Bool
    let persistenceFailing: Bool
    let engineKeyReady: Bool
    let packs: [GatewayPack]
    /// The engine's models (internal ids removed), for the member picker.
    let models: [String]

    private enum CodingKeys: String, CodingKey {
        case storeAvailable = "store_available"
        case persistenceFailing = "persistence_failing"
        case engineKeyReady = "engine_key_ready"
        case packs, models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeAvailable = try container.decodeIfPresent(Bool.self, forKey: .storeAvailable) ?? false
        persistenceFailing = try container.decodeIfPresent(Bool.self, forKey: .persistenceFailing) ?? false
        engineKeyReady = try container.decodeIfPresent(Bool.self, forKey: .engineKeyReady) ?? false
        packs = try container.decodeIfPresent([GatewayPack].self, forKey: .packs) ?? []
        models = (try container.decodeIfPresent([String].self, forKey: .models) ?? []).filter { !InternalModelID.isInternal($0) }
    }
}

/// `GET /cpa-admin/packs/keys?pack_id=`.
struct GatewayPackKeysResponse: Decodable, Sendable {
    let keys: [GatewayPackKey]
}

/// One key `create_keys` made: the only time its plaintext exists outside the gateway. Kept in
/// memory only (never logged, saved or put on the clipboard without the user's click).
struct GatewayCreatedPackKey: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let key: String
    let tail: String
    let label: String
}

struct GatewayCreatedPackKeysResponse: Decodable, Sendable {
    let keys: [GatewayCreatedPackKey]
}

/// A field of a patch: `keep` is not written, `set` writes the value, `clear` writes null.
enum PatchField<T: Encodable & Sendable>: Sendable {
    case keep
    case set(T)
    case clear

    var isKept: Bool {
        if case .keep = self { return true }
        return false
    }
}

extension PatchField: Equatable where T: Equatable {}

/// `create_keys`: `count` keys of one pack (labels `<prefix>-<n>` when more than one).
struct GatewayPackKeyBatch: Equatable, Sendable {
    var packID: String
    var count: Int
    var labelPrefix: String
    var expiresAt: Date?
    var totalTokens: Int?
    var totalCostUSD: Decimal?
    var reset: GatewayResetSchedule?

    init(packID: String, count: Int = 1, labelPrefix: String = "", expiresAt: Date? = nil, totalTokens: Int? = nil, totalCostUSD: Decimal? = nil, reset: GatewayResetSchedule? = nil) {
        self.packID = packID
        self.count = count
        self.labelPrefix = labelPrefix
        self.expiresAt = expiresAt
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.reset = reset
    }
}

/// `update_key`: only the fields that are not `keep` are written; `clear` writes null.
struct GatewayPackKeyPatch: Encodable, Sendable {
    let keyID: String
    var label: PatchField<String> = .keep
    var enabled: PatchField<Bool> = .keep
    var expiresAt: PatchField<Date> = .keep
    var totalTokens: PatchField<Int> = .keep
    var totalCostUSD: PatchField<Decimal> = .keep
    var reset: PatchField<GatewayResetSchedule> = .keep

    init(keyID: String) {
        self.keyID = keyID
    }

    var isEmpty: Bool {
        label.isKept && enabled.isKept && expiresAt.isKept && totalTokens.isKept && totalCostUSD.isKept && reset.isKept
    }

    private enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case label, enabled
        case expiresAt = "expires_at"
        case totalTokens = "total_tokens"
        case totalCostUSD = "total_cost_usd"
        case reset
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyID, forKey: .keyID)
        try Self.write(label.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, .label, into: &container)
        try Self.write(enabled, .enabled, into: &container)
        try Self.write(expiresAt.map(GatewayDates.string(from:)), .expiresAt, into: &container)
        try Self.write(totalTokens, .totalTokens, into: &container)
        try Self.write(totalCostUSD, .totalCostUSD, into: &container)
        try Self.write(reset, .reset, into: &container)
    }

    private static func write<T: Encodable & Sendable>(_ field: PatchField<T>, _ key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch field {
        case .keep: break
        case .set(let value): try container.encode(value, forKey: key)
        case .clear: try container.encodeNil(forKey: key)
        }
    }
}

extension PatchField {
    func map<U: Encodable & Sendable>(_ transform: (T) -> U) -> PatchField<U> {
        switch self {
        case .keep: .keep
        case .set(let value): .set(transform(value))
        case .clear: .clear
        }
    }
}

/// The body of `POST /cpa-admin/packs/save` (`applyAdminAction`). No `assign_key`.
enum GatewayPacksSaveAction: Encodable, Sendable {
    case upsertPack(GatewayPackDraft)
    case deletePack(id: String)
    case createKeys(GatewayPackKeyBatch)
    case updateKey(GatewayPackKeyPatch)
    case resetUsage(keyID: String)
    case deleteKey(keyID: String)
    case unbindKey(keyID: String)

    var name: String {
        switch self {
        case .upsertPack: "upsert_pack"
        case .deletePack: "delete_pack"
        case .createKeys: "create_keys"
        case .updateKey: "update_key"
        case .resetUsage: "reset_usage"
        case .deleteKey: "delete_key"
        case .unbindKey: "unbind_key"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(name, forKey: AnyCodingKey("action"))
        switch self {
        case .upsertPack(let draft):
            try container.encode(draft, forKey: AnyCodingKey("pack"))
        case .deletePack(let id):
            try container.encode(id, forKey: AnyCodingKey("pack_id"))
        case .createKeys(let batch):
            try container.encode(batch.packID, forKey: AnyCodingKey("pack_id"))
            try container.encode(batch.count, forKey: AnyCodingKey("count"))
            let prefix = batch.labelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { try container.encode(prefix, forKey: AnyCodingKey("label_prefix")) }
            try container.encodeIfPresent(batch.expiresAt.map(GatewayDates.string(from:)), forKey: AnyCodingKey("expires_at"))
            try container.encodeIfPresent(batch.totalTokens, forKey: AnyCodingKey("total_tokens"))
            try container.encodeIfPresent(batch.totalCostUSD, forKey: AnyCodingKey("total_cost_usd"))
            try container.encodeIfPresent(batch.reset, forKey: AnyCodingKey("reset"))
        case .updateKey(let patch):
            try patch.encode(to: encoder)
        case .resetUsage(let keyID), .deleteKey(let keyID), .unbindKey(let keyID):
            try container.encode(keyID, forKey: AnyCodingKey("key_id"))
        }
    }
}

/// The gateway's input rules (`packs.mjs`: `text`, `normalizeMembers`, `normalizeFailover`,
/// `createKeys`, `resetSchedule`, `requirePricing`), checked before anything is sent. Lengths are
/// counted like JavaScript's `String#length` (UTF-16 code units) after trimming.
enum GatewayPackValidation {
    static let maximumNameLength = 100
    static let maximumModelIDLength = 64
    static let maximumMemberModelLength = 200
    static let maximumMembers = 8
    static let maximumBatch = 500
    static let maximumLabelPrefixLength = 80

    static func errors(pack: GatewayPackDraft, hasCostLimitedKeys: Bool = false) -> [String] {
        var errors: [String] = []
        let name = pack.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf16.count > maximumNameLength || containsControl(name) {
            errors.append(OasesLocalization.localizedFormat("名称最多 %lld 个字符，且不能含控制字符。", maximumNameLength))
        }
        let modelID = pack.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelID.isEmpty || modelID.utf16.count > maximumModelIDLength || containsControl(modelID) {
            errors.append(OasesLocalization.localizedFormat("对外模型名必填，最多 %lld 个字符，且不能含控制字符。", maximumModelIDLength))
        }
        if pack.members.isEmpty || pack.members.count > maximumMembers {
            errors.append(OasesLocalization.localizedFormat("成员模型需要 1 到 %lld 个。", maximumMembers))
        }
        var seen: Set<String> = []
        for member in pack.members {
            let model = member.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty || model.utf16.count > maximumMemberModelLength || containsControl(model) {
                errors.append(OasesLocalization.localizedFormat("成员模型名必填，最多 %lld 个字符。", maximumMemberModelLength))
            } else if !seen.insert(model.lowercased()).inserted {
                errors.append(OasesLocalization.localizedFormat("成员模型 %@ 重复了（不区分大小写）。", model))
            }
            for price in [member.inputUSDPer1M, member.outputUSDPer1M].compactMap({ $0 }) where price < 0 || price.isNaN {
                errors.append(OasesLocalization.localizedFormat("%@ 的价格不能是负数。", model))
                break
            }
        }
        if !GatewayPackFailover.timeoutRange.contains(pack.failover.firstByteTimeoutMs) {
            errors.append(OasesLocalization.localized("首字节超时必须在 1000 到 120000 毫秒之间。"))
        }
        if pack.failover.maxAttempts < 1 || pack.failover.maxAttempts > max(1, pack.members.count) {
            errors.append(OasesLocalization.localizedFormat("最多尝试次数必须在 1 到成员数（%lld）之间。", pack.members.count))
        }
        if hasCostLimitedKeys && !pack.members.allSatisfy(\.isPriced) {
            errors.append(pricingRequiredMessage)
        }
        return errors
    }

    static func errors(batch: GatewayPackKeyBatch, pack: GatewayPack, now: Date = Date()) -> [String] {
        var errors: [String] = []
        if batch.count < 1 || batch.count > maximumBatch {
            errors.append(OasesLocalization.localizedFormat("一次可以创建 1 到 %lld 把 Key。", maximumBatch))
        }
        let prefix = batch.labelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.utf16.count > maximumLabelPrefixLength || containsControl(prefix) {
            errors.append(OasesLocalization.localizedFormat("名称前缀最多 %lld 个字符，且不能含控制字符。", maximumLabelPrefixLength))
        }
        if let tokens = batch.totalTokens, tokens <= 0 {
            errors.append(OasesLocalization.localized("总 Token 上限必须是正整数，或留空表示不限。"))
        }
        if let cost = batch.totalCostUSD {
            if cost <= 0 {
                errors.append(OasesLocalization.localized("总花费上限必须大于 0，或留空表示不限。"))
            } else if !pack.isPriced {
                errors.append(pricingRequiredMessage)
            }
        }
        if let reset = batch.reset {
            errors += Self.errors(reset: reset, now: now)
        }
        return errors
    }

    static func errors(reset: GatewayResetSchedule, now: Date) -> [String] {
        var errors: [String] = []
        if reset.every < 1 || reset.every > reset.unit.maximumEvery {
            errors.append(OasesLocalization.localizedFormat("恢复周期必须在 1 到 %lld 之间。", reset.unit.maximumEvery))
        }
        if let anchor = reset.anchorAt, anchor.timeIntervalSince(now) > 86_400 {
            errors.append(OasesLocalization.localized("起算时间最多只能比现在晚 1 天。"))
        }
        return errors
    }

    /// The same meaning as the gateway's 400 `pricing_required`.
    static var pricingRequiredMessage: String {
        OasesLocalization.localized("设置总花费上限前，每个成员模型都需要输入和输出价格。")
    }

    private static func containsControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
