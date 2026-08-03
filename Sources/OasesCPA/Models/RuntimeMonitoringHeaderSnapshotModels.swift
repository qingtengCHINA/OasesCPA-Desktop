import Foundation

/// A compact, read-only response from CPAMP's per-identity header snapshot
/// endpoint. The native app deliberately decodes only derived, structured
/// fields and ignores response metadata, which can contain arbitrary provider
/// response content.
struct RuntimeMonitoringHeaderSnapshotsResponse: Decodable, Equatable, Sendable {
    let generatedAtMs: Int64
    let fromMs: Int64
    let toMs: Int64
    let items: [RuntimeMonitoringHeaderSnapshot]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        generatedAtMs = Self.integer(Self.value(in: root, keys: ["generated_at_ms", "generatedAtMs"]))
        fromMs = Self.integer(Self.value(in: root, keys: ["from_ms", "fromMs"]))
        toMs = Self.integer(Self.value(in: root, keys: ["to_ms", "toMs"]))
        if case .some(.array(let rawItems)) = Self.value(in: root, keys: ["items"]) {
            items = rawItems.compactMap(RuntimeMonitoringHeaderSnapshot.init(value:))
        } else {
            items = []
        }
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
}

/// Known-safe, display-oriented evidence from the newest provider response for
/// one CPAMP authentication identity. Raw response metadata is intentionally
/// absent from this type and cannot be rendered by the native UI.
struct RuntimeMonitoringHeaderSnapshot: Identifiable, Equatable, Sendable {
    let eventHash: String
    let timestampMs: Int64
    let authFileSnapshot: String
    let authIndex: String
    let accountSnapshot: String
    let authLabelSnapshot: String
    let authProviderSnapshot: String
    let authProjectIdSnapshot: String
    let source: String
    let sourceHash: String
    let headerQuotaRecoverAtMs: Int64?
    let headerQuotaUsedPercent: Double?
    let headerQuotaPlanType: String
    let headerErrorKind: String
    let headerErrorCode: String
    let headerTraceId: String

    var id: String { eventHash }

    init?(value: RuntimeJSONValue) {
        guard case .object(let values) = value else { return nil }
        let eventHash = Self.string(Self.value(in: values, keys: ["event_hash", "eventHash"]))
        let timestampMs = Self.integer(Self.value(in: values, keys: ["timestamp_ms", "timestampMs"]))
        guard !eventHash.isEmpty, timestampMs > 0 else { return nil }

        self.eventHash = eventHash
        self.timestampMs = timestampMs
        authFileSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_file_snapshot", "authFileSnapshot"])
        )
        authIndex = Self.string(Self.value(in: values, keys: ["auth_index", "authIndex"]))
        accountSnapshot = Self.string(
            Self.value(in: values, keys: ["account_snapshot", "accountSnapshot"])
        )
        authLabelSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_label_snapshot", "authLabelSnapshot"])
        )
        authProviderSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_provider_snapshot", "authProviderSnapshot"])
        )
        authProjectIdSnapshot = Self.string(
            Self.value(in: values, keys: ["auth_project_id_snapshot", "authProjectIdSnapshot"])
        )
        source = Self.string(Self.value(in: values, keys: ["source"]))
        sourceHash = Self.string(Self.value(in: values, keys: ["source_hash", "sourceHash"]))
        headerQuotaRecoverAtMs = Self.optionalInteger(
            Self.value(
                in: values,
                keys: ["header_quota_recover_at_ms", "headerQuotaRecoverAtMs"]
            )
        ).flatMap { $0 > 0 ? $0 : nil }
        headerQuotaUsedPercent = Self.optionalDouble(
            Self.value(
                in: values,
                keys: ["header_quota_used_percent", "headerQuotaUsedPercent"]
            )
        ).flatMap { (0...100).contains($0) ? $0 : nil }
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
    }

    var sourceTitle: String {
        [
            authLabelSnapshot,
            accountSnapshot,
            authFileSnapshot,
            source,
            authIndex
        ]
        .first(where: { !$0.isEmpty }) ?? OasesLocalization.localized("未知认证来源")
    }

    var providerTitle: String {
        [authProviderSnapshot, authIndex]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var errorTitle: String? {
        let values = [headerErrorKind, headerErrorCode].filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var quotaUsedPercentTitle: String? {
        guard let headerQuotaUsedPercent else { return nil }
        return String(format: "%.1f%%", headerQuotaUsedPercent)
    }

    var hasErrorSignal: Bool {
        errorTitle != nil
    }

    private static func value(
        in values: [String: RuntimeJSONValue],
        keys: [String]
    ) -> RuntimeJSONValue? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func string(_ value: RuntimeJSONValue?) -> String {
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

    private static func safeInteger(_ number: Double) -> Int64? {
        let rounded = number.rounded(.towardZero)
        let lowerBound = -9_223_372_036_854_775_808.0
        let upperBound = 9_223_372_036_854_775_808.0
        guard rounded >= lowerBound, rounded < upperBound else { return nil }
        return Int64(rounded)
    }
}
