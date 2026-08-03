import Foundation

struct SystemModelDirectoryClassification: Hashable, Sendable {
    let provider: String
    let family: String

    var stableKey: String {
        "\(provider.lowercased())/\(family.lowercased())"
    }
}

struct SystemModelDirectoryGroup: Identifiable, Hashable, Sendable {
    let classification: SystemModelDirectoryClassification
    let models: [RuntimeGatewayModel]

    var id: String { classification.stableKey }
    var provider: String { classification.provider }
    var family: String { classification.family }
    var title: String { "\(provider) / \(family)" }
}

enum SystemModelDirectory {
    private static let knownFamilyPrefixes: Set<String> = [
        "claude", "command", "codestral", "deepseek", "doubao", "gemini",
        "glm", "gpt", "grok", "kimi", "llama", "minimax", "mistral",
        "moonshot", "o", "qwen", "yi"
    ]

    static func filteredModels(
        _ models: [RuntimeGatewayModel],
        query: String
    ) -> [RuntimeGatewayModel] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return sortedModels(models)
        }

        return sortedModels(models.filter { model in
            model.id.localizedCaseInsensitiveContains(normalizedQuery)
                || model.title.localizedCaseInsensitiveContains(normalizedQuery)
                || (model.ownedBy?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
        })
    }

    static func groups(
        for models: [RuntimeGatewayModel],
        query: String = ""
    ) -> [SystemModelDirectoryGroup] {
        let grouped = Dictionary(grouping: filteredModels(models, query: query)) { model in
            classification(for: model)
        }

        return grouped
            .map { classification, models in
                SystemModelDirectoryGroup(
                    classification: classification,
                    models: sortedModels(models)
                )
            }
            .sorted { lhs, rhs in
                let left = lhs.id.lowercased()
                let right = rhs.id.lowercased()
                return left == right ? lhs.id < rhs.id : left < right
            }
    }

    static func classification(for model: RuntimeGatewayModel) -> SystemModelDirectoryClassification {
        let identifier = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifierParts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        let namespace = identifierParts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelName = identifierParts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? identifier

        let provider = normalizedProvider(model.ownedBy) ?? (identifierParts.count > 1 ? namespace : nil)
            ?? firstToken(in: modelName)
            ?? "unknown"
        let family = familyName(for: modelName)

        return SystemModelDirectoryClassification(
            provider: provider,
            family: family
        )
    }

    private static func sortedModels(_ models: [RuntimeGatewayModel]) -> [RuntimeGatewayModel] {
        models.sorted { lhs, rhs in
            let left = lhs.id.lowercased()
            let right = rhs.id.lowercased()
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    private static func normalizedProvider(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func familyName(for modelName: String) -> String {
        let tokens = modelName
            .split(whereSeparator: { character in
                character == "-" || character == "_" || character == "." || character == " "
            })
            .map(String.init)

        guard let first = tokens.first, !first.isEmpty else { return "unknown" }
        let normalizedFirst = first.lowercased()
        guard knownFamilyPrefixes.contains(normalizedFirst) else { return first }

        // Keep a useful generation marker for well-known families while avoiding
        // one group per version/suffix (for example, gpt-4o-mini stays in gpt-4o).
        if tokens.count > 1, let second = tokens.dropFirst().first, !second.isEmpty {
            return "\(first)-\(second)"
        }
        return first
    }

    private static func firstToken(in value: String) -> String? {
        value
            .split(whereSeparator: { character in
                character == "-" || character == "_" || character == "." || character == " "
            })
            .first
            .map(String.init)
    }
}
