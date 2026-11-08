import Foundation

enum RuntimeCPAQuickConfigValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case string(String)

    var jsonObject: Any {
        switch self {
        case .bool(let value): value
        case .integer(let value): value
        case .string(let value): value
        }
    }

    static func decode(from data: Data, for field: RuntimeCPAQuickConfigField) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object[field.responseKey] else {
            throw ManagementAPIError.invalidResponse
        }

        if field == .oauthRequestScopedErrors {
            // `{"oauth-request-scoped-errors": null | {"<channel>": [rule, …]}}` (v8.0.51): the
            // number of rules over every channel.
            if rawValue is NSNull { return .integer(0) }
            guard let channels = rawValue as? [String: Any] else { throw ManagementAPIError.invalidResponse }
            var count = 0
            for rules in channels.values {
                if rules is NSNull { continue }
                guard let list = rules as? [Any] else { throw ManagementAPIError.invalidResponse }
                count += list.count
            }
            return .integer(count)
        }

        switch field.valueKind {
        case .bool:
            guard let value = rawValue as? Bool else { throw ManagementAPIError.invalidResponse }
            return .bool(value)
        case .integer:
            if let value = rawValue as? Int {
                return .integer(value)
            }
            if let value = rawValue as? NSNumber {
                return .integer(value.intValue)
            }
            throw ManagementAPIError.invalidResponse
        case .string:
            guard let value = rawValue as? String else { throw ManagementAPIError.invalidResponse }
            return .string(value)
        }
    }
}

extension RuntimeCPAQuickConfigValue {
    /// The YAML scalar the value is written as in `config.yaml`.
    var yamlScalar: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .string(let value): "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }

    /// The value of a YAML scalar read from `config.yaml` (nil: the key is absent or null, the
    /// engine's default applies). Booleans are YAML 1.2's `true`/`false`, which the engine reads.
    static func fromYAMLScalar(_ scalar: String?, kind: RuntimeCPAQuickConfigValueKind) throws -> Self? {
        guard let scalar else { return nil }
        switch kind {
        case .bool:
            switch scalar.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw ManagementAPIError.invalidResponse
            }
        case .integer:
            guard let value = Int(scalar) else { throw ManagementAPIError.invalidResponse }
            return .integer(value)
        case .string:
            return .string(scalar)
        }
    }
}

enum RuntimeCPAQuickConfigValueKind: Sendable {
    case bool
    case integer
    case string
}

/// How a setting is read and written. Most have a management endpoint
/// (`/v0/management/<key>`, `{"value": …}`); a few exist only in `config.yaml` (CLIProxyAPI
/// v8.0.51 answers 404 for `disable-cooling` and `response-compression`, see
/// docs/acceptance/engine-v8.0.51-probe.md): those are read from and written to the file at
/// `path` (`CPAConfigYAMLPatcher`).
enum RuntimeCPAQuickConfigTransport: Equatable, Sendable {
    case endpoint
    case yaml(path: [String])
}

enum RuntimeCPAQuickConfigField: String, CaseIterable, Codable, Hashable, Sendable {
    case debug
    case usageStatisticsEnabled = "usage-statistics-enabled"
    case loggingToFile = "logging-to-file"
    case requestLog = "request-log"
    case websocketAuth = "ws-auth"
    case forceModelPrefix = "force-model-prefix"
    case quotaSwitchProject = "quota-exceeded/switch-project"
    case quotaSwitchPreviewModel = "quota-exceeded/switch-preview-model"
    case requestRetry = "request-retry"
    case maxRetryCredentials = "max-retry-credentials"
    case maxRetryInterval = "max-retry-interval"
    case disableCooling = "disable-cooling"
    /// Read-only: the number of rules (the engine stores a map of channels to rule lists, not a
    /// switch; a `{"value": …}` write would replace every rule).
    case oauthRequestScopedErrors = "oauth-request-scoped-errors"
    case logsMaxTotalSizeMB = "logs-max-total-size-mb"
    case errorLogsMaxFiles = "error-logs-max-files"
    case proxyURL = "proxy-url"
    case responseCompression = "response-compression/enabled"
    case routingStrategy = "routing/strategy"

    var endpointPath: String { rawValue }

    var transport: RuntimeCPAQuickConfigTransport {
        switch self {
        case .disableCooling: .yaml(path: ["disable-cooling"])
        case .responseCompression: .yaml(path: ["response-compression", "enabled"])
        default: .endpoint
        }
    }

    /// Shown, never written by the app.
    var isReadOnly: Bool { self == .oauthRequestScopedErrors }

    var responseKey: String {
        switch self {
        case .routingStrategy: "strategy"
        default: rawValue.split(separator: "/").last.map(String.init) ?? rawValue
        }
    }

    var valueKind: RuntimeCPAQuickConfigValueKind {
        switch self {
        case .requestRetry, .maxRetryCredentials, .maxRetryInterval, .logsMaxTotalSizeMB, .errorLogsMaxFiles, .oauthRequestScopedErrors:
            .integer
        case .proxyURL, .routingStrategy:
            .string
        default:
            .bool
        }
    }

    var title: String {
        let key = switch self {
        case .debug: "调试模式"
        case .usageStatisticsEnabled: "用量统计"
        case .loggingToFile: "写入日志文件"
        case .requestLog: "记录请求日志"
        case .websocketAuth: "WebSocket 鉴权"
        case .forceModelPrefix: "强制模型前缀"
        case .quotaSwitchProject: "超额后切换项目"
        case .quotaSwitchPreviewModel: "超额后切换预览模型"
        case .requestRetry: "请求重试次数"
        case .maxRetryCredentials: "每轮最多尝试的凭据数"
        case .maxRetryInterval: "最大重试间隔"
        case .disableCooling: "关闭冷却"
        case .oauthRequestScopedErrors: "OAuth 请求错误规则"
        case .responseCompression: "压缩响应"
        case .logsMaxTotalSizeMB: "日志总大小上限"
        case .errorLogsMaxFiles: "错误日志文件数"
        case .proxyURL: "网络代理地址"
        case .routingStrategy: "路由策略"
        }
        return OasesLocalization.localized(key)
    }

    var explanation: String {
        let key = switch self {
        case .debug: "遇到问题时临时打开，正常使用无需开启。"
        case .usageStatisticsEnabled: "用于仪表盘、用量分析和成本统计。"
        case .loggingToFile: "把运行日志保存到本地，方便排查问题。"
        case .requestLog: "记录每次请求的详细信息，可能增加日志量。"
        case .websocketAuth: "保护 WebSocket 管理连接，远程访问时建议开启。"
        case .forceModelPrefix: "统一给模型名加上 Provider 前缀，兼容特殊客户端。"
        case .quotaSwitchProject: "一个账号达到额度后，自动尝试下一个项目。"
        case .quotaSwitchPreviewModel: "额度受限时允许切换到预览模型。"
        case .requestRetry: "网络短暂失败时自动重试的次数。"
        case .maxRetryCredentials: "每一轮重试最多换几个不同的凭据；0 表示尝试全部可用凭据。"
        case .maxRetryInterval: "自动重试之间允许等待的最长秒数。"
        case .disableCooling: "失败后不让账号或模型进入冷却等待；单个供应商或凭据自己的设置优先。写入配置文件。"
        case .oauthRequestScopedErrors: "按通道把上游错误归类的规则（引擎中是规则表，不是开关）。这里只显示条数，请在配置文件编辑器中修改。"
        case .responseCompression: "客户端支持 gzip 或 zstd 时压缩返回内容（含流式）；引擎默认开启。写入配置文件。"
        case .logsMaxTotalSizeMB: "所有日志允许占用的最大空间（MB）。"
        case .errorLogsMaxFiles: "错误日志最多保留的文件数量。"
        case .proxyURL: "访问上游服务时使用的 HTTP/SOCKS 代理地址。"
        case .routingStrategy: "多个可用账号之间的选择方式。"
        }
        return OasesLocalization.localized(key)
    }

    var isRisky: Bool {
        switch self {
        case .debug, .requestLog, .websocketAuth, .forceModelPrefix, .proxyURL, .responseCompression:
            true
        default:
            false
        }
    }

    var group: RuntimeCPAQuickConfigGroup {
        switch self {
        case .routingStrategy:
            .routing
        case .quotaSwitchProject, .quotaSwitchPreviewModel, .requestRetry, .maxRetryCredentials, .maxRetryInterval,
             .disableCooling, .oauthRequestScopedErrors:
            .reliabilityAndQuota
        case .loggingToFile, .requestLog, .usageStatisticsEnabled, .logsMaxTotalSizeMB, .errorLogsMaxFiles, .debug:
            .loggingAndDiagnostics
        case .websocketAuth, .forceModelPrefix, .proxyURL, .responseCompression:
            .securityAndAdvanced
        }
    }
}

enum RuntimeCPAQuickConfigGroup: String, CaseIterable, Sendable {
    case routing
    case reliabilityAndQuota
    case loggingAndDiagnostics
    case securityAndAdvanced

    var title: String {
        let key = switch self {
        case .routing: "路由方式"
        case .reliabilityAndQuota: "稳定性与额度"
        case .loggingAndDiagnostics: "日志与诊断"
        case .securityAndAdvanced: "安全与高级设置"
        }
        return OasesLocalization.localized(key)
    }

    var explanation: String {
        let key = switch self {
        case .routing: "决定请求如何在多个可用账号之间流转。"
        case .reliabilityAndQuota: "让短暂失败自动恢复，并在额度受限时继续工作。"
        case .loggingAndDiagnostics: "控制统计和日志，排查问题时最有用。"
        case .securityAndAdvanced: "这些选项会影响连接方式和兼容性，请确认后再修改。"
        }
        return OasesLocalization.localized(key)
    }
}

struct RuntimeCPAQuickConfiguration: Equatable, Sendable {
    var debug = false
    var usageStatisticsEnabled = true
    var loggingToFile = true
    var requestLog = false
    var websocketAuth = false
    var forceModelPrefix = false
    var quotaSwitchProject = true
    var quotaSwitchPreviewModel = false
    var requestRetry = 3
    /// 0: every available credential (the engine's default).
    var maxRetryCredentials = 0
    var maxRetryInterval = 30
    var disableCooling = false
    /// Rules of `oauth-request-scoped-errors` over every channel (read-only).
    var oauthRequestScopedErrorRules = 0
    /// The engine's default when `response-compression.enabled` is absent.
    var responseCompression = true
    var logsMaxTotalSizeMB = 100
    var errorLogsMaxFiles = 10
    var proxyURL = ""
    var routingStrategy = "round-robin"

    static let `default` = RuntimeCPAQuickConfiguration()

    subscript(field: RuntimeCPAQuickConfigField) -> RuntimeCPAQuickConfigValue {
        get {
            switch field {
            case .debug: .bool(debug)
            case .usageStatisticsEnabled: .bool(usageStatisticsEnabled)
            case .loggingToFile: .bool(loggingToFile)
            case .requestLog: .bool(requestLog)
            case .websocketAuth: .bool(websocketAuth)
            case .forceModelPrefix: .bool(forceModelPrefix)
            case .quotaSwitchProject: .bool(quotaSwitchProject)
            case .quotaSwitchPreviewModel: .bool(quotaSwitchPreviewModel)
            case .requestRetry: .integer(requestRetry)
            case .maxRetryCredentials: .integer(maxRetryCredentials)
            case .maxRetryInterval: .integer(maxRetryInterval)
            case .disableCooling: .bool(disableCooling)
            case .oauthRequestScopedErrors: .integer(oauthRequestScopedErrorRules)
            case .responseCompression: .bool(responseCompression)
            case .logsMaxTotalSizeMB: .integer(logsMaxTotalSizeMB)
            case .errorLogsMaxFiles: .integer(errorLogsMaxFiles)
            case .proxyURL: .string(proxyURL)
            case .routingStrategy: .string(routingStrategy)
            }
        }
        set {
            switch (field, newValue) {
            case (.debug, .bool(let value)): debug = value
            case (.usageStatisticsEnabled, .bool(let value)): usageStatisticsEnabled = value
            case (.loggingToFile, .bool(let value)): loggingToFile = value
            case (.requestLog, .bool(let value)): requestLog = value
            case (.websocketAuth, .bool(let value)): websocketAuth = value
            case (.forceModelPrefix, .bool(let value)): forceModelPrefix = value
            case (.quotaSwitchProject, .bool(let value)): quotaSwitchProject = value
            case (.quotaSwitchPreviewModel, .bool(let value)): quotaSwitchPreviewModel = value
            case (.requestRetry, .integer(let value)): requestRetry = max(0, value)
            case (.maxRetryCredentials, .integer(let value)): maxRetryCredentials = max(0, value)
            case (.maxRetryInterval, .integer(let value)): maxRetryInterval = max(0, value)
            case (.disableCooling, .bool(let value)): disableCooling = value
            case (.oauthRequestScopedErrors, .integer(let value)): oauthRequestScopedErrorRules = max(0, value)
            case (.responseCompression, .bool(let value)): responseCompression = value
            case (.logsMaxTotalSizeMB, .integer(let value)): logsMaxTotalSizeMB = max(0, value)
            case (.errorLogsMaxFiles, .integer(let value)): errorLogsMaxFiles = max(0, value)
            case (.proxyURL, .string(let value)): proxyURL = value
            case (.routingStrategy, .string(let value)): routingStrategy = value
            default: break
            }
        }
    }
}

struct RuntimeCPAQuickConfigLoadResult: Equatable, Sendable {
    let configuration: RuntimeCPAQuickConfiguration
    let errors: [RuntimeCPAQuickConfigField: String]
}
