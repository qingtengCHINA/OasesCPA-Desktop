import Foundation

/// A model discovered from an unsaved OpenAI-compatible Provider draft.
struct RuntimeDiscoveredProviderModel: Equatable, Sendable {
    let name: String
    let alias: String?
    let description: String?

    init(name: String, alias: String? = nil, description: String? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = Self.normalizedOptional(alias)
        self.description = Self.normalizedOptional(description)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RuntimeProviderDraftDiagnosticsOutcome: Equatable, Sendable {
    enum Kind: String, Sendable {
        case models
        case chatCompletions
    }

    let kind: Kind
    let statusCode: Int
    let modelCount: Int?
    let isSuccess: Bool
    let message: String
}

enum RuntimeProviderDraftDiagnosticsError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case missingModel
    case missingCredential
    case maskedCredential
    case invalidResponse
    case upstreamStatus(Int)

    var safeMessage: String {
        switch self {
        case .invalidBaseURL:
            return OasesLocalization.localized("服务地址无效，请检查地址后重试。")
        case .missingModel:
            return OasesLocalization.localized("请先选择一个模型。")
        case .missingCredential:
            return OasesLocalization.localized("请填写 API Key，或提供可用的凭证索引。")
        case .maskedCredential:
            return OasesLocalization.localized("当前 API Key 是遮罩值，请重新输入完整密钥。")
        case .invalidResponse:
            return OasesLocalization.localized("服务返回的数据格式无法识别。")
        case let .upstreamStatus(statusCode):
            return "请求未成功（状态码 " + String(statusCode) + "）。"
        }
    }

    var errorDescription: String? { safeMessage }
}

/// Pure request construction for an unsaved draft. The returned payload is
/// intended for CLIProxyAPI's /v0/management/api-call endpoint.
enum RuntimeProviderDraftDiagnosticsFactory {
    private static let modelsSuffix = "/models"
    private static let chatCompletionsSuffix = "/chat/completions"

    static func modelsRequest(
        baseURL: String,
        apiKey: String? = nil,
        authIndex: String? = nil,
        headers: [String: String] = [:]
    ) throws -> RuntimeAPICallRequest {
        let endpoint = try endpoint(baseURL: baseURL, kind: .models)
        let resolvedAuthIndex = normalizedAuthIndex(authIndex)
        let requestHeaders = try resolvedHeaders(
            customHeaders: headers,
            apiKey: apiKey,
            authIndex: resolvedAuthIndex,
            includeJSONContentType: false
        )
        return RuntimeAPICallRequest(
            authIndex: resolvedAuthIndex,
            method: "GET",
            url: endpoint,
            header: requestHeaders
        )
    }

    static func chatCompletionsRequest(
        baseURL: String,
        apiKey: String? = nil,
        authIndex: String? = nil,
        headers: [String: String] = [:],
        model: String
    ) throws -> RuntimeAPICallRequest {
        let endpoint = try endpoint(baseURL: baseURL, kind: .chatCompletions)
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw RuntimeProviderDraftDiagnosticsError.missingModel
        }

        let resolvedAuthIndex = normalizedAuthIndex(authIndex)
        let requestHeaders = try resolvedHeaders(
            customHeaders: headers,
            apiKey: apiKey,
            authIndex: resolvedAuthIndex,
            includeJSONContentType: true
        )
        let body: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": "Hi"]],
            "stream": false,
            "max_tokens": 5
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let bodyString = String(data: data, encoding: .utf8) else {
            throw RuntimeProviderDraftDiagnosticsError.invalidResponse
        }

        return RuntimeAPICallRequest(
            authIndex: resolvedAuthIndex,
            method: "POST",
            url: endpoint,
            header: requestHeaders,
            data: bodyString
        )
    }

    fileprivate static func parseModelsJSON(
        _ data: Data
    ) throws -> [RuntimeDiscoveredProviderModel] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RuntimeProviderDraftDiagnosticsError.invalidResponse
        }

        let entries: [Any]
        if let array = object as? [Any] {
            entries = array
        } else if let dictionary = object as? [String: Any] {
            if let data = dictionary["data"] as? [Any] {
                entries = data
            } else if let models = dictionary["models"] as? [Any] {
                entries = models
            } else {
                throw RuntimeProviderDraftDiagnosticsError.invalidResponse
            }
        } else {
            throw RuntimeProviderDraftDiagnosticsError.invalidResponse
        }

        var result: [RuntimeDiscoveredProviderModel] = []
        var seen: Set<String> = []
        for entry in entries {
            let discoveredModel: RuntimeDiscoveredProviderModel?
            if let dictionary = entry as? [String: Any] {
                discoveredModel = model(from: dictionary)
            } else if let string = entry as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                discoveredModel = trimmed.isEmpty ? nil : RuntimeDiscoveredProviderModel(name: trimmed)
            } else {
                discoveredModel = nil
            }
            guard let discoveredModel else { continue }
            let key = discoveredModel.name.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(discoveredModel)
        }
        return result
    }

    private enum EndpointKind {
        case models
        case chatCompletions
    }

    private static func endpoint(baseURL: String, kind: EndpointKind) throws -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw RuntimeProviderDraftDiagnosticsError.invalidBaseURL
        }
        if !value.contains("://") {
            value = "http://" + value
        }
        value = value.replacingOccurrences(
            of: "\\/?v0/management/?$",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "/+/?$", with: "", options: .regularExpression)

        let lowercased = value.lowercased()
        if lowercased.hasSuffix(modelsSuffix) {
            value = String(value.dropLast(modelsSuffix.count))
        } else if lowercased.hasSuffix(chatCompletionsSuffix) {
            value = String(value.dropLast(chatCompletionsSuffix.count))
        }
        value = value.replacingOccurrences(of: "/+/?$", with: "", options: .regularExpression)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw RuntimeProviderDraftDiagnosticsError.invalidBaseURL
        }

        switch kind {
        case .models:
            return value + modelsSuffix
        case .chatCompletions:
            return value + chatCompletionsSuffix
        }
    }

    private static func resolvedHeaders(
        customHeaders: [String: String],
        apiKey: String?,
        authIndex: String?,
        includeJSONContentType: Bool
    ) throws -> [String: String] {
        var result = customHeaders
        if let authorizationKey = result.keys.first(where: {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }), isObviousMask(result[authorizationKey] ?? "") {
            throw RuntimeProviderDraftDiagnosticsError.maskedCredential
        }

        let hasAuthorization = result.keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        if !hasAuthorization {
            let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedKey.isEmpty, !isObviousMask(trimmedKey) {
                result["Authorization"] = "Bearer " + trimmedKey
            } else if isObviousMask(trimmedKey) {
                guard authIndex != nil else {
                    throw RuntimeProviderDraftDiagnosticsError.maskedCredential
                }
                result["Authorization"] = "Bearer $TOKEN$"
            } else if authIndex != nil {
                result["Authorization"] = "Bearer $TOKEN$"
            } else {
                // Some OpenAI-compatible gateways expose a public /models
                // endpoint. Preserve that unauthenticated request shape.
            }
        }

        if includeJSONContentType,
           !result.keys.contains(where: {
               $0.caseInsensitiveCompare("Content-Type") == .orderedSame
           }) {
            result["Content-Type"] = "application/json"
        }
        return result
    }

    private static func normalizedAuthIndex(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isObviousMask(_ value: String) -> Bool {
        value.contains("•") || value.contains("*")
    }

    private static func model(
        from dictionary: [String: Any]
    ) -> RuntimeDiscoveredProviderModel? {
        let name = stringValue(dictionary["id"])
            ?? stringValue(dictionary["name"])
            ?? ""
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return RuntimeDiscoveredProviderModel(
            name: trimmedName,
            alias: stringValue(dictionary["alias"]),
            description: stringValue(dictionary["description"])
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        return value as? String
    }
}

enum RuntimeProviderDraftDiagnosticsParser {
    enum OutcomeKind: Sendable {
        case models
        case chatCompletions
    }

    static func models(
        from response: RuntimeAPICallResponse
    ) throws -> [RuntimeDiscoveredProviderModel] {
        guard (200..<300).contains(response.statusCode) else {
            throw RuntimeProviderDraftDiagnosticsError.upstreamStatus(response.statusCode)
        }
        guard let data = response.body.data(using: .utf8) else {
            throw RuntimeProviderDraftDiagnosticsError.invalidResponse
        }
        return try RuntimeProviderDraftDiagnosticsFactory.parseModelsJSON(data)
    }

    static func safeOutcome(
        from response: RuntimeAPICallResponse,
        kind: OutcomeKind
    ) -> RuntimeProviderDraftDiagnosticsOutcome {
        switch kind {
        case .models:
            do {
                let discoveredModels = try models(from: response)
                return RuntimeProviderDraftDiagnosticsOutcome(
                    kind: .models,
                    statusCode: response.statusCode,
                    modelCount: discoveredModels.count,
                    isSuccess: true,
                    message: "已发现 " + String(discoveredModels.count) + " 个模型。"
                )
            } catch let error as RuntimeProviderDraftDiagnosticsError {
                return RuntimeProviderDraftDiagnosticsOutcome(
                    kind: .models,
                    statusCode: response.statusCode,
                    modelCount: nil,
                    isSuccess: false,
                    message: error.safeMessage
                )
            } catch {
                return RuntimeProviderDraftDiagnosticsOutcome(
                    kind: .models,
                    statusCode: response.statusCode,
                    modelCount: nil,
                    isSuccess: false,
                    message: RuntimeProviderDraftDiagnosticsError.invalidResponse.safeMessage
                )
            }
        case .chatCompletions:
            let success = (200..<300).contains(response.statusCode)
            let status = String(response.statusCode)
            return RuntimeProviderDraftDiagnosticsOutcome(
                kind: .chatCompletions,
                statusCode: response.statusCode,
                modelCount: nil,
                isSuccess: success,
                message: success
                    ? "连通性测试成功（状态码 " + status + "）。"
                    : "连通性测试未通过（状态码 " + status + "）。"
            )
        }
    }
}
