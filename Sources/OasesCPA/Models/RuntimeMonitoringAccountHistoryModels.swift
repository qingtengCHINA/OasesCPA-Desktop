import Foundation

/// Request body for CPAMP's account-history endpoint. The native app only
/// sends identity fields that are already available in its safe header
/// snapshots; it never persists or renders the server-derived account key.
struct RuntimeMonitoringAccountHistoryRequest: Encodable, Sendable {
    static let maximumTargets = 200

    let accounts: [RuntimeMonitoringAccountHistoryTarget]
    let catchUp: Bool

    init(
        accounts: [RuntimeMonitoringAccountHistoryTarget],
        catchUp: Bool
    ) {
        self.accounts = Array(accounts.prefix(Self.maximumTargets))
        self.catchUp = catchUp
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case catchUp = "catch_up"
    }
}

/// A display-safe CPAMP account-history lookup target. An account key is
/// intentionally absent: CPAMP derives it from these normalized fields.
struct RuntimeMonitoringAccountHistoryTarget: Identifiable, Hashable, Encodable, Sendable {
    let accountSnapshot: String
    let authLabelSnapshot: String
    let authIndex: String
    let source: String

    init?(
        accountSnapshot: String,
        authLabelSnapshot: String,
        authIndex: String,
        source: String
    ) {
        self.accountSnapshot = Self.normalized(accountSnapshot)
        self.authLabelSnapshot = Self.normalized(authLabelSnapshot)
        self.authIndex = Self.normalized(authIndex)
        self.source = Self.normalized(source)

        guard !self.accountSnapshot.isEmpty ||
              !self.authLabelSnapshot.isEmpty ||
              !self.authIndex.isEmpty ||
              !self.source.isEmpty else {
            return nil
        }
    }

    init?(snapshot: RuntimeMonitoringHeaderSnapshot) {
        self.init(
            accountSnapshot: snapshot.accountSnapshot,
            authLabelSnapshot: snapshot.authLabelSnapshot,
            authIndex: snapshot.authIndex,
            source: snapshot.source
        )
    }

    var id: String {
        [
            "account:\(accountSnapshot.count):\(accountSnapshot)",
            "label:\(authLabelSnapshot.count):\(authLabelSnapshot)",
            "source:\(source.count):\(source)",
            "index:\(authIndex.count):\(authIndex)"
        ]
        .joined(separator: "|")
    }

    var displayTitle: String {
        [
            authLabelSnapshot,
            accountSnapshot,
            source,
            authIndex
        ]
        .first(where: { !$0.isEmpty }) ?? OasesLocalization.localized("未知认证来源")
    }

    private enum CodingKeys: String, CodingKey {
        case accountSnapshot = "account_snapshot"
        case authLabelSnapshot = "auth_label_snapshot"
        case authIndex = "auth_index"
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !accountSnapshot.isEmpty {
            try container.encode(accountSnapshot, forKey: .accountSnapshot)
        }
        if !authLabelSnapshot.isEmpty {
            try container.encode(authLabelSnapshot, forKey: .authLabelSnapshot)
        }
        if !authIndex.isEmpty {
            try container.encode(authIndex, forKey: .authIndex)
        }
        if !source.isEmpty {
            try container.encode(source, forKey: .source)
        }
    }

    private static func normalized(_ rawValue: String) -> String {
        String(
            rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
        )
    }
}

/// Read-only response from CPAMP's per-identity history aggregate endpoint.
/// The items collection preserves server response positions so malformed
/// entries cannot be shifted onto a different local identity.
struct RuntimeMonitoringAccountHistoryResponse: Decodable, Equatable, Sendable {
    let generatedAtMs: Int64
    let checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    let items: [RuntimeMonitoringAccountHistoryItem?]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        generatedAtMs = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: root,
                keys: ["generated_at_ms", "generatedAtMs"]
            )
        )
        checkpoint = RuntimeMonitoringAccountHistoryCheckpoint(
            value: RuntimeMonitoringAccountHistoryValue.value(
                in: root,
                keys: ["checkpoint"]
            )
        )
        if case .some(.array(let rawItems)) = RuntimeMonitoringAccountHistoryValue.value(
            in: root,
            keys: ["items"]
        ) {
            items = rawItems.map(RuntimeMonitoringAccountHistoryItem.init(value:))
        } else {
            items = []
        }
    }
}

struct RuntimeMonitoringAccountHistoryCheckpoint: Equatable, Sendable {
    let lastEventID: Int64
    let latestID: Int64
    let pending: Bool
    let processed: Int64

    init(value: RuntimeJSONValue?) {
        guard case .some(.object(let values)) = value else {
            lastEventID = 0
            latestID = 0
            pending = false
            processed = 0
            return
        }

        lastEventID = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["last_event_id", "lastEventId"]
            )
        )
        latestID = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["latest_id", "latestId"]
            )
        )
        pending = RuntimeMonitoringAccountHistoryValue.boolean(
            RuntimeMonitoringAccountHistoryValue.value(in: values, keys: ["pending"])
        )
        processed = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(in: values, keys: ["processed"])
        )
    }
}

enum RuntimeMonitoringAccountHistorySyncStatus: String, Equatable, Sendable {
    case ready
    case pending
    case empty
    case unknown

    init(value: RuntimeJSONValue?) {
        let normalized = RuntimeMonitoringAccountHistoryValue.string(value)
            .lowercased()
        self = Self(rawValue: normalized) ?? .unknown
    }

    var title: String {
        switch self {
        case .ready:
            OasesLocalization.localized("已汇总")
        case .pending:
            OasesLocalization.localized("待补齐")
        case .empty:
            OasesLocalization.localized("暂无汇总")
        case .unknown:
            OasesLocalization.localized("状态未知")
        }
    }
}

/// Aggregate fields that are safe to display for one identity. The upstream
/// account key field is deliberately ignored during decoding.
struct RuntimeMonitoringAccountHistoryItem: Equatable, Sendable {
    let matched: Bool
    let totalRequests: Int64
    let successCalls: Int64
    let failureCalls: Int64
    let totalTokens: Int64
    let totalCost: Double
    let successRate: Double?
    let firstSeenMs: Int64?
    let lastSeenMs: Int64?
    let syncStatus: RuntimeMonitoringAccountHistorySyncStatus

    init?(value: RuntimeJSONValue) {
        guard case .object(let values) = value else { return nil }

        matched = RuntimeMonitoringAccountHistoryValue.boolean(
            RuntimeMonitoringAccountHistoryValue.value(in: values, keys: ["matched"])
        )
        totalRequests = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["total_requests", "totalRequests"]
            )
        )
        successCalls = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["success_calls", "successCalls"]
            )
        )
        failureCalls = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["failure_calls", "failureCalls"]
            )
        )
        totalTokens = RuntimeMonitoringAccountHistoryValue.nonnegativeInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["total_tokens", "totalTokens"]
            )
        )
        totalCost = RuntimeMonitoringAccountHistoryValue.nonnegativeDouble(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["total_cost", "totalCost"]
            )
        )
        successRate = RuntimeMonitoringAccountHistoryValue.optionalDouble(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["success_rate", "successRate"]
            )
        )
        .flatMap { (0...1).contains($0) ? $0 : nil }
        firstSeenMs = RuntimeMonitoringAccountHistoryValue.optionalPositiveInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["first_seen_ms", "firstSeenMs"]
            )
        )
        lastSeenMs = RuntimeMonitoringAccountHistoryValue.optionalPositiveInteger(
            RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["last_seen_ms", "lastSeenMs"]
            )
        )
        syncStatus = RuntimeMonitoringAccountHistorySyncStatus(
            value: RuntimeMonitoringAccountHistoryValue.value(
                in: values,
                keys: ["sync_status", "syncStatus"]
            )
        )
    }
}

/// Local pairing of the request target and response position. This lets the
/// UI show a friendly, safe identity title without trusting server account keys.
struct RuntimeMonitoringAccountHistoryEntry: Identifiable, Equatable, Sendable {
    let target: RuntimeMonitoringAccountHistoryTarget
    let item: RuntimeMonitoringAccountHistoryItem?

    var id: String { target.id }
}

private enum RuntimeMonitoringAccountHistoryValue {
    static func value(
        in values: [String: RuntimeJSONValue],
        keys: [String]
    ) -> RuntimeJSONValue? {
        keys.lazy.compactMap { values[$0] }.first
    }

    static func string(_ value: RuntimeJSONValue?) -> String {
        let rawValue: String
        switch value {
        case .some(.string(let value)):
            rawValue = value
        case .some(.number(let value)) where value.isFinite:
            guard let integer = safeInteger(value) else { return "" }
            rawValue = String(integer)
        case .some(.boolean(let value)):
            rawValue = String(value)
        default:
            return ""
        }
        return String(
            rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
        )
    }

    static func integer(_ value: RuntimeJSONValue?) -> Int64 {
        switch value {
        case .some(.number(let value)) where value.isFinite:
            return safeInteger(value) ?? 0
        case .some(.string(let value)):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    static func nonnegativeInteger(_ value: RuntimeJSONValue?) -> Int64 {
        max(0, integer(value))
    }

    static func optionalPositiveInteger(_ value: RuntimeJSONValue?) -> Int64? {
        let parsed: Int64?
        switch value {
        case .some(.number(let value)) where value.isFinite:
            parsed = safeInteger(value)
        case .some(.string(let value)):
            parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }

    static func optionalDouble(_ value: RuntimeJSONValue?) -> Double? {
        switch value {
        case .some(.number(let value)) where value.isFinite:
            return value
        case .some(.string(let value)):
            guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed.isFinite else {
                return nil
            }
            return parsed
        default:
            return nil
        }
    }

    static func nonnegativeDouble(_ value: RuntimeJSONValue?) -> Double {
        guard let value = optionalDouble(value), value >= 0 else { return 0 }
        return min(value, 1_000_000_000_000_000)
    }

    static func boolean(_ value: RuntimeJSONValue?) -> Bool {
        switch value {
        case .some(.boolean(let value)):
            return value
        case .some(.number(let value)) where value.isFinite:
            return value != 0
        case .some(.string(let value)):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            default:
                return false
            }
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
