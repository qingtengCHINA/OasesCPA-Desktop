import CryptoKit
import Foundation
import Security

enum RuntimeOpenRouterOAuth {
    static let providerName = "openrouter-oauth"
    static let apiBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let authorizationEndpoint = URL(string: "https://openrouter.ai/auth")!
    static let tokenEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    /// The token exchange returns an API key and the model list sends one: no disk cache.
    static var session: URLSession { SecretBearingURLSession.shared }

    static func makeSession(callbackURL: URL) throws -> RuntimeOpenRouterOAuthSession {
        let codeVerifier = try secureRandomBase64URL(byteCount: 48)
        let state = try secureRandomBase64URL(byteCount: 32)
        let challenge = base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))

        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw RuntimeOpenRouterOAuthError.invalidAuthorizationURL
        }
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizationURL = components.url else {
            throw RuntimeOpenRouterOAuthError.invalidAuthorizationURL
        }

        return RuntimeOpenRouterOAuthSession(
            callbackURL: callbackURL,
            authorizationURL: authorizationURL,
            codeVerifier: codeVerifier,
            state: state
        )
    }

    static func parseLoopbackCallbackTarget(_ target: String) -> RuntimeOpenRouterOAuthCallback {
        guard target.hasPrefix("/"),
              let components = URLComponents(string: target),
              components.path == "/callback" else {
            return .malformed(OasesLocalization.localized("回调地址不是预期的 /callback 路径。"))
        }

        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        let state = values["state"]?
            .compactMap(\.value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        if let providerError = values["error"]?
            .compactMap(\.value)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            let description = values["error_description"]?
                .compactMap(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            return .providerError(message: description ?? providerError, state: state)
        }

        guard let code = values["code"]?
            .compactMap(\.value)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return .malformed(OasesLocalization.localized("授权回调没有包含 code。"))
        }
        guard let state else {
            return .malformed(OasesLocalization.localized("授权回调没有包含 state。"))
        }
        return .authorizationCode(code: code, state: state)
    }

    static func authorizationGrant(
        from callback: RuntimeOpenRouterOAuthCallback,
        session: RuntimeOpenRouterOAuthSession
    ) -> Result<RuntimeOpenRouterAuthorizationGrant, RuntimeOpenRouterOAuthError> {
        switch callback {
        case .authorizationCode(let code, let state):
            guard securelyEquals(state, session.state) else {
                return .failure(.stateMismatch)
            }
            return .success(
                RuntimeOpenRouterAuthorizationGrant(
                    code: code,
                    codeVerifier: session.codeVerifier
                )
            )
        case .providerError(let message, let state):
            guard let state, securelyEquals(state, session.state) else {
                return .failure(.stateMismatch)
            }
            return .failure(.authorizationDenied(message))
        case .malformed(let message):
            return .failure(.invalidCallback(message))
        }
    }

    static func tokenExchangeRequest(
        code: String,
        codeVerifier: String
    ) throws -> URLRequest {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVerifier = codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty, !trimmedVerifier.isEmpty else {
            throw RuntimeOpenRouterOAuthError.invalidAuthorizationCode
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": trimmedCode,
            "code_verifier": trimmedVerifier,
            "code_challenge_method": "S256"
        ])
        return request
    }

    static func exchangeCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> String {
        let request = try tokenExchangeRequest(code: code, codeVerifier: codeVerifier)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeOpenRouterOAuthError.invalidTokenResponse
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let key = (payload?["key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200..<300).contains(httpResponse.statusCode), !key.isEmpty else {
            let reason = conciseProviderError(
                payload: payload,
                fallback: "HTTP \(httpResponse.statusCode)"
            )
            throw RuntimeOpenRouterOAuthError.tokenExchangeFailed(reason)
        }
        return key
    }

    static func fetchModels(apiKey: String) async -> RuntimeOpenRouterModelCatalog {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .unavailable
        }

        var request = URLRequest(url: apiBaseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = payload["data"] as? [[String: Any]] else {
                return .unavailable
            }

            var seen = Set<String>()
            let models = entries.compactMap { entry -> RuntimeProviderModel? in
                let id = (entry["id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                return RuntimeProviderModel(name: id, alias: id)
            }
            return .loaded(models)
        } catch {
            return .unavailable
        }
    }

    private static func secureRandomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RuntimeOpenRouterOAuthError.secureRandomUnavailable
        }
        return base64URLEncoded(Data(bytes))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func securelyEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func conciseProviderError(
        payload: [String: Any]?,
        fallback: String
    ) -> String {
        let value = (payload?["error_description"] as? String)
            ?? (payload?["error"] as? String)
            ?? fallback
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return OasesLocalization.localized("OpenRouter 未返回可用的 API Key。") }
        return String(trimmed.prefix(280))
    }
}

struct RuntimeOpenRouterOAuthSession: Equatable, Sendable {
    let callbackURL: URL
    let authorizationURL: URL
    let codeVerifier: String
    let state: String
}

struct RuntimeOpenRouterAuthorizationGrant: Equatable, Sendable {
    let code: String
    let codeVerifier: String
}

enum RuntimeOpenRouterOAuthCallback: Equatable, Sendable {
    case authorizationCode(code: String, state: String)
    case providerError(message: String, state: String?)
    case malformed(String)
}

enum RuntimeOpenRouterModelCatalog: Sendable {
    case loaded([RuntimeProviderModel])
    case unavailable

    var models: [RuntimeProviderModel] {
        switch self {
        case .loaded(let models):
            models
        case .unavailable:
            []
        }
    }

    var didLoad: Bool {
        if case .loaded = self { return true }
        return false
    }
}

struct RuntimeOpenRouterProviderSaveResult: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case created
        case updated
    }

    let disposition: Disposition
    let modelCount: Int
    let preservedExistingModels: Bool
}

enum RuntimeOpenRouterOAuthError: LocalizedError, Equatable, Sendable {
    case secureRandomUnavailable
    case invalidAuthorizationURL
    case invalidAuthorizationCode
    case invalidCallback(String)
    case stateMismatch
    case authorizationDenied(String)
    case invalidTokenResponse
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .secureRandomUnavailable:
            OasesLocalization.localized("macOS 无法生成安全随机值，已取消 OpenRouter 授权。")
        case .invalidAuthorizationURL:
            OasesLocalization.localized("无法创建 OpenRouter 授权地址。")
        case .invalidAuthorizationCode:
            OasesLocalization.localized("OpenRouter 回调中的授权码无效。")
        case .invalidCallback(let message):
            "OpenRouter 回调无效：\(message)"
        case .stateMismatch:
            OasesLocalization.localized("OpenRouter 回调的 state 不匹配，已拒绝该请求。")
        case .authorizationDenied(let message):
            "OpenRouter 授权未完成：\(message)"
        case .invalidTokenResponse:
            OasesLocalization.localized("OpenRouter 返回了无法识别的换取凭证响应。")
        case .tokenExchangeFailed(let message):
            "OpenRouter 换取 API Key 失败：\(message)"
        }
    }
}
