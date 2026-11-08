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

extension GatewayAdminClient {
    /// `GET /cpa-admin/permissions/api/models/providers?model=<id>` (reads the engine's providers).
    func modelProviders(model: String) async throws -> GatewayModelProvidersResponse {
        try await get(
            "/cpa-admin/permissions/api/models/providers",
            query: [URLQueryItem(name: "model", value: model)],
            timeout: GatewayAdminTimeouts.modelProviders
        )
    }
}

extension GatewayAdminClient {
    /// `POST /cpa-admin/permissions/api/models/reorder`. A dry run always answers 200 with the
    /// plan (a refused order has `rejected`); the real change answers 200 `{ok:true, …plan}`, or
    /// 409 `{ok:false, …plan}` when the order is refused. Both carry a plan and are returned
    /// with their status. 502 (`management_unavailable`: the engine could not be read or
    /// written) and every other status throw `GatewayAdminError`; 401 throws `.unauthorized`.
    func reorder(_ request: GatewayReorderRequest) async throws -> (status: Int, plan: GatewayReorderPlan) {
        let (status, data) = try await postAllowingStatus(
            "/cpa-admin/permissions/api/models/reorder",
            body: request,
            allowed: [409],
            timeout: GatewayAdminTimeouts.modelReorder
        )
        do {
            return (status, try JSONDecoder().decode(GatewayReorderPlan.self, from: data))
        } catch {
            throw GatewayAdminError.decoding(GatewayAdminError.sanitized(String(describing: error), secrets: [managementKey]))
        }
    }
}
