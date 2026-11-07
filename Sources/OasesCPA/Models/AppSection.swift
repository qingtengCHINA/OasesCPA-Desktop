import SwiftUI

/// Sidebar groups, matching the web panel and the iOS companion:
/// 概览 / 账号 / 网关 / 配置 / 运维.
enum SectionGroup: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case gateway
    case configuration
    case operations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: OasesLocalization.localized("概览")
        case .accounts: OasesLocalization.localized("账号")
        case .gateway: OasesLocalization.localized("网关")
        case .configuration: OasesLocalization.localized("配置")
        case .operations: OasesLocalization.localized("运维")
        }
    }

    /// Sidebar order inside the group.
    var sections: [AppSection] {
        switch self {
        case .overview: [.dashboard, .usageAnalytics, .monitoring]
        case .accounts: [.authFiles, .oauth, .quota, .accountActions, .codexInspection]
        case .gateway: [.accessKeys, .aiProviders]
        case .configuration: [.config, .modelPrices, .plugins]
        case .operations: [.environments, .panel, .logs, .system]
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case environments
    case panel
    case dashboard
    case usageAnalytics
    case monitoring
    case accountActions
    case modelPrices
    case config
    case accessKeys
    case aiProviders
    case plugins
    case authFiles
    case oauth
    case quota
    case codexInspection
    case logs
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .environments: OasesLocalization.localized("连接与部署")
        case .panel: OasesLocalization.localized("CPAMP 面板")
        case .dashboard: OasesLocalization.localized("仪表盘")
        case .usageAnalytics: OasesLocalization.localized("用量分析")
        case .monitoring: OasesLocalization.localized("请求监控")
        case .accountActions: OasesLocalization.localized("账号待办")
        case .modelPrices: OasesLocalization.localized("成本与价格")
        case .config: OasesLocalization.localized("配置面板")
        case .accessKeys: OasesLocalization.localized("调用 API Key")
        case .aiProviders: OasesLocalization.localized("AI 提供商")
        case .plugins: OasesLocalization.localized("插件管理")
        case .authFiles: OasesLocalization.localized("认证文件")
        case .oauth: OasesLocalization.localized("OAuth 登录")
        case .quota: OasesLocalization.localized("配额管理")
        case .codexInspection: OasesLocalization.localized("凭证健康巡检")
        case .logs: OasesLocalization.localized("日志查看")
        case .system: OasesLocalization.localized("系统信息")
        }
    }

    var subtitle: String {
        switch self {
        case .environments: OasesLocalization.localized("本机或 SSH / VPS 部署 CLIProxyAPI")
        case .panel: OasesLocalization.localized("在 App 内管理你的 CPA 中转站")
        case .dashboard: OasesLocalization.localized("CPA 网关与资源概览")
        case .usageAnalytics: OasesLocalization.localized("Token、成本与调用趋势")
        case .monitoring: OasesLocalization.localized("请求链路与失败诊断")
        case .accountActions: OasesLocalization.localized("认证异常的人工处理队列")
        case .modelPrices: OasesLocalization.localized("成本估算与模型计价")
        case .config: OasesLocalization.localized("网关配置与运行策略")
        case .accessKeys: OasesLocalization.localized("调用地址、访问密钥与模型目录")
        case .aiProviders: OasesLocalization.localized("添加服务、读取模型并检查连接")
        case .plugins: OasesLocalization.localized("扩展能力与插件资源")
        case .authFiles: OasesLocalization.localized("账号、凭证与认证池")
        case .oauth: OasesLocalization.localized("第三方 OAuth 授权")
        case .quota: OasesLocalization.localized("配额窗口与冷却状态")
        case .codexInspection: OasesLocalization.localized("账号健康与自动化建议")
        case .logs: OasesLocalization.localized("运行日志与证据")
        case .system: OasesLocalization.localized("连接、版本与本机状态")
        }
    }

    var systemImage: String {
        switch self {
        case .environments: "arrow.triangle.branch"
        case .panel: "rectangle.on.rectangle"
        case .dashboard: "square.grid.2x2"
        case .usageAnalytics: "chart.bar.xaxis"
        case .monitoring: "waveform.path.ecg"
        case .accountActions: "person.crop.circle.badge.exclamationmark"
        case .modelPrices: "dollarsign.arrow.circlepath"
        case .config: "slider.horizontal.3"
        case .accessKeys: "key.horizontal"
        case .aiProviders: "point.3.connected.trianglepath.dotted"
        case .plugins: "puzzlepiece.extension"
        case .authFiles: "doc.badge.gearshape"
        case .oauth: "person.badge.key"
        case .quota: "gauge.with.dots.needle.67percent"
        case .codexInspection: "checkmark.shield"
        case .logs: "text.alignleft"
        case .system: "gearshape.2"
        }
    }

    var group: SectionGroup {
        SectionGroup.allCases.first { $0.sections.contains(self) } ?? .operations
    }

}
