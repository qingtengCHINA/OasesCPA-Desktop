import Foundation
import Security

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

    init(id: String, displayName: String?, ownedBy: String?) {
        self.id = id
        self.displayName = displayName
        self.ownedBy = ownedBy
    }

    /// `display_name` / `owned_by` are read with either spelling, so the model decodes the same
    /// whatever key strategy the decoder uses (a `.convertFromSnakeCase` decoder once dropped them).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        displayName = try? container.decodeIfPresent(String.self, snakeOrCamel: "display_name")
        ownedBy = try? container.decodeIfPresent(String.self, snakeOrCamel: "owned_by")
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
