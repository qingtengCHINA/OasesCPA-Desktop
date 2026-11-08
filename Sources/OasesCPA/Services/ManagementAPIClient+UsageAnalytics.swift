import Foundation

extension ManagementAPIClient {
    func usageAnalytics(
        _ payload: RuntimeUsageAnalyticsRequest,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeUsageAnalyticsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/monitoring/analytics"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ManagementAPIError.server(
                status: httpResponse.statusCode,
                message: message.isEmpty ? "请求失败" : message
            )
        }

        do {
            // The models spell out their snake_case CodingKeys: a key strategy would rename the
            // JSON keys first ("total_calls" → "totalCalls") so that none of them matched.
            return try JSONDecoder().decode(RuntimeUsageAnalyticsResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }
}
