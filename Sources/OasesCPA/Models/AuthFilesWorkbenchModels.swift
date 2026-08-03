import Foundation

/// The auth-file payload is intentionally more permissive than
/// `RuntimeAuthFile`. CPAMP and CLIProxyAPI add provider-specific fields over
/// time, so the workbench only depends on stable display and mutation fields.
struct AuthFilesWorkbenchResponse: Decodable, Sendable {
    let files: [AuthFilesWorkbenchFile]
    let total: Int?
}

struct AuthFilesWorkbenchFile: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let rawID: String?
    let type: String?
    let provider: String?
    let authIndex: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let runtimeOnly: Bool?
    let email: String?
    let account: String?
    let accountID: String?
    let project: String?
    let projectID: String?
    let priority: Int?
    let note: String?
    let plan: String?
    let size: Int?
    let modified: Date?

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        name = Self.string(in: container, keys: ["name"]) ?? ""
        rawID = Self.string(in: container, keys: ["id"])
        type = Self.string(in: container, keys: ["type"])
        provider = Self.string(in: container, keys: ["provider", "channel"])
        authIndex = Self.string(in: container, keys: ["auth_index", "authIndex"])
        status = Self.string(in: container, keys: ["status"])
        statusMessage = Self.string(in: container, keys: ["status_message", "statusMessage"])
        disabled = Self.bool(in: container, keys: ["disabled"])
        unavailable = Self.bool(in: container, keys: ["unavailable"])
        runtimeOnly = Self.bool(in: container, keys: ["runtime_only", "runtimeOnly"])
        email = Self.string(in: container, keys: ["email", "account_email", "accountEmail"])
            ?? Self.nestedString(in: container, objectKeys: ["account"], keys: ["email", "email_address", "emailAddress"])
        account = Self.string(in: container, keys: ["account_name", "accountName"])
            ?? Self.nestedString(in: container, objectKeys: ["account"], keys: ["name", "id", "email"])
        accountID = Self.string(in: container, keys: [
            "account_id", "accountId", "chatgpt_account_id", "chatgptAccountId"
        ])
        project = Self.string(in: container, keys: ["project", "project_name", "projectName"])
            ?? Self.nestedString(in: container, objectKeys: ["project"], keys: ["name", "id"])
        projectID = Self.string(in: container, keys: [
            "project_id", "projectId", "gemini_virtual_project", "geminiVirtualProject"
        ])
        priority = Self.int(in: container, keys: ["priority"])
        note = Self.string(in: container, keys: ["note", "remark", "description"])
        plan = Self.string(in: container, keys: ["plan", "plan_type", "planType"])
            ?? Self.nestedString(in: container, objectKeys: ["id_token", "idToken"], keys: ["plan_type", "planType"])
        size = Self.int(in: container, keys: ["size", "bytes"])
        modified = Self.date(in: container, keys: ["modtime", "modified", "modified_at", "modifiedAt"])
    }

    var id: String { rawID?.isEmpty == false ? rawID! : name }

    /// Prefer the runtime identity for mutations. This prevents a virtual
    /// plugin credential from silently mutating or deleting its shared source
    /// file when the user selected only one expanded runtime row.
    var mutationSelector: String {
        let runtimeID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return runtimeID.isEmpty ? name : runtimeID
    }

    var providerTitle: String {
        let value = (provider ?? type ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : value
    }

    var accountTitle: String? {
        [email, account, accountID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var isDisabled: Bool { disabled == true }

    var needsAttention: Bool {
        if isDisabled || unavailable == true { return true }
        let value = [status, statusMessage]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return ["error", "fail", "expired", "invalid", "unauthor", "cooldown", "rate", "limit", "warning", "warn"]
            .contains { value.contains($0) }
    }

    var displayStatus: String {
        if isDisabled { return "已禁用" }
        if unavailable == true { return "不可用" }
        return status?.isEmpty == false ? status! : "已加载"
    }

    var searchableText: String {
        [name, providerTitle, type, email, account, accountID, project, projectID, plan, note, status]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    private static func string<C: KeyedDecodingContainerProtocol>(
        in container: C,
        keys: [String]
    ) -> String? where C.Key == Key {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let value = try? container.decode(String.self, forKey: codingKey) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: codingKey) {
                return String(value)
            }
            if let value = try? container.decode(Double.self, forKey: codingKey) {
                return String(value)
            }
        }
        return nil
    }

    private static func bool<C: KeyedDecodingContainerProtocol>(
        in container: C,
        keys: [String]
    ) -> Bool? where C.Key == Key {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let value = try? container.decode(Bool.self, forKey: codingKey) { return value }
            if let value = try? container.decode(String.self, forKey: codingKey) {
                switch value.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: break
                }
            }
        }
        return nil
    }

    private static func int<C: KeyedDecodingContainerProtocol>(
        in container: C,
        keys: [String]
    ) -> Int? where C.Key == Key {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let value = try? container.decode(Int.self, forKey: codingKey) { return value }
            if let value = try? container.decode(Double.self, forKey: codingKey) { return Int(value) }
            if let value = try? container.decode(String.self, forKey: codingKey), let number = Int(value) { return number }
        }
        return nil
    }

    private static func date<C: KeyedDecodingContainerProtocol>(
        in container: C,
        keys: [String]
    ) -> Date? where C.Key == Key {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let value = try? container.decode(Double.self, forKey: codingKey) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            if let value = try? container.decode(Int64.self, forKey: codingKey) {
                let seconds = Double(value)
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
            }
            if let value = try? container.decode(String.self, forKey: codingKey) {
                if let number = Double(value) {
                    return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
                }
                if let date = ISO8601DateFormatter().date(from: value) { return date }
            }
        }
        return nil
    }

    private static func nestedString<C: KeyedDecodingContainerProtocol>(
        in container: C,
        objectKeys: [String],
        keys: [String]
    ) -> String? where C.Key == Key {
        for objectKey in objectKeys {
            guard let key = Key(stringValue: objectKey),
                  let nested = try? container.nestedContainer(keyedBy: Key.self, forKey: key) else { continue }
            if let value = string(in: nested, keys: keys) { return value }
        }
        return nil
    }
}

struct AuthFilesWorkbenchModelsResponse: Decodable, Sendable {
    let models: [AuthFilesWorkbenchModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        models = (try? container.decode([AuthFilesWorkbenchModel].self, forKey: DynamicCodingKey(stringValue: "models")!)) ?? []
    }
}

struct AuthFilesWorkbenchModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String?
    let type: String?
    let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type
        case ownedBy = "owned_by"
    }
}

struct AuthFilesWorkbenchStatusPatch: Encodable, Sendable {
    let name: String
    let authIndex: String?
    let disabled: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case authIndex = "auth_index"
        case disabled
    }
}

struct AuthFilesWorkbenchFieldsPatch: Encodable, Sendable {
    let name: String
    let priority: Int?
    let note: String?
    let projectID: String?
    let expired: String?
    let lastRefresh: String?

    init(
        name: String,
        priority: Int? = nil,
        note: String? = nil,
        projectID: String? = nil,
        expired: String? = nil,
        lastRefresh: String? = nil
    ) {
        self.name = name
        self.priority = priority
        self.note = note
        self.projectID = projectID
        self.expired = expired
        self.lastRefresh = lastRefresh
    }

    private enum CodingKeys: String, CodingKey {
        case name, priority, note
        case projectID = "project_id"
        case expired
        case lastRefresh = "last_refresh"
    }
}

enum AuthFilesWorkbenchProviderFilter: Hashable, Sendable {
    case all
    case provider(String)
}

enum AuthFilesWorkbenchAttentionFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case attention
    case enabled
    case disabled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return OasesLocalization.localized("全部")
        case .attention: return OasesLocalization.localized("需关注")
        case .enabled: return OasesLocalization.localized("已启用")
        case .disabled: return OasesLocalization.localized("已禁用")
        }
    }
}

enum AuthFilesWorkbenchSort: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case name
    case priority
    case plan

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: return OasesLocalization.localized("默认")
        case .name: return OasesLocalization.localized("名称")
        case .priority: return OasesLocalization.localized("优先级")
        case .plan: return OasesLocalization.localized("套餐")
        }
    }
}

enum AuthFilesWorkbenchDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case regular
    case compact

    var id: String { rawValue }
    var title: String {
        OasesLocalization.localized(self == .regular ? "卡片" : "紧凑")
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
