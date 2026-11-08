import Foundation

struct RuntimeOAuthExcludedModelsResponse: Decodable, Sendable {
    let rules: [String: [String]]

    private enum CodingKeys: String, CodingKey {
        case dashed = "oauth-excluded-models"
        case camel = "oauthExcludedModels"
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decodeIfPresent([String: [String]].self, forKey: .dashed)
            ?? container.decodeIfPresent([String: [String]].self, forKey: .camel)
            ?? container.decodeIfPresent([String: [String]].self, forKey: .items)
            ?? (try? [String: [String]](from: decoder))
            ?? [:]
        rules = RuntimeOAuthModelPolicyValidator.normalizedExcludedRules(source)
    }
}

struct RuntimeOAuthModelAliasResponse: Decodable, Sendable {
    let aliases: [String: [RuntimeOAuthModelAliasEntry]]

    private enum CodingKeys: String, CodingKey {
        case dashed = "oauth-model-alias"
        case camel = "oauthModelAlias"
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decodeIfPresent([String: [RuntimeOAuthModelAliasEntry]].self, forKey: .dashed)
            ?? container.decodeIfPresent([String: [RuntimeOAuthModelAliasEntry]].self, forKey: .camel)
            ?? container.decodeIfPresent([String: [RuntimeOAuthModelAliasEntry]].self, forKey: .items)
            ?? (try? [String: [RuntimeOAuthModelAliasEntry]](from: decoder))
            ?? [:]
        aliases = RuntimeOAuthModelPolicyValidator.normalizedAliasesByChannel(source)
    }
}

/// A global OAuth model alias. Unknown server fields are retained so a native
/// edit of one mapping does not discard fields introduced by a newer backend.
struct RuntimeOAuthModelAliasEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var alias: String
    var fork: Bool
    var displayName: String
    var forceMapping: Bool
    var extraFields: [String: RuntimeJSONValue]

    init(
        id: UUID = UUID(),
        name: String,
        alias: String,
        fork: Bool = false,
        displayName: String = "",
        forceMapping: Bool = false,
        extraFields: [String: RuntimeJSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.alias = alias
        self.fork = fork
        self.displayName = displayName
        self.forceMapping = forceMapping
        self.extraFields = extraFields
    }

    init(from decoder: Decoder) throws {
        let values = try [String: RuntimeJSONValue](from: decoder)
        id = UUID()
        name = Self.string(values["name"])
        alias = Self.string(values["alias"])
        fork = Self.bool(values["fork"])
        displayName = Self.string(values["display-name"])
        forceMapping = Self.bool(values["force-mapping"])
        extraFields = values.filter { key, _ in
            !["name", "alias", "fork", "display-name", "force-mapping"].contains(key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = extraFields
        values["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        values["alias"] = .string(alias.trimmingCharacters(in: .whitespacesAndNewlines))
        if fork {
            values["fork"] = .boolean(true)
        } else {
            values.removeValue(forKey: "fork")
        }
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            values.removeValue(forKey: "display-name")
        } else {
            values["display-name"] = .string(title)
        }
        if forceMapping {
            values["force-mapping"] = .boolean(true)
        } else {
            values.removeValue(forKey: "force-mapping")
        }
        try values.encode(to: encoder)
    }

    func normalized() -> RuntimeOAuthModelAliasEntry {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    private static func string(_ value: RuntimeJSONValue?) -> String {
        guard case .some(.string(let value)) = value else { return "" }
        return value
    }

    private static func bool(_ value: RuntimeJSONValue?) -> Bool {
        guard case .some(.boolean(let value)) = value else { return false }
        return value
    }
}

struct RuntimeOAuthExcludedModelsPatch: Encodable, Sendable {
    let provider: String
    let models: [String]
}

struct RuntimeOAuthModelAliasPatch: Encodable, Sendable {
    let channel: String
    let aliases: [RuntimeOAuthModelAliasEntry]
}

enum RuntimeOAuthModelPolicyValidator {
    static func normalizedChannel(_ value: String) -> String? {
        let channel = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !channel.isEmpty,
              channel.count <= 128,
              !channel.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            return nil
        }
        return channel
    }

    static func normalizedExcludedRules(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules.compactMap { raw in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !normalized.contains(where: { $0.isNewline }), seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func normalizedExcludedRules(_ rules: [String: [String]]) -> [String: [String]] {
        var output: [String: [String]] = [:]
        for (channel, entries) in rules {
            guard let normalizedChannel = normalizedChannel(channel) else { continue }
            let normalized = normalizedExcludedRules(entries)
            if !normalized.isEmpty {
                output[normalizedChannel] = normalized
            }
        }
        return output
    }

    static func normalizedAliasesByChannel(
        _ aliases: [String: [RuntimeOAuthModelAliasEntry]]
    ) -> [String: [RuntimeOAuthModelAliasEntry]] {
        var output: [String: [RuntimeOAuthModelAliasEntry]] = [:]
        for (channel, entries) in aliases {
            guard let normalizedChannel = normalizedChannel(channel),
                  validationMessage(for: entries) == nil else {
                continue
            }
            let normalized = entries.map { $0.normalized() }
            if !normalized.isEmpty {
                output[normalizedChannel] = normalized
            }
        }
        return output
    }

    static func validationMessage(for aliases: [RuntimeOAuthModelAliasEntry]) -> String? {
        var seenAliases = Set<String>()
        for (index, entry) in aliases.enumerated() {
            let normalized = entry.normalized()
            guard !normalized.name.isEmpty, !normalized.alias.isEmpty else {
                return OasesLocalization.localizedFormat("第 %lld 条模型别名缺少上游模型或客户端模型 ID。", index + 1)
            }
            guard !normalized.name.contains(where: { $0.isNewline }),
                  !normalized.alias.contains(where: { $0.isNewline }),
                  normalized.name.count <= 512,
                  normalized.alias.count <= 512 else {
                return OasesLocalization.localizedFormat("第 %lld 条模型 ID 格式无效。", index + 1)
            }
            guard normalized.name.caseInsensitiveCompare(normalized.alias) != .orderedSame else {
                return OasesLocalization.localizedFormat("第 %lld 条模型别名不能与上游模型 ID 相同。", index + 1)
            }
            let aliasKey = normalized.alias.lowercased()
            guard seenAliases.insert(aliasKey).inserted else {
                return OasesLocalization.localizedFormat("客户端模型 ID “%@” 在当前渠道中重复。", normalized.alias)
            }
        }
        return nil
    }
}
