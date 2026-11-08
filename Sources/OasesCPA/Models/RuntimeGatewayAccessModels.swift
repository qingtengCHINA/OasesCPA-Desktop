import Foundation
import Security

struct RuntimeAPIKeysResponse: Decodable, Sendable {
    let keys: [String]

    private enum CodingKeys: String, CodingKey {
        case keys = "api-keys"
    }
}

struct RuntimeAPIKey: Identifiable, Hashable, Sendable {
    let index: Int
    let value: String

    var id: Int { index }

    var maskedValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else {
            return trimmed.isEmpty ? OasesLocalization.localized("暂无") : "\(trimmed.prefix(4))••••"
        }
        return "\(trimmed.prefix(7))••••\(trimmed.suffix(4))"
    }
}

struct RuntimeGatewayModelsResponse: Decodable, Sendable {
    /// The engine's `/v1/models` without internal `pin-x/…` ids (the engine lists one per pinned
    /// provider; they are never shown).
    let data: [RuntimeGatewayModel]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(data: [RuntimeGatewayModel]) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([RuntimeGatewayModel].self, forKey: .data)
            .filter { InternalModelID.publicName($0.id) == $0.id }
    }
}

struct RuntimeGatewayModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String?
    let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id : name
    }

    /// The model directory of a gateway deployment: the public ids of the gateway's
    /// `groupedModels` (internal `pin-x/…` ids dropped), each owned by the first group that lists
    /// it, sorted by id.
    static func directory(fromGroupedModels groupedModels: [String: [String]]) -> [RuntimeGatewayModel] {
        GatewayModelRow.rows(groupedModels: groupedModels, health: [:]).map {
            RuntimeGatewayModel(id: $0.id, displayName: nil, ownedBy: $0.groups.first)
        }
    }
}

struct RuntimeAPIKeyAddPatch: Encodable {
    let value: String

    private enum CodingKeys: String, CodingKey {
        case old
        case new
    }

    func encode(to encoder: Encoder) throws {
        // CLIProxyAPI appends when `old` is not found. Sending the new value for
        // both fields makes creation idempotent and avoids a whole-list PUT race.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .old)
        try container.encode(value, forKey: .new)
    }
}

struct RuntimeAPIKeyReplacePatch: Encodable {
    let index: Int
    let value: String
}

enum RuntimeAPIKeyGenerator {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return "sk-cpa-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        return "sk-cpa-\(token)"
    }
}
