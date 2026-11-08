import SwiftUI

/// AI providers (OpenAI-compatible upstreams of the engine): a table with an inspector for the
/// selected provider; with none yet, the first provider is added inline (URL, key, test, add).
/// Editing happens in the provider editor window. The advanced tools (direct credentials,
/// channel health, connectivity check, config file) sit in a collapsed group below the table.
struct ProvidersView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.openWindow) private var openWindow
    @State private var deletingProvider: RuntimeOpenAICompatibility?
    @State private var selection: RuntimeOpenAICompatibility.ID?
    @State private var advancedToolsExpanded = false

    private var providers: [RuntimeOpenAICompatibility] { runtimeDataStore.openAICompatibility }
    private var isAttached: Bool { deploymentStore.stage == .attached }

    var body: some View {
        DetailPaneSplit(
            showsPane: selectedProvider != nil,
            paneTitle: "提供商详情",
            onClose: { selection = nil }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Oases.Space.section) {
                    content
                    if isAttached {
                        advancedTools
                    }
                }
                .padding(Oases.Space.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } pane: {
            if let provider = selectedProvider {
                ProviderInspector(
                    provider: provider,
                    onEdit: { presentProviderEditor(.editOpenAICompatibility(providerID: provider.id)) },
                    onDelete: { deletingProvider = provider }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { presentProviderEditor(.createOpenAICompatibility) } label: {
                    Label("添加提供商", systemImage: "plus")
                }
                .disabled(!isAttached || runtimeDataStore.isSavingProviders)
                .help(isAttached ? OasesLocalization.localized("添加提供商") : OasesLocalization.localized("请先连接一个目标环境。"))
            }
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshProviders(using: deploymentStore)
            if isAttached, !runtimeDataStore.hasLoadedDirectProviderCredentials {
                runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
            }
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("删除 %@？", deletingProvider?.name ?? ""),
            isPresented: Binding(get: { deletingProvider != nil }, set: { if !$0 { deletingProvider = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let provider = deletingProvider {
                    Task {
                        // A failure is shown by RuntimeDataStore (providerErrorMessage).
                        try? await runtimeDataStore.deleteOpenAICompatibility(provider, using: deploymentStore)
                    }
                    if selection == provider.id { selection = nil }
                }
                deletingProvider = nil
            }
            Button("取消", role: .cancel) { deletingProvider = nil }
        } message: {
            Text("这会从当前目标 CLIProxyAPI 的兼容 Provider 列表中删除该条目。")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !isAttached {
            GatewayStateLine(
                systemImage: "link",
                message: "先在“连接与部署”接入本机或 SSH / VPS 目标，这一页才有数据。",
                actionTitle: "打开连接与部署",
                action: { store.selectSection(.environments) }
            )
        } else if providers.isEmpty, runtimeDataStore.isLoadingProviders {
            GatewayLoadingView(title: "正在读取 AI 提供商…")
                .frame(height: 160)
        } else if providers.isEmpty, let error = runtimeDataStore.providerErrorMessage {
            GatewayLoadFailedView(message: error) { runtimeDataStore.refreshProviders(using: deploymentStore) }
        } else if providers.isEmpty {
            FirstProviderForm()
        } else {
            VStack(alignment: .leading, spacing: Oases.Space.sm) {
                if let error = runtimeDataStore.providerErrorMessage {
                    InlineProblem(message: error)
                }
                ProvidersTable(
                    providers: providers,
                    selection: $selection,
                    onEdit: { presentProviderEditor(.editOpenAICompatibility(providerID: $0.id)) },
                    onDelete: { deletingProvider = $0 }
                )
                // A table in a scroll view needs a height: every row, at most about 12.
                .frame(height: min(CGFloat(providers.count), 12) * 26 + 30)
                Text("选中一行查看详情；双击编辑。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    private var selectedProvider: RuntimeOpenAICompatibility? {
        guard let selection else { return nil }
        return providers.first { $0.id == selection }
    }

    // MARK: - Advanced tools

    private var advancedTools: some View {
        DisclosureGroup(isExpanded: $advancedToolsExpanded) {
            VStack(alignment: .leading, spacing: Oases.Space.section) {
                DirectProviderCredentialsCard()

                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: Oases.Space.sm) {
                        OasesSectionHeader(title: "运行概况")
                        ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                            HStack(spacing: Oases.Space.m) {
                                StatusDot(tone: tone(for: channel.tone))
                                Text(channelTitle(channel))
                                    .lineLimit(1)
                                Spacer()
                                Text(OasesLocalization.localizedFormat("调用 %@ · 失败 %@ · Token %@", channel.calls.formatted(), channel.failures.formatted(), compactToken(Double(channel.tokens))))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(Oases.Color.textSecondary)
                                Text(statusTitle(channel.tone))
                                    .frame(minWidth: 40, alignment: .trailing)
                            }
                            .padding(.vertical, Oases.Space.xs)
                            .accessibilityElement(children: .combine)
                            if index < channels.count - 1 { Divider() }
                        }
                    }
                }

                ProviderConnectivityCard()

                HStack(alignment: .firstTextBaseline) {
                    Text("在“配置面板”的“完整 YAML”中直接编辑 config.yaml；运行日志和请求错误文件在“日志查看”。")
                        .font(.callout)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("编辑配置文件") { store.selectSection(.config) }
                }
            }
            .padding(.top, Oases.Space.m)
        } label: {
            Text("高级工具")
                .font(.headline)
        }
    }

    private func presentProviderEditor(_ route: ProviderEditorRoute) {
        store.openProviderEditor(route)
        openWindow(id: ProviderEditorWindowScene.id)
    }

    private var channels: [RuntimeChannelHealth] {
        runtimeDataStore.dashboard?.channelHealth ?? []
    }

    private func channelTitle(_ channel: RuntimeChannelHealth) -> String {
        channel.authLabel ?? channel.channel ?? channel.source ?? channel.authIndex
    }

    private func statusTitle(_ tone: String) -> String {
        switch tone {
        case "bad": OasesLocalization.localized("异常")
        case "warn": OasesLocalization.localized("关注")
        default: OasesLocalization.localized("正常")
        }
    }

    private func tone(for value: String) -> Oases.Tone {
        switch value {
        case "bad": .danger
        case "warn": .warning
        default: .success
        }
    }

    private func compactToken(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
        case 1_000...: String(format: "%.1fK", value / 1_000)
        default: value.formatted(.number.precision(.fractionLength(0)))
        }
    }
}

/// The providers table: status dot + name, endpoint (monospaced), keys, models, prefix.
struct ProvidersTable: View {
    let providers: [RuntimeOpenAICompatibility]
    @Binding var selection: RuntimeOpenAICompatibility.ID?
    var onEdit: (RuntimeOpenAICompatibility) -> Void = { _ in }
    var onDelete: (RuntimeOpenAICompatibility) -> Void = { _ in }

    var body: some View {
        Table(providers, selection: $selection) {
            TableColumn("名称") { provider in
                HStack(spacing: Oases.Space.s) {
                    StatusDot(tone: provider.disabled ? .neutral : .success)
                    Text(ProviderTexts.name(provider))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(provider.disabled ? OasesLocalization.localized("已停用") : OasesLocalization.localized("已启用"))
            }
            .width(min: 120, ideal: 170)
            TableColumn("接口地址") { provider in
                Text(provider.baseURL.isEmpty ? OasesLocalization.localized("未填写服务地址") : provider.baseURL)
                    .font(.body.monospaced())
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(provider.baseURL)
            }
            .width(min: 160, ideal: 260)
            TableColumn("模型") { provider in
                Text(ProviderTexts.models(provider))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("API Key") { provider in
                Text(ProviderTexts.keys(provider))
                    .monospacedDigit()
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("路由前缀") { provider in
                Text(provider.prefix.isEmpty ? "—" : provider.prefix)
                    .font(.body.monospaced())
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: RuntimeOpenAICompatibility.ID.self) { ids in
            if let provider = single(ids) {
                Button("编辑…") { onEdit(provider) }
                Divider()
                Button("删除…", role: .destructive) { onDelete(provider) }
            }
        } primaryAction: { ids in
            if let provider = single(ids) { onEdit(provider) }
        }
    }

    private func single(_ ids: Set<RuntimeOpenAICompatibility.ID>) -> RuntimeOpenAICompatibility? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return providers.first { $0.id == id }
    }
}

enum ProviderTexts {
    static func name(_ provider: RuntimeOpenAICompatibility) -> String {
        provider.name.isEmpty ? OasesLocalization.localized("未命名服务") : provider.name
    }

    static func models(_ provider: RuntimeOpenAICompatibility) -> String {
        provider.models.isEmpty
            ? OasesLocalization.localized("跟随上游模型")
            : OasesLocalization.localizedFormat("%lld 个", provider.models.count)
    }

    static func keys(_ provider: RuntimeOpenAICompatibility) -> String {
        provider.apiKeyEntries.isEmpty
            ? OasesLocalization.localized("无密钥")
            : OasesLocalization.localizedFormat("%lld 个", provider.apiKeyEntries.count)
    }
}

/// The selected provider: label-above-value rows, the key masked with "显示", a connection test
/// (reads the provider's /models through the engine), 编辑… and 删除….
struct ProviderInspector: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    let provider: RuntimeOpenAICompatibility
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?

    private var firstKey: RuntimeProviderAPIKey? { provider.apiKeyEntries.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.md) {
                InspectorField(label: "名称") {
                    HStack(spacing: Oases.Space.s) {
                        StatusDot(tone: provider.disabled ? .neutral : .success)
                        Text(ProviderTexts.name(provider))
                        if provider.disabled {
                            Text("已停用").foregroundStyle(Oases.Color.textSecondary)
                        }
                    }
                }
                InspectorField(label: "接口地址") {
                    Text(provider.baseURL.isEmpty ? OasesLocalization.localized("未填写服务地址") : provider.baseURL)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InspectorField(label: "API Key") {
                    keyRow
                }
                InspectorField(label: "模型映射") {
                    Text(ProviderTexts.models(provider))
                }
                // The configuration screen may show the internal routing prefix (pin-…).
                InspectorField(label: "路由前缀") {
                    Text(provider.prefix.isEmpty ? OasesLocalization.localized("无前缀") : provider.prefix)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                testRow
                Divider()
                HStack {
                    Button("编辑…", action: onEdit)
                    Spacer()
                    Menu {
                        Button("删除…", role: .destructive, action: onDelete)
                    } label: {
                        Text("更多")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("更多操作")
                }
            }
            .padding(Oases.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: provider.id) { _, _ in
            revealsKey = false
            testResult = nil
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        if let key = firstKey {
            HStack(spacing: Oases.Space.sm) {
                Text(revealsKey && !key.appearsRedacted ? key.apiKey : key.redacted)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !key.appearsRedacted {
                    Button(revealsKey ? "隐藏" : "显示") { revealsKey.toggle() }
                        .buttonStyle(.borderless)
                }
            }
            if provider.apiKeyEntries.count > 1 {
                Text(OasesLocalization.localizedFormat("共 %lld 把密钥", provider.apiKeyEntries.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        } else {
            Text("无密钥").foregroundStyle(Oases.Color.textSecondary)
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            HStack(spacing: Oases.Space.sm) {
                Button("测试连接", action: runTest)
                    .disabled(isTesting || provider.baseURL.isEmpty)
                if isTesting { ProgressView().controlSize(.small) }
            }
            if let testResult {
                Label {
                    Text(testResult.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: testResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testResult.success ? Oases.Color.success : Oases.Color.danger)
                }
                .font(.callout)
            } else if provider.baseURL.isEmpty {
                Text("先填写接口地址。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let key = firstKey
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let request = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
                    baseURL: provider.baseURL,
                    apiKey: key.flatMap { $0.appearsRedacted ? nil : $0.apiKey },
                    authIndex: key?.authIndex ?? provider.authIndex,
                    headers: provider.headers
                )
                let response = try await ManagementAPIClient().apiCall(
                    request,
                    baseURL: deploymentStore.engineBaseURL,
                    managementKey: deploymentStore.managementKey
                )
                let outcome = RuntimeProviderDraftDiagnosticsParser.safeOutcome(from: response, kind: .models)
                testResult = (outcome.isSuccess, outcome.isSuccess
                              ? OasesLocalization.localizedFormat("连接正常 · %lld 个模型", outcome.modelCount ?? 0)
                              : outcome.message)
            } catch let error as RuntimeProviderDraftDiagnosticsError {
                testResult = (false, error.safeMessage)
            } catch {
                testResult = (false, OasesLocalization.localized("无法完成请求，请检查网络和服务配置。"))
            }
        }
    }
}

/// The empty state: add the first provider in place. 测试连接 reads the provider's /models
/// through the engine (no chat request, no cost); 添加 writes it with an automatic name and
/// routing prefix (and the models the test found). Both are disabled, with the reason shown,
/// until the endpoint and the key are filled in.
struct FirstProviderForm: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var discovered: [RuntimeDiscoveredProviderModel]?
    @State private var message: (success: Bool, text: String)?

    private var isFilled: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            Text("添加你的第一个 AI 提供商")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("填写提供商的接口地址和 API Key。网关会读取它的模型，客户端用你在“调用 API Key”创建的 Key 调用。")
                .foregroundStyle(Oases.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Oases.Space.m, verticalSpacing: Oases.Space.sm) {
                GridRow {
                    Text("接口地址")
                        .gridColumnAlignment(.trailing)
                    TextField("接口地址", text: $baseURL, prompt: Text(OasesLocalization.localized("例如 https://api.deepseek.com")))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                GridRow {
                    Text("API Key")
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
            .onChange(of: baseURL) { _, _ in resetTest() }
            .onChange(of: apiKey) { _, _ in resetTest() }

            HStack(spacing: Oases.Space.sm) {
                Button("测试连接", action: runTest)
                    .disabled(!isFilled || isTesting)
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isFilled || isTesting || runtimeDataStore.isSavingProviders)
                if isTesting || runtimeDataStore.isSavingProviders { ProgressView().controlSize(.small) }
            }
            if !isFilled {
                Text("先填写接口地址和 API Key")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            } else if let message {
                Label {
                    Text(message.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: message.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(message.success ? Oases.Color.success : Oases.Color.danger)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func resetTest() {
        discovered = nil
        message = nil
    }

    private func runTest() {
        isTesting = true
        message = nil
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let request = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(baseURL: baseURL, apiKey: apiKey)
                let response = try await ManagementAPIClient().apiCall(
                    request,
                    baseURL: deploymentStore.engineBaseURL,
                    managementKey: deploymentStore.managementKey
                )
                let models = try RuntimeProviderDraftDiagnosticsParser.models(from: response)
                discovered = models
                message = (true, OasesLocalization.localizedFormat("连接正常 · %lld 个模型", models.count))
            } catch let error as RuntimeProviderDraftDiagnosticsError {
                message = (false, error.safeMessage)
            } catch {
                message = (false, OasesLocalization.localized("无法完成请求，请检查网络和服务配置。"))
            }
        }
    }

    private func add() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Self.providerName(forBaseURL: trimmedURL)
        let taken = ProviderPrefixAllocator.takenPrefixes(from: runtimeDataStore, excludingProviderNamed: nil)
        let prefix: String
        switch ProviderPrefixAllocator.prefixForNewProvider(typed: "", name: name, taken: taken) {
        case .success(let value):
            prefix = value
        case .failure(let error):
            message = (false, error.localizedDescription)
            runtimeDataStore.refreshProviders(using: deploymentStore)
            runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
            return
        }
        let directPrefixes = ProviderPrefixAllocator.takenPrefixes(
            openAICompatibility: [],
            directCredentials: runtimeDataStore.directProviderCredentials,
            excludingProviderNamed: nil
        ) ?? []
        runtimeDataStore.createOpenAICompatibility(
            RuntimeOpenAICompatibilityWrite(
                name: name,
                priority: 0,
                disabled: false,
                prefix: prefix,
                baseURL: trimmedURL,
                apiKeyEntries: [RuntimeProviderAPIKey(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))],
                models: (discovered ?? []).map {
                    RuntimeProviderModel(name: $0.name, alias: $0.alias ?? "", displayName: $0.description ?? "")
                },
                headers: [:],
                disableCooling: false
            ),
            allocatePrefixAgainst: directPrefixes,
            using: deploymentStore
        )
        apiKey = ""
    }

    /// A readable provider name from the endpoint's host: `https://api.deepseek.com/v1` →
    /// `deepseek`, `https://openrouter.ai/api` → `openrouter`; an IP address or an unparsable
    /// value is used as it is.
    static func providerName(forBaseURL value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased(), !host.isEmpty else {
            return trimmed.isEmpty ? OasesLocalization.localized("未命名服务") : trimmed
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        var labels = host.split(separator: ".").map(String.init)
        if labels.count > 1 { labels.removeLast() }
        if labels.count > 1, ["api", "www", "gateway", "llm"].contains(labels[0]) { labels.removeFirst() }
        return labels.first ?? host
    }
}
