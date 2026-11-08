import Foundation

struct ManagementAPIQuickConfigResult: Sendable {
    let field: RuntimeCPAQuickConfigField
    let value: RuntimeCPAQuickConfigValue?
    let errorMessage: String?
}

extension ManagementAPIClient {
    /// Reads one of CLIProxyAPI's specialized management settings.
    /// The endpoint returns an object whose key is the final management key,
    /// for example `{"strategy":"round-robin"}`.
    func quickConfigurationValue(
        for field: RuntimeCPAQuickConfigField,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCPAQuickConfigValue {
        let url = try quickConfigurationURL(for: field, baseURL: baseURL)
        let data = try await quickConfigurationData(
            url: url,
            method: "GET",
            managementKey: managementKey,
            body: nil
        )
        return try RuntimeCPAQuickConfigValue.decode(from: data, for: field)
    }

    /// Updates one setting using the exact CLIProxyAPI contract:
    /// `PATCH /v0/management/{key}` with `{ "value": ... }`.
    func updateQuickConfigurationValue(
        _ value: RuntimeCPAQuickConfigValue,
        for field: RuntimeCPAQuickConfigField,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try quickConfigurationURL(for: field, baseURL: baseURL)
        let body = try Self.quickConfigurationPatchBody(value)
        _ = try await quickConfigurationData(
            url: url,
            method: "PATCH",
            managementKey: managementKey,
            body: body
        )
    }

    /// Loads every field concurrently. A provider can expose an older
    /// management API with only some of these endpoints, so errors are kept
    /// per field instead of failing the whole workbench.
    func loadQuickConfiguration(
        baseURL: URL,
        managementKey: String
    ) async -> RuntimeCPAQuickConfigLoadResult {
        await withTaskGroup(of: ManagementAPIQuickConfigResult.self) { group in
            for field in RuntimeCPAQuickConfigField.allCases {
                group.addTask {
                    do {
                        let value = try await ManagementAPIClient().quickConfigurationValue(
                            for: field,
                            baseURL: baseURL,
                            managementKey: managementKey
                        )
                        return ManagementAPIQuickConfigResult(
                            field: field,
                            value: value,
                            errorMessage: nil
                        )
                    } catch {
                        return ManagementAPIQuickConfigResult(
                            field: field,
                            value: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            var configuration = RuntimeCPAQuickConfiguration.default
            var errors: [RuntimeCPAQuickConfigField: String] = [:]

            for await result in group {
                if let value = result.value {
                    configuration[result.field] = value
                }
                if let errorMessage = result.errorMessage {
                    errors[result.field] = errorMessage
                }
            }

            return RuntimeCPAQuickConfigLoadResult(
                configuration: configuration,
                errors: errors
            )
        }
    }

    static func quickConfigurationPatchBody(
        _ value: RuntimeCPAQuickConfigValue
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["value": value.jsonObject],
            options: [.sortedKeys]
        )
    }

    private func quickConfigurationURL(
        for field: RuntimeCPAQuickConfigField,
        baseURL: URL
    ) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/\(field.endpointPath)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func quickConfigurationData(
        url: URL,
        method: String,
        managementKey: String,
        body: Data?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "请求失败"
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            if httpResponse.statusCode == 409,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["restart_required"] as? Bool == true {
                throw ManagementAPIError.restartRequired(
                    message: object["message"] as? String ?? ""
                )
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
        return data
    }
}
