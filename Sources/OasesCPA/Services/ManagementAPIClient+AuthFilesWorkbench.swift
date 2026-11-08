import Foundation

extension ManagementAPIClient {
    func authFilesWorkbench(
        baseURL: URL,
        managementKey: String
    ) async throws -> AuthFilesWorkbenchResponse {
        let url = try authFilesWorkbenchURL(baseURL: baseURL, suffix: "")
        let data = try await authFilesWorkbenchData(
            authFilesWorkbenchRequest(url: url, method: "GET", managementKey: managementKey)
        )
        do {
            return try JSONDecoder.oasesWorkbench.decode(AuthFilesWorkbenchResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func authFileWorkbenchModels(
        name: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> AuthFilesWorkbenchModelsResponse {
        let url = try authFilesWorkbenchURL(
            baseURL: baseURL,
            suffix: "/models",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
        let data = try await authFilesWorkbenchData(
            authFilesWorkbenchRequest(url: url, method: "GET", managementKey: managementKey)
        )
        do {
            return try JSONDecoder.oasesWorkbench.decode(AuthFilesWorkbenchModelsResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func patchAuthFileWorkbenchStatus(
        _ patch: AuthFilesWorkbenchStatusPatch,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try authFilesWorkbenchURL(baseURL: baseURL, suffix: "/status")
        var request = authFilesWorkbenchRequest(url: url, method: "PATCH", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(patch)
        try await authFilesWorkbenchMutation(request)
    }

    func patchAuthFileWorkbenchFields(
        _ patch: AuthFilesWorkbenchFieldsPatch,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try authFilesWorkbenchURL(baseURL: baseURL, suffix: "/fields")
        var request = authFilesWorkbenchRequest(url: url, method: "PATCH", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(patch)
        try await authFilesWorkbenchMutation(request)
    }

    func deleteAuthFilesWorkbench(
        names: [String],
        baseURL: URL,
        managementKey: String
    ) async throws {
        let normalized = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        let url = try authFilesWorkbenchURL(
            baseURL: baseURL,
            suffix: "",
            queryItems: normalized.map { URLQueryItem(name: "name", value: $0) }
        )
        try await authFilesWorkbenchMutation(
            authFilesWorkbenchRequest(url: url, method: "DELETE", managementKey: managementKey)
        )
    }

    func deleteAllAuthFilesWorkbench(
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try authFilesWorkbenchURL(
            baseURL: baseURL,
            suffix: "",
            queryItems: [URLQueryItem(name: "all", value: "true")]
        )
        try await authFilesWorkbenchMutation(
            authFilesWorkbenchRequest(url: url, method: "DELETE", managementKey: managementKey)
        )
    }

    private func authFilesWorkbenchURL(
        baseURL: URL,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files\(suffix)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func authFilesWorkbenchRequest(
        url: URL,
        method: String,
        managementKey: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func authFilesWorkbenchMutation(_ request: URLRequest) async throws {
        _ = try await authFilesWorkbenchData(request)
    }

    private func authFilesWorkbenchData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            if httpResponse.statusCode == 409,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["restart_required"] as? Bool == true {
                throw ManagementAPIError.restartRequired(message: object["message"] as? String ?? "")
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
        return data
    }
}

private extension JSONDecoder {
    static var oasesWorkbench: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
