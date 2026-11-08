import Foundation

extension GatewayAdminClient {
    static let searchUsageDays = 1...62
    static let searchLogLimits = 1...500

    /// `GET /cpa-admin/search/providers`.
    func searchProviders() async throws -> [GatewaySearchProvider] {
        let response: GatewaySearchProvidersResponse = try await get("/cpa-admin/search/providers")
        return response.providers
    }

    /// `POST /cpa-admin/search/providers/save` → the saved entry.
    func saveSearchProvider(_ save: GatewaySearchProviderSave) async throws -> GatewaySearchProvider {
        let response: GatewaySearchProviderSaveResponse = try await post("/cpa-admin/search/providers/save", body: save)
        return response.provider
    }

    /// `POST /cpa-admin/search/providers/test` (a real request to the provider; 429 `test_throttled`
    /// when tested again too soon). Without `apiKey` the saved key is tested.
    func testSearchProvider(_ id: String, apiKey: String?) async throws -> GatewaySearchTestResult {
        let response: GatewaySearchTestResponse = try await post(
            "/cpa-admin/search/providers/test",
            body: GatewaySearchTestBody(provider: id, apiKey: apiKey),
            timeout: GatewayAdminTimeouts.searchTest
        )
        return response.result
    }

    /// The query of `searchUsage(days:)`: `days` clamped to 1…62 (the gateway keeps 62 days).
    static func searchUsageQuery(days: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "days", value: String(min(max(days, searchUsageDays.lowerBound), searchUsageDays.upperBound)))]
    }

    /// `GET /cpa-admin/search/usage?days=`.
    func searchUsage(days: Int) async throws -> GatewaySearchUsage {
        try await get("/cpa-admin/search/usage", query: Self.searchUsageQuery(days: days))
    }

    /// The query of `searchLogs(limit:provider:)`: `limit` clamped to 1…500, `provider` only when set.
    static func searchLogsQuery(limit: Int, provider: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, searchLogLimits.lowerBound), searchLogLimits.upperBound)))]
        if let provider, !provider.isEmpty { items.append(URLQueryItem(name: "provider", value: provider)) }
        return items
    }

    /// `GET /cpa-admin/search/logs?limit=&provider=`, newest first.
    func searchLogs(limit: Int, provider: String?) async throws -> [GatewaySearchLogEntry] {
        let response: GatewaySearchLogsResponse = try await get("/cpa-admin/search/logs", query: Self.searchLogsQuery(limit: limit, provider: provider))
        return response.logs
    }
}
