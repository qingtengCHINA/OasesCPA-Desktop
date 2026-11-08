import SwiftUI

/// What a gateway page shows when the gateway admin API cannot be used (`phase == .unavailable`):
/// one sentence that says how to get out of the state and at most one button.
struct GatewayUnavailableView: View {
    @EnvironmentObject private var appStore: AppStore
    let availability: GatewayAvailability
    /// The user's "verify again" after a rejected management key.
    let onRetryAuthentication: () -> Void

    var body: some View {
        switch availability {
        case .notAttached:
            GatewayStateLine(
                systemImage: "link",
                message: "先在“连接与部署”接入本机或 SSH / VPS 目标，这一页才有数据。",
                actionTitle: "打开连接与部署",
                action: { appStore.selectSection(.environments) }
            )
        case .needsUpgrade:
            // The upgrade itself (its one button, the backup promise, progress) lives on
            // 连接与部署; this button only takes the user there.
            GatewayStateLine(
                systemImage: "arrow.up.circle",
                message: "这是旧版 0.1.x 部署，网关功能需要升级。",
                actionTitle: "前往升级",
                action: { appStore.selectSection(.environments) }
            )
        case .dockerUnsupported:
            GatewayStateLine(
                systemImage: "shippingbox",
                message: "Docker 部署没有 Oases 网关；需要这一页的功能时，请改用原生部署。"
            )
        case .credentialsRejected:
            GatewayStateLine(
                systemImage: "lock",
                message: "网关拒绝了当前管理密钥，App 已停止自动请求。确认密钥无误后重新验证。",
                actionTitle: "重新验证",
                action: onRetryAuthentication
            )
        case .ready:
            EmptyView()
        }
    }
}

/// One inline sentence with a leading symbol and an optional trailing button.
struct GatewayStateLine: View {
    var systemImage: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Oases.Color.textSecondary)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(message))
                .foregroundStyle(Oases.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action)
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page's first load: a small spinner and what is being read.
struct GatewayLoadingView: View {
    var title: String

    var body: some View {
        HStack(spacing: Oases.Space.sm) {
            ProgressView().controlSize(.small)
            Text(LocalizedStringKey(title))
                .foregroundStyle(Oases.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A failed refresh or action while the data stays on screen: one line, symbol and text.
struct InlineProblem: View {
    var message: String

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(Oases.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Oases.Color.warning)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The first load of a gateway page failed (nothing to show yet).
struct GatewayLoadFailedView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            Text("读取网关数据失败")
                .font(.headline)
            InlineProblem(message: message)
            Button("重试", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
