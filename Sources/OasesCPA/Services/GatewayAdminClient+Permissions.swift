import Foundation

extension GatewayAdminClient {
    /// `GET /cpa-admin/permissions/api/data`.
    func permissionsData() async throws -> GatewayPermissionsData {
        try await get("/cpa-admin/permissions/api/data")
    }
}

extension GatewayAdminClient {
    /// `POST /cpa-admin/permissions/api/save`. Adding and deleting a key change the engine's
    /// configuration and the policy store (with rollback) and get a longer timeout.
    func save(_ action: GatewayKeysSaveAction) async throws -> RuntimeJSONValue {
        let timeout: TimeInterval
        switch action {
        case .addKey, .deleteKey: timeout = GatewayAdminTimeouts.keyMutation
        case .setLabel, .savePolicy: timeout = GatewayAdminTimeouts.standard
        }
        return try await post("/cpa-admin/permissions/api/save", body: action, timeout: timeout)
    }
}
