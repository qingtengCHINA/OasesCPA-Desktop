import Foundation

extension GatewayAdminClient {
    /// `GET /cpa-admin/packs/data`.
    func packsData() async throws -> GatewayPacksData {
        try await get("/cpa-admin/packs/data")
    }

    /// `GET /cpa-admin/packs/keys?pack_id=` (404 `not_found` for an unknown pack).
    func packKeys(packID: String) async throws -> [GatewayPackKey] {
        let response: GatewayPackKeysResponse = try await get(
            "/cpa-admin/packs/keys",
            query: [URLQueryItem(name: "pack_id", value: packID)]
        )
        return response.keys
    }

    /// `POST /cpa-admin/packs/save` for actions whose answer is not needed beyond success
    /// (`{pack}`, `{key}` or `{ok:true}`; the page reads the lists again afterwards).
    func savePacks(_ action: GatewayPacksSaveAction) async throws {
        let _: RuntimeJSONValue = try await post("/cpa-admin/packs/save", body: action)
    }

    /// `create_keys`: the plaintext keys, returned this one time only.
    func createPackKeys(_ batch: GatewayPackKeyBatch) async throws -> [GatewayCreatedPackKey] {
        let response: GatewayCreatedPackKeysResponse = try await post(
            "/cpa-admin/packs/save",
            body: GatewayPacksSaveAction.createKeys(batch),
            timeout: GatewayAdminTimeouts.keyMutation
        )
        return response.keys
    }
}
