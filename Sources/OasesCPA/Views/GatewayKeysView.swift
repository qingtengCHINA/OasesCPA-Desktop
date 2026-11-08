import AppKit
import SwiftUI

/// The API key page (#2): the call address on top, then the client keys with per-key policies
/// as a table, through the gateway admin API. Keys are masked everywhere; the full key appears
/// only in the one-time sheet after creating it and on the pasteboard after "copy".
struct GatewayKeysView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var appStore: AppStore
    @ObservedObject var store: GatewayKeysStore
    @State private var editorTarget: EditorTarget?
    @State private var createdKey: CreatedKey?
    /// A key created in the editor, shown once the editor sheet has closed.
    @State private var pendingCreatedKey: CreatedKey?
    @State private var keyToDelete: GatewayKeyRow?
    @State private var keyToRename: GatewayKeyRow?
    @State private var renameText = ""
    @State private var selection = Set<GatewayKeyRow.ID>()

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let mode: GatewayKeyPolicyEditor.Mode
        let baseline: GatewayKeyPolicy
    }

    private struct CreatedKey: Identifiable {
        let id = UUID()
        let key: String
    }

    private var baseURL: String { deploymentStore.endpoints.clientAPIBaseURL.absoluteString }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GatewayEndpointHero(
                baseURL: baseURL,
                targetKind: deploymentStore.targetKind,
                isAvailable: deploymentStore.stage == .attached
            )
            .padding(Oases.Space.page)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openCreate() } label: {
                    Label("创建 Key", systemImage: "plus")
                }
                .disabled(store.phase != .loaded || store.isMutating)
                .help(createHelp)
            }
        }
        // The welcome flow's "创建" step asks for the editor (`AppStore.createKeyRequested`); it
        // opens once the keys have loaded and the request never outlives this page.
        .onAppear { consumeCreateRequest() }
        .onChange(of: appStore.createKeyRequested) { _, _ in consumeCreateRequest() }
        .onChange(of: store.phase) { _, _ in consumeCreateRequest() }
        .onDisappear { appStore.createKeyRequested = false }
        .sheet(item: $editorTarget, onDismiss: {
            if let pending = pendingCreatedKey {
                pendingCreatedKey = nil
                createdKey = pending
            }
        }) { target in
            GatewayKeyPolicyEditor(store: store, mode: target.mode, baseline: target.baseline) { key in
                pendingCreatedKey = CreatedKey(key: key)
            }
        }
        .sheet(item: $createdKey) { created in
            GatewayNewKeySheet(key: created.key, baseURL: baseURL)
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("删除 %@？", keyToDelete?.maskedKey ?? ""),
            isPresented: Binding(get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let row = keyToDelete {
                    Task { _ = await store.deleteKey(row.key) }
                }
                keyToDelete = nil
            }
            Button("取消", role: .cancel) { keyToDelete = nil }
        } message: {
            Text("删除后，使用这把 Key 的客户端立即无法调用网关；它的策略一并删除。")
        }
        .alert("重命名 Key", isPresented: Binding(get: { keyToRename != nil }, set: { if !$0 { keyToRename = nil } })) {
            TextField("名称", text: $renameText)
            Button("保存") {
                if let row = keyToRename {
                    let label = renameText
                    Task { _ = await store.setLabel(key: row.key, label: label) }
                }
                keyToRename = nil
            }
            Button("取消", role: .cancel) { keyToRename = nil }
        } message: {
            Text("只改名称，不改这把 Key 的其他策略。")
        }
    }

    private var createHelp: String {
        switch store.phase {
        case .loaded: OasesLocalization.localized("创建一把新的调用 API Key")
        case .loading: OasesLocalization.localized("正在读取 API Key…")
        case .failed: OasesLocalization.localized("读取网关数据失败")
        case .unavailable(let availability): GatewayAccessSummaryCard.unavailableText(availability)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) { store.retryAuthentication() }
                .padding(Oases.Space.page)
        case .loading:
            GatewayLoadingView(title: "正在读取 API Key…")
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
                .padding(Oases.Space.page)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if store.rows.isEmpty {
            // The gateway hides its internal engine key, so an empty list is a normal state.
            OasesEmptyState(
                systemImage: "key.horizontal",
                title: "还没有 API Key",
                message: "客户端（Cursor、Claude Code 等）需要一个 Key 才能调用网关。",
                actionTitle: "创建 Key",
                action: { openCreate() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.actionError {
                    InlineProblem(message: error)
                        .padding(.horizontal, Oases.Space.page)
                        .padding(.vertical, Oases.Space.sm)
                    Divider()
                }
                GatewayKeysTable(
                    rows: store.rows,
                    selection: $selection,
                    isMutating: store.isMutating,
                    onCopy: { OasesPasteboard.copySecret($0.key) },
                    onEdit: { row in editorTarget = EditorTarget(mode: .edit(key: row.key), baseline: row.policy) },
                    onRename: { row in
                        renameText = row.label
                        keyToRename = row
                    },
                    onToggleEnabled: { row in toggleEnabled(row) },
                    onDelete: { row in keyToDelete = row }
                )
            }
        }
    }

    // MARK: - Actions

    private func openCreate() {
        editorTarget = EditorTarget(mode: .create, baseline: .newKeyDefault)
    }

    private func consumeCreateRequest() {
        guard appStore.createKeyRequested, store.phase == .loaded, !store.isMutating, editorTarget == nil else { return }
        appStore.createKeyRequested = false
        openCreate()
    }

    /// 停用 / 启用 is a policy save like the editor's (re-read first, refused when changed elsewhere).
    private func toggleEnabled(_ row: GatewayKeyRow) {
        var draft = GatewayKeyPolicyDraft(baseline: row.policy)
        draft.policy.enabled.toggle()
        Task { _ = await store.savePolicy(key: row.key, draft: draft) }
    }
}

/// The client keys as a native table: name, masked key, models, today's use, status. Rows have
/// a context menu (copy, edit, rename, disable, delete); a double click edits.
struct GatewayKeysTable: View {
    let rows: [GatewayKeyRow]
    @Binding var selection: Set<GatewayKeyRow.ID>
    var isMutating = false
    var onCopy: (GatewayKeyRow) -> Void = { _ in }
    var onEdit: (GatewayKeyRow) -> Void = { _ in }
    var onRename: (GatewayKeyRow) -> Void = { _ in }
    var onToggleEnabled: (GatewayKeyRow) -> Void = { _ in }
    var onDelete: (GatewayKeyRow) -> Void = { _ in }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("名称") { row in
                Text(row.label.isEmpty ? OasesLocalization.localized("未命名 Key") : row.label)
                    .foregroundStyle(row.label.isEmpty ? Oases.Color.textSecondary : Oases.Color.textPrimary)
                    .lineLimit(1)
                    .help(row.policy.notes)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Key") { row in
                Text(row.maskedKey)
                    .font(.body.monospaced())
                    .foregroundStyle(Oases.Color.textSecondary)
                    .privacySensitive()
            }
            .width(min: 110, ideal: 130)
            TableColumn("可用模型") { row in
                Text(Self.scopeText(row.policy))
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            TableColumn("今日用量") { row in
                Text(Self.usageText(row))
                    .monospacedDigit()
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)
            TableColumn("状态") { row in
                GatewayKeyStatusLabel(policy: row.policy)
            }
            .width(min: 80, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: GatewayKeyRow.ID.self) { ids in
            if let row = single(ids) {
                Button("复制 Key") { onCopy(row) }
                Button("编辑…") { onEdit(row) }.disabled(isMutating)
                Button("重命名…") { onRename(row) }.disabled(isMutating)
                Button(row.policy.enabled ? "停用 Key" : "启用 Key") { onToggleEnabled(row) }.disabled(isMutating)
                Divider()
                Button("删除…", role: .destructive) { onDelete(row) }.disabled(isMutating)
            }
        } primaryAction: { ids in
            if let row = single(ids), !isMutating { onEdit(row) }
        }
    }

    private func single(_ ids: Set<GatewayKeyRow.ID>) -> GatewayKeyRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    // MARK: - Texts

    static func scopeText(_ policy: GatewayKeyPolicy) -> String {
        switch policy.mode {
        case .denylist:
            return policy.deniedModels.isEmpty
                ? OasesLocalization.localized("全部模型")
                : OasesLocalization.localizedFormat("全部模型，除了 %lld 个", policy.deniedModels.count)
        case .allowlist:
            if policy.allowedModels.isEmpty {
                return policy.effectiveLegacyDefaultAllow ? OasesLocalization.localized("全部模型") : OasesLocalization.localized("不允许任何模型")
            }
            let pins = policy.modelProviderPins.count
            return pins > 0
                ? OasesLocalization.localizedFormat("%lld 个模型 · %lld 个指定供应商", policy.allowedModels.count, pins)
                : OasesLocalization.localizedFormat("%lld 个模型", policy.allowedModels.count)
        }
    }

    /// Today's tokens (and the daily limit when there is one), and the requests of the last minute
    /// when a rate limit applies.
    static func usageText(_ row: GatewayKeyRow) -> String {
        let used = row.usage?.tokens ?? 0
        var text = row.policy.rateLimit.tokensPerDay.map {
            OasesLocalization.localizedFormat("%@ / %@ Token", compact(used), compact($0))
        } ?? OasesLocalization.localizedFormat("%@ Token", compact(used))
        if let limit = row.policy.rateLimit.requestsPerMinute {
            text += " · " + OasesLocalization.localizedFormat("RPM %lld / %lld", row.usage?.requestsLastMinute ?? 0, limit)
        }
        return text
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: value.formatted()
        }
    }
}

/// Status dot and one word: 启用 / 停用 / 已过期 (the expiry date in the tooltip).
struct GatewayKeyStatusLabel: View {
    let policy: GatewayKeyPolicy

    private var tone: Oases.Tone {
        if policy.isExpired() { return .danger }
        return policy.enabled ? .success : .neutral
    }

    private var title: String {
        if policy.isExpired() { return OasesLocalization.localized("已过期") }
        return policy.enabled ? OasesLocalization.localized("已启用") : OasesLocalization.localized("已停用")
    }

    private var expiry: String {
        guard let date = policy.expiresAt else { return OasesLocalization.localized("不过期") }
        let formatted = date.oasesShortDateTime
        return policy.isExpired()
            ? OasesLocalization.localizedFormat("已于 %@ 过期", formatted)
            : OasesLocalization.localizedFormat("%@ 到期", formatted)
    }

    var body: some View {
        HStack(spacing: Oases.Space.s) {
            StatusDot(tone: tone)
            Text(title)
        }
        .help(expiry)
        .accessibilityElement(children: .combine)
    }
}
