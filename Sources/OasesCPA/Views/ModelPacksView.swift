import SwiftUI

/// Model packs (#3): packs on the left; the selected pack's members and keys on the right. Pack
/// keys are shown masked (`sk-pk-••••abcd`); the plaintext of new keys only in the one-time sheet.
/// Binding a key to an external account is not offered; a binding is shown and can be removed.
struct ModelPacksView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var store: ModelPacksStore
    @State private var selectedPackID: String?
    @State private var packEditor: PackEditorRoute?
    @State private var keyEditor: KeyEditorRoute?
    @State private var confirmation: Confirmation?
    @State private var showsRevealedKeys = false

    private struct PackEditorRoute: Identifiable {
        let id = UUID()
        let pack: GatewayPack?
    }

    private struct KeyEditorRoute: Identifiable {
        let id = UUID()
        let mode: PackKeyEditor.Mode
    }

    private enum Confirmation: Identifiable {
        case deletePack(GatewayPack)
        case resetUsage(GatewayPackKey)
        case deleteKey(GatewayPackKey)
        case unbindKey(GatewayPackKey)

        var id: String {
            switch self {
            case .deletePack(let pack): "pack-\(pack.id)"
            case .resetUsage(let key): "reset-\(key.id)"
            case .deleteKey(let key): "delete-\(key.id)"
            case .unbindKey(let key): "unbind-\(key.id)"
            }
        }
    }

    init(deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: ModelPacksStore(provider: deploymentStore))
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { packEditor = PackEditorRoute(pack: nil) } label: {
                    Label("新建模型包", systemImage: "plus")
                }
                .disabled(createPackDisabledReason != nil)
                .help(createPackDisabledReason ?? OasesLocalization.localized("新建模型包"))
            }
        }
        .onChange(of: store.packs) { _, packs in
            if selectedPackID == nil || !packs.contains(where: { $0.id == selectedPackID }) {
                selectedPackID = packs.first?.id
            }
        }
        .sheet(item: $packEditor) { route in
            ModelPackEditor(store: store, pack: route.pack)
        }
        // The one-time sheet opens from the editor's onDismiss (after the editor is gone), so it
        // never competes with the editor sheet; closing it forgets the plaintext.
        .sheet(item: $keyEditor, onDismiss: presentRevealedKeysIfAny) { route in
            PackKeyEditor(store: store, mode: route.mode)
        }
        .sheet(isPresented: $showsRevealedKeys, onDismiss: { store.dismissRevealedKeys() }) {
            PackKeysRevealSheet(keys: store.revealedKeys) { showsRevealedKeys = false }
                .interactiveDismissDisabled()
        }
        .onChange(of: store.revealedKeys) { _, keys in
            if keys.isEmpty {
                showsRevealedKeys = false
            } else if keyEditor == nil {
                showsRevealedKeys = true
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            confirmationButtons
        } message: {
            Text(confirmationMessage)
        }
    }

    private func presentRevealedKeysIfAny() {
        if !store.revealedKeys.isEmpty { showsRevealedKeys = true }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }

    // MARK: - Header and states

    /// Only the activity of a save; reading again is the window's refresh (⌘R) and 新建模型包
    /// is the toolbar's primary action.
    @ViewBuilder
    private var header: some View {
        if store.isMutating {
            HStack(spacing: Oases.Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在保存…").foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    private var createPackDisabledReason: String? {
        guard store.phase == .loaded else { return OasesLocalization.localized("模型包读取完成后才能新建。") }
        guard store.storeAvailable else { return OasesLocalization.localized("网关的模型包存储暂时不可用。") }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) { store.retryAuthentication() }
        case .loading:
            HStack(spacing: Oases.Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在读取模型包…").foregroundStyle(Oases.Color.textSecondary)
            }
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if !store.engineKeyReady {
            InfoBanner(title: "模型包 Key 暂时无法使用", message: "网关缺少内部引擎 Key（或它不在引擎的 api-keys 里），模型包请求会失败。请检查部署是否完整。", systemImage: "exclamationmark.triangle", tint: Oases.Color.warning)
        }
        if !store.storeAvailable {
            InfoBanner(title: "模型包数据不可用", message: "网关无法读取或写入模型包数据，模型包 Key 已暂停服务。请检查网关数据目录。", systemImage: "externaldrive.badge.exclamationmark", tint: Oases.Color.danger)
        } else if store.persistenceFailing {
            InfoBanner(title: "模型包用量暂时无法保存", message: "网关正在重试写入；持续失败两分钟后模型包 Key 会暂停服务。", systemImage: "exclamationmark.arrow.triangle.2.circlepath", tint: Oases.Color.warning)
        }
        if let error = store.actionError {
            InfoBanner(title: "操作没有完成", message: error, systemImage: "exclamationmark.triangle", tint: Oases.Color.danger)
        }
        if store.packs.isEmpty {
            OasesEmptyState(
                systemImage: "square.stack.3d.up",
                title: "还没有模型包",
                message: "模型包把几个模型合成一个对外模型名，并可以发放带额度和到期时间的 Key。",
                actionTitle: store.storeAvailable ? OasesLocalization.localized("新建模型包") : nil,
                action: store.storeAvailable ? { packEditor = PackEditorRoute(pack: nil) } : nil
            )
        } else {
            HStack(alignment: .top, spacing: Oases.Space.l) {
                packList
                    .frame(width: 240)
                if let pack = store.pack(id: selectedPackID) {
                    packDetail(pack)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Pack list

    private var packList: some View {
        OasesRowGroup {
            ForEach(store.packs) { pack in
                Button {
                    selectedPackID = pack.id
                } label: {
                    HStack(spacing: Oases.Space.sm) {
                        VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                            Text(pack.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Oases.Color.textPrimary)
                                .lineLimit(1)
                            Text(pack.modelID)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Oases.Color.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Oases.Space.xs)
                        if !pack.enabled { ToneBadge(text: "已停用", tone: .warning) }
                        Text("\(pack.activeKeyCount)/\(pack.keyCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Oases.Color.textTertiary)
                            .help("可用 Key / 全部 Key")
                    }
                    .padding(.horizontal, Oases.Space.m)
                    .padding(.vertical, Oases.Space.sm)
                    .contentShape(Rectangle())
                    .background(selectedPackID == pack.id ? Oases.Color.washStrong : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPackID == pack.id ? .isSelected : [])
            }
        }
    }

    // MARK: - Pack detail

    @ViewBuilder
    private func packDetail(_ pack: GatewayPack) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Oases.Space.xs) {
                    Text(pack.name).font(.title3.weight(.semibold))
                    Text(OasesLocalization.localizedFormat("对外模型名：%@ · %@", pack.modelID, pack.mode.title))
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("编辑", systemImage: "slider.horizontal.3") { packEditor = PackEditorRoute(pack: pack) }
                    .buttonStyle(.bordered)
                    .disabled(store.isMutating)
                Button("删除", systemImage: "trash", role: .destructive) { confirmation = .deletePack(pack) }
                    .buttonStyle(.bordered)
                    .disabled(store.isMutating)
            }

            OasesSectionHeader(title: "成员模型", trailing: OasesLocalization.localizedFormat("超时 %lld ms · 最多尝试 %lld 个", pack.failover.firstByteTimeoutMs, pack.failover.maxAttempts))
            OasesRowGroup {
                ForEach(Array(pack.members.enumerated()), id: \.offset) { index, member in
                    HStack {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Oases.Color.textTertiary)
                        Text(member.model).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(priceText(member))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(member.isPriced ? Oases.Color.textSecondary : Oases.Color.warningText)
                    }
                    .padding(.horizontal, Oases.Space.md)
                    .padding(.vertical, Oases.Space.sm)
                }
            }

            HStack {
                OasesSectionHeader(title: "模型包 Key")
                Button("新建 Key", systemImage: "plus") { keyEditor = KeyEditorRoute(mode: .create(pack)) }
                    .buttonStyle(.bordered)
                    .disabled(store.isMutating || !store.storeAvailable)
            }
            let keys = store.keysByPack[pack.id] ?? []
            if keys.isEmpty {
                OasesEmptyState(systemImage: "key", title: "这个模型包还没有 Key", message: "新建的 Key 只显示一次完整内容，请当场复制保存。")
            } else {
                OasesRowGroup {
                    ForEach(keys) { key in keyRow(key, pack: pack) }
                }
            }
        }
    }

    private func priceText(_ member: GatewayPackMember) -> String {
        guard member.isPriced, let input = member.inputUSDPer1M, let output = member.outputUSDPer1M else {
            return OasesLocalization.localized("未配置价格")
        }
        return OasesLocalization.localizedFormat("输入 $%@ / 输出 $%@ 每百万 Token",
                                                 NSDecimalNumber(decimal: input).stringValue, NSDecimalNumber(decimal: output).stringValue)
    }

    @ViewBuilder
    private func keyRow(_ key: GatewayPackKey, pack: GatewayPack) -> some View {
        HStack(alignment: .top, spacing: Oases.Space.m) {
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                HStack(spacing: Oases.Space.s) {
                    Text(key.label.isEmpty ? OasesLocalization.localized("未命名 Key") : key.label)
                        .font(.callout.weight(.medium))
                    ToneBadge(text: key.status.title, tone: tone(key.status))
                    if key.bound {
                        ToneBadge(text: "已绑定", tone: .info)
                    }
                }
                Text(key.maskedKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Oases.Color.textSecondary)
                Text(usageText(key))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
                if let expires = key.expiresAt {
                    Text(OasesLocalization.localizedFormat("到期：%@", expires.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(expires <= Date() ? Oases.Color.dangerText : Oases.Color.textTertiary)
                }
                if let next = key.reset?.nextResetAt {
                    Text(OasesLocalization.localizedFormat("下次恢复：%@", next.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Oases.Color.textTertiary)
                }
                if key.bound, let boundAt = key.boundAt {
                    Text(OasesLocalization.localizedFormat("绑定于 %@", boundAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Oases.Color.textTertiary)
                }
            }
            Spacer()
            Menu {
                Button("编辑", systemImage: "slider.horizontal.3") { keyEditor = KeyEditorRoute(mode: .edit(key, pack)) }
                Button("清零用量", systemImage: "arrow.counterclockwise") { confirmation = .resetUsage(key) }
                if key.bound {
                    Button("解绑", systemImage: "link.badge.plus") { confirmation = .unbindKey(key) }
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) { confirmation = .deleteKey(key) }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isMutating)
            .help("更多操作")
            .accessibilityLabel(OasesLocalization.localizedFormat("%@ 的操作", key.label.isEmpty ? key.maskedKey : key.label))
        }
        .padding(.horizontal, Oases.Space.md)
        .padding(.vertical, Oases.Space.sm)
    }

    private func tone(_ status: GatewayPackKeyStatus) -> Oases.Tone {
        switch status {
        case .active: .success
        case .disabled: .neutral
        case .expired, .exhausted: .danger
        case .other: .warning
        }
    }

    private func usageText(_ key: GatewayPackKey) -> String {
        let tokens = key.limits.totalTokens.map { OasesLocalization.localizedFormat("Token %lld / %lld", key.usage.tokens, $0) }
            ?? OasesLocalization.localizedFormat("Token %lld（不限）", key.usage.tokens)
        let used = NSDecimalNumber(decimal: key.usage.costUSD).doubleValue.formatted(.number.precision(.fractionLength(0...4)))
        let cost = key.limits.totalCostUSD.map { OasesLocalization.localizedFormat("花费 $%@ / $%@", used, NSDecimalNumber(decimal: $0).stringValue) }
            ?? OasesLocalization.localizedFormat("花费 $%@（不限）", used)
        return "\(tokens) · \(cost) · " + OasesLocalization.localizedFormat("%lld 次请求", key.usage.requests)
    }

    // MARK: - Confirmations

    private var confirmationTitle: String {
        switch confirmation {
        case .deletePack(let pack)?: OasesLocalization.localizedFormat("删除模型包 %@？", pack.name)
        case .resetUsage?: OasesLocalization.localized("清零这把 Key 的用量？")
        case .deleteKey?: OasesLocalization.localized("删除这把 Key？")
        case .unbindKey?: OasesLocalization.localized("解除这把 Key 的绑定？")
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .deletePack?: OasesLocalization.localized("模型包和它的全部 Key 都会删除，使用这些 Key 的客户端会立即失效。")
        case .resetUsage?: OasesLocalization.localized("本周期用量并入累计，额度立即重新开始；定时恢复的时间不变。")
        case .deleteKey?: OasesLocalization.localized("使用这把 Key 的客户端会立即失效，无法恢复。")
        case .unbindKey?: OasesLocalization.localized("解除与外部账号的绑定，并删除网关为它保存的密封副本。Key 本身仍然可用。")
        case nil: ""
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmation {
        case .deletePack(let pack)?:
            Button("删除", role: .destructive) { run { await store.deletePack(id: pack.id) } }
        case .resetUsage(let key)?:
            Button("清零用量") { run { await store.resetUsage(keyID: key.id) } }
        case .deleteKey(let key)?:
            Button("删除", role: .destructive) { run { await store.deleteKey(keyID: key.id) } }
        case .unbindKey(let key)?:
            Button("解绑") { run { await store.unbindKey(keyID: key.id) } }
        case nil:
            EmptyView()
        }
        Button("取消", role: .cancel) { confirmation = nil }
    }

    private func run(_ action: @escaping @MainActor () async -> Bool) {
        confirmation = nil
        Task { _ = await action() }
    }
}
