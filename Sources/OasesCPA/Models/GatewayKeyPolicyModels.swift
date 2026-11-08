import Foundation

/// `GET /cpa-admin/permissions/api/data` (Server `gateway/server.mjs`).
///
/// The gateway answers `{ keys, permissions, groupedModels, disabledProviders, schema_version,
/// usage }`; this minimal version reads the model directory only.
struct GatewayPermissionsData: Decodable, Sendable {
    /// Model ids by group: an openai-compatibility provider's name, or "认证文件 / 引擎模型" for the
    /// engine's other models. Contains internal `pin-x/…` ids, which callers must drop.
    let groupedModels: [String: [String]]

    private enum CodingKeys: String, CodingKey {
        case groupedModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupedModels = try container.decodeIfPresent([String: [String]].self, forKey: .groupedModels) ?? [:]
    }
}
