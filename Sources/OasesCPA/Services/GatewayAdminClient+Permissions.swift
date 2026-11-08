import Foundation

extension GatewayAdminClient {
    /// `GET /cpa-admin/permissions/api/data`.
    func permissionsData() async throws -> GatewayPermissionsData {
        try await get("/cpa-admin/permissions/api/data")
    }
}
