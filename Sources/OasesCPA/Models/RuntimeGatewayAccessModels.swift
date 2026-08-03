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
    let data: [RuntimeGatewayModel]
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
