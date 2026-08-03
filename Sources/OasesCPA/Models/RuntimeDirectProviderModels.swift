import Foundation

/// The built-in credential collections exposed by CLIProxyAPI's management API.
///
/// These are deliberately separate from OAuth auth-files and OpenAI-compatible
/// providers: each collection has its own endpoint and upstream routing rules.
enum RuntimeDirectProviderKind: String, CaseIterable, Identifiable, Sendable {
    case gemini
    case interactions
    case codex
    case xai
    case claude
    case vertex

    var id: String { rawValue }

    var managementSection: String {
        switch self {
        case .gemini: "gemini-api-key"
        case .interactions: "interactions-api-key"
        case .codex: "codex-api-key"
        case .xai: "xai-api-key"
        case .claude: "claude-api-key"
        case .vertex: "vertex-api-key"
        }
    }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .interactions: "Interactions"
        case .codex: "Codex"
        case .xai: "xAI"
        case .claude: "Claude"
        case .vertex: "Vertex Compatible"
        }
    }

    var subtitle: String {
        switch self {
        case .gemini: OasesLocalization.localized("Google Gemini API 密钥与路由覆盖")
        case .interactions: OasesLocalization.localized("OpenAI Interactions API 密钥")
        case .codex: OasesLocalization.localized("Codex / Responses 上游密钥")
        case .xai: OasesLocalization.localized("xAI 上游密钥与路由覆盖")
        case .claude: OasesLocalization.localized("Anthropic Claude API 密钥")
        case .vertex: OasesLocalization.localized("Vertex 风格兼容 API 密钥")
        }
    }

    var systemImage: String {
        switch self {
        case .gemini: "sparkles"
        case .interactions: "bubble.left.and.bubble.right"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .xai: "bolt.circle"
        case .claude: "text.quote"
        case .vertex: "triangle"
        }
    }

    /// The current CLIProxyAPI PUT handlers silently filter empty-base-url
    /// Codex and xAI entries, and their PATCH handlers treat an empty base URL
    /// as a removal. Requiring one prevents a misleading save or accidental
    /// deletion from the simplified native editor.
    var requiresBaseURL: Bool {
        self == .codex || self == .xai
    }

    var baseURLPlaceholder: String {
        switch self {
        case .gemini:
            OasesLocalization.localized("留空使用 Gemini 默认地址")
        case .interactions:
            OasesLocalization.localized("留空使用 Interactions 默认地址")
        case .codex:
            "https://api.openai.com/v1"
        case .xai:
            "https://api.x.ai/v1"
        case .claude:
            OasesLocalization.localized("留空使用 Claude 默认地址")
        case .vertex:
            OasesLocalization.localized("留空使用 Vertex 默认地址")
        }
    }
}

/// A raw provider entry that round-trips all server fields, including fields
/// newer than this App. The simplified native UI only changes selected fields.
struct RuntimeProviderCredentialPayload: Codable, Equatable, Sendable {
    var values: [String: RuntimeJSONValue]

    init(values: [String: RuntimeJSONValue] = [:]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        values = try [String: RuntimeJSONValue](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    func stringValue(for key: String) -> String {
        guard case .string(let value) = values[key] else { return "" }
        return value
    }

    func intValue(for key: String) -> Int? {
        guard case .number(let value) = values[key], value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    func arrayValue(for key: String) -> [RuntimeJSONValue] {
        guard case .array(let value) = values[key] else { return [] }
        return value
    }
}

struct RuntimeDirectProviderCredential: Identifiable, Equatable, Sendable {
    let kind: RuntimeDirectProviderKind
    let index: Int
    let payload: RuntimeProviderCredentialPayload

    var id: String {
        let authIndex = payload.stringValue(for: "auth-index")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return authIndex.isEmpty ? "\(kind.rawValue):\(index)" : "\(kind.rawValue):\(authIndex)"
    }

    var apiKey: String { payload.stringValue(for: "api-key") }
    var baseURL: String { payload.stringValue(for: "base-url") }
    var prefix: String { payload.stringValue(for: "prefix") }
    var proxyURL: String { payload.stringValue(for: "proxy-url") }
    var authIndex: String { payload.stringValue(for: "auth-index") }
    var weight: Int? { payload.intValue(for: "weight") }
    var priority: Int? { payload.intValue(for: "priority") }

    var maskedAPIKey: String {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return OasesLocalization.localized("未配置") }
        guard value.count > 8 else { return "••••••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    var modelIDs: [String] {
        var seen = Set<String>()
        return payload.arrayValue(for: "models").compactMap { value in
            guard case .object(let object) = value else { return nil }
            let alias: String
            if case .string(let value) = object["alias"] {
                alias = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                alias = ""
            }
            let name: String
            if case .string(let value) = object["name"] {
                name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = ""
            }
            let candidate = alias.isEmpty ? name : alias
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { return nil }
            return candidate
        }
    }
}

enum RuntimeDirectProviderCredentialDecoder {
    static func decode(
        _ data: Data,
        kind: RuntimeDirectProviderKind,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> [RuntimeDirectProviderCredential] {
        let root = try decoder.decode([String: RuntimeJSONValue].self, from: data)
        let listValue = root[kind.managementSection] ?? root["items"]
        guard case .array(let values) = listValue else { return [] }

        return values.enumerated().compactMap { index, value in
            guard case .object(let object) = value else { return nil }
            return RuntimeDirectProviderCredential(
                kind: kind,
                index: index,
                payload: RuntimeProviderCredentialPayload(values: object)
            )
        }
    }
}

struct RuntimeDirectProviderCredentialDraft: Equatable, Sendable {
    var apiKey: String
    var baseURL: String
    var prefix: String
    var proxyURL: String
    var weight: Int?

    init(
        apiKey: String = "",
        baseURL: String = "",
        prefix: String = "",
        proxyURL: String = "",
        weight: Int? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.prefix = prefix
        self.proxyURL = proxyURL
        self.weight = weight
    }

    init(credential: RuntimeDirectProviderCredential) {
        // The existing secret is intentionally not copied into editable UI
        // state. An empty API key means "keep the existing key" on PATCH.
        apiKey = ""
        baseURL = credential.baseURL
        prefix = credential.prefix
        proxyURL = credential.proxyURL
        weight = credential.weight
    }

    func validationMessage(
        for kind: RuntimeDirectProviderKind,
        isNew: Bool
    ) -> String? {
        let newKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew && newKey.isEmpty {
            return OasesLocalization.localized("请填写 API Key。")
        }
        if !newKey.isEmpty && (newKey.count > 4_096 || newKey.contains(where: { $0.isNewline })) {
            return OasesLocalization.localized("API Key 不能包含换行，且长度不能超过 4096 个字符。")
        }

        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind.requiresBaseURL && endpoint.isEmpty {
            return "\(kind.title) 凭证需要填写上游 Base URL。"
        }
        if !endpoint.isEmpty && !Self.isHTTPURL(endpoint) {
            return OasesLocalization.localized("Base URL 必须是包含 http 或 https 协议的有效地址。")
        }

        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty && !Self.isNetworkURL(proxy) {
            return OasesLocalization.localized("代理地址必须包含有效协议和主机名。")
        }

        if prefix.contains(where: { $0.isNewline }) || prefix.count > 240 {
            return OasesLocalization.localized("模型前缀不能包含换行，且长度不能超过 240 个字符。")
        }
        if let weight, !(1...1_000_000).contains(weight) {
            return OasesLocalization.localized("流量权重必须介于 1 和 1,000,000 之间。")
        }
        return nil
    }

    func newPayload(for kind: RuntimeDirectProviderKind) -> RuntimeProviderCredentialPayload {
        var values: [String: RuntimeJSONValue] = [
            "api-key": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        insertCommonValues(into: &values)
        return RuntimeProviderCredentialPayload(values: values)
    }

    func patch(relativeTo credential: RuntimeDirectProviderCredential) -> RuntimeProviderCredentialPayload? {
        var values: [String: RuntimeJSONValue] = [:]
        let candidateKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidateKey.isEmpty && candidateKey != credential.apiKey {
            values["api-key"] = .string(candidateKey)
        }

        let candidateBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateBaseURL != credential.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) {
            values["base-url"] = .string(candidateBaseURL)
        }

        let candidatePrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidatePrefix != credential.prefix.trimmingCharacters(in: .whitespacesAndNewlines) {
            values["prefix"] = .string(candidatePrefix)
        }

        let candidateProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateProxy != credential.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines) {
            values["proxy-url"] = .string(candidateProxy)
        }

        if weight != credential.weight {
            values["weight"] = weight.map { .number(Double($0)) } ?? .null
        }

        guard !values.isEmpty else { return nil }
        return RuntimeProviderCredentialPayload(values: values)
    }

    private func insertCommonValues(into values: inout [String: RuntimeJSONValue]) {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { values["base-url"] = .string(endpoint) }

        let modelPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelPrefix.isEmpty { values["prefix"] = .string(modelPrefix) }

        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty { values["proxy-url"] = .string(proxy) }

        if let weight { values["weight"] = .number(Double(weight)) }
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func isNetworkURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }
}

struct RuntimeDirectProviderCredentialPatchRequest: Encodable, Sendable {
    let index: Int
    let value: RuntimeProviderCredentialPayload
}
