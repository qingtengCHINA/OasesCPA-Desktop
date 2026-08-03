import Foundation

struct RuntimeAuthFilesResponse: Decodable, Sendable {
    let files: [RuntimeAuthFile]
    let total: Int?
}

struct RuntimeAuthFileStatusPatch: Encodable, Sendable {
    let name: String
    let authIndex: String?
    let disabled: Bool

    init(name: String, authIndex: String? = nil, disabled: Bool) {
        self.name = name
        self.authIndex = authIndex
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case authIndex = "auth_index"
        case disabled
    }
}

struct RuntimeAuthFile: Decodable, Identifiable, Sendable {
    let name: String
    let type: String?
    let provider: String?
    let size: Int?
    let authIndex: String?
    let runtimeOnly: Bool?
    let disabled: Bool?
    let unavailable: Bool?
    let status: String?
    let statusMessage: String?
    let modified: Double?
    let accountID: String?
    let chatgptAccountID: String?
    let idToken: RuntimeAuthFileIDTokenClaims?

    private enum CodingKeys: String, CodingKey {
        case name, type, provider, size, authIndex, runtimeOnly, disabled, unavailable, status, statusMessage, modified
        case accountID, chatgptAccountID, idToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        size = Self.decodeInt(container, forKey: .size)
        authIndex = Self.decodeString(container, forKey: .authIndex)
        runtimeOnly = Self.decodeBool(container, forKey: .runtimeOnly)
        disabled = Self.decodeBool(container, forKey: .disabled)
        unavailable = Self.decodeBool(container, forKey: .unavailable)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        modified = Self.decodeDouble(container, forKey: .modified)
        accountID = Self.decodeString(container, forKey: .accountID)
        chatgptAccountID = Self.decodeString(container, forKey: .chatgptAccountID)
        idToken = try container.decodeIfPresent(RuntimeAuthFileIDTokenClaims.self, forKey: .idToken)
    }

    private static func decodeString<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        return try? container.decodeIfPresent(Double.self, forKey: key).map(Int.init)
    }

    private static func decodeDouble<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        return try? container.decodeIfPresent(Int.self, forKey: key).map(Double.init)
    }

    private static func decodeBool<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    var id: String { name }

    var codexAccountID: String? {
        [
            chatgptAccountID,
            accountID,
            idToken?.chatgptAccountID,
            idToken?.accountID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    var displayStatus: String {
        if disabled == true { return OasesLocalization.localized("已禁用") }
        if unavailable == true { return OasesLocalization.localized("不可用") }
        if let status, !status.isEmpty { return status }
        return OasesLocalization.localized("已加载")
    }

    var statusTint: RuntimeAuthFileTint {
        if disabled == true || unavailable == true { return .warning }
        return .healthy
    }
}

struct RuntimeAuthFileIDTokenClaims: Decodable, Sendable {
    let accountID: String?
    let chatgptAccountID: String?
    let planType: String?

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptAccountIDCamel = "chatgptAccountId"
        case planType = "plan_type"
        case planTypeCamel = "planType"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = Self.decodeString(container, forKey: .accountID)
            ?? Self.decodeString(container, forKey: .accountIDCamel)
        chatgptAccountID = Self.decodeString(container, forKey: .chatgptAccountID)
            ?? Self.decodeString(container, forKey: .chatgptAccountIDCamel)
        planType = Self.decodeString(container, forKey: .planType)
            ?? Self.decodeString(container, forKey: .planTypeCamel)
    }

    private static func decodeString<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

enum RuntimeAuthFileTint: Equatable, Sendable {
    case healthy
    case warning
}
