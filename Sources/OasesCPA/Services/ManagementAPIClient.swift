import Foundation

enum ManagementAPIError: LocalizedError {
    case invalidURL
    case unauthorized
    case apiKeyUnauthorized
    case invalidPluginID
    case invalidPluginConfiguration
    case invalidPluginOAuthProvider
    case invalidOAuthModelPolicyChannel
    case invalidAccountActionCandidateID
    case invalidCodexInspectionRunID
    case invalidRequestErrorLogName
    case restartRequired(message: String)
    /// `PUT config.yaml` answered 412/428: the file changed since it was read (only possible
    /// when the engine sent an `ETag`; v8.0.51 sends none, so its writes are last-writer-wins).
    case configConflict
    /// CPA Manager Plus refused a stale `updatedAtMs` (409 `manager_config_conflict`).
    case managerConfigConflict
    case server(status: Int, message: String)
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return OasesLocalization.localized("管理地址无效。")
        case .unauthorized:
            return OasesLocalization.localized("当前目标的管理密钥无效或已失效。")
        case .apiKeyUnauthorized:
            return OasesLocalization.localized("网关拒绝读取模型目录；请创建或选择可用的调用 API Key。")
        case .invalidPluginID:
            return OasesLocalization.localized("插件标识无效。")
        case .invalidPluginConfiguration:
            return OasesLocalization.localized("插件配置必须是有效的 JSON 顶层对象。")
        case .invalidPluginOAuthProvider:
            return OasesLocalization.localized("插件 OAuth Provider 标识无效。")
        case .invalidOAuthModelPolicyChannel:
            return OasesLocalization.localized("OAuth 模型规则渠道标识无效。")
        case .invalidAccountActionCandidateID:
            return OasesLocalization.localized("账号待办标识无效。")
        case .invalidCodexInspectionRunID:
            return OasesLocalization.localized("凭证健康巡检运行标识无效。")
        case .invalidRequestErrorLogName:
            return OasesLocalization.localized("请求错误文件名无效。")
        case .restartRequired(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? OasesLocalization.localized("当前操作需要重启目标服务后再继续。")
                : OasesLocalization.localizedFormat("当前操作需要重启目标服务后再继续：%@", detail)
        case .configConflict:
            return OasesLocalization.localized("配置已被其他人修改，请重新加载。")
        case .managerConfigConflict:
            return OasesLocalization.localized("CPAMP 设置已被其他人修改，请重新读取后再保存。")
        case .server(let status, let message):
            return OasesLocalization.localizedFormat("当前目标管理 API 返回 HTTP %lld：%@", status, message)
        case .invalidResponse:
            return OasesLocalization.localized("当前目标管理 API 返回了无法解析的数据。")
        case .decoding(let detail):
            return OasesLocalization.localizedFormat("当前目标管理 API 响应格式不兼容：%@", detail)
        }
    }
}

/// One read of the engine's `config.yaml` with the version token the engine sent, if any.
struct RuntimeConfigYAMLSnapshot: Sendable, Equatable {
    let data: Data
    let etag: String?
}

struct ManagementAPIClient {
    private let decoder: JSONDecoder
    /// The transport of every request (tests inject a stubbed session). The default keeps
    /// nothing on disk: management responses include client API keys.
    let session: URLSession

    init(session: URLSession = SecretBearingURLSession.shared) {
        self.session = session
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func dashboardSummary(
        baseURL: URL,
        managementKey: String,
        range: RuntimeDashboardRange = .today,
        now: Date = Date()
    ) async throws -> RuntimeDashboardSummary {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }

        let calendar = Calendar(identifier: .gregorian)
        let rangeStart = range.startDate(relativeTo: now, calendar: calendar)
        let todayStartMs = Int64(rangeStart.timeIntervalSince1970 * 1_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        components.path = "/v0/management/dashboard/summary"
        components.queryItems = [
            URLQueryItem(name: "today_start_ms", value: String(todayStartMs)),
            URLQueryItem(name: "now_ms", value: String(nowMs)),
            URLQueryItem(name: "top_models", value: "8"),
            URLQueryItem(name: "recent_failures", value: "8")
        ]

        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func monitoringEvents(
        _ payload: RuntimeMonitoringEventsRequest,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeMonitoringEventsPage {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/monitoring/analytics"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = managementRequest(
            url: url,
            method: "POST",
            managementKey: managementKey
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await performData(request)
        do {
            let response = try decoder.decode(
                RuntimeMonitoringEventsAnalyticsResponse.self,
                from: data
            )
            guard let events = response.events else {
                throw ManagementAPIError.invalidResponse
            }
            return events
        } catch let error as ManagementAPIError {
            throw error
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func monitoringHeaderSnapshots(
        days: Int = 30,
        limit: Int = 200,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeMonitoringHeaderSnapshotsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/monitoring/header-snapshots"
        components.queryItems = [
            URLQueryItem(name: "days", value: String(min(max(days, 1), 365))),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 5_000)))
        ]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func monitoringAccountHistory(
        _ payload: RuntimeMonitoringAccountHistoryRequest,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeMonitoringAccountHistoryResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/monitoring/account-history"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = managementRequest(
            url: url,
            method: "POST",
            managementKey: managementKey
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await performData(request)
        do {
            return try decoder.decode(
                RuntimeMonitoringAccountHistoryResponse.self,
                from: data
            )
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func authFiles(baseURL: URL, managementKey: String) async throws -> RuntimeAuthFilesResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func gatewayModels(baseURL: URL, apiKey: String? = nil) async throws -> RuntimeGatewayModelsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v1/models"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await performData(request, unauthorizedError: .apiKeyUnauthorized)
        do {
            // A plain decoder: the model spells its snake_case keys out (`display_name`).
            return try JSONDecoder().decode(RuntimeGatewayModelsResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func directProviderCredentials(
        kind: RuntimeDirectProviderKind,
        baseURL: URL,
        managementKey: String
    ) async throws -> [RuntimeDirectProviderCredential] {
        let url = try directProviderURL(baseURL: baseURL, kind: kind)
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try RuntimeDirectProviderCredentialDecoder.decode(
                data,
                kind: kind,
                using: decoder
            )
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    /// CLIProxyAPI exposes no create-one endpoint for these provider
    /// collections. Re-read the authoritative list immediately before PUT so
    /// a new credential does not replace a stale in-memory collection.
    func appendDirectProviderCredential(
        _ payload: RuntimeProviderCredentialPayload,
        kind: RuntimeDirectProviderKind,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let current = try await directProviderCredentials(
            kind: kind,
            baseURL: baseURL,
            managementKey: managementKey
        )
        try await replaceDirectProviderCredentials(
            current.map(\.payload) + [payload],
            kind: kind,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    func replaceDirectProviderCredentials(
        _ credentials: [RuntimeProviderCredentialPayload],
        kind: RuntimeDirectProviderKind,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try directProviderURL(baseURL: baseURL, kind: kind)
        var request = managementRequest(url: url, method: "PUT", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(credentials)
        try await performMutation(request)
    }

    /// Re-reads the authoritative collection before replacing one entry. Some
    /// direct-provider PATCH handlers expose only a subset of the fields that
    /// their PUT schema supports (for example priority or model mappings), so
    /// a fresh merge + PUT is required for complete native editing.
    func updateDirectProviderCredential(
        _ credential: RuntimeDirectProviderCredential,
        patch: RuntimeProviderCredentialPayload,
        baseURL: URL,
        managementKey: String
    ) async throws {
        var current = try await directProviderCredentials(
            kind: credential.kind,
            baseURL: baseURL,
            managementKey: managementKey
        )

        let targetIndex: Int? = {
            let authIndex = credential.authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
            if !authIndex.isEmpty,
               let match = current.firstIndex(where: { $0.authIndex == authIndex }) {
                return match
            }
            if current.indices.contains(credential.index),
               current[credential.index].apiKey == credential.apiKey,
               current[credential.index].baseURL == credential.baseURL {
                return credential.index
            }
            return current.firstIndex {
                $0.apiKey == credential.apiKey && $0.baseURL == credential.baseURL
            }
        }()

        guard let targetIndex else {
            throw ManagementAPIError.server(
                status: 409,
                message: OasesLocalization.localized("凭证列表已变化，请刷新后重试。")
            )
        }

        var mergedValues = current[targetIndex].payload.values
        for (key, value) in patch.values {
            if value == .null {
                mergedValues.removeValue(forKey: key)
            } else {
                mergedValues[key] = value
            }
        }
        current[targetIndex] = RuntimeDirectProviderCredential(
            kind: credential.kind,
            index: targetIndex,
            payload: RuntimeProviderCredentialPayload(values: mergedValues)
        )

        try await replaceDirectProviderCredentials(
            current.map(\.payload),
            kind: credential.kind,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    func deleteDirectProviderCredential(
        kind: RuntimeDirectProviderKind,
        index: Int,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard index >= 0 else { throw ManagementAPIError.invalidResponse }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/\(kind.managementSection)"
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        let request = managementRequest(url: url, method: "DELETE", managementKey: managementKey)
        try await performMutation(request)
    }

    func oauthExcludedModels(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthExcludedModelsResponse {
        let url = try oauthModelPolicyURL(baseURL: baseURL, endpoint: "oauth-excluded-models")
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeOAuthExcludedModelsResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func patchOAuthExcludedModels(
        provider: String,
        models: [String],
        baseURL: URL,
        managementKey: String
    ) async throws {
        let provider = try normalizedOAuthModelPolicyChannel(provider)
        let url = try oauthModelPolicyURL(baseURL: baseURL, endpoint: "oauth-excluded-models")
        var request = managementRequest(url: url, method: "PATCH", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(
            RuntimeOAuthExcludedModelsPatch(provider: provider, models: models)
        )
        try await performMutation(request)
    }

    func deleteOAuthExcludedModels(
        provider: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let provider = try normalizedOAuthModelPolicyChannel(provider)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/oauth-excluded-models"
        components.queryItems = [URLQueryItem(name: "provider", value: provider)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        let request = managementRequest(url: url, method: "DELETE", managementKey: managementKey)
        try await performMutation(request)
    }

    func oauthModelAliases(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthModelAliasResponse {
        let url = try oauthModelPolicyURL(baseURL: baseURL, endpoint: "oauth-model-alias")
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeOAuthModelAliasResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func patchOAuthModelAliases(
        channel: String,
        aliases: [RuntimeOAuthModelAliasEntry],
        baseURL: URL,
        managementKey: String
    ) async throws {
        let channel = try normalizedOAuthModelPolicyChannel(channel)
        let url = try oauthModelPolicyURL(baseURL: baseURL, endpoint: "oauth-model-alias")
        var request = managementRequest(url: url, method: "PATCH", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(
            RuntimeOAuthModelAliasPatch(channel: channel, aliases: aliases)
        )
        try await performMutation(request)
    }

    func deleteOAuthModelAliases(
        channel: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let channel = try normalizedOAuthModelPolicyChannel(channel)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/oauth-model-alias"
        components.queryItems = [URLQueryItem(name: "channel", value: channel)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        let request = managementRequest(url: url, method: "DELETE", managementKey: managementKey)
        try await performMutation(request)
    }

    func modelPrices(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeModelPricesResponse {
        let url = try modelPricesURL(baseURL: baseURL, suffix: "")
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeModelPricesResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func modelPriceUsageSummary(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeModelPriceUsageSummary {
        let url = try modelPricesURL(baseURL: baseURL, suffix: "/usage-summary")
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeModelPriceUsageSummary.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func replaceModelPrices(
        _ prices: [String: RuntimeModelPricePayload],
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeModelPricesResponse {
        let url = try modelPricesURL(baseURL: baseURL, suffix: "")
        var request = managementRequest(url: url, method: "PUT", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(RuntimeModelPricesReplaceRequest(prices: prices))
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeModelPricesResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func syncModelPrices(
        models: [String],
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeModelPriceSyncResponse {
        let url = try modelPricesURL(baseURL: baseURL, suffix: "/sync")
        var request = managementRequest(url: url, method: "POST", managementKey: managementKey)
        request.timeoutInterval = 55
        request.httpBody = try JSONEncoder().encode(RuntimeModelPriceSyncRequest(models: models))
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeModelPriceSyncResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func accountActionCandidates(
        status: RuntimeAccountActionStatusFilter,
        limit: Int = 200,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeAccountActionCandidatesResponse {
        let url = try accountActionCandidatesURL(
            baseURL: baseURL,
            status: status,
            limit: limit
        )
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeAccountActionCandidatesResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func mutateAccountActionCandidate(
        _ candidateID: Int64,
        operation: RuntimeAccountActionOperation,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeAccountActionCandidateResponse {
        let url = try accountActionURL(
            baseURL: baseURL,
            candidateID: candidateID,
            operation: operation
        )
        let request = managementRequest(url: url, method: "POST", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeAccountActionCandidateResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func codexInspectionRuns(
        limit: Int = 30,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCodexInspectionRunsResponse {
        let url = try codexInspectionRunsURL(baseURL: baseURL, limit: limit)
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeCodexInspectionRunsResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func codexInspectionRun(
        _ runID: Int64,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCodexInspectionRunDetail {
        let url = try codexInspectionRunURL(baseURL: baseURL, runID: runID, suffix: "")
        let request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeCodexInspectionRunDetail.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func startCodexInspectionRun(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCodexInspectionRunDetail {
        let url = try codexInspectionStartURL(baseURL: baseURL)
        var request = managementRequest(url: url, method: "POST", managementKey: managementKey)
        // CPAMP may wait for the initial provider probe before returning the
        // first durable run detail. Keep parity with its own web console.
        request.timeoutInterval = 10 * 60
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeCodexInspectionRunDetail.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func cancelCodexInspectionRun(
        _ runID: Int64,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeCodexInspectionRunDetail {
        let url = try codexInspectionRunURL(baseURL: baseURL, runID: runID, suffix: "/cancel")
        let request = managementRequest(url: url, method: "POST", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeCodexInspectionRunDetail.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func plugins(baseURL: URL, managementKey: String) async throws -> RuntimePluginsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/plugins"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func setPluginEnabled(
        _ pluginID: String,
        enabled: Bool,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try pluginURL(
            baseURL: baseURL,
            pluginID: pluginID,
            suffix: "/enabled"
        )
        var request = managementRequest(url: url, method: "PATCH", managementKey: managementKey)
        request.httpBody = try JSONEncoder().encode(RuntimePluginEnabledPatch(enabled: enabled))
        try await performMutation(request)
    }

    func pluginConfig(
        for pluginID: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> Data {
        let url = try pluginURL(
            baseURL: baseURL,
            pluginID: pluginID,
            suffix: "/config"
        )
        var request = managementRequest(url: url, method: "GET", managementKey: managementKey)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await performData(request)
        guard let canonicalData = RuntimePluginConfigValidator.canonicalData(from: data) else {
            throw ManagementAPIError.invalidPluginConfiguration
        }
        return canonicalData
    }

    func replacePluginConfig(
        _ data: Data,
        for pluginID: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard let canonicalData = RuntimePluginConfigValidator.canonicalData(from: data) else {
            throw ManagementAPIError.invalidPluginConfiguration
        }
        let url = try pluginURL(
            baseURL: baseURL,
            pluginID: pluginID,
            suffix: "/config"
        )
        var request = managementRequest(url: url, method: "PUT", managementKey: managementKey)
        request.httpBody = canonicalData
        try await performMutation(request)
    }

    func pluginStore(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimePluginStoreResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/plugin-store"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func installPluginFromStore(
        pluginID: String,
        sourceID: String,
        version: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimePluginStoreInstallResult {
        let url = try pluginStoreInstallURL(
            baseURL: baseURL,
            pluginID: pluginID,
            sourceID: sourceID
        )
        var request = managementRequest(url: url, method: "POST", managementKey: managementKey)
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(
            RuntimePluginStoreInstallRequest(
                version: version.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimePluginStoreInstallResult.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func deletePlugin(
        _ pluginID: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimePluginDeleteResult {
        let url = try pluginURL(baseURL: baseURL, pluginID: pluginID, suffix: "")
        let request = managementRequest(url: url, method: "DELETE", managementKey: managementKey)
        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimePluginDeleteResult.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func apiCall(
        _ payload: RuntimeAPICallRequest,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeAPICallResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/api-call"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await performData(request)
        do {
            return try decoder.decode(RuntimeAPICallResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func activeQuotaCooldowns(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeQuotaCooldownsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/usage-service/quota-cooldowns"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func resetQuota(
        authIndex: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/reset-quota"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["auth_index": authIndex])
        try await performMutation(request)
    }

    func configYAML(baseURL: URL, managementKey: String) async throws -> RuntimeConfigYAMLSnapshot {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/config.yaml"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/yaml, text/yaml, text/plain;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await performDataAndResponse(request)
        return RuntimeConfigYAMLSnapshot(data: data, etag: Self.entityTag(in: response))
    }

    /// Writes `config.yaml`. With an `etag` from the read the write is conditional
    /// (`If-Match`); a 412/428 answer becomes `.configConflict`. Without one (CLIProxyAPI v8.0.51
    /// sends none and ignores `If-Match`) the write is unconditional: last writer wins.
    /// Returns the `ETag` of the written file when the engine sends one.
    @discardableResult
    func saveConfigYAML(
        _ data: Data,
        etag: String?,
        baseURL: URL,
        managementKey: String
    ) async throws -> String? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/config.yaml"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/yaml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, Self.configYAMLWritesAreChecked(etag: etag) {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        request.httpBody = data
        do {
            let (_, response) = try await performDataAndResponse(request)
            return Self.entityTag(in: response)
        } catch ManagementAPIError.server(let status, _) where status == 412 || status == 428 {
            throw ManagementAPIError.configConflict
        }
    }

    /// Whether a `config.yaml` write made with this read's `etag` is compare-and-set.
    static func configYAMLWritesAreChecked(etag: String?) -> Bool {
        guard let etag else { return false }
        return !etag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func entityTag(in response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// The engine's request-error files (`GET /v0/management/request-error-logs`).
    func requestErrorLogs(baseURL: URL, managementKey: String) async throws -> [RuntimeRequestErrorLog] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = RuntimeRequestErrorLogFiles.listPath
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        let response: RuntimeRequestErrorLogsResponse = try await get(url: url, managementKey: managementKey)
        return response.files
    }

    /// One request-error file as the engine stores it (`GET …/request-error-logs/<name>`). The
    /// caller masks secrets before the bytes go anywhere (`RuntimeRequestErrorLogFiles`).
    func downloadRequestErrorLog(name: String, baseURL: URL, managementKey: String) async throws -> Data {
        guard let path = RuntimeRequestErrorLogFiles.downloadPath(for: name) else {
            throw ManagementAPIError.invalidRequestErrorLogName
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.percentEncodedPath = path
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        return try await performData(request)
    }

    func downloadAuthFile(
        name: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files/download"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await performData(request)
    }

    func uploadAuthFile(
        name: String,
        data: Data,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data
        try await performMutation(request)
    }

    func deleteAuthFile(
        name: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await performMutation(request)
    }

    func patchAuthFileStatus(
        _ patch: RuntimeAuthFileStatusPatch,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/auth-files/status"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(patch)
        try await performMutation(request)
    }

    func openAICompatibility(
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOpenAICompatibilityResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/openai-compatibility"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func patchOpenAICompatibility(
        name: String?,
        index: Int? = nil,
        value: RuntimeOpenAICompatibilityPatch,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/openai-compatibility"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            RuntimeOpenAICompatibilityPatchRequest(name: name, index: index, value: value)
        )
        try await performMutation(request)
    }

    func replaceOpenAICompatibility(
        _ providers: [RuntimeOpenAICompatibilityWrite],
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/openai-compatibility"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(providers)
        try await performMutation(request)
    }

    /// CLIProxyAPI currently exposes list replacement rather than a dedicated
    /// append endpoint. Read the raw list immediately before writing so fields
    /// introduced by newer targets are passed through untouched.
    /// Reads the whole list from `GET /v0/management/config` (complete raw entries; the list
    /// endpoint's GET may leave fields out) and PUTs it back with `provider` appended.
    func appendOpenAICompatibility(
        _ provider: RuntimeOpenAICompatibilityWrite,
        allocatePrefixAgainst otherPrefixes: [String]? = nil,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOpenAICompatibilityListAppendOutcome {
        let url = try openAICompatibilityURL(baseURL: baseURL)
        let getRequest = managementRequest(url: try configURL(baseURL: baseURL), method: "GET", managementKey: managementKey)
        let responseData = try await performData(getRequest)
        let payload = try RuntimeOpenAICompatibilityListMutation.append(
            provider,
            to: responseData,
            allocatePrefixAgainst: otherPrefixes
        )
        guard case .appended = payload.outcome else {
            return payload.outcome
        }
        guard let requestBody = payload.requestBody else {
            throw RuntimeOpenAICompatibilityListMutationError.invalidProvider
        }

        var request = managementRequest(url: url, method: "PUT", managementKey: managementKey)
        request.httpBody = requestBody
        try await performMutation(request)
        return .appended
    }

    /// Gives one provider `priority` through a read-modify-write of the whole list (GET
    /// `/v0/management/config`, PUT `/v0/management/openai-compatibility`), for engines whose PATCH
    /// does not take `priority`. Nothing is written when the stored value already matches.
    func setOpenAICompatibilityPriority(
        _ priority: Int,
        providerNamed name: String,
        index: Int?,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let getRequest = managementRequest(url: try configURL(baseURL: baseURL), method: "GET", managementKey: managementKey)
        let responseData = try await performData(getRequest)
        guard let body = try RuntimeOpenAICompatibilityListMutation.settingPriority(
            priority, ofProviderNamed: name, index: index, in: responseData
        ) else { return }
        var request = managementRequest(url: try openAICompatibilityURL(baseURL: baseURL), method: "PUT", managementKey: managementKey)
        request.httpBody = body
        try await performMutation(request)
    }

    private func configURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/config"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    func deleteOpenAICompatibility(
        name: String? = nil,
        index: Int? = nil,
        baseURL: URL,
        managementKey: String
    ) async throws {
        let url = try Self.openAICompatibilityDeleteURL(
            name: name,
            index: index,
            baseURL: baseURL
        )

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await performMutation(request)
    }

    static func openAICompatibilityDeleteURL(
        name: String?,
        index: Int?,
        baseURL: URL
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/openai-compatibility"
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedName.isEmpty {
            components.queryItems = [URLQueryItem(name: "name", value: normalizedName)]
        } else if let index {
            components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        } else {
            components.queryItems = nil
        }
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    func logs(
        baseURL: URL,
        managementKey: String,
        after: Int64? = nil,
        cursor: String? = nil,
        limit: Int = 300
    ) async throws -> RuntimeLogsResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/logs"
        var queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 2_000))))]
        if let after {
            queryItems.append(URLQueryItem(name: "after", value: String(after)))
        }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func clearLogs(baseURL: URL, managementKey: String) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/logs"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
    }

    func setLoggingToFile(
        _ enabled: Bool,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/logging-to-file"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["value": enabled])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
    }

    func oauthStart(
        provider: RuntimeOAuthProvider,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthStartResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/\(provider.rawValue)-auth-url"
        components.queryItems = provider.sendsWebUIFlag
            ? [URLQueryItem(name: "is_webui", value: "true")]
            : nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func pluginOAuthStart(
        provider: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthStartResponse {
        let provider = try normalizedPluginOAuthProvider(provider)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.percentEncodedPath = "/v0/management/\(provider)-auth-url"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func oauthStatus(
        state: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthStatusResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/get-auth-status"
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func oauthCallback(
        provider: RuntimeOAuthProvider,
        redirectURL: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthCallbackResponse {
        try await oauthCallback(
            provider: provider.rawValue,
            redirectURL: redirectURL,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    func pluginOAuthCallback(
        provider: String,
        redirectURL: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthCallbackResponse {
        try await oauthCallback(
            provider: try normalizedPluginOAuthProvider(provider),
            redirectURL: redirectURL,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    private func oauthCallback(
        provider: String,
        redirectURL: String,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeOAuthCallbackResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/oauth-callback"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": provider,
            "redirect_url": redirectURL
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
        do {
            return try decoder.decode(RuntimeOAuthCallbackResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    func cancelOAuth(
        state: String,
        baseURL: URL,
        managementKey: String
    ) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/oauth-session"
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }
    }

    func systemStatus(baseURL: URL, managementKey: String) async throws -> RuntimeSystemStatus {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/status"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    func managerConfig(baseURL: URL, managementKey: String) async throws -> RuntimeManagerConfigResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/usage-service/config"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return try await get(url: url, managementKey: managementKey)
    }

    /// Saves CPA Manager Plus's manager config. A config read from the server carries
    /// `updatedAtMs`; it is sent both in the body and as `If-Match: "<ms>"`, which the oases
    /// fork uses as the expected version (409 `manager_config_conflict` when stale) and
    /// upstream v1.14.10 ignores.
    func saveManagerConfig(
        _ config: RuntimeManagerConfig,
        baseURL: URL,
        managementKey: String
    ) async throws -> RuntimeManagerConfigResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/usage-service/config"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let version = config.updatedAtMs {
            request.setValue("\"\(version)\"", forHTTPHeaderField: "If-Match")
        }
        request.httpBody = try JSONEncoder().encode(RuntimeManagerConfigPayload(config: config))

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
               object["code"] as? String == "manager_config_conflict" {
                throw ManagementAPIError.managerConfigConflict
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }

        do {
            return try decoder.decode(RuntimeManagerConfigResponse.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    private func get<T: Decodable>(url: URL, managementKey: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManagementAPIError.unauthorized
            }
            throw ManagementAPIError.server(status: httpResponse.statusCode, message: message)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ManagementAPIError.decoding(String(describing: error))
        }
    }

    private func pluginURL(baseURL: URL, pluginID: String, suffix: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        let encodedID = try encodedPluginIdentifier(pluginID)
        components.percentEncodedPath = "/v0/management/plugins/\(encodedID)\(suffix)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func directProviderURL(
        baseURL: URL,
        kind: RuntimeDirectProviderKind
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        // `managementSection` is a fixed enum, never user input.
        components.path = "/v0/management/\(kind.managementSection)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func oauthModelPolicyURL(baseURL: URL, endpoint: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/\(endpoint)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func modelPricesURL(baseURL: URL, suffix: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/model-prices\(suffix)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func openAICompatibilityURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/openai-compatibility"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func accountActionCandidatesURL(
        baseURL: URL,
        status: RuntimeAccountActionStatusFilter,
        limit: Int
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/account-action-candidates"
        let normalizedLimit = min(max(limit, 1), 200)
        var queryItems = [URLQueryItem(name: "limit", value: String(normalizedLimit))]
        if let status = status.queryValue {
            queryItems.insert(URLQueryItem(name: "status", value: status), at: 0)
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func accountActionURL(
        baseURL: URL,
        candidateID: Int64,
        operation: RuntimeAccountActionOperation
    ) throws -> URL {
        guard candidateID > 0 else { throw ManagementAPIError.invalidAccountActionCandidateID }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/account-action-candidates/\(candidateID)/\(operation.endpointComponent)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func codexInspectionStartURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/codex-inspection/run"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func codexInspectionRunsURL(baseURL: URL, limit: Int) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/codex-inspection/runs"
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))
        ]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func codexInspectionRunURL(
        baseURL: URL,
        runID: Int64,
        suffix: String
    ) throws -> URL {
        guard runID > 0 else { throw ManagementAPIError.invalidCodexInspectionRunID }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        components.path = "/v0/management/codex-inspection/runs/\(runID)\(suffix)"
        components.queryItems = nil
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func pluginStoreInstallURL(
        baseURL: URL,
        pluginID: String,
        sourceID: String
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ManagementAPIError.invalidURL
        }
        let encodedID = try encodedPluginIdentifier(pluginID)
        components.percentEncodedPath = "/v0/management/plugin-store/\(encodedID)/install"
        let source = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = source.isEmpty ? nil : [URLQueryItem(name: "source", value: source)]
        guard let url = components.url else { throw ManagementAPIError.invalidURL }
        return url
    }

    private func encodedPluginIdentifier(_ pluginID: String) throws -> String {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ManagementAPIError.invalidPluginID }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ManagementAPIError.invalidPluginID
        }
        return encodedID
    }

    private func normalizedPluginOAuthProvider(_ provider: String) throws -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "-")
              }) else {
            throw ManagementAPIError.invalidPluginOAuthProvider
        }
        return normalized
    }

    private func normalizedOAuthModelPolicyChannel(_ channel: String) throws -> String {
        guard let normalized = RuntimeOAuthModelPolicyValidator.normalizedChannel(channel) else {
            throw ManagementAPIError.invalidOAuthModelPolicyChannel
        }
        return normalized
    }

    private func managementRequest(url: URL, method: String, managementKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func performMutation(_ request: URLRequest) async throws {
        _ = try await performData(request)
    }

    private func performData(
        _ request: URLRequest,
        unauthorizedError: ManagementAPIError = .unauthorized
    ) async throws -> Data {
        try await performDataAndResponse(request, unauthorizedError: unauthorizedError).0
    }

    private func performDataAndResponse(
        _ request: URLRequest,
        unauthorizedError: ManagementAPIError = .unauthorized
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagementAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? OasesLocalization.localized("请求失败")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw unauthorizedError
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
        return (data, httpResponse)
    }
}
