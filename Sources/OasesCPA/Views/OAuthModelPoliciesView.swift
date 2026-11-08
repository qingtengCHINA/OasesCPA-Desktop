import SwiftUI

struct OAuthModelPoliciesCard: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var editorTarget: OAuthModelPolicyEditorTarget?

    private var channels: [String] {
        Set(runtimeDataStore.oauthExcludedModels.keys)
            .union(runtimeDataStore.oauthModelAliases.keys)
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                CardTitle(
                    title: "OAuth 模型规则",
                    subtitle: "按 OAuth 渠道隐藏模型或统一客户端模型名",
                    icon: "arrow.triangle.branch"
                )
                Spacer()
                if runtimeDataStore.isLoadingOAuthModelPolicies {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    runtimeDataStore.refreshOAuthModelPolicies(using: deploymentStore)
                }
                .buttonStyle(.bordered)
                .disabled(
                    deploymentStore.stage != .attached ||
                    runtimeDataStore.isLoadingOAuthModelPolicies
                )

                Button("添加规则渠道", systemImage: "plus") {
                    editorTarget = OAuthModelPolicyEditorTarget(channel: "")
                }
                .buttonStyle(.oasesPrimary)
                .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingOAuthModelPolicies)
            }

            if deploymentStore.stage != .attached {
                InfoBanner(
                    title: "连接后管理 OAuth 模型规则",
                    message: "连接本机或 SSH / VPS 目标后，可按 OAuth 渠道排除上游模型，并为客户端建立稳定的模型别名。",
                    systemImage: "link.badge.plus",
                    tint: .oasesOrange
                )
            } else if channels.isEmpty, !runtimeDataStore.isLoadingOAuthModelPolicies {
                ContentUnavailableView {
                    Label("尚未设置 OAuth 模型规则", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("可创建渠道规则，隐藏不应对外暴露的模型，或把上游模型映射为统一的客户端模型 ID。")
                } actions: {
                    Button("添加规则渠道", systemImage: "plus") {
                        editorTarget = OAuthModelPolicyEditorTarget(channel: "")
                    }
                    .buttonStyle(.oasesPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(channels, id: \.self) { channel in
                        OAuthModelPolicyChannelRow(
                            channel: channel,
                            excludedModelCount: runtimeDataStore.oauthExcludedModels[channel]?.count ?? 0,
                            aliasCount: runtimeDataStore.oauthModelAliases[channel]?.count ?? 0,
                            isSaving: runtimeDataStore.isSavingOAuthModelPolicies,
                            onEdit: {
                                editorTarget = OAuthModelPolicyEditorTarget(channel: channel)
                            }
                        )
                        if channel != channels.last {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .oasesCard()
            }

            if let error = runtimeDataStore.oauthModelPoliciesErrorMessage {
                InfoBanner(
                    title: "OAuth 模型规则读取或保存失败",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            InfoBanner(
                title: "规则直接写入 CLIProxyAPI",
                message: "模型排除与别名分别保存到当前目标的 Management API。编辑已有别名时会保留服务端新增的高级字段；空规则会明确删除该渠道对应的规则。",
                systemImage: "lock.shield",
                tint: .oasesBlue
            )
        }
        .padding(20)
        .oasesCard()
        .sheet(item: $editorTarget) { target in
            OAuthModelPolicyEditorView(
                initialChannel: target.channel,
                initialExcludedModels: runtimeDataStore.oauthExcludedModels[target.channel] ?? [],
                initialAliases: runtimeDataStore.oauthModelAliases[target.channel] ?? [],
                occupiedChannels: Set(channels)
            )
        }
    }
}

private struct OAuthModelPolicyEditorTarget: Identifiable {
    let id = UUID()
    let channel: String
}

private struct OAuthModelPolicyChannelRow: View {
    let channel: String
    let excludedModelCount: Int
    let aliasCount: Int
    let isSaving: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 36, height: 36)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 5) {
                Text(channel)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(OasesLocalization.localized(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if excludedModelCount > 0 {
                StatusPill(
                    title: OasesLocalization.localizedFormat("排除 %lld", excludedModelCount),
                    tint: .oasesOrange,
                    systemImage: "eye.slash"
                )
            }
            if aliasCount > 0 {
                StatusPill(
                    title: OasesLocalization.localizedFormat("别名 %lld", aliasCount),
                    tint: .oasesGreen,
                    systemImage: "arrow.left.arrow.right"
                )
            }

            Button("管理", systemImage: "slider.horizontal.3") {
                onEdit()
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
        }
        .padding(.vertical, 13)
    }

    private var summary: String {
        switch (excludedModelCount, aliasCount) {
        case (0, 0):
            return "尚未保存具体规则"
        case (0, _):
            return OasesLocalization.localizedFormat("%lld 条客户端模型别名", aliasCount)
        case (_, 0):
            return OasesLocalization.localizedFormat("%lld 个模型不会对外暴露", excludedModelCount)
        default:
            return OasesLocalization.localizedFormat("%lld 个模型排除 · %lld 条模型别名", excludedModelCount, aliasCount)
        }
    }
}

private struct OAuthModelPolicyEditorView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.dismiss) private var dismiss

    let initialChannel: String
    let occupiedChannels: Set<String>

    @State private var channel: String
    @State private var excludedModels: [String]
    @State private var savedExcludedModels: [String]
    @State private var newExcludedModel = ""
    @State private var aliases: [RuntimeOAuthModelAliasEntry]
    @State private var savedAliases: [RuntimeOAuthModelAliasEntry]
    @State private var ownsChannel: Bool
    @State private var showExcludedSaveConfirmation = false
    @State private var showAliasSaveConfirmation = false
    @State private var operationError: String?

    init(
        initialChannel: String,
        initialExcludedModels: [String],
        initialAliases: [RuntimeOAuthModelAliasEntry],
        occupiedChannels: Set<String>
    ) {
        self.initialChannel = initialChannel
        self.occupiedChannels = occupiedChannels
        let normalizedChannel = RuntimeOAuthModelPolicyValidator.normalizedChannel(initialChannel)
            ?? initialChannel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedExcludedModels = RuntimeOAuthModelPolicyValidator.normalizedExcludedRules(initialExcludedModels)
        let normalizedAliases = initialAliases.map { $0.normalized() }
        _channel = State(initialValue: normalizedChannel)
        _excludedModels = State(initialValue: normalizedExcludedModels)
        _savedExcludedModels = State(initialValue: normalizedExcludedModels)
        _aliases = State(initialValue: normalizedAliases)
        _savedAliases = State(initialValue: normalizedAliases)
        _ownsChannel = State(initialValue: !normalizedChannel.isEmpty)
    }

    private var normalizedChannel: String? {
        RuntimeOAuthModelPolicyValidator.normalizedChannel(channel)
    }

    private var channelValidationMessage: String? {
        guard let normalizedChannel else {
            return "请填写渠道标识（例如 codex、claude 或 gemini），且不要包含空格或换行。"
        }
        if !ownsChannel, occupiedChannels.contains(normalizedChannel) {
            return "该渠道已有规则。请关闭此窗口后，从规则列表打开它，避免用空白表单覆盖已有设置。"
        }
        return nil
    }

    private var normalizedExcludedModels: [String] {
        RuntimeOAuthModelPolicyValidator.normalizedExcludedRules(excludedModels)
    }

    private var normalizedAliases: [RuntimeOAuthModelAliasEntry] {
        aliases.map { $0.normalized() }
    }

    private var pendingExcludedModel: String? {
        guard let candidate = RuntimeOAuthModelPolicyValidator
            .normalizedExcludedRules([newExcludedModel])
            .first,
              !normalizedExcludedModels.contains(candidate) else {
            return nil
        }
        return candidate
    }

    private var hasExcludedChanges: Bool {
        normalizedExcludedModels != savedExcludedModels
    }

    private var hasAliasChanges: Bool {
        normalizedAliases != savedAliases
    }

    private var aliasValidationMessage: String? {
        channelValidationMessage ?? RuntimeOAuthModelPolicyValidator.validationMessage(for: aliases)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    channelCard
                    excludedModelsCard
                    aliasesCard

                    if let operationError {
                        Label(operationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.oasesRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
            }

            Divider()

            HStack {
                Text("两类规则独立确认并写入，避免一次操作出现部分成功。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
        }
        .frame(minWidth: 690, idealWidth: 760, minHeight: 650, idealHeight: 760)
        .confirmationDialog(
            "保存模型排除规则？",
            isPresented: $showExcludedSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认保存") {
                saveExcludedModels()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(excludedSaveConfirmationMessage)
        }
        .confirmationDialog(
            "保存模型别名？",
            isPresented: $showAliasSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认保存") {
                saveAliases()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(aliasSaveConfirmationMessage)
        }
    }

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("OAuth 渠道", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if ownsChannel {
                    StatusPill(title: "现有规则", tint: .oasesGreen, systemImage: "checkmark.circle")
                } else {
                    StatusPill(title: "新规则", tint: .oasesBlue, systemImage: "plus.circle")
                }
            }

            TextField("渠道标识，例如 codex、claude 或 gemini", text: $channel)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(ownsChannel)

            Text(ownsChannel
                 ? "渠道标识锁定，确保现有规则只更新当前渠道。"
                 : "渠道标识会规范化为小写；首次保存后将锁定，避免误写到其它渠道。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let channelValidationMessage {
                Label(channelValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
            }
        }
        .padding(16)
        .oasesCard()
    }

    private var excludedModelsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("隐藏上游模型", systemImage: "eye.slash")
                        .font(.headline)
                    Text("这些模型不会通过该 OAuth 渠道暴露给客户端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: "(normalizedExcludedModels.count) 个模型",
                    tint: normalizedExcludedModels.isEmpty ? .oasesOrange : .oasesGreen,
                    systemImage: "eye.slash"
                )
            }

            HStack(spacing: 10) {
                TextField("输入要排除的上游模型 ID", text: $newExcludedModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addExcludedModel)
                Button("添加", systemImage: "plus") {
                    addExcludedModel()
                }
                .buttonStyle(.bordered)
                .disabled(pendingExcludedModel == nil)
            }

            if normalizedExcludedModels.isEmpty {
                Text("目前不排除任何模型。添加模型 ID 后再保存即可生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(normalizedExcludedModels, id: \.self) { model in
                        HStack(spacing: 10) {
                            Text(model)
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            Button("移除", systemImage: "minus.circle", role: .destructive) {
                                excludedModels.removeAll { $0 == model }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 8)
                        if model != normalizedExcludedModels.last {
                            Divider()
                        }
                    }
                }
            }

            HStack {
                if let channelValidationMessage {
                    Text(channelValidationMessage)
                        .font(.caption)
                        .foregroundStyle(Color.oasesRed)
                        .lineLimit(2)
                } else if normalizedExcludedModels.isEmpty, !savedExcludedModels.isEmpty {
                    Text("保存空列表会删除该渠道现有的模型排除规则。")
                        .font(.caption)
                        .foregroundStyle(Color.oasesOrange)
                }
                Spacer()
                Button(normalizedExcludedModels.isEmpty ? "清除排除规则" : "保存排除规则") {
                    showExcludedSaveConfirmation = true
                }
                .buttonStyle(.oasesPrimary)
                .disabled(
                    !hasExcludedChanges ||
                    channelValidationMessage != nil ||
                    runtimeDataStore.isSavingOAuthModelPolicies
                )
            }
        }
        .padding(16)
        .oasesCard()
    }

    private var aliasesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("客户端模型别名", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    Text("把上游模型 ID 映射为稳定的客户端模型 ID；可保留显示名称和高级选项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: OasesLocalization.localizedFormat("%lld 条别名", aliases.count),
                    tint: aliases.isEmpty ? .oasesOrange : .oasesGreen,
                    systemImage: "arrow.left.arrow.right"
                )
            }

            if aliases.isEmpty {
                Text("尚未添加模型别名。客户端会继续看到服务端原始模型 ID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            } else {
                ForEach($aliases) { $alias in
                    OAuthModelAliasEditorRow(alias: $alias) {
                        aliases.removeAll { $0.id == alias.id }
                    }
                }
            }

            Button("添加模型别名", systemImage: "plus") {
                aliases.append(RuntimeOAuthModelAliasEntry(name: "", alias: ""))
            }
            .buttonStyle(.bordered)

            if let aliasValidationMessage {
                Label(aliasValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
            } else if aliases.isEmpty, !savedAliases.isEmpty {
                Text("保存空列表会删除该渠道现有的模型别名规则。")
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
            }

            HStack {
                Spacer()
                Button(aliases.isEmpty ? "清除模型别名" : "保存模型别名") {
                    showAliasSaveConfirmation = true
                }
                .buttonStyle(.oasesPrimary)
                .disabled(
                    !hasAliasChanges ||
                    aliasValidationMessage != nil ||
                    runtimeDataStore.isSavingOAuthModelPolicies
                )
            }
        }
        .padding(16)
        .oasesCard()
    }

    private var excludedSaveConfirmationMessage: String {
        let target = normalizedChannel ?? OasesLocalization.localized("当前渠道")
        if normalizedExcludedModels.isEmpty {
            return OasesLocalization.localizedFormat("这会删除 %@ 渠道当前保存的模型排除规则。", target)
        }
        return OasesLocalization.localizedFormat("这会把 %lld 个模型排除规则写入 %@ 渠道。", normalizedExcludedModels.count, target)
    }

    private var aliasSaveConfirmationMessage: String {
        let target = normalizedChannel ?? OasesLocalization.localized("当前渠道")
        if aliases.isEmpty {
            return OasesLocalization.localizedFormat("这会删除 %@ 渠道当前保存的模型别名规则。", target)
        }
        return OasesLocalization.localizedFormat("这会把 %lld 条模型别名写入 %@ 渠道。", aliases.count, target)
    }

    private func addExcludedModel() {
        guard let model = pendingExcludedModel else { return }
        excludedModels.append(model)
        newExcludedModel = ""
    }

    private func saveExcludedModels() {
        guard let target = normalizedChannel else { return }
        let rules = normalizedExcludedModels
        operationError = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.saveOAuthExcludedModels(
                    channel: target,
                    rules: rules,
                    using: deploymentStore
                )
                channel = target
                excludedModels = rules
                savedExcludedModels = rules
                ownsChannel = true
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func saveAliases() {
        guard let target = normalizedChannel else { return }
        let values = normalizedAliases
        operationError = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.saveOAuthModelAliases(
                    channel: target,
                    aliases: values,
                    using: deploymentStore
                )
                channel = target
                aliases = values
                savedAliases = values
                ownsChannel = true
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct OAuthModelAliasEditorRow: View {
    @Binding var alias: RuntimeOAuthModelAliasEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("模型别名", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("移除", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                TextField("上游模型 ID", text: $alias.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("客户端模型 ID", text: $alias.alias)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            TextField("显示名称（可选）", text: $alias.displayName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 18) {
                Toggle("支持 fork", isOn: $alias.fork)
                Toggle("强制映射", isOn: $alias.forceMapping)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
