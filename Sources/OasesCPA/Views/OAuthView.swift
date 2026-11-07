import AppKit
import SwiftUI

struct OAuthView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var provider: RuntimeOAuthProvider = .codex
    @State private var flowState: FlowState = .idle
    @State private var authorizationURL = ""
    @State private var oauthState = ""
    @State private var callbackURL = ""
    @State private var callbackMessage: String?
    @State private var errorMessage: String?
    @State private var activePollingState: String?
    @State private var isSubmittingCallback = false
    @StateObject private var openRouterOAuth = OpenRouterOAuthLoopbackListener()
    @State private var isOpenRouterConfirmationPresented = false

    private enum FlowState {
        case idle
        case starting
        case waiting
        case success
        case failed

        var title: String {
            switch self {
            case .idle: OasesLocalization.localized("未开始")
            case .starting: OasesLocalization.localized("正在创建授权会话")
            case .waiting: OasesLocalization.localized("等待完成授权")
            case .success: OasesLocalization.localized("授权完成")
            case .failed: OasesLocalization.localized("授权失败")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "连接目标后开始 OAuth",
                        message: "授权请求会发送到当前目标的 CLIProxyAPI，并由目标服务把凭证写入自己的 auths 目录。",
                        systemImage: "lock.shield",
                        tint: .oasesOrange
                    )
                } else {
                    providerCard
                    openRouterCard

                    if let errorMessage {
                        InfoBanner(
                            title: "OAuth 操作失败",
                            message: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tint: .oasesRed
                        )
                    }

                    if !authorizationURL.isEmpty {
                        authorizationCard
                    }

                    if provider.supportsManualCallback && !oauthState.isEmpty {
                        callbackCard
                    }

                    securityCard
                }
            }
            .padding(28)
        }
        .task(id: activePollingState) {
            await pollAuthorization()
        }
        .task(id: openRouterOAuth.callbackToken) {
            await completeOpenRouterAuthorization()
        }
        .onChange(of: provider) { _, _ in
            cancelCurrentFlow()
        }
        .onChange(of: openRouterOAuth.authorizationURL) { _, authorizationURL in
            guard let authorizationURL else { return }
            if !NSWorkspace.shared.open(authorizationURL) {
                openRouterOAuth.fail(
                    message: "macOS 无法打开 OpenRouter 授权页，请重新开始授权。"
                )
            }
        }
        .onDisappear {
            cancelCurrentFlow()
            openRouterOAuth.cancel()
        }
        .confirmationDialog(
            "将 OpenRouter 授权写入当前目标？",
            isPresented: $isOpenRouterConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("继续并打开浏览器") {
                beginOpenRouterAuthorization()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "浏览器完成授权后，App 会把新 API Key 直接写入「\(deploymentStore.targetTitle)」的 \(RuntimeOpenRouterOAuth.providerName) Provider。若该专用 Provider 已存在，其密钥将被替换；API Key 不会存入 App 偏好设置或显示在界面中。"
            )
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageHeader(section: .oauth)
            Spacer()

            StatusPill(
                title: flowState.title,
                tint: flowState.tint,
                systemImage: flowState.systemImage
            )

            Button("打开 CPAMP", systemImage: "rectangle.on.rectangle") {
                store.selectSection(.panel)
            }
            .buttonStyle(.oasesPrimary)
            .disabled(deploymentStore.stage != .attached)
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(
                title: "选择授权渠道",
                subtitle: "App 直接调用当前目标的 CLIProxyAPI 管理接口",
                icon: "person.badge.key"
            )

            HStack(alignment: .center, spacing: 14) {
                Picker("Provider", selection: $provider) {
                    ForEach(RuntimeOAuthProvider.allCases) { item in
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                        .tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title)
                        .font(.headline)
                    Text(provider.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(flowState == .starting ? "正在准备…" : "开始授权", systemImage: "arrow.up.right") {
                    startAuthorization()
                }
                .buttonStyle(.oasesPrimary)
                .disabled(flowState == .starting || deploymentStore.stage != .attached)
            }

            if provider.supportsManualCallback {
                Text("浏览器完成登录后通常会自动进入完成状态；如果当前是 SSH/VPS 目标或浏览器无法回传，请把回调地址粘贴到下方。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("这是设备授权流程。打开授权页并完成确认后，App 会每 3 秒查询目标服务的授权状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    subtitle: "由当前目标服务生成，不经过 Oases CPA 服务器",
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

            HStack(spacing: 12) {
                StatusPill(
                    title: oauthState.isEmpty ? "无状态" : "状态已建立",
                    tint: oauthState.isEmpty ? .oasesRed : .oasesMint,
                    systemImage: oauthState.isEmpty ? "exclamationmark.circle" : "key"
                )
                if !oauthState.isEmpty {
                    Text("state: \(oauthState)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if flowState == .waiting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在轮询授权状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var openRouterCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                CardTitle(
                    title: "OpenRouter OAuth",
                    subtitle: "原生 PKCE + 当前 Mac 的 localhost 回调，可写入本机或 SSH/VPS 目标",
                    icon: "point.3.connected.trianglepath.dotted"
                )
                Spacer()
                StatusPill(
                    title: openRouterOAuth.phase.title,
                    tint: openRouterStatusTint,
                    systemImage: openRouterOAuth.phase.systemImage
                )
            }

            Text(
                "授权在此 Mac 的浏览器完成；回调只监听 127.0.0.1 的临时端口。授权过程不会把 API Key 写入 App 偏好设置，换取后的密钥会直接用于读取模型目录并写入当前 CLIProxyAPI。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let callbackURL = openRouterOAuth.callbackURL {
                LabeledContent("本机回调地址") {
                    Text(callbackURL.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let authorizationURL = openRouterOAuth.authorizationURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("授权地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(authorizationURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)

                    if openRouterOAuth.phase == .waiting {
                        Button("重新打开授权页", systemImage: "safari") {
                            if !NSWorkspace.shared.open(authorizationURL) {
                                openRouterOAuth.fail(
                                    message: "macOS 无法打开 OpenRouter 授权页，请复制授权地址到当前 Mac 的浏览器。"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let notice = openRouterOAuth.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(openRouterOAuth.phase == .completed ? Color.oasesGreen : Color.oasesOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failureMessage = openRouterOAuth.failureMessage {
                InfoBanner(
                    title: "OpenRouter 连接未完成",
                    message: failureMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            HStack(spacing: 12) {
                Button(
                    openRouterOAuth.phase == .preparing ? "正在准备…" : "连接 OpenRouter",
                    systemImage: "lock.open"
                ) {
                    isOpenRouterConfirmationPresented = true
                }
                .buttonStyle(.oasesPrimary)
                .disabled(openRouterIsBusy || runtimeDataStore.isSavingProviders)

                if openRouterCanCancel {
                    Button("取消本次授权", systemImage: "xmark") {
                        openRouterOAuth.cancel()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("查看 Provider", systemImage: "slider.horizontal.3") {
                    store.selectSection(.aiProviders)
                }
                .buttonStyle(.bordered)
            }

            Text("请在运行 Oases CPA 的这台 Mac 上完成浏览器授权。GitHub Copilot 仍需要用户配置 GitHub OAuth App 的 HTTP(S) 回调地址与 CPAMP server secret，因此暂保留 CPAMP 兼容流程。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .oasesCard()
    }

    private var callbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "手动提交回调",
                subtitle: "适用于 SSH/VPS 或浏览器没有自动回传的情况",
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

                Spacer()
                Button("取消本次授权", systemImage: "xmark") {
                    cancelCurrentFlow()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var securityCard: some View {
        InfoBanner(
            title: "凭证由目标 CLIProxyAPI 管理",
            message: "内置 OAuth 的凭证由目标 CLIProxyAPI 写入 auths 目录。OpenRouter 使用本机 loopback 回调与 PKCE，换得的 API Key 不会写入 App 偏好设置，并会直接写入当前目标的 OpenAI-compatible 配置；GitHub Copilot 仍使用 CPAMP 兼容流程。",
            systemImage: "checkmark.shield",
            tint: .oasesBlue
        )
    }

    private func startAuthorization() {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            errorMessage = "请先完成本机或 SSH/VPS 部署，并确认 CPA 管理密钥可用。"
            return
        }

        cancelCurrentFlow(sendCancel: false)
        flowState = .starting
        errorMessage = nil
        callbackMessage = nil
        callbackURL = ""

        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        Task { @MainActor in
            do {
                let response = try await ManagementAPIClient().oauthStart(
                    provider: provider,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                let urlString = response.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let state = response.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !urlString.isEmpty else {
                    throw OAuthViewError.missingAuthorizationURL
                }
                guard !state.isEmpty else {
                    throw OAuthViewError.missingState
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
        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey

        while !Task.isCancelled {
            do {
                let response = try await ManagementAPIClient().oauthStatus(
                    state: state,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                guard !Task.isCancelled, self.activePollingState == state else { return }
                switch response.status {
                case .ok:
                    flowState = .success
                    callbackMessage = "目标服务已确认凭证写入。"
                    activePollingState = nil
                case .wait:
                    flowState = .waiting
                case .error, .unknown:
                    flowState = .failed
                    errorMessage = response.error ?? "目标服务未能完成 OAuth 授权。"
                    activePollingState = nil
                }
                if activePollingState == nil { return }
            } catch {
                guard !Task.isCancelled, self.activePollingState == state else { return }
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
            errorMessage = "请先开始一个 OAuth 会话。"
            return
        }

        let input = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        isSubmittingCallback = true
        callbackMessage = nil
        errorMessage = nil

        Task { @MainActor in
            do {
                let response = try await ManagementAPIClient().oauthCallback(
                    provider: provider,
                    redirectURL: input,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
                isSubmittingCallback = false
                if response.status == .ok {
                    callbackMessage = "回调已提交，继续等待目标服务完成换 token。"
                    flowState = .waiting
                    if activePollingState == nil {
                        activePollingState = oauthState
                    }
                } else {
                    flowState = .failed
                    errorMessage = response.error ?? "目标服务拒绝了回调。"
                }
            } catch {
                isSubmittingCallback = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openAuthorizationURL() {
        guard let url = URL(string: authorizationURL) else {
            errorMessage = "授权地址不是有效的 URL。"
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "macOS 无法打开授权地址，请复制上方 URL 到浏览器。"
        }
    }

    private var openRouterIsBusy: Bool {
        switch openRouterOAuth.phase {
        case .preparing, .waiting, .readyToExchange, .exchanging, .saving:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    private var openRouterCanCancel: Bool {
        switch openRouterOAuth.phase {
        case .preparing, .waiting:
            true
        case .idle, .readyToExchange, .exchanging, .saving, .completed, .failed:
            false
        }
    }

    private var openRouterStatusTint: Color {
        switch openRouterOAuth.phase {
        case .idle:
            .oasesBlue
        case .preparing, .waiting, .readyToExchange, .exchanging, .saving:
            .oasesOrange
        case .completed:
            .oasesGreen
        case .failed:
            .oasesRed
        }
    }

    private func beginOpenRouterAuthorization() {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            openRouterOAuth.fail(message: "请先连接一个本机或 SSH/VPS 目标。")
            return
        }
        openRouterOAuth.begin()
    }

    private func completeOpenRouterAuthorization() async {
        guard let grant = openRouterOAuth.consumeAuthorizationGrant() else { return }

        do {
            let apiKey = try await RuntimeOpenRouterOAuth.exchangeCode(
                grant.code,
                codeVerifier: grant.codeVerifier
            )
            guard !Task.isCancelled else { return }

            let modelCatalog = await RuntimeOpenRouterOAuth.fetchModels(apiKey: apiKey)
            guard !Task.isCancelled else { return }

            openRouterOAuth.markSaving()
            let result = try await runtimeDataStore.saveOpenRouterOAuthProvider(
                apiKey: apiKey,
                modelCatalog: modelCatalog,
                using: deploymentStore
            )
            guard !Task.isCancelled else { return }

            let action = result.disposition == .created ? "已创建" : "已更新"
            let modelSummary: String
            if modelCatalog.didLoad {
                modelSummary = "已同步 \(result.modelCount) 个模型映射。"
            } else if result.preservedExistingModels {
                modelSummary = "OpenRouter 模型目录暂不可读，已保留原有模型映射。"
            } else {
                modelSummary = "OpenRouter 模型目录暂不可读；请在「AI Providers」补充模型映射。"
            }
            openRouterOAuth.complete(
                message: "\(action)当前目标的 OpenRouter Provider；\(modelSummary)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            openRouterOAuth.fail(message: error.localizedDescription)
        }
    }

    private func cancelCurrentFlow(sendCancel: Bool = true) {
        let state = oauthState.trimmingCharacters(in: .whitespacesAndNewlines)
        activePollingState = nil
        authorizationURL = ""
        oauthState = ""
        callbackURL = ""
        callbackMessage = nil
        isSubmittingCallback = false
        if flowState != .starting {
            flowState = .idle
        }

        guard sendCancel,
              !state.isEmpty,
              deploymentStore.stage == .attached,
              !deploymentStore.managementKey.isEmpty else { return }
        let baseURL = deploymentStore.cpaBaseURL
        let managementKey = deploymentStore.managementKey
        Task { @MainActor in
            try? await ManagementAPIClient().cancelOAuth(
                state: state,
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
    }
}

private enum OAuthViewError: LocalizedError {
    case missingAuthorizationURL
    case missingState

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationURL: "目标服务没有返回授权地址。"
        case .missingState: "目标服务没有返回 OAuth state，无法安全轮询或提交回调。"
        }
    }
}
