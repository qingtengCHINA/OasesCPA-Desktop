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
        case .interactions: OasesLocalization.localized("Interactions API 密钥")
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

    /// These fields are represented by the current CLIProxyAPI collection
    /// schemas. The App performs a fresh read before replacing a collection so
    /// fields unknown to this App but known to the target are retained.
    var supportsPriority: Bool { true }
    var supportsDisableCooling: Bool { self != .vertex }
    var supportsModelMappings: Bool { true }

    var baseURLPlaceholder: String {
        switch self {
        case .gemini:
            OasesLocalization.localized("留空使用 Gemini 默认地址")
        case .interactions:
            OasesLocalization.localized("留空使用 Interactions 默认地址")
        case .codex:
            "https://api.example.com/v1"
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

    func objectValue(for key: String) -> [String: RuntimeJSONValue] {
        guard case .object(let value) = values[key] else { return [:] }
        return value
    }

    func boolValue(for key: String) -> Bool? {
        guard case .boolean(let value) = values[key] else { return nil }
        return value
    }
}

/// A model mapping entry. `values` deliberately contains the complete raw
/// object so newer CLIProxyAPI model fields survive a native edit.
struct RuntimeDirectProviderModel: Identifiable, Equatable, Sendable {
    let index: Int
    let values: [String: RuntimeJSONValue]

    var id: String {
        "\(index):\(name):\(alias)"
    }

    var name: String { stringValue(for: "name") }
    var alias: String { stringValue(for: "alias") }

    init(index: Int, values: [String: RuntimeJSONValue]) {
        self.index = index
        self.values = values
    }

    private func stringValue(for key: String) -> String {
        guard case .string(let value) = values[key] else { return "" }
        return value
    }

}

/// Editable model mapping state. Known fields are projected into properties;
/// the raw dictionary remains the source of truth for unknown child fields.
struct RuntimeDirectProviderModelDraft: Equatable, Sendable {
    var name: String
    var alias: String
    var values: [String: RuntimeJSONValue]

    init(
        name: String = "",
        alias: String = "",
        values: [String: RuntimeJSONValue] = [:]
    ) {
        self.name = name
        self.alias = alias
        self.values = values
    }

    init(model: RuntimeDirectProviderModel) {
        name = model.name
        alias = model.alias
        values = model.values
    }

    func payloadValue() -> RuntimeJSONValue {
        var result = values
        let modelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelName.isEmpty {
            result.removeValue(forKey: "name")
        } else {
            result["name"] = .string(modelName)
        }

        let modelAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelAlias.isEmpty {
            result.removeValue(forKey: "alias")
        } else {
            result["alias"] = .string(modelAlias)
        }

        return .object(result)
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
    var disableCooling: Bool { payload.boolValue(for: "disable-cooling") ?? false }
    var headerValues: [String: RuntimeJSONValue] { payload.objectValue(for: "headers") }
    var headers: [String: String] {
        headerValues.reduce(into: [:]) { result, item in
            guard case .string(let value) = item.value else { return }
            result[item.key] = value
        }
    }
    var models: [RuntimeDirectProviderModel] {
        payload.arrayValue(for: "models").enumerated().compactMap { index, value in
            guard case .object(let object) = value else { return nil }
            return RuntimeDirectProviderModel(index: index, values: object)
        }
    }

    var maskedAPIKey: String {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return OasesLocalization.localized("未配置") }
        guard value.count > 8 else { return "••••••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    var modelIDs: [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let candidate = model.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                : model.alias.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var priority: Int?
    var disableCooling: Bool
    var headers: [String: String]
    var preservedHeaderValues: [String: RuntimeJSONValue]
    var models: [RuntimeDirectProviderModelDraft]

    init(
        apiKey: String = "",
        baseURL: String = "",
        prefix: String = "",
        proxyURL: String = "",
        weight: Int? = nil,
        priority: Int? = nil,
        disableCooling: Bool = false,
        headers: [String: String] = [:],
        preservedHeaderValues: [String: RuntimeJSONValue] = [:],
        models: [RuntimeDirectProviderModelDraft] = []
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.prefix = prefix
        self.proxyURL = proxyURL
        self.weight = weight
        self.priority = priority
        self.disableCooling = disableCooling
        self.headers = headers
        self.preservedHeaderValues = preservedHeaderValues
        self.models = models
    }

    init(credential: RuntimeDirectProviderCredential) {
        // The existing secret is intentionally not copied into editable UI
        // state. An empty API key means "keep the existing key" on PATCH.
        apiKey = ""
        baseURL = credential.baseURL
        prefix = credential.prefix
        proxyURL = credential.proxyURL
        weight = credential.weight
        priority = credential.priority
        disableCooling = credential.disableCooling
        headers = credential.headers
        preservedHeaderValues = credential.headerValues.filter { item in
            if case .string = item.value { return false }
            return true
        }
        models = credential.models.map(RuntimeDirectProviderModelDraft.init(model:))
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
            return OasesLocalization.localizedFormat("%@ 凭证需要填写上游 Base URL。", kind.title)
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
        if let priority, !(0...1_000_000).contains(priority) {
            return OasesLocalization.localized("优先级必须介于 0 和 1,000,000 之间。")
        }

        for (key, value) in headers {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return OasesLocalization.localized("请求 Header 名称不能为空。")
            }
            if key.count > 256 || key.contains(where: { $0.isNewline }) {
                return OasesLocalization.localized("请求 Header 名称不能换行，且长度不能超过 256 个字符。")
            }
            if value.count > 8_192 || value.contains(where: { $0.isNewline }) {
                return OasesLocalization.localized("请求 Header 值不能换行，且长度不能超过 8192 个字符。")
            }
        }

        for model in models {
            let modelName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if modelName.isEmpty {
                return OasesLocalization.localized("模型映射的名称不能为空。")
            }
            if modelName.count > 512 || modelName.contains(where: { $0.isNewline }) {
                return OasesLocalization.localized("模型名称不能换行，且长度不能超过 512 个字符。")
            }
            if model.alias.count > 512 || model.alias.contains(where: { $0.isNewline }) {
                return OasesLocalization.localized("模型别名不能换行，且长度不能超过 512 个字符。")
            }
        }
        return nil
    }

    func newPayload(for kind: RuntimeDirectProviderKind) -> RuntimeProviderCredentialPayload {
        var values: [String: RuntimeJSONValue] = [
            "api-key": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        insertCommonValues(into: &values, for: kind)
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

        if credential.kind.supportsPriority, priority != credential.priority {
            values["priority"] = .number(Double(priority ?? 0))
        }

        if credential.kind.supportsDisableCooling,
           disableCooling != credential.disableCooling || (disableCooling && credential.payload.values["disable-cooling"] == nil) {
            if !(disableCooling == false && credential.payload.values["disable-cooling"] == nil) {
                values["disable-cooling"] = .boolean(disableCooling)
            }
        }

        let candidateHeaders = effectiveHeaderValues()
        if candidateHeaders != credential.headerValues {
            values["headers"] = .object(candidateHeaders)
        }

        if credential.kind.supportsModelMappings {
            let candidateModels = models.map { $0.payloadValue() }
            let originalModels = credential.payload.arrayValue(for: "models")
            if candidateModels != originalModels {
                values["models"] = .array(candidateModels)
            }
        }

        guard !values.isEmpty else { return nil }
        return RuntimeProviderCredentialPayload(values: values)
    }

    private func insertCommonValues(
        into values: inout [String: RuntimeJSONValue],
        for kind: RuntimeDirectProviderKind
    ) {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { values["base-url"] = .string(endpoint) }

        let modelPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelPrefix.isEmpty { values["prefix"] = .string(modelPrefix) }

        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty { values["proxy-url"] = .string(proxy) }

        if let weight { values["weight"] = .number(Double(weight)) }
        if kind.supportsPriority, let priority {
            values["priority"] = .number(Double(priority))
        }
        if kind.supportsDisableCooling {
            values["disable-cooling"] = .boolean(disableCooling)
        }

        let headerValues = effectiveHeaderValues()
        if !headerValues.isEmpty { values["headers"] = .object(headerValues) }

        if kind.supportsModelMappings {
            let modelValues = models.map { $0.payloadValue() }
            if !modelValues.isEmpty { values["models"] = .array(modelValues) }
        }
    }

    private func effectiveHeaderValues() -> [String: RuntimeJSONValue] {
        var result = preservedHeaderValues
        for (key, value) in headers {
            result[key] = .string(value)
        }
        return result
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
