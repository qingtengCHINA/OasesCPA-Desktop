import Foundation

/// Errors of the gateway admin API (`/cpa-admin/*` on 127.0.0.1:18320).
///
/// Every message that came from the server or the transport is masked with `SecretRedactor`
/// and limited to `maximumMessageLength` characters before it is stored here.
enum GatewayAdminError: LocalizedError, Equatable, Sendable {
    /// 401: the management key was rejected. Never retried automatically.
    case unauthorized
    /// Any other non-success status, with the gateway's `code` when it sent one.
    case server(status: Int, code: String?, message: String)
    case decoding(String)
    case invalidResponse
    case transport(String)

    static let maximumMessageLength = 300

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return OasesLocalization.localized("网关拒绝了当前管理密钥。为避免触发网关的全局退避，App 已停止使用这把密钥自动请求；请检查密钥后点“重新验证”。")
        case .server(let status, let code, let message):
            if let code, let known = Self.message(forCode: code) {
                return known
            }
            return OasesLocalization.localizedFormat("网关返回 HTTP %lld：%@", status, message)
        case .decoding(let detail):
            return OasesLocalization.localizedFormat("网关返回的数据格式不兼容：%@", detail)
        case .invalidResponse:
            return OasesLocalization.localized("网关返回了无法解析的响应。")
        case .transport(let detail):
            return OasesLocalization.localizedFormat("无法连接网关管理接口：%@", detail)
        }
    }

    /// Readable messages for the gateway's machine codes (gateway/server.mjs).
    private static func message(forCode code: String) -> String? {
        switch code {
        case "internal_key":
            return OasesLocalization.localized("这把 Key 是网关内部使用的引擎 Key，由网关自己管理，不能修改或删除。")
        case "last_api_key":
            return OasesLocalization.localized("至少要保留一把 API Key（网关内部使用的引擎 Key 也算在内），这把 Key 不能删除。")
        case "management_unavailable":
            return OasesLocalization.localized("网关暂时连不上引擎的管理接口，本次操作没有生效；请确认引擎在运行后重试。")
        case "management_timeout":
            return OasesLocalization.localized("网关访问引擎的管理接口超时，本次操作没有生效；请稍后重试。")
        case "policy_unavailable":
            return OasesLocalization.localized("网关的 Key 策略文件暂时不可用，本次修改没有保存；请检查网关数据目录后重试。")
        case "engine_key_missing":
            return OasesLocalization.localized("网关缺少内部引擎 Key，无法测试模型；请检查部署是否完整。")
        default:
            return nil
        }
    }

    /// The error for a non-success answer. Both body shapes of the gateway are read:
    /// `{"error":"…","code":"…"}` and `{"error":{"message":"…","code":"…"}}`.
    static func from(status: Int, data: Data, secrets: [String]) -> GatewayAdminError {
        if status == 401 { return .unauthorized }
        var message = ""
        var code: String?
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let text = object["error"] as? String {
                message = text
                code = object["code"] as? String
            } else if let error = object["error"] as? [String: Any] {
                message = (error["message"] as? String) ?? ""
                code = (error["code"] as? String) ?? (object["code"] as? String)
            } else {
                message = (object["message"] as? String) ?? ""
                code = object["code"] as? String
            }
        } else {
            message = String(decoding: data, as: UTF8.self)
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = HTTPURLResponse.localizedString(forStatusCode: status)
        }
        return .server(
            status: status,
            code: code.map { sanitized($0, secrets: secrets) },
            message: sanitized(message, secrets: secrets)
        )
    }

    /// Masks secrets and key shapes, then limits the length.
    static func sanitized(_ text: String, secrets: [String]) -> String {
        let redacted = SecretRedactor.redact(text, secrets: secrets)
        guard redacted.count > maximumMessageLength else { return redacted }
        return String(redacted.prefix(maximumMessageLength - 1)) + "…"
    }
}
