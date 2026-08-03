import Foundation

/// A deliberately presentation-safe description of one configured upstream
/// discovery check. It never carries a URL, API key, auth index, request
/// header, response header, or upstream response body.
struct RuntimeProviderConnectivityTarget: Identifiable, Equatable, Sendable {
    let id: String
    let providerTitle: String
    let providerKind: String
    let host: String
    let endpointLabel: String
    let systemImage: String
}

enum RuntimeProviderConnectivityStatus: String, Sendable {
    case pending
    case running
    case success
    case failed
    case skipped
    case cancelled

    var title: String {
        switch self {
        case .pending: OasesLocalization.localized("等待检查")
        case .running: OasesLocalization.localized("检查中")
        case .success: OasesLocalization.localized("可连接")
        case .failed: OasesLocalization.localized("需处理")
        case .skipped: OasesLocalization.localized("未发起")
        case .cancelled: OasesLocalization.localized("已取消")
        }
    }
}

/// The only result persisted for a provider connectivity check. In
/// particular, it intentionally does not preserve an upstream body, response
/// header, original URL, API key, auth index, or request headers.
struct RuntimeProviderConnectivityResult: Identifiable, Equatable, Sendable {
    let target: RuntimeProviderConnectivityTarget
    let status: RuntimeProviderConnectivityStatus
    let modelCount: Int?
    let statusCode: Int?
    let durationMilliseconds: Int?
    let message: String

    var id: String { target.id }

    init(
        target: RuntimeProviderConnectivityTarget,
        status: RuntimeProviderConnectivityStatus,
        modelCount: Int? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        message: String = ""
    ) {
        self.target = target
        self.status = status
        self.modelCount = modelCount
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.message = message
    }

    static func pending(for target: RuntimeProviderConnectivityTarget) -> Self {
        Self(target: target, status: .pending, message: OasesLocalization.localized("等待用户确认后开始。"))
    }

    static func skipped(
        for target: RuntimeProviderConnectivityTarget,
        reason: String
    ) -> Self {
        Self(target: target, status: .skipped, message: reason)
    }
}

/// A non-sensitive count used by the confirmation UI. It is calculated from a
/// transient plan and does not expose the plan's request payloads.
struct RuntimeProviderConnectivityPreview: Equatable, Sendable {
    let targetCount: Int
    let outboundRequestUpperBound: Int
    let skippedCount: Int

    var outboundTargetCount: Int {
        max(0, targetCount - skippedCount)
    }
}

/// Internal execution state. Request payloads are transient and never
/// published by RuntimeDataStore or passed into SwiftUI presentation models.
struct RuntimeProviderConnectivityExecution: Sendable {
    let target: RuntimeProviderConnectivityTarget
    let requests: [RuntimeAPICallRequest]
    let skipReason: String?

    init(
        target: RuntimeProviderConnectivityTarget,
        requests: [RuntimeAPICallRequest] = [],
        skipReason: String? = nil
    ) {
        self.target = target
        self.requests = requests
        self.skipReason = skipReason
    }
}

struct RuntimeProviderConnectivityPlan: Sendable {
    let executions: [RuntimeProviderConnectivityExecution]

    var preview: RuntimeProviderConnectivityPreview {
        RuntimeProviderConnectivityPreview(
            targetCount: executions.count,
            outboundRequestUpperBound: executions.reduce(0) { partial, execution in
                partial + execution.requests.count
            },
            skippedCount: executions.filter { $0.skipReason != nil }.count
        )
    }
}

/// Builds a constrained set of upstream model-discovery requests from the
/// current CLIProxyAPI configuration. The factory mirrors the upstream
/// CPAMP health-check routing rules, but intentionally limits Gemini to one
/// discovery page and never changes enablement or configuration.
enum RuntimeProviderConnectivityFactory {
    private enum EndpointStyle {
        case v1Models
        case models
        case claudeModels
        case geminiModels
    }

    private enum CredentialStyle {
        case bearer
        case header(String)
    }

    private struct EndpointResolution {
        let url: URL
        let host: String
    }

    private static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com"
    private static let defaultClaudeBaseURL = "https://api.anthropic.com"
    private static let defaultVertexBaseURL = "https://aiplatform.googleapis.com"
    private static let anthropicVersion = "2023-06-01"
    private static let credentialHeaderNames: Set<String> = [
        "authorization",
        "x-api-key",
        "x-goog-api-key"
    ]

    static func plan(
        directCredentials: [RuntimeDirectProviderKind: [RuntimeDirectProviderCredential]],
        openAICompatibility: [RuntimeOpenAICompatibility]
    ) -> RuntimeProviderConnectivityPlan {
        var executions: [RuntimeProviderConnectivityExecution] = []

        for kind in RuntimeDirectProviderKind.allCases {
            let credentials = (directCredentials[kind] ?? []).sorted { $0.index < $1.index }
            for credential in credentials {
                executions.append(directExecution(for: credential))
            }
        }

        for (providerIndex, provider) in openAICompatibility.enumerated() {
            executions.append(contentsOf: openAIExecutions(
                for: provider,
                providerIndex: providerIndex
            ))
        }

        return RuntimeProviderConnectivityPlan(executions: executions)
    }

    private static func directExecution(
        for credential: RuntimeDirectProviderCredential
    ) -> RuntimeProviderConnectivityExecution {
        let kind = credential.kind
        let endpointStyle: EndpointStyle
        let fallbackBaseURL: String?
        let credentialStyle: CredentialStyle
        let endpointLabel: String

        switch kind {
        case .gemini, .interactions:
            endpointStyle = .geminiModels
            fallbackBaseURL = defaultGeminiBaseURL
            credentialStyle = .header("x-goog-api-key")
            endpointLabel = "GET /v1beta/models"
        case .codex, .xai:
            endpointStyle = .v1Models
            fallbackBaseURL = nil
            credentialStyle = .bearer
            endpointLabel = "GET /v1/models"
        case .claude:
            endpointStyle = .claudeModels
            fallbackBaseURL = defaultClaudeBaseURL
            credentialStyle = .header("x-api-key")
            endpointLabel = "GET /v1/models"
        case .vertex:
            endpointStyle = .v1Models
            fallbackBaseURL = defaultVertexBaseURL
            credentialStyle = .header("x-goog-api-key")
            endpointLabel = OasesLocalization.localized("GET /v1/models（必要时 /models）")
        }

        let targetID = "direct.\(kind.rawValue).\(max(0, credential.index))"
        let targetTitle = "\(kind.title) · 凭证 \(credential.index + 1)"
        let resolution = endpoint(
            configuredBaseURL: credential.baseURL,
            fallbackBaseURL: fallbackBaseURL,
            style: endpointStyle
        )
        let target = target(
            id: targetID,
            providerTitle: targetTitle,
            providerKind: kind.title,
            host: resolution.map(\.host) ?? hostLabel(
                configuredBaseURL: credential.baseURL,
                fallbackBaseURL: fallbackBaseURL
            ),
            endpointLabel: endpointLabel,
            systemImage: kind.systemImage
        )

        guard let resolution else {
            return RuntimeProviderConnectivityExecution(
                target: target,
                skipReason: OasesLocalization.localized("未配置有效的 HTTP(S) Base URL，未发起请求。")
            )
        }

        let authIndex = normalizedAuthIndex(credential.authIndex)
        guard let credentialRequest = requestCredential(
            apiKey: credential.apiKey,
            authIndex: authIndex,
            style: credentialStyle,
            headers: headers(from: credential.payload)
        ) else {
            return RuntimeProviderConnectivityExecution(
                target: target,
                skipReason: OasesLocalization.localized("密钥被遮罩或缺少可解析的认证信息，未发起请求。")
            )
        }

        var requests = [
            RuntimeAPICallRequest(
                authIndex: authIndex,
                method: "GET",
                url: resolution.url.absoluteString,
                header: credentialRequest
            )
        ]
        if kind == .vertex,
           let fallback = endpoint(
               configuredBaseURL: credential.baseURL,
               fallbackBaseURL: fallbackBaseURL,
               style: .models
           ),
           fallback.url != resolution.url {
            requests.append(RuntimeAPICallRequest(
                authIndex: authIndex,
                method: "GET",
                url: fallback.url.absoluteString,
                header: credentialRequest
            ))
        }

        return RuntimeProviderConnectivityExecution(target: target, requests: requests)
    }

    private static func openAIExecutions(
        for provider: RuntimeOpenAICompatibility,
        providerIndex: Int
    ) -> [RuntimeProviderConnectivityExecution] {
        let providerName = displayText(
            provider.name,
            fallback: "OpenAI-compatible Provider \(providerIndex + 1)"
        )
        let endpointLabel = "GET /models"
        let resolution = endpoint(
            configuredBaseURL: provider.baseURL,
            fallbackBaseURL: nil,
            style: .models
        )

        let entries: [(index: Int, apiKey: String, authIndex: String?)]
        if provider.apiKeyEntries.isEmpty {
            entries = [(0, "", normalizedAuthIndex(provider.authIndex))]
        } else {
            entries = provider.apiKeyEntries.enumerated().map { index, entry in
                (
                    index,
                    entry.apiKey,
                    normalizedAuthIndex(entry.authIndex) ?? normalizedAuthIndex(provider.authIndex)
                )
            }
        }

        return entries.map { entry in
            let target = target(
                id: "openai.\(providerIndex).\(entry.index)",
                providerTitle: "\(providerName) · 密钥 \(entry.index + 1)",
                providerKind: "OpenAI-compatible",
                host: resolution.map(\.host) ?? hostLabel(
                    configuredBaseURL: provider.baseURL,
                    fallbackBaseURL: nil
                ),
                endpointLabel: endpointLabel,
                systemImage: "arrow.left.arrow.right"
            )

            if provider.disabled {
                return RuntimeProviderConnectivityExecution(
                    target: target,
                    skipReason: OasesLocalization.localized("该 Provider 当前已停用；原生检查不会自动启用它。")
                )
            }

            guard let resolution else {
                return RuntimeProviderConnectivityExecution(
                    target: target,
                    skipReason: OasesLocalization.localized("未配置有效的 HTTP(S) Base URL，未发起请求。")
                )
            }

            guard let requestHeaders = requestCredential(
                apiKey: entry.apiKey,
                authIndex: entry.authIndex,
                style: .bearer,
                headers: headers(from: provider.headers)
            ) else {
                return RuntimeProviderConnectivityExecution(
                    target: target,
                    skipReason: OasesLocalization.localized("密钥被遮罩或缺少可解析的认证信息，未发起请求。")
                )
            }

            return RuntimeProviderConnectivityExecution(
                target: target,
                requests: [
                    RuntimeAPICallRequest(
                        authIndex: entry.authIndex,
                        method: "GET",
                        url: resolution.url.absoluteString,
                        header: requestHeaders
                    )
                ]
            )
        }
    }

    private static func target(
        id: String,
        providerTitle: String,
        providerKind: String,
        host: String,
        endpointLabel: String,
        systemImage: String
    ) -> RuntimeProviderConnectivityTarget {
        RuntimeProviderConnectivityTarget(
            id: id,
            providerTitle: displayText(providerTitle, fallback: OasesLocalization.localized("未命名 Provider")),
            providerKind: displayText(providerKind, fallback: "Provider"),
            host: displayText(host, fallback: OasesLocalization.localized("未识别主机")),
            endpointLabel: endpointLabel,
            systemImage: systemImage
        )
    }

    private static func endpoint(
        configuredBaseURL: String,
        fallbackBaseURL: String?,
        style: EndpointStyle
    ) -> EndpointResolution? {
        let configured = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = configured.isEmpty
            ? (fallbackBaseURL ?? "")
            : configured
        guard !source.isEmpty,
              var components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }

        components.queryItems = nil
        components.fragment = nil
        let originalPath = trimmedPath(components.path)
        switch style {
        case .v1Models:
            let lower = originalPath.lowercased()
            if lower.hasSuffix("/v1/models") {
                components.path = originalPath
            } else if lower.hasSuffix("/v1") {
                components.path = appendPath(originalPath, "models")
            } else {
                components.path = appendPath(appendPath(originalPath, "v1"), "models")
            }
        case .models:
            if originalPath.lowercased().hasSuffix("/models") {
                components.path = originalPath
            } else {
                components.path = appendPath(originalPath, "models")
            }
        case .claudeModels:
            components.path = appendPath(
                appendPath(rootPath(beforeVersionMarker: originalPath, marker: "/v1"), "v1"),
                "models"
            )
        case .geminiModels:
            components.path = appendPath(
                appendPath(rootPath(beforeVersionMarker: originalPath, marker: "/v1beta"), "v1beta"),
                "models"
            )
        }

        guard let url = components.url else { return nil }
        return EndpointResolution(url: url, host: displayText(host, fallback: OasesLocalization.localized("未识别主机")))
    }

    private static func hostLabel(
        configuredBaseURL: String,
        fallbackBaseURL: String?
    ) -> String {
        let configured = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = configured.isEmpty ? (fallbackBaseURL ?? "") : configured
        guard let components = URLComponents(string: source),
              let host = components.host,
              !host.isEmpty else {
            return OasesLocalization.localized("未识别主机")
        }
        return displayText(host, fallback: OasesLocalization.localized("未识别主机"))
    }

    private static func requestCredential(
        apiKey: String,
        authIndex: String?,
        style: CredentialStyle,
        headers: [String: String]
    ) -> [String: String]? {
        var resolvedHeaders = headers
        if hasCredentialHeader(resolvedHeaders) {
            return resolvedHeaders
        }

        if let apiKey = usableAPIKey(apiKey) {
            switch style {
            case .bearer:
                setHeader("Authorization", value: "Bearer \(apiKey)", in: &resolvedHeaders)
            case .header(let name):
                setHeader(name, value: apiKey, in: &resolvedHeaders)
            }
            return resolvedHeaders
        }

        guard authIndex != nil else { return nil }
        switch style {
        case .bearer:
            setHeader("Authorization", value: "Bearer $TOKEN$", in: &resolvedHeaders)
        case .header(let name):
            setHeader(name, value: "$TOKEN$", in: &resolvedHeaders)
        }
        return resolvedHeaders
    }

    private static func headers(
        from payload: RuntimeProviderCredentialPayload
    ) -> [String: String] {
        guard case .object(let values) = payload.values["headers"] else { return [:] }
        var result: [String: String] = [:]
        for key in values.keys.sorted() {
            guard case .string(let value) = values[key] else { continue }
            addSanitizedHeader(key, value: value, to: &result)
        }
        return result
    }

    private static func headers(from source: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in source.keys.sorted() {
            guard let value = source[key] else { continue }
            addSanitizedHeader(key, value: value, to: &result)
        }
        return result
    }

    private static func addSanitizedHeader(
        _ rawName: String,
        value rawValue: String,
        to headers: inout [String: String]
    ) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHeaderName(name),
              !value.isEmpty,
              value.count <= 16_384,
              !value.contains(where: { $0.isNewline || $0 == "\r" }),
              !(credentialHeaderNames.contains(name.lowercased()) && looksRedacted(value)) else {
            return
        }
        setHeader(name, value: value, in: &headers)
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                true
            default:
                false
            }
        }
    }

    private static func setHeader(
        _ name: String,
        value: String,
        in headers: inout [String: String]
    ) {
        let matchingKeys = headers.keys.filter {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
        for key in matchingKeys {
            headers[key] = nil
        }
        headers[name] = value
    }

    private static func hasCredentialHeader(_ headers: [String: String]) -> Bool {
        headers.contains { key, value in
            credentialHeaderNames.contains(key.lowercased())
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !looksRedacted(value)
        }
    }

    private static func usableAPIKey(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 16_384,
              !value.contains(where: { $0.isNewline || $0 == "\r" }),
              !looksRedacted(value) else {
            return nil
        }
        return value
    }

    private static func normalizedAuthIndex(_ rawValue: String?) -> String? {
        let value = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 512,
              !value.contains(where: { $0.isNewline || $0 == "\r" }),
              !looksRedacted(value) else {
            return nil
        }
        return value
    }

    private static func looksRedacted(_ value: String) -> Bool {
        value.contains("•") || value.contains("*")
    }

    private static func displayText(
        _ rawValue: String,
        fallback: String,
        maximumLength: Int = 120
    ) -> String {
        let condensed = rawValue
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !condensed.isEmpty else { return fallback }
        guard condensed.count > maximumLength else { return condensed }
        return "\(condensed.prefix(maximumLength - 1))…"
    }

    private static func trimmedPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func appendPath(_ path: String, _ component: String) -> String {
        let root = trimmedPath(path)
        if root.isEmpty || root == "/" {
            return "/\(component)"
        }
        return "\(root)/\(component)"
    }

    private static func rootPath(
        beforeVersionMarker path: String,
        marker: String
    ) -> String {
        let lower = path.lowercased()
        guard let range = lower.range(of: marker, options: .backwards) else {
            return path
        }
        let suffixStart = range.upperBound
        guard suffixStart == lower.endIndex || lower[suffixStart] == "/" else {
            return path
        }
        return String(path[..<range.lowerBound])
    }
}

/// Parses just enough of an upstream discovery payload to count model records.
/// The source body is neither retained nor exposed to SwiftUI.
enum RuntimeProviderConnectivityModelParser {
    private static let maximumResponseBytes = 2_000_000
    private static let maximumModelCount = 10_000

    /// Returns nil when the payload is not a recognized model-list shape.
    /// A zero return value means the payload is recognized but contains no
    /// usable model identifiers.
    static func modelCount(from body: String) -> Int? {
        guard body.utf8.count <= maximumResponseBytes,
              let data = body.data(using: .utf8),
              let root = try? JSONDecoder().decode(RuntimeJSONValue.self, from: data) else {
            return nil
        }

        let entries: [RuntimeJSONValue]
        switch root {
        case .array(let value):
            entries = value
        case .object(let object):
            if case .array(let value) = object["data"] {
                entries = value
            } else if case .array(let value) = object["models"] {
                entries = value
            } else {
                return nil
            }
        default:
            return nil
        }

        var seen = Set<String>()
        for entry in entries {
            guard let identifier = modelIdentifier(from: entry) else { continue }
            let normalized = identifier.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            if seen.count >= maximumModelCount {
                return maximumModelCount
            }
        }
        return seen.count
    }

    private static func modelIdentifier(from value: RuntimeJSONValue) -> String? {
        switch value {
        case .string(let string):
            return boundedIdentifier(string)
        case .object(let object):
            for key in ["id", "name", "model", "value"] {
                if case .string(let string) = object[key],
                   let identifier = boundedIdentifier(string) {
                    return identifier
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func boundedIdentifier(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 512 else { return nil }
        return value
    }
}
