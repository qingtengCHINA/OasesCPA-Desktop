import Foundation

extension GatewayAdminClient {
    /// `GET /cpa-admin/permissions/api/models/health`.
    func modelHealth() async throws -> GatewayModelHealthResponse {
        try await get("/cpa-admin/permissions/api/models/health")
    }

    /// `POST /cpa-admin/permissions/api/models/test` with `{model}` (the engine picks the provider)
    /// or `{model, provider}` (only that provider). One real upstream request.
    func testModel(_ model: String, provider: String?) async throws -> GatewayModelTestResponse {
        try await post(
            "/cpa-admin/permissions/api/models/test",
            body: GatewayModelTestBody(model: model, provider: provider),
            timeout: GatewayAdminTimeouts.modelTest
        )
    }

    /// `POST /cpa-admin/permissions/api/models/test-all` with `{}`: starts a run (or returns the one
    /// already going) and answers at once; progress is read from `modelHealth()`.
    func testAllModels() async throws -> GatewayTestAllResponse {
        try await post(
            "/cpa-admin/permissions/api/models/test-all",
            body: [String: String](),
            timeout: GatewayAdminTimeouts.modelTestAll
        )
    }
}

/// `{model}` or `{model, provider}`; a nil provider is not written.
private struct GatewayModelTestBody: Encodable, Sendable {
    let model: String
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case model, provider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(provider, forKey: .provider)
    }
}
