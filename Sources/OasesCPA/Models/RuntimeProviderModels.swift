import Foundation

struct RuntimeOpenAICompatibilityResponse: Decodable, Sendable {
    let providers: [RuntimeOpenAICompatibility]

    private enum CodingKeys: String, CodingKey {
        case dashed = "openai-compatibility"
        case camel = "openaiCompatibility"
        case legacy = "openAICompatibility"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([RuntimeOpenAICompatibility].self, forKey: .dashed)
            ?? container.decodeIfPresent([RuntimeOpenAICompatibility].self, forKey: .camel)
            ?? container.decodeIfPresent([RuntimeOpenAICompatibility].self, forKey: .legacy)
            ?? []
    }
}

struct RuntimeOpenAICompatibility: Decodable, Identifiable, Sendable {
    let name: String
    let priority: Int
    let disabled: Bool
    let prefix: String
    let baseURL: String
    let apiKeyEntries: [RuntimeProviderAPIKey]
    let models: [RuntimeProviderModel]
    let headers: [String: String]
    let disableCooling: Bool
    let authIndex: String?

    init(
        name: String,
        priority: Int = 0,
        disabled: Bool = false,
        prefix: String = "",
        baseURL: String,
        apiKeyEntries: [RuntimeProviderAPIKey] = [],
        models: [RuntimeProviderModel] = [],
        headers: [String: String] = [:],
        disableCooling: Bool = false,
        authIndex: String? = nil
    ) {
        self.name = name
        self.priority = priority
        self.disabled = disabled
        self.prefix = prefix
        self.baseURL = baseURL
        self.apiKeyEntries = apiKeyEntries
        self.models = models
        self.headers = headers
        self.disableCooling = disableCooling
        self.authIndex = authIndex
    }

    var id: String {
        let identity = authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return identity.isEmpty ? "\(name)\u{0}\(baseURL)" : identity
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case priority
        case disabled
        case prefix
        case baseURL = "base-url"
        case apiKeyEntries = "api-key-entries"
        case models
        case headers
        case disableCooling = "disable-cooling"
        case authIndex = "auth-index"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKeyEntries = try container.decodeIfPresent([RuntimeProviderAPIKey].self, forKey: .apiKeyEntries) ?? []
        models = try container.decodeIfPresent([RuntimeProviderModel].self, forKey: .models) ?? []
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        disableCooling = try container.decodeIfPresent(Bool.self, forKey: .disableCooling) ?? false
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
    }
}

struct RuntimeOpenAICompatibilityWrite: Encodable, Sendable {
    /// A copy with another prefix.
    func withPrefix(_ prefix: String) -> RuntimeOpenAICompatibilityWrite {
        RuntimeOpenAICompatibilityWrite(
            name: name, priority: priority, disabled: disabled, prefix: prefix, baseURL: baseURL,
            apiKeyEntries: apiKeyEntries, models: models, headers: headers, disableCooling: disableCooling
        )
    }

    let name: String
    let priority: Int
    let disabled: Bool
    let prefix: String
    let baseURL: String
    let apiKeyEntries: [RuntimeProviderAPIKey]
    let models: [RuntimeProviderModel]
    let headers: [String: String]
    let disableCooling: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case priority
        case disabled
        case prefix
        case baseURL = "base-url"
        case apiKeyEntries = "api-key-entries"
        case models
        case headers
        case disableCooling = "disable-cooling"
    }
}

struct RuntimeProviderAPIKey: Codable, Sendable {
    let apiKey: String
    let weight: Int?
    let proxyURL: String
    let authIndex: String?

    var redacted: String {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 8 else { return value.isEmpty ? OasesLocalization.localized("未配置") : "••••••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    var appearsRedacted: Bool {
        apiKey.contains("•") || apiKey.contains("*")
    }

    init(apiKey: String, weight: Int? = nil, proxyURL: String = "", authIndex: String? = nil) {
        self.apiKey = apiKey
        self.weight = weight
        self.proxyURL = proxyURL
        self.authIndex = authIndex
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api-key"
        case weight
        case proxyURL = "proxy-url"
        case authIndex = "auth-index"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        weight = try container.decodeIfPresent(Int.self, forKey: .weight)
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encodeIfPresent(weight, forKey: .weight)
        if !proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(proxyURL, forKey: .proxyURL)
        }
        // auth-index is generated by CLIProxyAPI and must not be client-authored.
    }
}

struct RuntimeProviderModel: Codable, Sendable {
    let name: String
    let alias: String
    let displayName: String
    let forceMapping: Bool?
    let image: Bool?
    let inputModalities: [String]?
    let outputModalities: [String]?
    let thinking: RuntimeJSONValue?

    init(
        name: String,
        alias: String = "",
        displayName: String = "",
        forceMapping: Bool? = nil,
        image: Bool? = nil,
        inputModalities: [String]? = nil,
        outputModalities: [String]? = nil,
        thinking: RuntimeJSONValue? = nil
    ) {
        self.name = name
        self.alias = alias
        self.displayName = displayName
        self.forceMapping = forceMapping
        self.image = image
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.thinking = thinking
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case alias
        case displayName = "display-name"
        case forceMapping = "force-mapping"
        case image
        case inputModalities = "input-modalities"
        case outputModalities = "output-modalities"
        case thinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        forceMapping = try container.decodeIfPresent(Bool.self, forKey: .forceMapping)
        image = try container.decodeIfPresent(Bool.self, forKey: .image)
        inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities)
        outputModalities = try container.decodeIfPresent([String].self, forKey: .outputModalities)
        thinking = try container.decodeIfPresent(RuntimeJSONValue.self, forKey: .thinking)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if !alias.isEmpty {
            try container.encode(alias, forKey: .alias)
        }
        if !displayName.isEmpty {
            try container.encode(displayName, forKey: .displayName)
        }
        try container.encodeIfPresent(forceMapping, forKey: .forceMapping)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(inputModalities, forKey: .inputModalities)
        try container.encodeIfPresent(outputModalities, forKey: .outputModalities)
        try container.encodeIfPresent(thinking, forKey: .thinking)
    }
}

enum RuntimeJSONValue: Codable, Equatable, Sendable {
    case object([String: RuntimeJSONValue])
    case array([RuntimeJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RuntimeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RuntimeJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct RuntimeOpenAICompatibilityPatch: Encodable, Sendable {
    let name: String?
    let prefix: String?
    /// Higher is tried first. nil is not encoded (the engine keeps the stored value).
    let priority: Int?
    let disabled: Bool?
    let disableCooling: Bool?
    let baseURL: String?
    let apiKeyEntries: [RuntimeProviderAPIKey]?
    let models: [RuntimeProviderModel]?
    let headers: [String: String]?

    init(
        name: String? = nil,
        prefix: String? = nil,
        priority: Int? = nil,
        disabled: Bool? = nil,
        disableCooling: Bool? = nil,
        baseURL: String? = nil,
        apiKeyEntries: [RuntimeProviderAPIKey]? = nil,
        models: [RuntimeProviderModel]? = nil,
        headers: [String: String]? = nil
    ) {
        self.name = name
        self.prefix = prefix
        self.priority = priority
        self.disabled = disabled
        self.disableCooling = disableCooling
        self.baseURL = baseURL
        self.apiKeyEntries = apiKeyEntries
        self.models = models
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case prefix
        case priority
        case disabled
        case disableCooling = "disable-cooling"
        case baseURL = "base-url"
        case apiKeyEntries = "api-key-entries"
        case models
        case headers
    }
}

struct RuntimeOpenAICompatibilityPatchRequest: Encodable, Sendable {
    let name: String?
    let index: Int?
    let value: RuntimeOpenAICompatibilityPatch

    private enum CodingKeys: String, CodingKey {
        case name
        case index
        case value
    }
}

enum RuntimeOpenAICompatibilityListAppendOutcome: Equatable, Sendable {
    case appended
    case existing(index: Int)
}

struct RuntimeOpenAICompatibilityListAppendPayload: Sendable {
    let outcome: RuntimeOpenAICompatibilityListAppendOutcome
    let requestBody: Data?
}

enum RuntimeOpenAICompatibilityListMutationError: LocalizedError {
    case invalidResponse
    case invalidProvider

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            OasesLocalization.localized("当前目标返回的兼容 Provider 列表格式不兼容。")
        case .invalidProvider:
            OasesLocalization.localized("要写入的兼容 Provider 缺少名称或 Base URL。")
        }
    }
}

enum RuntimeOpenAICompatibilityListMutation {
    private static let responseKeys = [
        "openai-compatibility",
        "openaiCompatibility",
        "openAICompatibility"
    ]

    /// The raw entries of a response that carries the list: `GET /v0/management/config` (the
    /// whole engine config; the list is written back from it because the list endpoint's GET may
    /// leave out fields, see the panel's `providers.ts`) or `GET /v0/management/openai-compatibility`.
    /// A JSON null list (an engine config without providers) is an empty list.
    static func entries(in responseData: Data) throws -> [Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let responseKey = responseKeys.first(where: { envelope[$0] != nil }) else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidResponse
        }
        if envelope[responseKey] is NSNull { return [] }
        guard let entries = envelope[responseKey] as? [Any] else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidResponse
        }
        return entries
    }

    /// Creates a PUT payload from the just-read raw response. Existing entries
    /// are intentionally not decoded into the app's UI model so newer
    /// CLIProxyAPI fields and auth-index metadata survive an append operation.
    /// With `allocatePrefixAgainst` (prefixes in use outside this list, i.e. the direct
    /// providers'), the provider's prefix is allocated again against the entries just read.
    static func append(
        _ provider: RuntimeOpenAICompatibilityWrite,
        to responseData: Data,
        allocatePrefixAgainst otherPrefixes: [String]? = nil
    ) throws -> RuntimeOpenAICompatibilityListAppendPayload {
        let providerName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerName.isEmpty, !baseURL.isEmpty else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidProvider
        }

        var entries = try Self.entries(in: responseData)
        var provider = provider
        if let otherPrefixes {
            let listPrefixes = entries.compactMap { ($0 as? [String: Any])?["prefix"] as? String }
            if let allocated = ProviderPrefixAllocator.resolve(prefix: nil, name: providerName, taken: listPrefixes + otherPrefixes) {
                provider = provider.withPrefix(allocated)
            }
        }

        let normalizedName = providerName.lowercased()
        for (index, entry) in entries.enumerated() {
            guard let item = entry as? [String: Any],
                  let existingName = item["name"] as? String else { continue }
            if existingName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName {
                return RuntimeOpenAICompatibilityListAppendPayload(
                    outcome: .existing(index: index),
                    requestBody: nil
                )
            }
        }

        let encodedProvider = try JSONEncoder().encode(provider)
        let providerObject = try JSONSerialization.jsonObject(with: encodedProvider)
        entries.append(providerObject)
        guard JSONSerialization.isValidJSONObject(entries) else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidProvider
        }

        return RuntimeOpenAICompatibilityListAppendPayload(
            outcome: .appended,
            requestBody: try JSONSerialization.data(withJSONObject: entries)
        )
    }

    /// The PUT body that gives the entry `priority`: the entry at `index` when its name is
    /// `name` (trimmed), otherwise the first entry of that name. Every other field and entry is
    /// sent back exactly as read (unknown fields, integers as integers). nil when the entry
    /// already has that priority (nothing to write); `.invalidProvider` when it is not there.
    static func settingPriority(
        _ priority: Int,
        ofProviderNamed name: String,
        index: Int?,
        in responseData: Data
    ) throws -> Data? {
        var entries = try Self.entries(in: responseData)
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ entry: Any) -> Bool {
            ((entry as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        let target: Int?
        if let index, entries.indices.contains(index), matches(entries[index]) {
            target = index
        } else {
            target = entries.firstIndex(where: matches)
        }
        guard !wanted.isEmpty, let target, var entry = entries[target] as? [String: Any] else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidProvider
        }
        let current = (entry["priority"] as? NSNumber)?.intValue ?? 0
        guard current != priority else { return nil }
        entry["priority"] = priority
        entries[target] = entry
        guard JSONSerialization.isValidJSONObject(entries) else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidProvider
        }
        return try JSONSerialization.data(withJSONObject: entries)
    }
}
