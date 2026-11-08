import AppKit
import SwiftUI

/// Creates a key or edits one key's policy. Saving an edit re-reads the server first
/// (`GatewayKeysStore.savePolicy`); provider pins that would be dropped are listed for
/// confirmation before anything is sent.
struct GatewayKeyPolicyEditor: View {
    enum Mode: Equatable {
        case create
        case edit(key: String)
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: GatewayKeysStore
    let mode: Mode
    /// Called with the new key after a successful create (shown once by the caller).
    var onCreated: (String) -> Void = { _ in }

    @State private var draft: GatewayKeyPolicyDraft
    @State private var limitsInvalid = false
    @State private var pinsToDrop: [String] = []
    @State private var providersByModel: [String: [GatewayModelProvider]] = [:]
    @State private var providerErrors: [String: String] = [:]
    @State private var loadingProviders: Set<String> = []
    @State private var saveError: String?
    @State private var isSaving = false

    init(store: GatewayKeysStore, mode: Mode, baseline: GatewayKeyPolicy, onCreated: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.mode = mode
        self.onCreated = onCreated
        _draft = State(initialValue: GatewayKeyPolicyDraft(baseline: baseline))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mode == .create ? "新建调用 API Key" : "编辑 Key 策略")
                .font(.title2.weight(.bold))
                .padding([.horizontal, .top], Oases.Space.xl)
                .padding(.bottom, Oases.Space.m)
            Form {
                basicsSection
                modelsSection
                if showsPins { pinsSection }
                capabilitiesSection
                limitsSection
                expirySection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 640, height: 720)
        .confirmationDialog(
            "清除供应商指定？",
            isPresented: Binding(get: { !pinsToDrop.isEmpty }, set: { if !$0 { pinsToDrop = [] } }),
            titleVisibility: .visible
        ) {
            Button("清除并保存", role: .destructive) {
                draft.dropUnreachablePins()
                pinsToDrop = []
                save()
            }
            Button("取消", role: .cancel) { pinsToDrop = [] }
        } message: {
            Text(OasesLocalization.localizedFormat("保存后，这些模型将不再指定供应商：%@。", pinsToDrop.joined(separator: "、")))
        }
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section {
            TextField("名称", text: $draft.policy.label, prompt: Text("例如：笔记本、CI"))
            Toggle("启用", isOn: $draft.policy.enabled)
            // One line: the gateway removes newlines and other control characters from notes,
            // so they are removed here too (what is shown is what is stored).
            TextField("备注", text: Binding(
                get: { draft.policy.notes },
                set: { draft.policy.notes = GatewayKeyPolicy.normalizedNotes($0) }
            ))
        } footer: {
            if mode == .create {
                Text("Key 由 App 随机生成，创建后只显示一次，请立即复制保存。")
            }
        }
    }

    private var modelsSection: some View {
        Section("模型") {
            Picker("规则", selection: $draft.policyMode) {
                Text("只允许选中的模型").tag(GatewayPolicyMode.allowlist)
                Text("禁止选中的模型").tag(GatewayPolicyMode.denylist)
            }
            if draft.policy.mode == .allowlist {
                Toggle("允许全部模型", isOn: $draft.allowsAllModels)
                if !draft.allowsAllModels {
                    ModelMultiPicker(
                        groupedModels: store.groupedModels,
                        selection: $draft.scopedAllowedModels,
                        disabledGroups: store.disabledProviders
                    )
                    if draft.policy.allowedModels.isEmpty {
                        Text("一个模型都没选：这把 Key 不能调用任何模型。")
                            .font(.caption)
                            .foregroundStyle(Oases.Color.warningText)
                    }
                }
            } else {
                ModelMultiPicker(
                    groupedModels: store.groupedModels,
                    selection: $draft.scopedDeniedModels,
                    disabledGroups: store.disabledProviders
                )
                Text("拒绝列表模式不能指定供应商。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    private var showsPins: Bool {
        draft.policy.mode == .allowlist && !draft.allowsAllModels && !draft.policy.allowedModels.isEmpty
    }

    private var pinsSection: some View {
        Section {
            ForEach(draft.policy.allowedModels, id: \.self) { model in
                pinRow(model)
            }
        } header: {
            Text("按模型指定供应商")
        } footer: {
            Text("“只走这一家”时这家不可用就直接报错；“优先这一家”时会改用其他供应商。")
        }
    }

    @ViewBuilder
    private func pinRow(_ model: String) -> some View {
        if let providers = providersByModel[model] {
            ProviderPinEditor(
                model: model,
                providers: providers,
                pin: Binding(get: { draft.pin(for: model) }, set: { draft.setPin($0, for: model) })
            )
        } else {
            HStack(spacing: Oases.Space.m) {
                Text(model)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .frame(minWidth: 140, alignment: .leading)
                if let pin = draft.pin(for: model) {
                    Text(OasesLocalization.localizedFormat("已指定 %@ · %@", pin.provider, pin.mode == .only ? OasesLocalization.localized("只走这一家") : OasesLocalization.localized("优先这一家")))
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                } else {
                    Text("自动")
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                }
                Spacer()
                if loadingProviders.contains(model) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("选择供应商…") { loadProviders(for: model) }
                        .buttonStyle(.borderless)
                }
            }
            if let error = providerErrors[model] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Oases.Color.dangerText)
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("可用接口") {
            Toggle("Chat Completions（/v1/chat/completions）", isOn: $draft.policy.capabilities.chatCompletions)
            Toggle("Responses（/v1/responses）", isOn: $draft.policy.capabilities.responses)
            Toggle("Messages（/v1/messages）", isOn: $draft.policy.capabilities.messages)
            Toggle("图像生成", isOn: $draft.policy.capabilities.imageGeneration)
            Toggle("联网搜索（会产生第三方搜索费用）", isOn: $draft.policy.capabilities.webSearch)
        }
    }

    private var limitsSection: some View {
        Section {
            LimitFields(rateLimit: $draft.policy.rateLimit, hasError: $limitsInvalid)
        } header: {
            Text("限额")
        } footer: {
            Text("普通 Key 每天 00:00 UTC 恢复；定时恢复只适用于模型包 Key")
        }
    }

    private var expirySection: some View {
        Section("到期") {
            ExpiryPicker(date: $draft.policy.expiresAt)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            let errors = draft.validationErrors()
            if let message = saveError ?? (errors.isEmpty ? nil : errors.joined(separator: "\n")) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Oases.Color.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(mode == .create ? "创建 Key" : "保存") { requestSave() }
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || limitsInvalid || !canSave)
            }
        }
        .padding(Oases.Space.xl)
    }

    private var canSave: Bool {
        let errors = draft.validationErrors()
        // A denylist with pins becomes savable once the user confirms dropping them.
        let onlyPinError = draft.policy.mode == .denylist && errors.count == 1 && !draft.policy.modelProviderPins.isEmpty
        // Editing: nothing to save until a known field differs from the opened policy.
        let hasSomethingToSave = mode == .create || draft.hasChanges
        return hasSomethingToSave && (errors.isEmpty || onlyPinError)
    }

    // MARK: - Actions

    private func requestSave() {
        let dropped = draft.pinsThatWouldBeDropped()
        if !dropped.isEmpty {
            pinsToDrop = dropped
            return
        }
        save()
    }

    private func save() {
        saveError = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            switch mode {
            case .create:
                if let key = await store.addKey(policy: draft.policy) {
                    onCreated(key)
                    dismiss()
                } else {
                    saveError = store.mutationFailureMessage
                }
            case .edit(let key):
                if await store.savePolicy(key: key, draft: draft) {
                    dismiss()
                } else {
                    saveError = store.mutationFailureMessage
                }
            }
        }
    }

    private func loadProviders(for model: String) {
        loadingProviders.insert(model)
        providerErrors[model] = nil
        Task {
            defer { loadingProviders.remove(model) }
            switch await store.pinnableProviders(for: model) {
            case .success(let providers):
                providersByModel[model] = providers
            case .failure(let error):
                providerErrors[model] = error.errorDescription
            }
        }
    }
}

/// Shows a new key once, with a copy button.
struct GatewayNewKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            Text("新 Key 已创建")
                .font(.title2.weight(.bold))
            Text("这是唯一一次显示完整 Key。请立即复制到密码管理器或客户端配置中；之后列表里只显示掩码。")
                .font(.callout)
                .foregroundStyle(Oases.Color.textSecondary)
            Text(key)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(Oases.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .oasesIconTile()
            HStack {
                Button(copied ? "已复制" : "复制 Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Oases.Space.xl)
        .frame(width: 560)
    }
}
