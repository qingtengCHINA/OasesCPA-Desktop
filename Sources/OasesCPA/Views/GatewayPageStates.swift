import SwiftUI

/// What a gateway page shows when the gateway admin API cannot be used (`phase == .unavailable`).
struct GatewayUnavailableView: View {
    let availability: GatewayAvailability
    /// The user's "verify again" after a rejected management key.
    let onRetryAuthentication: () -> Void

    var body: some View {
        switch availability {
        case .notAttached:
            OasesEmptyState(
                systemImage: "link.badge.plus",
                title: "连接目标后使用网关功能",
                message: "先在“连接与部署”接入本机或 SSH / VPS 目标；这里不会读取其他目标的数据。"
            )
        case .needsUpgrade:
            OasesEmptyState(
                systemImage: "arrow.up.circle",
                title: "需要升级到完整版",
                message: "当前目标是旧版（0.1.x）部署，没有 Oases 网关。请在“连接与部署”里升级后再使用这一页。"
            )
        case .dockerUnsupported:
            OasesEmptyState(
                systemImage: "shippingbox",
                title: "Oases 网关只支持原生部署",
                message: "Docker 部署没有 Oases 网关；需要这一页的功能时，请改用原生部署。"
            )
        case .credentialsRejected:
            OasesEmptyState(
                systemImage: "lock.trianglebadge.exclamationmark",
                title: "管理密钥被拒绝，请重新验证",
                message: "网关拒绝了当前管理密钥。为避免触发网关的全局退避，App 已停止自动请求；确认密钥无误后点“重新验证”。",
                actionTitle: "重新验证",
                action: onRetryAuthentication
            )
        case .ready:
            EmptyView()
        }
    }
}

/// The first load of a gateway page failed (nothing to show yet).
struct GatewayLoadFailedView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            InfoBanner(
                title: "读取网关数据失败",
                message: message,
                systemImage: "exclamationmark.triangle",
                tint: Oases.Color.danger
            )
            Button("重试", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.bordered)
        }
    }
}
