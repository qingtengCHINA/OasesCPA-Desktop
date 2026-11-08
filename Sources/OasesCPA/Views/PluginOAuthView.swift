import SwiftUI

struct PluginOAuthView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var deploymentStore: DeploymentStore

    let plugin: RuntimePlugin
    let provider: String

    @State private var flowState: FlowState = .idle
    @State private var authorizationURL = ""
    @State private var oauthState = ""
    @State private var callbackURL = ""
    @State private var callbackMessage: String?
    @State private var errorMessage: String?
    @State private var activePollingState: String?
    @State private var isSubmittingCallback = false

    private enum FlowState {
        case idle
        case starting
        case waiting
        case success
        case failed

        var title: String {
            switch self {
            case .idle: "未开始"
            case .starting: "正在创建会话"
            case .waiting: "等待授权"
            case .success: "授权完成"
            case .failed: "授权失败"
            }
        }

        var tint: Color {
            switch self {
            case .idle: .oasesBlue
            case .starting, .waiting: .oasesOrange
            case .success: .oasesGreen
            case .failed: .oasesRed
            }
        }

        var systemImage: String {
            switch self {
            case .idle: "circle.dotted"
            case .starting: "arrow.triangle.2.circlepath"
            case .waiting: "hourglass"
            case .success: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard

                    if let errorMessage {
                        InfoBanner(
                            title: "插件 OAuth 失败",
                            message: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tint: .oasesRed
                        )
                    }

                    if !authorizationURL.isEmpty {
                        authorizationCard
                    }

                    if !oauthState.isEmpty {
                        callbackCard
                    }

                    InfoBanner(
                        title: "凭证由目标插件处理",
                        message: "App 仅创建 OAuth 会话、打开授权页、轮询状态和按需转交回调地址。授权令牌不会写入 App 偏好设置或日志；插件与当前目标 CLIProxyAPI 决定凭证的实际存储位置。",
                        systemImage: "checkmark.shield",
                        tint: .oasesBlue
                    )
                }
                .padding(24)
            }
            .navigationTitle("插件 OAuth")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 660)
        .task(id: activePollingState) {
            await pollAuthorization()
        }
        .onDisappear {
            if flowState == .starting || flowState == .waiting {
                cancelCurrentFlow()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(plugin.displayTitle)
                    .font(.title2.weight(.bold))
                Text("Provider：\(provider)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                title: flowState.title,
                tint: flowState.tint,
                systemImage: flowState.systemImage
            )
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "发起动态插件授权",
                subtitle: "直接调用当前目标的 /v0/management/\(provider)-auth-url",
                icon: "person.badge.key"
            )

            Text("该 Provider 由已注册插件声明。浏览器完成登录后，App 会查询当前目标服务的会话状态。若浏览器无法将回调送达目标，可粘贴完整回调地址。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(flowState == .starting ? "正在准备…" : "开始授权", systemImage: "arrow.up.right") {
                    startAuthorization()
                }
                .buttonStyle(.oasesPrimary)
                .disabled(flowState == .starting || deploymentStore.stage != .attached)

                if deploymentStore.stage != .attached {
                    Text("请先连接目标环境")
                        .font(.caption)
                        .foregroundStyle(Color.oasesOrange)
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var authorizationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "授权地址",
                    subtitle: "由当前目标上的插件生成",
                    icon: "link"
                )
                Spacer()
                Button("打开授权页", systemImage: "safari") {
                    openAuthorizationURL()
                }
                .buttonStyle(.oasesPrimary)
            }

            Text(authorizationURL)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                if flowState == .waiting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在轮询授权状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消本次授权", systemImage: "xmark") {
                    cancelCurrentFlow()
                }
                .buttonStyle(.bordered)
                .disabled(oauthState.isEmpty)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var callbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "手动提交回调",
                subtitle: "适用于 SSH / VPS 或浏览器无法自动回传的情况",
                icon: "arrow.down.doc"
            )

            TextEditor(text: $callbackURL)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 92, maxHeight: 150)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if callbackURL.isEmpty {
                        Text("粘贴包含 code 和 state 的完整回调 URL")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 12) {
                Button("提交回调", systemImage: "arrow.up.circle") {
                    submitCallback()
                }
                .buttonStyle(.oasesPrimary)
                .disabled(callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingCallback)

                if isSubmittingCallback {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在提交…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let callbackMessage {
                    Text(callbackMessage)
                        .font(.caption)
                        .foregroundStyle(Color.oasesGreen)
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private func startAuthorization() {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            errorMessage = "请先完成本机或 SSH/VPS 部署，并确认 CPA 管理密钥可用。"
            return
        }

        cancelCurrentFlow(sendCancel: true, resetUI: false)
        flowState = .starting
        errorMessage = nil
        callbackMessage = nil
        callbackURL = ""
        authorizationURL = ""
        oauthState = ""

        let baseURL = deploymentStore.engineBaseURL
        let managementKey = deploymentStore.managementKey
        Task { @MainActor in
            do {
                let response = try await ManagementAPIClient().pluginOAuthStart(
                    provider: provider,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                let urlString = response.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let state = response.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !urlString.isEmpty else {
                    throw PluginOAuthViewError.missingAuthorizationURL
                }
                guard !state.isEmpty else {
                    throw PluginOAuthViewError.missingState
                }
                authorizationURL = urlString
                oauthState = state
                flowState = .waiting
                activePollingState = state
                openAuthorizationURL()
            } catch {
                guard !Task.isCancelled else { return }
                flowState = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pollAuthorization() async {
        guard let pollingState = activePollingState, !pollingState.isEmpty else { return }
        let state = pollingState
        let baseURL = deploymentStore.engineBaseURL
        let managementKey = deploymentStore.managementKey

        while !Task.isCancelled {
            do {
                let response = try await ManagementAPIClient().oauthStatus(
                    state: state,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled, activePollingState == state else { return }
                switch response.status {
                case .ok:
                    flowState = .success
                    callbackMessage = "目标服务已确认插件授权完成。"
                    activePollingState = nil
                case .wait:
                    flowState = .waiting
                case .error, .unknown:
                    flowState = .failed
                    errorMessage = response.error ?? "目标服务未能完成插件 OAuth 授权。"
                    activePollingState = nil
                }
                if activePollingState == nil { return }
            } catch {
                guard !Task.isCancelled, activePollingState == state else { return }
                flowState = .failed
                errorMessage = error.localizedDescription
                activePollingState = nil
                return
            }

            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
        }
    }

    private func submitCallback() {
        guard deploymentStore.stage == .attached,
              !deploymentStore.managementKey.isEmpty,
              !oauthState.isEmpty else {
            errorMessage = "请先开始一个插件 OAuth 会话。"
            return
        }

        let input = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let baseURL = deploymentStore.engineBaseURL
        let managementKey = deploymentStore.managementKey
        isSubmittingCallback = true
        callbackMessage = nil
        errorMessage = nil

        Task { @MainActor in
            do {
                let response = try await ManagementAPIClient().pluginOAuthCallback(
                    provider: provider,
                    redirectURL: input,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                isSubmittingCallback = false
                if response.status == .ok {
                    callbackMessage = "回调已提交，继续等待目标服务完成授权。"
                    flowState = .waiting
                    if activePollingState == nil {
                        activePollingState = oauthState
                    }
                } else {
                    flowState = .failed
                    errorMessage = response.error ?? "目标服务拒绝了插件 OAuth 回调。"
                }
            } catch {
                isSubmittingCallback = false
                flowState = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openAuthorizationURL() {
        guard let url = URL(string: authorizationURL) else {
            errorMessage = "授权地址格式无效。"
            return
        }
        openURL(url)
    }

    private func cancelCurrentFlow(sendCancel: Bool = true, resetUI: Bool = true) {
        let state = activePollingState ?? oauthState
        activePollingState = nil

        if resetUI {
            flowState = .idle
            authorizationURL = ""
            oauthState = ""
            callbackURL = ""
            callbackMessage = nil
        }

        guard sendCancel,
              !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deploymentStore.stage == .attached,
              !deploymentStore.managementKey.isEmpty else { return }
        let baseURL = deploymentStore.engineBaseURL
        let managementKey = deploymentStore.managementKey
        Task {
            try? await ManagementAPIClient().cancelOAuth(
                state: state,
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
    }
}

private enum PluginOAuthViewError: LocalizedError {
    case missingAuthorizationURL
    case missingState

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationURL:
            "目标插件没有返回授权地址。"
        case .missingState:
            "目标插件没有返回有效的 OAuth state。"
        }
    }
}
