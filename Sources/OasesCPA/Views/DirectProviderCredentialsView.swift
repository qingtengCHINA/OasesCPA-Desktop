import SwiftUI

struct DirectProviderCredentialsCard: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var selectedKind: RuntimeDirectProviderKind = .gemini
    @State private var editorTarget: DirectProviderEditorTarget?
    @State private var deletingCredential: RuntimeDirectProviderCredential?
    @State private var deleteConfirmationPresented = false
    @State private var operationError: String?

    private var credentials: [RuntimeDirectProviderCredential] {
        runtimeDataStore.directCredentials(for: selectedKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                CardTitle(
                    title: "内置上游 Provider",
                    subtitle: "直接管理 CLIProxyAPI 的密钥池与基础路由",
                    icon: "key.horizontal"
                )
                Spacer()
                if runtimeDataStore.isLoadingDirectProviders {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("完整配置", systemImage: "doc.text") {
                    appStore.selectSection(.config)
                }
                .buttonStyle(.bordered)
                .help("打开 CLIProxyAPI config.yaml，调整未在简化表单中展示的高级字段")

                Button("刷新", systemImage: "arrow.clockwise") {
                    runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
                }
                .buttonStyle(.bordered)
                .disabled(deploymentStore.stage != .attached || runtimeDataStore.isLoadingDirectProviders)

                Button("添加凭证", systemImage: "plus") {
                    editorTarget = DirectProviderEditorTarget(kind: selectedKind, credential: nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingDirectProviders)
            }

            Picker("上游类型", selection: $selectedKind) {
                ForEach(RuntimeDirectProviderKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Image(systemName: selectedKind.systemImage)
                    .foregroundStyle(Color.oasesBlue)
                Text(selectedKind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(
                    title: "\(credentials.count) 个凭证",
                    tint: credentials.isEmpty ? .oasesOrange : .oasesGreen,
                    systemImage: "key"
                )
            }

            if deploymentStore.stage != .attached {
                InfoBanner(
                    title: "连接后管理上游凭证",
                    message: "连接本机或 SSH / VPS 目标后，Oases CPA 会读取目标 CLIProxyAPI 的真实 Provider 密钥池。",
                    systemImage: "link.badge.plus",
                    tint: .oasesOrange
                )
            } else if let error = runtimeDataStore.directProviderError(for: selectedKind) {
                InfoBanner(
                    title: "\(selectedKind.title) 凭证池暂不可用",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            } else if credentials.isEmpty, !runtimeDataStore.isLoadingDirectProviders {
                ContentUnavailableView {
                    Label("尚未配置 \(selectedKind.title) 凭证", systemImage: "key")
                } description: {
                    Text("添加后会直接写入当前目标 CLIProxyAPI，不依赖 Oases dev 或浏览器面板。")
                } actions: {
                    Button("添加 \(selectedKind.title) 凭证", systemImage: "plus") {
                        editorTarget = DirectProviderEditorTarget(kind: selectedKind, credential: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(credentials) { credential in
                        DirectProviderCredentialRow(
                            credential: credential,
                            isSaving: runtimeDataStore.isSavingDirectProviders,
                            onEdit: {
                                editorTarget = DirectProviderEditorTarget(
                                    kind: selectedKind,
                                    credential: credential
                                )
                            },
                            onDelete: {
                                deletingCredential = credential
                                deleteConfirmationPresented = true
                            }
                        )
                        if credential.id != credentials.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .oasesCard()
            }

            if let operationError {
                InfoBanner(
                    title: "Provider 凭证操作失败",
                    message: operationError,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            InfoBanner(
                title: "日常与高级配置都在这里",
                message: "支持 API Key、Base URL、模型前缀、代理、权重、优先级、Headers、冷却策略和模型映射。保存前会重新读取目标的最新凭证列表，再合并本次变更。",
                systemImage: "lock.shield",
                tint: .oasesBlue
            )
        }
        .padding(20)
        .oasesCard()
        .task(id: deploymentStore.stage) {
            guard deploymentStore.stage == .attached else { return }
            runtimeDataStore.refreshDirectProviderCredentials(using: deploymentStore)
        }
        .sheet(item: $editorTarget) { target in
            DirectProviderCredentialEditorView(kind: target.kind, credential: target.credential)
        }
        .confirmationDialog(
            "删除 \(deletingCredential?.kind.title ?? "") 凭证？",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let credential = deletingCredential {
                Button("删除凭证", role: .destructive) {
                    delete(credential)
                }
            }
            Button("取消", role: .cancel) {
                deletingCredential = nil
            }
        } message: {
            Text("这会从当前目标 CLIProxyAPI 的 \(deletingCredential?.kind.title ?? "") 凭证池中移除此条目，无法自动恢复。")
        }
    }

    private func delete(_ credential: RuntimeDirectProviderCredential) {
        Task {
            do {
                try await runtimeDataStore.deleteDirectProviderCredential(
                    credential,
                    using: deploymentStore
                )
                deletingCredential = nil
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct DirectProviderEditorTarget: Identifiable {
    let kind: RuntimeDirectProviderKind
    let credential: RuntimeDirectProviderCredential?

    var id: String {
        credential.map { "\(kind.rawValue):\($0.id)" } ?? "\(kind.rawValue):new"
    }
}

private struct DirectProviderCredentialRow: View {
    let credential: RuntimeDirectProviderCredential
    let isSaving: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: credential.kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.oasesMint)
                .frame(width: 36, height: 36)
                .background(Color.oasesMint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(credential.maskedAPIKey)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                    if let weight = credential.weight {
                        StatusPill(title: "权重 \(weight)", tint: .oasesBlue)
                    } else {
                        StatusPill(title: "默认权重", tint: .oasesGreen)
                    }
                }

                Text(credential.baseURL.isEmpty ? "使用服务默认 Base URL" : credential.baseURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !credential.prefix.isEmpty {
                        Text("前缀 \(credential.prefix)")
                    }
                    if !credential.proxyURL.isEmpty {
                        Text("独立代理")
                    }
                    if let priority = credential.priority {
                        Text("优先级 \(priority)")
                    }
                    if credential.disableCooling {
                        Text("已禁用冷却")
                    }
                    if !credential.headers.isEmpty {
                        Text("Headers \(credential.headers.count)")
                    }
                    if !credential.models.isEmpty {
                        Text("模型映射 \(credential.models.count)")
                    }
                    if !credential.authIndex.isEmpty {
                        Text("认证索引 \(credential.authIndex)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button("编辑", systemImage: "slider.horizontal.3") {
                onEdit()
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            Menu {
                Button("编辑", systemImage: "slider.horizontal.3", action: onEdit)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(isSaving)
            .help("更多操作")
        }
        .padding(.vertical, 13)
    }
}

private struct DirectProviderEditorHeaderRow: Identifiable, Equatable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

private struct DirectProviderEditorModelRow: Identifiable, Equatable {
    let id: UUID
    var name: String
    var alias: String
    var values: [String: RuntimeJSONValue]

    init(
        id: UUID = UUID(),
        name: String = "",
        alias: String = "",
        values: [String: RuntimeJSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.alias = alias
        self.values = values
    }

    init(draft: RuntimeDirectProviderModelDraft) {
        id = UUID()
        name = draft.name
        alias = draft.alias
        values = draft.values
    }

    func modelDraft() -> RuntimeDirectProviderModelDraft {
        RuntimeDirectProviderModelDraft(
            name: name,
            alias: alias,
            values: values
        )
    }
}

struct DirectProviderCredentialEditorView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.dismiss) private var dismiss

    let kind: RuntimeDirectProviderKind
    let credential: RuntimeDirectProviderCredential?

    @State private var apiKey: String
    @State private var baseURL: String
    @State private var prefix: String
    @State private var proxyURL: String
    @State private var usesDefaultWeight: Bool
    @State private var weightText: String
    @State private var usesDefaultPriority: Bool
    @State private var priorityText: String
    @State private var disableCooling: Bool
    @State private var headerRows: [DirectProviderEditorHeaderRow]
    @State private var modelRows: [DirectProviderEditorModelRow]
    @State private var showAPIKey = false
    @State private var showSaveConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var allowClose = false
    @State private var operationError: String?

    init(kind: RuntimeDirectProviderKind, credential: RuntimeDirectProviderCredential?) {
        self.kind = kind
        self.credential = credential
        let draft = credential.map(RuntimeDirectProviderCredentialDraft.init(credential:))
            ?? RuntimeDirectProviderCredentialDraft()
        _apiKey = State(initialValue: draft.apiKey)
        _baseURL = State(initialValue: draft.baseURL)
        _prefix = State(initialValue: draft.prefix)
        _proxyURL = State(initialValue: draft.proxyURL)
        _usesDefaultWeight = State(initialValue: draft.weight == nil)
        _weightText = State(initialValue: draft.weight.map(String.init) ?? "")
        _usesDefaultPriority = State(initialValue: draft.priority == nil)
        _priorityText = State(initialValue: draft.priority.map(String.init) ?? "")
        _disableCooling = State(initialValue: draft.disableCooling)
        _headerRows = State(initialValue: draft.headers
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { DirectProviderEditorHeaderRow(name: $0.key, value: $0.value) })
        _modelRows = State(initialValue: draft.models.map(DirectProviderEditorModelRow.init(draft:)))
    }

    private var isNew: Bool { credential == nil }

    private var draft: RuntimeDirectProviderCredentialDraft {
        RuntimeDirectProviderCredentialDraft(
            apiKey: apiKey,
            baseURL: baseURL,
            prefix: prefix,
            proxyURL: proxyURL,
            weight: usesDefaultWeight ? nil : Int(weightText.trimmingCharacters(in: .whitespacesAndNewlines)),
            priority: usesDefaultPriority ? nil : Int(priorityText.trimmingCharacters(in: .whitespacesAndNewlines)),
            disableCooling: disableCooling,
            headers: Dictionary(
                headerRows.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            preservedHeaderValues: credential?.headerValues.filter { item in
                if case .string = item.value { return false }
                return true
            } ?? [:],
            models: modelRows.map { $0.modelDraft() }
        )
    }

    private var validationMessage: String? {
        if !usesDefaultWeight,
           Int(weightText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return "请填写有效的整数流量权重，或使用默认权重。"
        }
        return draft.validationMessage(for: kind, isNew: isNew)
    }

    private var editorValidationMessage: String? {
        if !usesDefaultPriority,
           Int(priorityText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return "请填写有效的整数优先级，或使用默认优先级。"
        }
        if headerRows.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "请求 Header 名称不能为空。"
        }
        let headerNames = headerRows.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if Set(headerNames).count != headerNames.count {
            return "请求 Header 名称不能重复。"
        }
        return validationMessage
    }

    private var hasChanges: Bool {
        if isNew {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let credential else { return false }
        return draft.patch(relativeTo: credential) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                Section {
                    LabeledContent("上游类型") {
                        Label(kind.title, systemImage: kind.systemImage)
                            .foregroundStyle(.primary)
                    }
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("凭证") {
                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField(isNew ? "API Key" : "留空以保持当前 API Key", text: $apiKey)
                            } else {
                                SecureField(isNew ? "API Key" : "留空以保持当前 API Key", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(showAPIKey ? "隐藏" : "显示", systemImage: showAPIKey ? "eye.slash" : "eye") {
                            showAPIKey.toggle()
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(isNew ? "密钥只用于写入当前目标；不会保存到 App 偏好设置或日志。" : "为避免暴露已有密钥，编辑时不会预填。留空即可保留当前密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("路由") {
                    TextField("上游 Base URL", text: $baseURL, prompt: Text(kind.baseURLPlaceholder))
                        .textFieldStyle(.roundedBorder)
                    TextField("模型前缀（可选）", text: $prefix, prompt: Text("例如 team-a/"))
                        .textFieldStyle(.roundedBorder)
                    TextField("独立代理地址（可选）", text: $proxyURL, prompt: Text("例如 socks5://127.0.0.1:1080"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("高级路由") {
                    Toggle("使用默认权重", isOn: $usesDefaultWeight)
                    if !usesDefaultWeight {
                        TextField("权重", text: $weightText, prompt: Text("1-1,000,000"))
                            .textFieldStyle(.roundedBorder)
                    }
                    if kind.supportsPriority {
                        Toggle("使用默认优先级", isOn: $usesDefaultPriority)
                        if !usesDefaultPriority {
                            TextField("优先级", text: $priorityText, prompt: Text("0-1,000,000"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if kind.supportsDisableCooling {
                        Toggle("禁用冷却", isOn: $disableCooling)
                    }
                    Text(kind.supportsPriority
                         ? "权重和优先级会参与多凭证路由；冷却选项用于 xAI 特殊路由。"
                         : "多条凭证共存时，CLIProxyAPI 会按当前路由策略使用权重。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("请求 Headers") {
                    if headerRows.isEmpty {
                        Text("未配置额外请求 Header。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($headerRows) { $row in
                        HStack(spacing: 8) {
                            TextField("Header 名称", text: $row.name)
                                .textFieldStyle(.roundedBorder)
                            TextField("Header 值", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                            Button("删除", systemImage: "trash", role: .destructive) {
                                headerRows.removeAll { $0.id == row.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("添加 Header", systemImage: "plus") {
                        headerRows.append(DirectProviderEditorHeaderRow())
                    }
                    Text("Header 值仅在保存时提交；服务端返回的未知非文本 Header 值会继续保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if kind.supportsModelMappings {
                    Section("模型映射") {
                    if modelRows.isEmpty {
                        Text("未配置模型映射，将使用上游返回的模型名称。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($modelRows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("上游模型名称", text: $row.name)
                                    .textFieldStyle(.roundedBorder)
                                TextField("客户端别名（可选）", text: $row.alias)
                                    .textFieldStyle(.roundedBorder)
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    modelRows.removeAll { $0.id == row.id }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("添加模型映射", systemImage: "plus") {
                        modelRows.append(DirectProviderEditorModelRow())
                    }
                    Text("模型映射中的未知字段会保留，便于 CLIProxyAPI 新版本字段无损往返。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let editorValidationMessage {
                    Section {
                        Label(editorValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.oasesRed)
                    }
                }

                if let operationError {
                    Section {
                        Label(operationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.oasesRed)
                    }
                }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Text("高级字段会保留；底部按钮始终可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { requestDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加凭证" : "保存修改") {
                    showSaveConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    editorValidationMessage != nil ||
                    !hasChanges ||
                    runtimeDataStore.isSavingDirectProviders
                )
            }
            .padding(18)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 760)
        .background(
            WindowCloseGuard {
                guard !allowClose, hasChanges else { return true }
                showDiscardConfirmation = true
                return false
            }
        )
        .confirmationDialog(
            isNew ? "添加 \(kind.title) 凭证？" : "保存 \(kind.title) 凭证修改？",
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(isNew ? "确认添加" : "确认保存") {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("操作会直接写入当前已连接目标的 CLIProxyAPI。密钥内容不会在确认提示中显示。")
        }
        .confirmationDialog(
            "舍弃未保存的 Provider 配置？",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("舍弃更改并关闭", role: .destructive) {
                allowClose = true
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("关闭会丢失尚未保存的密钥、路由、Headers 和模型映射。")
        }
    }

    private func requestDismiss() {
        guard hasChanges else {
            allowClose = true
            dismiss()
            return
        }
        showDiscardConfirmation = true
    }

    private func save() {
        Task {
            do {
                if let credential {
                    try await runtimeDataStore.updateDirectProviderCredential(
                        credential,
                        draft: draft,
                        using: deploymentStore
                    )
                } else {
                    try await runtimeDataStore.createDirectProviderCredential(
                        kind: kind,
                        draft: draft,
                        using: deploymentStore
                    )
                }
                allowClose = true
                dismiss()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}
