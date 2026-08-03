import Foundation

enum RuntimeAccountActionStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case pending
    case all
    case ignored
    case resolved
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: OasesLocalization.localized("待处理")
        case .all: OasesLocalization.localized("全部")
        case .ignored: OasesLocalization.localized("已忽略")
        case .resolved: OasesLocalization.localized("已处理")
        case .deleted: OasesLocalization.localized("已删除")
        }
    }

    var queryValue: String? {
        self == .all ? nil : rawValue
    }
}

/// CPAMP only accepts status mutations for an existing pending candidate.
/// Deleting its auth file is intentionally left to the dedicated native
/// authentication-file workspace, where the destructive flow is explicit.
enum RuntimeAccountActionOperation: String, CaseIterable, Sendable {
    case ignore
    case resolve
    case enable

    var title: String {
        switch self {
        case .ignore: OasesLocalization.localized("忽略")
        case .resolve: OasesLocalization.localized("标记已处理")
        case .enable: OasesLocalization.localized("重新启用")
        }
    }

    var endpointComponent: String { rawValue }
}

struct RuntimeAccountActionCandidate: Identifiable, Equatable, Sendable {
    let id: Int64
    let actionType: String
    let status: String
    let provider: String
    let authFileName: String
    let authIndex: String
    let accountSnapshot: String
    let accountIDSnapshot: String
    let authLabel: String
    let reasonCode: String
    let reason: String
    let autoDisableEligible: Bool
    let autoDisabledAtMs: Int64?
    let evidence: RuntimeJSONValue?
    let lastError: String
    let firstSeenAtMs: Int64
    let lastSeenAtMs: Int64
    let hitCount: Int
    let createdAtMs: Int64
    let updatedAtMs: Int64

    init?(value: RuntimeJSONValue) {
        guard case .object(let values) = value,
              let id = Self.positiveInteger(values["id"]) else {
            return nil
        }

        self.id = id
        actionType = Self.string(values["actionType"])
        status = Self.string(values["status"])
        provider = Self.string(values["provider"])
        authFileName = Self.string(values["authFileName"])
        authIndex = Self.string(values["authIndex"])
        accountSnapshot = Self.string(values["accountSnapshot"])
        accountIDSnapshot = Self.string(values["accountIdSnapshot"])
        authLabel = Self.string(values["authLabel"])
        reasonCode = Self.string(values["reasonCode"])
        reason = Self.string(values["reason"])
        autoDisableEligible = Self.bool(values["autoDisableEligible"])
        autoDisabledAtMs = Self.positiveInteger(values["autoDisabledAtMs"])
        evidence = values["evidence"]
        lastError = Self.string(values["lastError"])
        firstSeenAtMs = Self.integer(values["firstSeenAtMs"])
        lastSeenAtMs = Self.integer(values["lastSeenAtMs"])
        hitCount = Int(clamping: max(0, Self.integer(values["hitCount"])))
        createdAtMs = Self.integer(values["createdAtMs"])
        updatedAtMs = Self.integer(values["updatedAtMs"])
    }

    var isPending: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
    }

    var actionTitle: String {
        switch actionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "delete": OasesLocalization.localized("删除认证文件")
        case "reauth": OasesLocalization.localized("重新授权")
        case "review": OasesLocalization.localized("人工复核")
        default: actionType.isEmpty ? OasesLocalization.localized("未说明") : actionType
        }
    }

    var statusTitle: String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": OasesLocalization.localized("待处理")
        case "ignored": OasesLocalization.localized("已忽略")
        case "resolved": OasesLocalization.localized("已处理")
        case "deleted": OasesLocalization.localized("已删除")
        default: status.isEmpty ? OasesLocalization.localized("未知") : status
        }
    }

    var accountTitle: String {
        [accountSnapshot, authLabel, authFileName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? OasesLocalization.localized("未命名账号")
    }

    var evidenceText: String {
        guard let evidence else { return OasesLocalization.localized("CPAMP 未返回可展示的脱敏证据。") }
        switch evidence {
        case .string(let value): return value
        case .number(let value): return numberText(value)
        case .boolean(let value): return String(value)
        case .null: return "null"
        case .object, .array: break
        }
        guard let data = try? JSONEncoder().encode(evidence),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return OasesLocalization.localized("CPAMP 返回了无法格式化的证据。")
        }
        return String(decoding: formatted, as: UTF8.self)
    }

    var searchText: String {
        [
            accountSnapshot,
            authLabel,
            accountIDSnapshot,
            provider,
            authFileName,
            authIndex,
            actionType,
            reasonCode,
            reason,
            status,
            lastError,
            evidenceHeaderValue(for: "headerErrorKind"),
            evidenceHeaderValue(for: "headerErrorCode"),
            evidenceHeaderValue(for: "headerTraceId")
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    func evidenceHeaderValue(for key: String) -> String {
        guard case .object(let values)? = evidence,
              let value = values[key] else {
            return ""
        }
        switch value {
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value): return numberText(value)
        case .boolean(let value): return String(value)
        default: return ""
        }
    }

    private static func string(_ value: RuntimeJSONValue?) -> String {
        guard case .some(.string(let value)) = value else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bool(_ value: RuntimeJSONValue?) -> Bool {
        guard case .some(.boolean(let value)) = value else { return false }
        return value
    }

    private static func positiveInteger(_ value: RuntimeJSONValue?) -> Int64? {
        let value = integer(value)
        return value > 0 ? value : nil
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int64 {
        guard case .some(.number(let numeric)) = value,
              numeric.isFinite,
              numeric >= Double(Int64.min),
              numeric <= Double(Int64.max) else {
            return 0
        }
        return Int64(numeric.rounded(.towardZero))
    }

    private func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value.rounded(.towardZero) == value,
           value >= Double(Int64.min),
           value <= Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }
}

struct RuntimeAccountActionCandidatesResponse: Decodable, Sendable {
    let items: [RuntimeAccountActionCandidate]
    let pendingCount: Int

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        if case .array(let values) = root["items"] {
            items = values.compactMap(RuntimeAccountActionCandidate.init(value:))
        } else {
            items = []
        }
        pendingCount = Int(clamping: max(0, Self.integer(root["pendingCount"])))
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int64 {
        guard case .some(.number(let numeric)) = value,
              numeric.isFinite,
              numeric >= Double(Int64.min),
              numeric <= Double(Int64.max) else {
            return 0
        }
        return Int64(numeric.rounded(.towardZero))
    }
}

struct RuntimeAccountActionCandidateResponse: Decodable, Sendable {
    let item: RuntimeAccountActionCandidate

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        guard let item = root["item"].flatMap(RuntimeAccountActionCandidate.init(value:)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing account-action candidate item")
            )
        }
        self.item = item
    }
}
