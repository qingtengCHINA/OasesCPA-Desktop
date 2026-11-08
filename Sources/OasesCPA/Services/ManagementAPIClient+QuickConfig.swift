import Foundation

struct ManagementAPIQuickConfigResult: Sendable {
    let field: RuntimeCPAQuickConfigField
    let value: RuntimeCPAQuickConfigValue?
    let errorMessage: String?
}

/// Why a setting was not written: it is read-only, or the config file has a shape the app does
/// not change automatically.
enum QuickConfigWriteError: LocalizedError, Equatable {
    case readOnly(RuntimeCPAQuickConfigField)
    /// The file uses CLIProxyAPI v8's nested layout (`config-version: 8`): the setting is not a
    /// top-level key there and the app does not write that layout.
    case nestedLayout

    var errorDescription: String? {
        switch self {
        case .readOnly:
            OasesLocalization.localized("这项设置只能在配置文件编辑器中修改。")
        case .nestedLayout:
            OasesLocalization.localized("配置文件使用了 v8 的新分组布局，这项设置无法自动修改，请在配置文件编辑器中手动修改。")
        }
    }
}

extension ManagementAPIClient {
    /// Reads one of CLIProxyAPI's specialized management settings.
    /// The endpoint returns an object whose key is the final management key,
    /// for example `{"strategy":"round-robin"}`. A config-file setting is read from
    /// `config.yaml` (absent: the engine's default).
    func quickConfigurationValue(
        for field: RuntimeCPAQuickConfigField,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCPAQuickConfigValue {
        if case .yaml = field.transport {
            let yaml = try await configYAMLText(baseURL: baseURL, managementKey: managementKey)
            return try Self.quickConfigurationValue(of: field, inYAML: yaml)
        }
        let url = try quickConfigurationURL(for: field, baseURL: baseURL)
        let data = try await quickConfigurationData(
            url: url,
            method: "GET",
            managementKey: managementKey,
            body: nil
        )
        return try RuntimeCPAQuickConfigValue.decode(from: data, for: field)
    }

    /// Updates one setting. Endpoint settings use the exact CLIProxyAPI contract:
    /// `PATCH /v0/management/{key}` with `{ "value": ... }`. A config-file setting reads
    /// `config.yaml`, changes that one scalar (`CPAConfigYAMLPatcher`) and writes the file back
    /// (`PUT /v0/management/config.yaml`; the engine reloads it), with `If-Match` when the read
    /// had an `ETag`. v8.0.51 sends none and ignores `If-Match` (measured): a change another
    /// client makes between the read and the write is overwritten, so the window is kept to one
    /// read and one write.
    func updateQuickConfigurationValue(
        _ value: RuntimeCPAQuickConfigValue,
        for field: RuntimeCPAQuickConfigField,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard !field.isReadOnly else { throw QuickConfigWriteError.readOnly(field) }
        if case .yaml(let path) = field.transport {
            let snapshot = try await configYAML(baseURL: baseURL, managementKey: managementKey)
            let yaml = try Self.configYAMLText(snapshot.data)
            try Self.refuseNestedLayout(yaml)
            let patched = try CPAConfigYAMLPatcher.setting(value.yamlScalar, at: path, in: yaml)
            guard patched != yaml else { return }
            try await saveConfigYAML(Data(patched.utf8), etag: snapshot.etag, baseURL: baseURL, managementKey: managementKey)
            return
        }
        let url = try quickConfigurationURL(for: field, baseURL: baseURL)
        let body = try Self.quickConfigurationPatchBody(value)
        _ = try await quickConfigurationData(
            url: url,
            method: "PATCH",
            managementKey: managementKey,
            body: body
        )
    }

    /// Loads every field. Endpoint fields are read concurrently; the config-file fields come
    /// from ONE read of `config.yaml`. A provider can expose an older management API with only
    /// some of these endpoints, so errors are kept per field instead of failing the whole
    /// workbench.
    func loadQuickConfiguration(
        baseURL: URL,
        managementKey: String
    ) async -> RuntimeCPAQuickConfigLoadResult {
        let client = self
        let endpointFields = RuntimeCPAQuickConfigField.allCases.filter { $0.transport == .endpoint }
        let yamlFields = RuntimeCPAQuickConfigField.allCases.filter { $0.transport != .endpoint }
        var results = await withTaskGroup(of: ManagementAPIQuickConfigResult.self) { group in
            for field in endpointFields {
                group.addTask {
                    do {
                        let value = try await client.quickConfigurationValue(
                            for: field,
                            baseURL: baseURL,
                            managementKey: managementKey
                        )
                        return ManagementAPIQuickConfigResult(field: field, value: value, errorMessage: nil)
                    } catch {
                        return ManagementAPIQuickConfigResult(field: field, value: nil, errorMessage: error.localizedDescription)
                    }
                }
            }
            var collected: [ManagementAPIQuickConfigResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        if !yamlFields.isEmpty {
            do {
                let yaml = try await configYAMLText(baseURL: baseURL, managementKey: managementKey)
                for field in yamlFields {
                    do {
                        let value = try Self.quickConfigurationValue(of: field, inYAML: yaml)
                        results.append(ManagementAPIQuickConfigResult(field: field, value: value, errorMessage: nil))
                    } catch {
                        results.append(ManagementAPIQuickConfigResult(field: field, value: nil, errorMessage: error.localizedDescription))
                    }
                }
            } catch {
                for field in yamlFields {
                    results.append(ManagementAPIQuickConfigResult(field: field, value: nil, errorMessage: error.localizedDescription))
                }
            }
        }

        var configuration = RuntimeCPAQuickConfiguration.default
        var errors: [RuntimeCPAQuickConfigField: String] = [:]
        for result in results {
            if let value = result.value {
                configuration[result.field] = value
            }
            if let errorMessage = result.errorMessage {
                errors[result.field] = errorMessage
            }
        }
        return RuntimeCPAQuickConfigLoadResult(configuration: configuration, errors: errors)
    }

    /// A config-file field's value in `yaml`; absent or null is the engine's default.
    static func quickConfigurationValue(of field: RuntimeCPAQuickConfigField, inYAML yaml: String) throws -> RuntimeCPAQuickConfigValue {
        guard case .yaml(let path) = field.transport else { throw ManagementAPIError.invalidResponse }
        try refuseNestedLayout(yaml)
        let scalar = try CPAConfigYAMLPatcher.value(at: path, in: yaml)
        return try RuntimeCPAQuickConfigValue.fromYAMLScalar(scalar, kind: field.valueKind)
            ?? RuntimeCPAQuickConfiguration.default[field]
    }

    /// CLIProxyAPI v8's nested layout (`config-version: 8` or later) keeps these settings in
    /// groups; the deployments use the legacy top-level layout (R14), and the app never writes
    /// the nested one.
    static func refuseNestedLayout(_ yaml: String) throws {
        if let version = try? CPAConfigYAMLPatcher.value(at: ["config-version"], in: yaml), let number = Int(version), number >= 8 {
            throw QuickConfigWriteError.nestedLayout
        }
    }

    private func configYAMLText(baseURL: URL, managementKey: String) async throws -> String {
        try Self.configYAMLText(try await configYAML(baseURL: baseURL, managementKey: managementKey).data)
    }

    private static func configYAMLText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw ManagementAPIError.invalidResponse }
        return text
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
