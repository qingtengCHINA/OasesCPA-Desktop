import Foundation

struct RuntimeAPICallRequest: Encodable, Sendable {
    let authIndex: String?
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    init(
        authIndex: String?,
        method: String,
        url: String,
        header: [String: String] = [:],
        data: String? = nil
    ) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

struct RuntimeAPICallResponse: Decodable, Sendable {
    let statusCode: Int
    let header: [String: [String]]
    let body: String

    private enum CodingKeys: String, CodingKey {
        case statusCode
        case header
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = Self.decodeInt(container, forKey: .statusCode) ?? 0
        header = try container.decodeIfPresent([String: [String]].self, forKey: .header) ?? [:]
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    private static func decodeInt<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct RuntimeQuotaCooldownsResponse: Decodable, Sendable {
    let items: [RuntimeQuotaCooldown]
}

struct RuntimeQuotaCooldown: Decodable, Identifiable, Sendable {
    let authFileName: String
    let authIndex: String?
    let accountSnapshot: String?
    let provider: String?
    let owner: String?
    let reasonCode: String?
    let windowKind: String?
    let recoverAtMs: Int64
    let disabledAtMs: Int64?
    let createdAtMs: Int64?
    let evidence: RuntimeProviderUsageMetadata?

    var id: String {
        [authIndex, authFileName, windowKind].compactMap { $0 }.joined(separator: "\u{0}")
    }

    var recoverAt: Date {
        Date(timeIntervalSince1970: Double(recoverAtMs) / 1_000)
    }
}

struct RuntimeProviderUsageMetadata: Decodable, Sendable {
    let provider: String?
    let kind: String?
    let state: String?
    let code: String?
    let model: String?
    let unit: String?
    let actual: Double?
    let limit: Double?
    let remaining: Double?
    let overage: Double?
    let windowKind: String?
    let observedAtMs: Int64?
    let recoverAtMs: Int64?
    let recoverAtEstimated: Bool?
    let source: String?

    /// Decoded inside `RuntimeQuotaCooldownsResponse` by the client's `.convertFromSnakeCase`
    /// decoder: the snake_case fields are read with either spelling (a snake_case `CodingKey`
    /// alone never matched there).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        provider = try? container.decodeIfPresent(String.self, snakeOrCamel: "provider")
        kind = try? container.decodeIfPresent(String.self, snakeOrCamel: "kind")
        state = try? container.decodeIfPresent(String.self, snakeOrCamel: "state")
        code = try? container.decodeIfPresent(String.self, snakeOrCamel: "code")
        model = try? container.decodeIfPresent(String.self, snakeOrCamel: "model")
        unit = try? container.decodeIfPresent(String.self, snakeOrCamel: "unit")
        actual = try? container.decodeIfPresent(Double.self, snakeOrCamel: "actual")
        limit = try? container.decodeIfPresent(Double.self, snakeOrCamel: "limit")
        remaining = try? container.decodeIfPresent(Double.self, snakeOrCamel: "remaining")
        overage = try? container.decodeIfPresent(Double.self, snakeOrCamel: "overage")
        windowKind = try? container.decodeIfPresent(String.self, snakeOrCamel: "window_kind")
        observedAtMs = try? container.decodeIfPresent(Int64.self, snakeOrCamel: "observed_at_ms")
        recoverAtMs = try? container.decodeIfPresent(Int64.self, snakeOrCamel: "recover_at_ms")
        recoverAtEstimated = try? container.decodeIfPresent(Bool.self, snakeOrCamel: "recover_at_estimated")
        source = try? container.decodeIfPresent(String.self, snakeOrCamel: "source")
    }
}

enum RuntimeQuotaEvidenceStatus: Equatable, Sendable {
    case success
    case failed
    case unsupported

    var title: String {
        switch self {
        case .success: OasesLocalization.localized("已读取")
        case .failed: OasesLocalization.localized("读取失败")
        case .unsupported: OasesLocalization.localized("未支持")
        }
    }
}

struct RuntimeQuotaWindow: Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let resetAt: Date?
    let resetAfterSeconds: Double?
    let limitWindowSeconds: Double?

    var normalizedUsedPercent: Double? {
        if let usedPercent {
            return max(0, min(100, usedPercent))
        }
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, min(100, used / limit * 100))
    }

    var normalizedRemainingPercent: Double? {
        if let remaining, let limit, limit > 0 {
            return max(0, min(100, remaining / limit * 100))
        }
        guard let usedPercent = normalizedUsedPercent else { return nil }
        return max(0, 100 - usedPercent)
    }
}

struct RuntimeQuotaEvidence: Identifiable, Sendable {
    let fileName: String
    let provider: String
    let authIndex: String?
    let observedAt: Date
    let statusCode: Int?
    let status: RuntimeQuotaEvidenceStatus
    let windows: [RuntimeQuotaWindow]
    let plan: String?
    let message: String?

    var id: String { fileName }
}

struct RuntimeQuotaRequest: Sendable {
    let provider: String
    let method: String
    let url: String
    let headers: [String: String]
    let data: String?
}

enum RuntimeQuotaRequestFactory {
    static func request(for file: RuntimeAuthFile) -> RuntimeQuotaRequest? {
        let provider = (file.provider ?? file.type ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch provider {
        case "codex", "openai-codex":
            var headers = [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "codex_cli_rs/0.76.0 (macOS; arm64) OasesCPA"
            ]
            if let accountID = file.codexAccountID {
                headers["Chatgpt-Account-Id"] = accountID
            }
            return RuntimeQuotaRequest(
                provider: "codex",
                method: "GET",
                url: "https://chatgpt.com/backend-api/wham/usage",
                headers: headers,
                data: nil
            )

        case "claude", "anthropic":
            return RuntimeQuotaRequest(
                provider: "claude",
                method: "GET",
                url: "https://api.anthropic.com/api/oauth/usage",
                headers: [
                    "Authorization": "Bearer $TOKEN$",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20"
                ],
                data: nil
            )

        case "kimi", "moonshot":
            return RuntimeQuotaRequest(
                provider: "kimi",
                method: "GET",
                url: "https://api.kimi.com/coding/v1/usages",
                headers: ["Authorization": "Bearer $TOKEN$"],
                data: nil
            )

        case "xai", "grok":
            return RuntimeQuotaRequest(
                provider: "xai",
                method: "GET",
                url: "https://cli-chat-proxy.grok.com/v1/billing",
                headers: [
                    "Authorization": "Bearer $TOKEN$",
                    "x-xai-token-auth": "xai-grok-cli",
                    "x-grok-client-version": "0.2.101",
                    "Accept": "application/json",
                    "User-Agent": "xai-grok-workspace/0.2.101"
                ],
                data: nil
            )

        default:
            return nil
        }
    }
}

enum RuntimeQuotaParser {
    static func parse(
        file: RuntimeAuthFile,
        request: RuntimeQuotaRequest,
        response: RuntimeAPICallResponse,
        observedAt: Date = Date()
    ) -> RuntimeQuotaEvidence {
        let provider = request.provider
        guard (200..<300).contains(response.statusCode) else {
            return RuntimeQuotaEvidence(
                fileName: file.name,
                provider: provider,
                authIndex: file.authIndex,
                observedAt: observedAt,
                statusCode: response.statusCode,
                status: .failed,
                windows: [],
                plan: nil,
                message: failureMessage(response)
            )
        }

        guard let data = response.body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RuntimeJSONValue.self, from: data),
              case .object(let object) = payload else {
            return RuntimeQuotaEvidence(
                fileName: file.name,
                provider: provider,
                authIndex: file.authIndex,
                observedAt: observedAt,
                statusCode: response.statusCode,
                status: .failed,
                windows: [],
                plan: nil,
                message: OasesLocalization.localized("Provider 返回的额度响应不是有效 JSON。")
            )
        }

        let parsed: (windows: [RuntimeQuotaWindow], plan: String?)
        switch provider {
        case "codex": parsed = parseCodex(object: object, now: observedAt)
        case "claude": parsed = parseClaude(object: object, now: observedAt)
        case "kimi": parsed = parseKimi(object: object, now: observedAt)
        case "xai": parsed = parseXAI(object: object, now: observedAt)
        default: parsed = ([], nil)
        }

        return RuntimeQuotaEvidence(
            fileName: file.name,
            provider: provider,
            authIndex: file.authIndex,
            observedAt: observedAt,
            statusCode: response.statusCode,
            status: parsed.windows.isEmpty ? .unsupported : .success,
            windows: parsed.windows,
            plan: parsed.plan,
            message: parsed.windows.isEmpty ? OasesLocalization.localized("已收到 Provider 响应，但当前版本未识别出额度窗口。") : nil
        )
    }

    private static func parseCodex(
        object: [String: RuntimeJSONValue],
        now: Date
    ) -> (windows: [RuntimeQuotaWindow], plan: String?) {
        var windows: [RuntimeQuotaWindow] = []
        let rateLimit = object.firstObject(forKeys: ["rate_limit", "rateLimit"])
        if let rateLimit {
            appendCodexWindow(
                to: &windows,
                id: "five-hour",
                label: OasesLocalization.localized("5 小时窗口"),
                object: rateLimit.firstObject(forKeys: ["primary_window", "primaryWindow"]),
                now: now
            )
            appendCodexWindow(
                to: &windows,
                id: "long-window",
                label: OasesLocalization.localized("长期窗口"),
                object: rateLimit.firstObject(forKeys: ["secondary_window", "secondaryWindow"]),
                now: now
            )
        }

        if let codeReview = object.firstObject(forKeys: ["code_review_rate_limit", "codeReviewRateLimit"]) {
            appendCodexWindow(
                to: &windows,
                id: "code-review-primary",
                label: OasesLocalization.localized("Code review · 主窗口"),
                object: codeReview.firstObject(forKeys: ["primary_window", "primaryWindow"]),
                now: now
            )
            appendCodexWindow(
                to: &windows,
                id: "code-review-long",
                label: OasesLocalization.localized("Code review · 长期窗口"),
                object: codeReview.firstObject(forKeys: ["secondary_window", "secondaryWindow"]),
                now: now
            )
        }

        if let additional = object.firstArray(forKeys: ["additional_rate_limits", "additionalRateLimits"]) {
            for (index, entry) in additional.enumerated() {
                guard let entry = entry.objectValue,
                      let nested = entry.firstObject(forKeys: ["rate_limit", "rateLimit"]) else { continue }
                let name = entry.firstString(forKeys: ["limit_name", "limitName", "metered_feature", "meteredFeature"])
                    ?? OasesLocalization.localized("附加窗口 (index + 1)")
                appendCodexWindow(
                    to: &windows,
                    id: "additional-\(index)",
                    label: name,
                    object: nested.firstObject(forKeys: ["primary_window", "primaryWindow"]),
                    now: now
                )
            }
        }

        return (windows, object.firstString(forKeys: ["plan_type", "planType"]))
    }

    private static func appendCodexWindow(
        to windows: inout [RuntimeQuotaWindow],
        id: String,
        label: String,
        object: [String: RuntimeJSONValue]?,
        now: Date
    ) {
        guard let object,
              let window = makeWindow(
                id: id,
                label: label,
                object: object,
                usedPercentKeys: ["used_percent", "usedPercent"],
                resetKeys: ["reset_at", "resetAt"],
                resetAfterKeys: ["reset_after_seconds", "resetAfterSeconds"],
                limitWindowKeys: ["limit_window_seconds", "limitWindowSeconds"],
                now: now
              ) else { return }
        windows.append(window)
    }

    private static func parseClaude(
        object: [String: RuntimeJSONValue],
        now: Date
    ) -> (windows: [RuntimeQuotaWindow], plan: String?) {
        let keys: [(String, String)] = [
            ("five_hour", OasesLocalization.localized("5 小时窗口")),
            ("seven_day", OasesLocalization.localized("7 天窗口")),
            ("seven_day_oauth_apps", OasesLocalization.localized("7 天 · OAuth 应用")),
            ("seven_day_opus", OasesLocalization.localized("7 天 · Opus")),
            ("seven_day_sonnet", OasesLocalization.localized("7 天 · Sonnet")),
            ("seven_day_cowork", OasesLocalization.localized("7 天 · Cowork")),
            ("iguana_necktie", "Iguana Necktie")
        ]
        let windows: [RuntimeQuotaWindow] = keys.compactMap { entry -> RuntimeQuotaWindow? in
            let (key, label) = entry
            guard let window = object[key]?.objectValue else { return nil }
            return makeWindow(
                id: key.replacingOccurrences(of: "_", with: "-"),
                label: label,
                object: window,
                usedPercentKeys: ["utilization", "used_percent", "usedPercent", "percent"],
                resetKeys: ["resets_at", "resetsAt", "reset_at", "resetAt"],
                resetAfterKeys: ["reset_in", "resetIn", "ttl"],
                limitWindowKeys: [],
                now: now
            )
        }
        return (windows, nil)
    }

    private static func parseKimi(
        object: [String: RuntimeJSONValue],
        now: Date
    ) -> (windows: [RuntimeQuotaWindow], plan: String?) {
        var windows: [RuntimeQuotaWindow] = []
        if let usage = object.firstObject(forKeys: ["usage"]) {
            appendKimiWindow(to: &windows, id: "summary", label: OasesLocalization.localized("总览"), object: usage, now: now)
        }
        if let limits = object.firstArray(forKeys: ["limits"]) {
            for (index, item) in limits.enumerated() {
                guard let item = item.objectValue else { continue }
                let detail = item.firstObject(forKeys: ["detail"]) ?? item
                let label = item.firstString(forKeys: ["name", "title", "scope"])
                    ?? detail.firstString(forKeys: ["name", "title"])
                    ?? OasesLocalization.localized("限制窗口 (index + 1)")
                appendKimiWindow(to: &windows, id: "limit-\(index)", label: label, object: detail, now: now)
            }
        }
        return (windows, nil)
    }

    private static func appendKimiWindow(
        to windows: inout [RuntimeQuotaWindow],
        id: String,
        label: String,
        object: [String: RuntimeJSONValue],
        now: Date
    ) {
        guard let window = makeWindow(
            id: id,
            label: label,
            object: object,
            usedPercentKeys: [],
            resetKeys: ["reset_at", "resetAt", "reset_time", "resetTime"],
            resetAfterKeys: ["reset_in", "resetIn", "ttl"],
            limitWindowKeys: [],
            usedKeys: ["used"],
            limitKeys: ["limit"],
            remainingKeys: ["remaining"],
            now: now
        ) else { return }
        windows.append(window)
    }

    private static func parseXAI(
        object: [String: RuntimeJSONValue],
        now: Date
    ) -> (windows: [RuntimeQuotaWindow], plan: String?) {
        let config = object.firstObject(forKeys: ["config"]) ?? object
        let period = config.firstObject(forKeys: ["current_period", "currentPeriod"])
        let label = period?.firstString(forKeys: ["type"]) ?? OasesLocalization.localized("当前计费周期")
        let window = makeWindow(
            id: "billing-period",
            label: label,
            object: config,
            usedPercentKeys: ["credit_usage_percent", "creditUsagePercent"],
            resetKeys: ["billing_period_end", "billingPeriodEnd"],
            resetAfterKeys: [],
            limitWindowKeys: [],
            usedKeys: [],
            limitKeys: [],
            remainingKeys: [],
            now: now
        )
        return (window.map { [$0] } ?? [], nil)
    }

    private static func makeWindow(
        id: String,
        label: String,
        object: [String: RuntimeJSONValue],
        usedPercentKeys: [String],
        resetKeys: [String],
        resetAfterKeys: [String],
        limitWindowKeys: [String],
        usedKeys: [String] = ["used"],
        limitKeys: [String] = ["limit"],
        remainingKeys: [String] = ["remaining"],
        now: Date
    ) -> RuntimeQuotaWindow? {
        let usedPercent = object.firstNumber(forKeys: usedPercentKeys)
        let used = object.firstNumber(forKeys: usedKeys)
        let limit = object.firstNumber(forKeys: limitKeys)
        let remaining = object.firstNumber(forKeys: remainingKeys)
        let resetAfter = object.firstNumber(forKeys: resetAfterKeys)
        let resetAt = object.firstDate(forKeys: resetKeys, now: now)
        let limitWindow = object.firstNumber(forKeys: limitWindowKeys)

        guard usedPercent != nil || used != nil || limit != nil || remaining != nil || resetAt != nil || resetAfter != nil else {
            return nil
        }
        return RuntimeQuotaWindow(
            id: id,
            label: label,
            usedPercent: usedPercent,
            used: used,
            limit: limit,
            remaining: remaining,
            resetAt: resetAt,
            resetAfterSeconds: resetAfter,
            limitWindowSeconds: limitWindow
        )
    }

    private static func failureMessage(_ response: RuntimeAPICallResponse) -> String {
        let body = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "Provider 返回 HTTP \(response.statusCode)。" }
        let preview = String(body.prefix(280))
        return "Provider 返回 HTTP \(response.statusCode)：\(preview)"
    }
}

private extension RuntimeJSONValue {
    var objectValue: [String: RuntimeJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [RuntimeJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    func firstObject(forKeys keys: [String]) -> [String: RuntimeJSONValue]? {
        for key in keys {
            if let value = self[key]?.objectValue { return value }
        }
        return nil
    }

    func firstArray(forKeys keys: [String]) -> [RuntimeJSONValue]? {
        for key in keys {
            if let value = self[key]?.arrayValue { return value }
        }
        return nil
    }

    func firstString(forKeys keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    func firstNumber(forKeys keys: [String]) -> Double? {
        for key in keys {
            if let value = self[key]?.numberValue { return value }
        }
        return nil
    }

    func firstDate(forKeys keys: [String], now: Date) -> Date? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case .number(let number):
                return RuntimeQuotaParser.date(from: number, now: now)
            case .string(let string):
                if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return RuntimeQuotaParser.date(from: number, now: now)
                }
                if let date = ISO8601DateFormatter().date(from: string) { return date }
            default:
                continue
            }
        }
        return nil
    }

    subscript(key: String) -> RuntimeJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}

private extension Dictionary where Key == String, Value == RuntimeJSONValue {
    func firstObject(forKeys keys: [String]) -> [String: RuntimeJSONValue]? {
        for key in keys {
            if let value = self[key]?.objectValue { return value }
        }
        return nil
    }

    func firstArray(forKeys keys: [String]) -> [RuntimeJSONValue]? {
        for key in keys {
            if let value = self[key]?.arrayValue { return value }
        }
        return nil
    }

    func firstString(forKeys keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    func firstNumber(forKeys keys: [String]) -> Double? {
        for key in keys {
            if let value = self[key]?.numberValue { return value }
        }
        return nil
    }

    func firstDate(forKeys keys: [String], now: Date) -> Date? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case .number(let number):
                return RuntimeQuotaParser.date(from: number, now: now)
            case .string(let string):
                if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return RuntimeQuotaParser.date(from: number, now: now)
                }
                if let date = ISO8601DateFormatter().date(from: string) { return date }
            default:
                continue
            }
        }
        return nil
    }
}

private extension RuntimeQuotaParser {
    static func date(from raw: Double, now: Date) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 10_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1_000)
        }
        if raw > now.timeIntervalSince1970 - 31_536_000 {
            return Date(timeIntervalSince1970: raw)
        }
        return now.addingTimeInterval(raw)
    }
}
