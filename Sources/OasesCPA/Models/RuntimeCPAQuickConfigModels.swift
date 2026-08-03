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

enum RuntimeCPAQuickConfigValueKind: Sendable {
    case bool
    case integer
    case string
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
    case maxRetryInterval = "max-retry-interval"
    case logsMaxTotalSizeMB = "logs-max-total-size-mb"
    case errorLogsMaxFiles = "error-logs-max-files"
    case proxyURL = "proxy-url"
    case routingStrategy = "routing/strategy"

    var endpointPath: String { rawValue }

    var responseKey: String {
        switch self {
        case .routingStrategy: "strategy"
        default: rawValue.split(separator: "/").last.map(String.init) ?? rawValue
        }
    }

    var valueKind: RuntimeCPAQuickConfigValueKind {
        switch self {
        case .requestRetry, .maxRetryInterval, .logsMaxTotalSizeMB, .errorLogsMaxFiles:
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
        case .maxRetryInterval: "最大重试间隔"
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
        case .maxRetryInterval: "自动重试之间允许等待的最长秒数。"
        case .logsMaxTotalSizeMB: "所有日志允许占用的最大空间（MB）。"
        case .errorLogsMaxFiles: "错误日志最多保留的文件数量。"
        case .proxyURL: "访问上游服务时使用的 HTTP/SOCKS 代理地址。"
        case .routingStrategy: "多个可用账号之间的选择方式。"
        }
        return OasesLocalization.localized(key)
    }

    var isRisky: Bool {
        switch self {
        case .debug, .requestLog, .websocketAuth, .forceModelPrefix, .proxyURL:
            true
        default:
            false
        }
    }

    var group: RuntimeCPAQuickConfigGroup {
        switch self {
        case .routingStrategy:
            .routing
        case .quotaSwitchProject, .quotaSwitchPreviewModel, .requestRetry, .maxRetryInterval:
            .reliabilityAndQuota
        case .loggingToFile, .requestLog, .usageStatisticsEnabled, .logsMaxTotalSizeMB, .errorLogsMaxFiles, .debug:
            .loggingAndDiagnostics
        case .websocketAuth, .forceModelPrefix, .proxyURL:
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
    var maxRetryInterval = 30
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
            case .maxRetryInterval: .integer(maxRetryInterval)
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
            case (.maxRetryInterval, .integer(let value)): maxRetryInterval = max(0, value)
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
