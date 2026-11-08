import AppKit
import SwiftUI

/// The API key page (#2): client keys with per-key policies, through the gateway admin API.
/// Keys are masked everywhere; the full key appears only in the one-time sheet after creating it
/// and on the pasteboard after "copy".
struct GatewayKeysView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @ObservedObject var store: GatewayKeysStore
    @State private var editorTarget: EditorTarget?
    @State private var createdKey: CreatedKey?
    /// A key created in the editor, shown once the editor sheet has closed.
    @State private var pendingCreatedKey: CreatedKey?
    @State private var keyToDelete: GatewayKeyRow?
    @State private var keyToRename: GatewayKeyRow?
    @State private var renameText = ""
    @State private var copiedMessage: String?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let mode: GatewayKeyPolicyEditor.Mode
        let baseline: GatewayKeyPolicy
    }

    private struct CreatedKey: Identifiable {
        let id = UUID()
        let key: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.l) {
            header
            GatewayEndpointCard(
                baseURL: deploymentStore.endpoints.clientAPIBaseURL.absoluteString,
                targetKind: deploymentStore.targetKind,
                onCopy: { copy($0, message: OasesLocalization.localized("Base URL 已复制")) }
            )
            content
        }
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
            GatewayNewKeySheet(key: created.key)
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            Spacer()
            if store.phase == .loading || store.isMutating {
                ProgressView().controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") { store.refreshNow() }
                .buttonStyle(.bordered)
                .disabled(!isReady || store.phase == .loading)
            Button("新建 API Key", systemImage: "plus") { openCreate() }
                .buttonStyle(.oasesPrimary)
                .disabled(store.phase != .loaded || store.isMutating)
        }
    }

    private var isReady: Bool {
        if case .unavailable = store.phase { return false }
        return true
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) { store.retryAuthentication() }
        case .loading:
            ProgressView("正在读取 API Key…")
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
        case .loaded:
            statusStrip
            if let error = store.actionError {
                InfoBanner(title: "操作未完成", message: error, systemImage: "exclamationmark.triangle", tint: Oases.Color.danger)
            }
            keysCard
        }
    }

    private var statusStrip: some View {
        HStack(spacing: Oases.Space.m) {
            StatusPill(
                title: OasesLocalization.localizedFormat("%lld 个调用 Key", store.rows.count),
                tint: store.rows.isEmpty ? Oases.Color.neutral : Oases.Color.success,
                systemImage: "key.horizontal"
            )
            let expired = store.rows.filter { $0.policy.isExpired() }.count
            if expired > 0 {
                StatusPill(title: OasesLocalization.localizedFormat("%lld 个已过期", expired), tint: Oases.Color.danger)
            }
            Spacer()
            if let copiedMessage {
                Label(copiedMessage, systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.successText)
            }
        }
    }

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            CardTitle(
                title: "调用 API Key",
                subtitle: "每把 Key 有自己的模型、接口、限额和到期设置；列表只显示掩码",
                icon: "key.fill"
            )
            if store.rows.isEmpty {
                // The gateway hides its internal engine key, so an empty list is a normal state.
                OasesEmptyState(
                    systemImage: "key.horizontal",
                    title: "还没有调用 Key",
                    message: "网关自己使用的内部引擎 Key 不在这里显示。创建一把调用 Key 后，客户端即可通过上面的 Base URL 调用网关。",
                    actionTitle: "创建第一个 Key",
                    action: { openCreate() }
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        keyRow(row)
                        if row.id != store.rows.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(Oases.Space.l)
        .oasesCard()
    }

    private func keyRow(_ row: GatewayKeyRow) -> some View {
        let expired = row.policy.isExpired()
        return HStack(spacing: Oases.Space.md) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 32, height: 32)
                .oasesIconTile()
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                HStack(spacing: Oases.Space.s) {
                    Text(row.label.isEmpty ? OasesLocalization.localized("未命名 Key") : row.label)
                        .font(.headline)
                    ToneBadge(text: row.policy.enabled ? OasesLocalization.localized("已启用") : OasesLocalization.localized("已停用"), tone: row.policy.enabled ? .success : .neutral)
                    if expired { ToneBadge(text: "已过期", tone: .danger) }
                }
                Text(row.maskedKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Oases.Color.textSecondary)
                Text(scopeText(row.policy))
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Oases.Space.m)
            VStack(alignment: .trailing, spacing: Oases.Space.xxs) {
                Text(tokensText(row))
                    .font(.caption.monospacedDigit())
                Text(rpmText(row))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
                Text(expiryText(row.policy))
                    .font(.caption2)
                    .foregroundStyle(expired ? Oases.Color.dangerText : Oases.Color.textTertiary)
            }
            Button("复制", systemImage: "doc.on.doc") {
                copy(row.key, message: OasesLocalization.localized("API Key 已复制"))
            }
            .buttonStyle(.bordered)
            Button("编辑") {
                editorTarget = EditorTarget(mode: .edit(key: row.key), baseline: row.policy)
            }
            .buttonStyle(.bordered)
            .disabled(store.isMutating)
            Menu {
                Button("重命名", systemImage: "pencil") {
                    renameText = row.label
                    keyToRename = row
                }
                Button("删除", systemImage: "trash", role: .destructive) { keyToDelete = row }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .disabled(store.isMutating)
            .help(OasesLocalization.localized("更多操作"))
            .accessibilityLabel(OasesLocalization.localizedFormat("%@ 的更多操作", row.label.isEmpty ? row.maskedKey : row.label))
        }
        .padding(.vertical, Oases.Space.m)
    }

    // MARK: - Texts

    private func scopeText(_ policy: GatewayKeyPolicy) -> String {
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

    private func tokensText(_ row: GatewayKeyRow) -> String {
        let used = row.usage?.tokens ?? 0
        if let limit = row.policy.rateLimit.tokensPerDay {
            return OasesLocalization.localizedFormat("今日 Token %@ / %@", Self.compact(used), Self.compact(limit))
        }
        return OasesLocalization.localizedFormat("今日 Token %@", Self.compact(used))
    }

    private func rpmText(_ row: GatewayKeyRow) -> String {
        guard let limit = row.policy.rateLimit.requestsPerMinute else { return OasesLocalization.localized("RPM 不限") }
        return OasesLocalization.localizedFormat("RPM %lld / %lld", row.usage?.requestsLastMinute ?? 0, limit)
    }

    private func expiryText(_ policy: GatewayKeyPolicy) -> String {
        guard let date = policy.expiresAt else { return OasesLocalization.localized("不过期") }
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return policy.isExpired()
            ? OasesLocalization.localizedFormat("已于 %@ 过期", formatted)
            : OasesLocalization.localizedFormat("%@ 到期", formatted)
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: value.formatted()
        }
    }

    // MARK: - Actions

    private func openCreate() {
        editorTarget = EditorTarget(mode: .create, baseline: .newKeyDefault)
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
    }
}
