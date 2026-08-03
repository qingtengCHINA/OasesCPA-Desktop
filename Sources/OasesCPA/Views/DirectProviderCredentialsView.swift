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
                title: "为日常配置保留简单入口",
                message: "这里提供 API Key、Base URL、模型前缀、独立代理和流量权重。已有凭证编辑使用 PATCH，只提交实际改动；headers、模型映射等高级字段会被保留，可从完整配置继续调整。",
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
                    if !credential.modelIDs.isEmpty {
                        Text("映射 \(credential.modelIDs.count) 个模型")
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
    @State private var showAPIKey = false
    @State private var showSaveConfirmation = false
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
    }

    private var isNew: Bool { credential == nil }

    private var draft: RuntimeDirectProviderCredentialDraft {
        RuntimeDirectProviderCredentialDraft(
            apiKey: apiKey,
            baseURL: baseURL,
            prefix: prefix,
            proxyURL: proxyURL,
            weight: usesDefaultWeight ? nil : Int(weightText.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private var validationMessage: String? {
        if !usesDefaultWeight,
           Int(weightText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return "请填写有效的整数流量权重，或使用默认权重。"
        }
        return draft.validationMessage(for: kind, isNew: isNew)
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

                Section("流量分配") {
                    Toggle("使用默认权重", isOn: $usesDefaultWeight)
                    if !usesDefaultWeight {
                        TextField("权重", text: $weightText, prompt: Text("1-1,000,000"))
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("多条凭证共存时，CLIProxyAPI 会按其路由策略使用权重。默认权重由服务端处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
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

            Divider()

            HStack {
                Text("高级 headers、模型映射和其它未展示字段会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加凭证" : "保存修改") {
                    showSaveConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    validationMessage != nil ||
                    !hasChanges ||
                    runtimeDataStore.isSavingDirectProviders
                )
            }
            .padding(18)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560)
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
                dismiss()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}
