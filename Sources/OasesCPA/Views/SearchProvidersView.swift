import SwiftUI

/// Web search providers (#6): enable, set the third-party API key (SecureField; afterwards only
/// the gateway's hint "…abcd" is shown), daily limit, test, daily usage and the call log. Key
/// fingerprints in the log are not shown.
struct SearchProvidersView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var store: SearchProvidersStore
    @State private var editing: GatewaySearchProvider?
    @State private var testing: GatewaySearchProvider?
    @State private var clearingKey: GatewaySearchProvider?

    init(deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: SearchProvidersStore(provider: deploymentStore))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.l) {
                header
                content
            }
            .padding(Oases.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: reloadKey) {
            if store.isActive { store.refreshNow() } else { store.activate() }
        }
        .onDisappear { store.deactivate() }
        .sheet(item: $editing) { provider in
            SearchProviderEditor(store: store, provider: provider)
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("测试 %@？", testing?.name ?? ""),
            isPresented: Binding(get: { testing != nil }, set: { if !$0 { testing = nil } }),
            titleVisibility: .visible
        ) {
            Button("测试") {
                if let provider = testing { Task { await store.test(provider.id) } }
                testing = nil
            }
            Button("取消", role: .cancel) { testing = nil }
        } message: {
            Text("测试会用已保存的 Key 向服务商发送一次真实请求，可能计入服务商的用量。")
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("删除 %@ 的 API Key？", clearingKey?.name ?? ""),
            isPresented: Binding(get: { clearingKey != nil }, set: { if !$0 { clearingKey = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                if let provider = clearingKey {
                    Task { await store.save(GatewaySearchProviderSave(provider: provider.id, apiKey: .clear)) }
                }
                clearingKey = nil
            }
            Button("取消", role: .cancel) { clearingKey = nil }
        } message: {
            Text("网关会删除保存的 Key，这个服务商随即不能再搜索。")
        }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            Spacer()
            if store.phase == .loading || store.isMutating {
                ProgressView().controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") { store.refreshNow() }
                .buttonStyle(.bordered)
                .disabled(store.phase == .loading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) { store.retryAuthentication() }
        case .loading:
            HStack(spacing: Oases.Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在读取搜索服务商…").foregroundStyle(Oases.Color.textSecondary)
            }
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let error = store.actionError {
            InfoBanner(title: "操作没有完成", message: error, systemImage: "exclamationmark.triangle", tint: Oases.Color.danger)
        }
        Text("Key 需要开启“网络搜索”能力并允许对应服务商，才能通过 /v1/search 使用这些服务商。")
            .font(.callout)
            .foregroundStyle(Oases.Color.textSecondary)
        if store.providers.isEmpty {
            OasesEmptyState(systemImage: "magnifyingglass", title: "网关没有可用的搜索服务商")
        } else {
            OasesRowGroup {
                ForEach(store.providers) { provider in providerRow(provider) }
            }
        }
        logsSection
    }

    // MARK: - Providers

    @ViewBuilder
    private func providerRow(_ provider: GatewaySearchProvider) -> some View {
        HStack(alignment: .top, spacing: Oases.Space.m) {
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                HStack(spacing: Oases.Space.s) {
                    Text(provider.name).font(.callout.weight(.medium))
                    ToneBadge(text: provider.enabled ? OasesLocalization.localized("已启用") : OasesLocalization.localized("已停用"), tone: provider.enabled ? .success : .neutral)
                    if provider.kind == "summary" { ToneBadge(text: "摘要", tone: .info) }
                }
                Text(provider.configured ? OasesLocalization.localizedFormat("Key：%@", provider.keyHint ?? "…") : OasesLocalization.localized("还没有填写 Key"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(provider.configured ? Oases.Color.textSecondary : Oases.Color.warningText)
                Text(limitText(provider))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
                if let result = store.result(for: provider.id) {
                    HStack(spacing: Oases.Space.xs) {
                        StatusDot(tone: result.ok ? .success : .danger)
                        Text(testText(result))
                            .font(.caption)
                            .foregroundStyle(result.ok ? Oases.Color.successText : Oases.Color.dangerText)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: Oases.Space.sm)
            sparkline(provider)
            VStack(alignment: .trailing, spacing: Oases.Space.xs) {
                Toggle("启用", isOn: Binding(
                    get: { provider.enabled },
                    set: { value in Task { await store.save(GatewaySearchProviderSave(provider: provider.id, enabled: value)) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.isMutating)
                .accessibilityLabel(OasesLocalization.localizedFormat("启用 %@", provider.name))
                HStack(spacing: Oases.Space.xs) {
                    Button("设置") { editing = provider }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("测试") { testing = provider }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!provider.configured || store.isMutating)
                    if provider.configured {
                        Button("删除 Key", role: .destructive) { clearingKey = provider }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.isMutating)
                    }
                }
            }
        }
        .padding(.horizontal, Oases.Space.md)
        .padding(.vertical, Oases.Space.sm)
    }

    @ViewBuilder
    private func sparkline(_ provider: GatewaySearchProvider) -> some View {
        let values = store.usage?.requests(of: provider.id) ?? []
        VStack(alignment: .trailing, spacing: Oases.Space.xxs) {
            if values.contains(where: { $0 > 0 }) {
                SparklineView(values: values.map { CGFloat($0) }, tint: Oases.Color.accent)
                    .frame(width: 110)
                    .accessibilityLabel(OasesLocalization.localizedFormat("近 %lld 天共 %lld 次请求", values.count, values.reduce(0, +)))
            }
            Text(OasesLocalization.localizedFormat("今天 %lld 次（失败 %lld）", provider.today.requests, provider.today.failed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Oases.Color.textTertiary)
        }
        .frame(width: 130, alignment: .trailing)
    }

    private func limitText(_ provider: GatewaySearchProvider) -> String {
        if let limit = provider.dailyLimit {
            return OasesLocalization.localizedFormat("每日上限 %lld 次（00:00 UTC 重置）", limit)
        }
        return OasesLocalization.localized("每日不限次数")
    }

    private func testText(_ result: GatewaySearchTestResult) -> String {
        let message = SecretRedactor.redact(result.message, secrets: [])
        let when = result.testedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return result.ok
            ? OasesLocalization.localizedFormat("测试通过 %@", when)
            : OasesLocalization.localizedFormat("测试失败 %@：%@", when, message)
    }

    // MARK: - Logs

    @ViewBuilder
    private var logsSection: some View {
        HStack {
            OasesSectionHeader(title: "调用记录")
            Picker("服务商", selection: Binding(get: { store.logProvider ?? "" }, set: { store.showLogs(of: $0.isEmpty ? nil : $0) })) {
                Text("全部服务商").tag("")
                ForEach(store.providers) { provider in Text(provider.name).tag(provider.id) }
            }
            .fixedSize()
        }
        if store.logs.isEmpty {
            OasesEmptyState(systemImage: "list.bullet.rectangle", title: "还没有搜索调用")
        } else {
            OasesRowGroup {
                ForEach(store.logs) { entry in
                    HStack(spacing: Oases.Space.m) {
                        StatusDot(tone: entry.succeeded ? .success : .danger, size: 8)
                        Text(entry.ts.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Oases.Color.textSecondary)
                            .frame(width: 170, alignment: .leading)
                        Text(providerName(entry.provider))
                            .font(.callout)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                        Text(entry.keyLabel.isEmpty ? OasesLocalization.localized("未命名 Key") : entry.keyLabel)
                            .font(.caption)
                            .foregroundStyle(Oases.Color.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Oases.Space.sm)
                        Text(statusText(entry))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(entry.succeeded ? Oases.Color.textSecondary : Oases.Color.dangerText)
                        if let latency = entry.latencyMs {
                            Text("\(latency) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Oases.Color.textSecondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, Oases.Space.md)
                    .padding(.vertical, Oases.Space.sm)
                }
            }
        }
    }

    private func providerName(_ id: String) -> String {
        store.providers.first { $0.id == id }?.name ?? id
    }

    private func statusText(_ entry: GatewaySearchLogEntry) -> String {
        let status = entry.status.map(String.init) ?? "—"
        guard let code = entry.code, !code.isEmpty else { return status }
        return "\(status) \(code)"
    }
}

/// One provider's settings: enabled, a new API key (typed into a SecureField, sent once, then
/// cleared), the daily limit (empty: no limit).
private struct SearchProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SearchProvidersStore
    let provider: GatewaySearchProvider
    @State private var enabled: Bool
    @State private var newKey = ""
    @State private var limitText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: SearchProvidersStore, provider: GatewaySearchProvider) {
        self.store = store
        self.provider = provider
        _enabled = State(initialValue: provider.enabled)
        _limitText = State(initialValue: provider.dailyLimit.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("启用", isOn: $enabled)
                    LabeledContent("当前 Key", value: provider.configured ? (provider.keyHint ?? "…") : OasesLocalization.localized("未填写"))
                    SecureField("新的 API Key", text: $newKey, prompt: Text(provider.configured ? "留空则保留当前 Key" : "粘贴服务商的 API Key"))
                    TextField("每日上限", text: $limitText, prompt: Text("不限"))
                    Text(OasesLocalization.localizedFormat("服务商建议的每日上限：%lld 次。", provider.defaultDailyLimit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Oases.Color.textSecondary)
                    if case .failure(let error) = LimitFields.parse(limitText) {
                        Text(error.message).font(.caption).foregroundStyle(Oases.Color.dangerText)
                    }
                } header: {
                    Text(provider.name)
                } footer: {
                    Text("Key 只保存在网关上；App 之后只显示末四位提示。")
                }
                if !problems.isEmpty || errorMessage != nil {
                    Section {
                        ForEach(problems, id: \.self) { Text($0).foregroundStyle(Oases.Color.dangerText) }
                        if let errorMessage { Text(errorMessage).foregroundStyle(Oases.Color.dangerText) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("测试新 Key") { Task { await testTypedKey() } }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || store.isMutating)
                Spacer()
                Button("取消") { newKey = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !problems.isEmpty || !limitIsValid)
            }
            .padding(Oases.Space.md)
        }
        .frame(width: 520, height: 440)
    }

    private var limitIsValid: Bool {
        if case .failure = LimitFields.parse(limitText) { return false }
        return true
    }

    private var change: GatewaySearchProviderSave {
        var change = GatewaySearchProviderSave(provider: provider.id)
        if enabled != provider.enabled { change.enabled = enabled }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { change.apiKey = .set(key) }
        if case .success(let limit) = LimitFields.parse(limitText), limit != provider.dailyLimit {
            change.dailyLimit = limit.map(PatchField.set) ?? .clear
        }
        return change
    }

    private var problems: [String] { change.validationErrors() }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let succeeded = await store.save(change)
        newKey = ""
        if succeeded {
            dismiss()
        } else {
            errorMessage = store.mutationFailureMessage
        }
    }

    private func testTypedKey() async {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        errorMessage = nil
        if await store.test(provider.id, apiKey: key) {
            if let result = store.result(for: provider.id) {
                errorMessage = result.ok ? nil : SearchProvidersError.mask(result.message, typedKey: key)
            }
        } else {
            errorMessage = store.mutationFailureMessage
        }
    }
}
