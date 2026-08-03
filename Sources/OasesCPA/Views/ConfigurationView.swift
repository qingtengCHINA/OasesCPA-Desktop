import SwiftUI

private enum ConfigurationWorkspaceMode: String, CaseIterable, Identifiable {
    case quick
    case source
    case manager

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: OasesLocalization.localized("可视化配置")
        case .source: OasesLocalization.localized("完整 YAML")
        case .manager: OasesLocalization.localized("CPAMP 设置")
        }
    }
}

struct ConfigurationEditState: Equatable {
    private(set) var revision = 0
    private(set) var savedRevision = 0

    var isDirty: Bool {
        revision != savedRevision
    }

    mutating func markChanged() {
        revision += 1
    }

    func beginSave() -> Int {
        revision
    }

    mutating func finishSave(revision submittedRevision: Int, succeeded: Bool) {
        guard succeeded, revision == submittedRevision else { return }
        savedRevision = submittedRevision
    }

    mutating func reset() {
        revision = 0
        savedRevision = 0
    }
}

struct ConfigurationView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var draft: RuntimeManagerConfig?
    @State private var editState = ConfigurationEditState()
    @State private var showSaveConfirmation = false
    @State private var showCPAConfigEditor = false
    @State private var showKey = false
    @State private var pollIntervalText = ""
    @State private var batchSizeText = ""
    @State private var queryLimitText = ""
    @State private var inspectionPolicyDraft: RuntimeCodexInspectionPolicyDraft?
    @State private var selectedWorkspaceMode: ConfigurationWorkspaceMode = .quick
    @State private var pendingWorkspaceMode: ConfigurationWorkspaceMode?
    @State private var showDiscardWorkspaceChanges = false
    @State private var quickConfigIsDirty = false
    @State private var quickConfigIdentity = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "连接后编辑 CPAMP 配置",
                        message: "配置保存发生在当前目标的 CPA Manager Plus Full Mode。先完成本机或 SSH / VPS 部署，App 才会读取和保存真实配置。",
                        systemImage: "lock.shield",
                        tint: .oasesOrange
                    )
                } else {
                    workspaceModePicker

                    switch selectedWorkspaceMode {
                    case .quick:
                        CPAQuickConfigurationView(
                            embedded: true,
                            onDirtyChange: { quickConfigIsDirty = $0 }
                        )
                        .id(quickConfigIdentity)
                    case .source:
                        cpaConfigCard
                    case .manager:
                        if runtimeDataStore.isLoadingManagerConfiguration && draft == nil {
                            loadingCard
                        } else if let draft {
                            form(for: draft)
                        } else {
                            emptyCard
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            if deploymentStore.stage == .attached {
                runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
                runtimeDataStore.refreshCPAConfig(using: deploymentStore)
            } else {
                draft = nil
                inspectionPolicyDraft = nil
                editState.reset()
                quickConfigIsDirty = false
                quickConfigIdentity = UUID()
            }
        }
        .onChange(of: runtimeDataStore.managerConfiguration) { _, response in
            guard let response, !editState.isDirty else { return }
            apply(response.config)
        }
        .onAppear {
            store.configurationHasUnsavedChanges = isDirty
        }
        .onChange(of: isDirty) { _, value in
            store.configurationHasUnsavedChanges = value
        }
        .confirmationDialog(
            saveConfirmationTitle,
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "保存并应用",
                role: effectiveInspectionPolicyDraft.isDestructive ? .destructive : nil
            ) {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(saveConfirmationMessage)
        }
        .confirmationDialog(
            "舍弃未保存的配置？",
            isPresented: Binding(
                get: { store.pendingSection != nil },
                set: { if !$0 { store.cancelPendingNavigation() } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingSection = store.pendingSection {
                Button("舍弃更改并前往 \(pendingSection.title)", role: .destructive) {
                    discardAllDrafts()
                    store.discardConfigurationChangesAndContinue()
                }
            }
            Button("留在此页", role: .cancel) {
                store.cancelPendingNavigation()
            }
        } message: {
            Text("当前配置还有未保存的修改。继续切换页面会丢弃这些草稿。")
        }
        .confirmationDialog(
            "切换配置模式并舍弃更改？",
            isPresented: $showDiscardWorkspaceChanges,
            titleVisibility: .visible
        ) {
            if let pendingWorkspaceMode {
                Button("舍弃更改并前往 \(pendingWorkspaceMode.title)", role: .destructive) {
                    discardAllDrafts()
                    selectedWorkspaceMode = pendingWorkspaceMode
                    self.pendingWorkspaceMode = nil
                }
            }
            Button("留在当前模式", role: .cancel) {
                pendingWorkspaceMode = nil
            }
        } message: {
            Text("可视化配置或 CPAMP 设置中仍有未保存的修改。")
        }
        .sheet(isPresented: $showCPAConfigEditor) {
            CPAConfigEditorView()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageHeader(section: .config)
            Spacer()

            if deploymentStore.stage == .attached {
                if selectedWorkspaceMode == .source {
                    Button("编辑 config.yaml", systemImage: "pencil") {
                        showCPAConfigEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                } else if selectedWorkspaceMode == .manager {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        editState.reset()
                        runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtimeDataStore.isLoadingManagerConfiguration || runtimeDataStore.isSavingManagerConfiguration)

                    Button("保存配置", systemImage: "checkmark.circle") {
                        showSaveConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editState.isDirty || runtimeDataStore.isSavingManagerConfiguration || !isValidDraft)
                }
            }
        }
    }

    private var workspaceModePicker: some View {
        Picker("配置模式", selection: Binding(
            get: { selectedWorkspaceMode },
            set: { requestWorkspaceMode($0) }
        )) {
            ForEach(ConfigurationWorkspaceMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 680)
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var cpaConfigCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                CardTitle(
                    title: "CLIProxyAPI 原生配置",
                    subtitle: "当前目标的 config.yaml，直连 CLIProxyAPI Management API",
                    icon: "doc.text"
                )
                Spacer()
                if runtimeDataStore.isLoadingCPAConfig {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("编辑 config.yaml", systemImage: "pencil") {
                    showCPAConfigEditor = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(runtimeDataStore.isLoadingCPAConfig || runtimeDataStore.isSavingCPAConfig)
            }

            InfoBanner(
                title: "这是 CLIProxyAPI 的完整配置入口",
                message: "可直接编辑监听端口、管理密钥、代理地址和其它原生字段。保存前建议先导出备份；CLIProxyAPI 会在服务端校验 YAML 和配置，错误配置可能影响服务启动。",
                systemImage: "exclamationmark.shield",
                tint: .oasesOrange
            )

            if let error = runtimeDataStore.cpaConfigErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
            } else if runtimeDataStore.cpaConfigYAML != nil {
                Label("已读取当前目标 config.yaml", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.oasesGreen)
            } else {
                Text("点击“编辑 config.yaml”读取原始配置内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .oasesCard()
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("正在读取 CPAMP Manager 配置")
                    .font(.headline)
                Text("不会读取或展示 Provider 私钥；这里只读取连接、采集器和运行策略。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
        .oasesCard()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "暂时无法读取配置", subtitle: "检查当前目标的 CPAMP 服务和管理密钥", icon: "exclamationmark.triangle")
            if let error = runtimeDataStore.managerConfigurationErrorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.oasesRed)
            }
            Button("重新读取", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(22)
        .oasesCard()
    }

    private func form(for config: RuntimeManagerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionCard(config)
            collectorCard(config)
            inspectionPolicyCard
            safetyCard(config)

            HStack(spacing: 12) {
                StatusPill(
                    title: runtimeDataStore.managerConfiguration?.source.map { "来源：\($0)" } ?? "来源：CPAMP",
                    tint: .oasesBlue,
                    systemImage: "server.rack"
                )
                if isDirty {
                    StatusPill(title: "有未保存变更", tint: .oasesOrange, systemImage: "circle.dotted")
                }
                if let error = runtimeDataStore.managerConfigurationErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.oasesRed)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private func connectionCard(_ config: RuntimeManagerConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(
                title: "CPA 中转站连接",
                subtitle: "CPAMP 使用这组信息访问你的 CLIProxyAPI 管理接口",
                icon: "point.3.connected.trianglepath.dotted"
            )

            LabeledField(
                title: "CPA Base URL",
                placeholder: "http://127.0.0.1:8317",
                text: baseURLBinding
            )

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CPA 管理密钥")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if showKey {
                            TextField("cpa_…", text: managementKeyBinding)
                        } else {
                            SecureField("cpa_…", text: managementKeyBinding)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }

                Button(showKey ? "隐藏" : "显示", systemImage: showKey ? "eye.slash" : "eye") {
                    showKey.toggle()
                }
                .buttonStyle(.bordered)
            }

            InfoBanner(
                title: "密钥只经 CPAMP 管理 API 提交",
                message: "App 不把 CPA 管理密钥写入普通偏好设置；部署生成的密钥仍由 Keychain 保存。修改后 CPAMP 会先验证连接再保存。",
                systemImage: "key.fill",
                tint: .oasesBlue
            )
        }
        .padding(22)
        .oasesCard()
    }

    private func collectorCard(_ config: RuntimeManagerConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(
                title: "请求监控采集器",
                subtitle: "控制 CPA 使用统计如何进入 CPAMP 仪表盘和监控",
                icon: "waveform.path.ecg"
            )

            Toggle("启用请求监控", isOn: monitoringBinding)
                .toggleStyle(.switch)

            HStack(spacing: 12) {
                Picker("采集模式", selection: collectorModeBinding) {
                    Text("自动").tag("auto")
                    Text("HTTP").tag("http")
                    Text("RESP").tag("resp")
                    Text("订阅").tag("subscribe")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("队列弹出方向", selection: popSideBinding) {
                    Text("右侧").tag("right")
                    Text("左侧").tag("left")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                numericField(title: "轮询间隔（毫秒）", text: $pollIntervalText)
                numericField(title: "批量大小", text: $batchSizeText)
                numericField(title: "查询上限", text: $queryLimitText)
            }

            Text("默认值适合大多数本机部署；RESP 模式需要 CPA 端口直接可达，远程反向代理场景通常使用自动或 HTTP。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .oasesCard()
    }

    private func safetyCard(_ config: RuntimeManagerConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "安全与应用行为", subtitle: "保存前明确展示可能影响连接的选项", icon: "lock.shield")

            Toggle("跳过 TLS 证书验证（不推荐）", isOn: tlsSkipVerifyBinding)
                .toggleStyle(.switch)

            if config.collector.tlsSkipVerify {
                InfoBanner(
                    title: "TLS 校验已关闭",
                    message: "仅在目标使用自签名证书且你已确认网络边界时启用。公网 VPS 建议保持关闭。",
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesOrange
                )
            }
        }
        .padding(22)
        .oasesCard()
    }

    private var inspectionPolicyCard: some View {
        CodexInspectionPolicyEditor(
            draft: inspectionPolicyBinding,
            onChange: {
                editState.markChanged()
            }
        )
    }

    private func numericField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("请输入数值", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { draft?.cpaConnection.cpaBaseURL ?? "" },
            set: { value in
                guard var draft else { return }
                draft.cpaConnection.cpaBaseURL = value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var managementKeyBinding: Binding<String> {
        Binding(
            get: { draft?.cpaConnection.managementKey ?? "" },
            set: { value in
                guard var draft else { return }
                draft.cpaConnection.managementKey = value.isEmpty ? nil : value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { draft?.isMonitoringEnabled ?? true },
            set: { value in
                guard var draft else { return }
                draft.collector.enabled = value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var collectorModeBinding: Binding<String> {
        Binding(
            get: { draft?.collector.collectorMode ?? "auto" },
            set: { value in
                guard var draft else { return }
                draft.collector.collectorMode = value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var popSideBinding: Binding<String> {
        Binding(
            get: { draft?.collector.popSide ?? "right" },
            set: { value in
                guard var draft else { return }
                draft.collector.popSide = value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var tlsSkipVerifyBinding: Binding<Bool> {
        Binding(
            get: { draft?.collector.tlsSkipVerify ?? false },
            set: { value in
                guard var draft else { return }
                draft.collector.tlsSkipVerify = value
                self.draft = draft
                editState.markChanged()
            }
        )
    }

    private var inspectionPolicyBinding: Binding<RuntimeCodexInspectionPolicyDraft> {
        Binding(
            get: { effectiveInspectionPolicyDraft },
            set: { value in
                inspectionPolicyDraft = value
                editState.markChanged()
            }
        )
    }

    private var effectiveInspectionPolicyDraft: RuntimeCodexInspectionPolicyDraft {
        inspectionPolicyDraft
            ?? RuntimeCodexInspectionPolicyDraft(
                config: draft?.codexInspection
                    ?? RuntimeCodexInspectionPolicyDraft.defaultConfig()
            )
    }

    private var isValidDraft: Bool {
        guard let draft,
              !draft.cpaConnection.cpaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pollInterval = Int(pollIntervalText), pollInterval > 0,
              let batchSize = Int(batchSizeText), batchSize > 0,
              let queryLimit = Int(queryLimitText), queryLimit > 0,
              effectiveInspectionPolicyDraft.validationMessage == nil else {
            return false
        }
        return draft.collector.popSide == "left" || draft.collector.popSide == "right"
    }

    private func apply(_ config: RuntimeManagerConfig) {
        draft = config
        pollIntervalText = String(config.collector.pollIntervalMs)
        batchSizeText = String(config.collector.batchSize)
        queryLimitText = String(config.collector.queryLimit)
        inspectionPolicyDraft = RuntimeCodexInspectionPolicyDraft(
            config: config.codexInspection
                ?? RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )
        editState.reset()
    }

    private func save() {
        guard var draft,
              let pollInterval = Int(pollIntervalText), pollInterval > 0,
              let batchSize = Int(batchSizeText), batchSize > 0,
              let queryLimit = Int(queryLimitText), queryLimit > 0,
              effectiveInspectionPolicyDraft.validationMessage == nil else { return }
        draft.collector.pollIntervalMs = pollInterval
        draft.collector.batchSize = batchSize
        draft.collector.queryLimit = queryLimit
        draft.codexInspection = effectiveInspectionPolicyDraft.applying(
            to: draft.codexInspection
                ?? RuntimeCodexInspectionPolicyDraft.defaultConfig()
        )
        self.draft = draft
        let submittedRevision = editState.beginSave()
        Task {
            do {
                _ = try await runtimeDataStore.saveManagerConfiguration(
                    draft,
                    using: deploymentStore
                )
                editState.finishSave(revision: submittedRevision, succeeded: true)
            } catch {
                editState.finishSave(revision: submittedRevision, succeeded: false)
            }
        }
    }

    private var isDirty: Bool {
        editState.isDirty || quickConfigIsDirty
    }

    private func requestWorkspaceMode(_ mode: ConfigurationWorkspaceMode) {
        guard mode != selectedWorkspaceMode else { return }
        guard isDirty else {
            selectedWorkspaceMode = mode
            return
        }
        pendingWorkspaceMode = mode
        showDiscardWorkspaceChanges = true
    }

    private func discardAllDrafts() {
        editState.reset()
        quickConfigIsDirty = false
        quickConfigIdentity = UUID()
    }

    private var saveConfirmationTitle: String {
        if effectiveInspectionPolicyDraft.isDestructive {
            return "保存含自动删除策略的配置？"
        }
        if effectiveInspectionPolicyDraft.isMutationCapable {
            return "保存含自动动作策略的配置？"
        }
        if effectiveInspectionPolicyDraft.hasActiveXAIInferenceProbe {
            return "保存含 xAI 推理探针的配置？"
        }
        return "保存 CPAMP 配置？"
    }

    private var saveConfirmationMessage: String {
        var details = [
            "CPAMP 会校验 CPA 管理地址和密钥；如果启用了请求监控，保存可能会重启采集器。"
        ]
        if effectiveInspectionPolicyDraft.isDestructive {
            details.append("本次保存不会立即运行巡检，但后续定时或手动巡检可能按策略删除目标认证文件。")
        } else if effectiveInspectionPolicyDraft.isMutationCapable {
            details.append("本次保存不会立即运行巡检，但后续定时或手动巡检可能按策略启用、禁用或恢复目标认证文件。")
        }
        if effectiveInspectionPolicyDraft.hasActiveXAIInferenceProbe {
            details.append("后续包含 xAI 的巡检会额外发送一次推理请求以验证实际可用性，可能消耗账号额度；保存本身不会发起该请求。")
        }
        return details.joined(separator: "\n\n")
    }
}
