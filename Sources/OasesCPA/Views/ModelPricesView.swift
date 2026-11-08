import SwiftUI

struct ModelPricesView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var search = ""
    @State private var editorTarget: ModelPriceEditorTarget?
    @State private var deletingRecord: RuntimeModelPriceRecord?
    @State private var deleteConfirmationPresented = false
    @State private var syncConfirmationPresented = false
    @State private var operationError: String?

    private var usageByModel: [String: RuntimeModelPriceUsageStat] {
        var output: [String: RuntimeModelPriceUsageStat] = [:]
        // Usage of internal `pin-x/…` ids counts for the public model it stands for.
        for statistic in runtimeDataStore.modelPriceUsageSummary?.models ?? [] {
            let model = InternalModelID.publicName(statistic.model)
            let existing = output[model]
            output[model] = RuntimeModelPriceUsageStat(
                model: model,
                calls: (existing?.calls ?? 0) + statistic.calls,
                requestedCalls: (existing?.requestedCalls ?? 0) + statistic.requestedCalls,
                resolvedCalls: (existing?.resolvedCalls ?? 0) + statistic.resolvedCalls
            )
        }
        return output
    }

    /// The stored price key shown for each public model name: the public name itself when it has
    /// a price, otherwise an older entry stored under one of its internal ids.
    private var priceKeysByModel: [String: String] {
        var output: [String: String] = [:]
        for key in runtimeDataStore.modelPrices.keys.sorted() {
            let model = InternalModelID.publicName(key)
            if key == model || output[model] == nil {
                output[model] = key
            }
        }
        return output
    }

    private var rows: [ModelPricePresentation] {
        let priceKeys = priceKeysByModel
        let models = Set(priceKeys.keys).union(Set(usageByModel.keys))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.compactMap { modelID in
            let priceKey = priceKeys[modelID]
            let payload = priceKey.flatMap { runtimeDataStore.modelPrices[$0] }
            let usage = usageByModel[modelID]
            let row = ModelPricePresentation(modelID: modelID, priceKey: priceKey ?? modelID, payload: payload, usage: usage)
            guard query.isEmpty ||
                    modelID.lowercased().contains(query) ||
                    payload?.source.lowercased().contains(query) == true ||
                    payload?.sourceModelID.lowercased().contains(query) == true else {
                return nil
            }
            return row
        }
        .sorted { left, right in
            if left.isConfigured != right.isConfigured {
                return !left.isConfigured
            }
            if left.calls != right.calls {
                return left.calls > right.calls
            }
            return left.modelID.localizedCaseInsensitiveCompare(right.modelID) == .orderedAscending
        }
    }

    private var modelsForSync: [String] {
        Set(rows.map(\.modelID)).sorted()
    }

    private var configuredCount: Int {
        priceKeysByModel.count
    }

    private var missingCount: Int {
        rows.filter { !$0.isConfigured }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    StatusPill(
                        title: OasesLocalization.localizedFormat("%lld 个已计价", configuredCount),
                        tint: configuredCount == 0 ? .oasesOrange : .oasesGreen,
                        systemImage: "dollarsign.circle"
                    )
                    StatusPill(
                        title: OasesLocalization.localizedFormat("%lld 个已调用", usageByModel.count),
                        tint: .oasesBlue,
                        systemImage: "chart.bar"
                    )
                    StatusPill(
                        title: runtimeDataStore.isSyncingModelPrices ? OasesLocalization.localized("正在自动计价") : OasesLocalization.localized("自动计价已开启"),
                        tint: runtimeDataStore.isSyncingModelPrices ? .oasesBlue : .oasesGreen,
                        systemImage: runtimeDataStore.isSyncingModelPrices ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                    )
                    if missingCount > 0 {
                        StatusPill(
                            title: OasesLocalization.localizedFormat("%lld 个待补价", missingCount),
                            tint: .oasesOrange,
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    if runtimeDataStore.modelPriceUsageSummary?.truncated == true {
                        StatusPill(
                            title: "调用摘要已采样",
                            tint: .oasesOrange,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                    if runtimeDataStore.isLoadingModelPrices {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("正在读取模型价格"))
                    }
                }

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "连接后管理成本估算",
                        message: "连接本机或 SSH / VPS 目标后，可直接读取 CPAMP 的模型价格表与轻量调用摘要。价格只影响本地成本展示，不会修改 CPA 路由或 Provider 账单。",
                        systemImage: "link.badge.plus",
                        tint: .oasesOrange
                    )
                } else if let error = runtimeDataStore.modelPricesErrorMessage, runtimeDataStore.modelPrices.isEmpty {
                    InfoBanner(
                        title: "模型价格读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                } else {
                    priceListCard
                }

                if let error = runtimeDataStore.modelPricesErrorMessage, !runtimeDataStore.modelPrices.isEmpty {
                    InfoBanner(
                        title: "模型价格操作失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                }

                if let error = runtimeDataStore.modelPriceUsageErrorMessage {
                    InfoBanner(
                        title: "调用次数摘要暂不可用",
                        message: OasesLocalization.localizedFormat("已保存的价格仍可管理；当前 CPAMP 版本可能尚未提供轻量 usage-summary 接口。\n%@", error),
                        systemImage: "chart.bar.xaxis",
                        tint: .oasesOrange
                    )
                }

                if let error = runtimeDataStore.automaticModelPriceSyncError {
                    InfoBanner(
                        title: "公开价格暂时无法更新",
                        message: OasesLocalization.localizedFormat("当前成本继续使用最近一次可用价格，App 稍后会自动重试。\n%@", error),
                        systemImage: "arrow.clockwise.circle",
                        tint: .oasesOrange
                    )
                }

                if let operationError {
                    InfoBanner(
                        title: "成本估算操作失败",
                        message: operationError,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                }

                if let result = runtimeDataStore.lastModelPriceSync {
                    ModelPriceSyncResultCard(result: result)
                }

                InfoBanner(
                    title: "价格自动更新，账单仍以服务商为准",
                    message: "App 默认按 models.dev、LiteLLM、OpenRouter 的顺序为已配置或已调用模型补充公开价格。新模型会尽快同步，既有价格每天更新一次；网络失败时保留最近一次可用价格。手动价格只用于特殊别名或内部模型。",
                    systemImage: "lock.shield",
                    tint: .oasesBlue
                )
            }
            .padding(Oases.Space.page)
        }
        // The page's actions live in the toolbar (refresh is the window's ⌘R): one primary
        // action, 添加手动价格, and 立即同步 beside it (it asks first).
        .toolbar {
            ToolbarItem {
                Button { syncConfirmationPresented = true } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(syncDisabledReason != nil)
                .help(syncDisabledReason ?? OasesLocalization.localized("从公开目录同步模型价格"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = ModelPriceEditorTarget(modelID: "", payload: nil, locksModelID: false)
                } label: {
                    Label("添加手动价格", systemImage: "plus")
                }
                .disabled(addDisabledReason != nil)
                .help(addDisabledReason ?? OasesLocalization.localized("添加手动价格"))
            }
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshModelPrices(using: deploymentStore)
        }
        .sheet(item: $editorTarget) { target in
            ModelPriceEditorView(target: target)
        }
        .confirmationDialog(
            "从公开目录同步模型价格？",
            isPresented: $syncConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认同步") {
                syncPrices()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(OasesLocalization.localizedFormat("当前目标 CPAMP 会为 %lld 个已配置或已调用模型查询 models.dev、LiteLLM 和 OpenRouter 公开元数据。同步不会自动覆盖存在歧义的模型，且不会修改 CPA 路由或真实 Provider 账单。", modelsForSync.count))
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("删除 %@ 的价格？", InternalModelID.publicName(deletingRecord?.modelID ?? "")),
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let record = deletingRecord {
                Button("删除本地价格", role: .destructive) {
                    delete(record)
                }
            }
            Button("取消", role: .cancel) {
                deletingRecord = nil
            }
        } message: {
            Text("这只删除 CPAMP 本地成本估算条目，不会停用认证文件、修改 Provider、删除请求历史或改变实际账单。")
        }
    }

    private var addDisabledReason: String? {
        if deploymentStore.stage != .attached { return OasesLocalization.localized("请先连接一个目标环境。") }
        if runtimeDataStore.isSavingModelPrices || runtimeDataStore.isSyncingModelPrices {
            return OasesLocalization.localized("正在保存或同步价格，完成后再试。")
        }
        return nil
    }

    private var syncDisabledReason: String? {
        if let reason = addDisabledReason { return reason }
        if modelsForSync.isEmpty { return OasesLocalization.localized("还没有已配置或已调用的模型。") }
        return nil
    }

    private var priceListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CardTitle(
                    title: "模型价格表",
                    subtitle: "单位：USD / 100 万 Token；调用次数来自轻量摘要",
                    icon: "dollarsign.arrow.circlepath"
                )
                Spacer()
                TextField("搜索模型或来源", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }

            if rows.isEmpty, !runtimeDataStore.isLoadingModelPrices {
                ContentUnavailableView {
                    Label("尚未配置模型价格", systemImage: "dollarsign.circle")
                } description: {
                    Text("添加手动价格，或在已有模型/调用记录后同步公开价格目录。")
                } actions: {
                    Button("添加手动价格", systemImage: "plus") {
                        editorTarget = ModelPriceEditorTarget(modelID: "", payload: nil, locksModelID: false)
                    }
                    .buttonStyle(.oasesPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if rows.isEmpty {
                ProgressView("正在读取模型价格")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ModelPriceRow(
                            row: row,
                            isSaving: runtimeDataStore.isSavingModelPrices || runtimeDataStore.isSyncingModelPrices,
                            onEdit: {
                                editorTarget = ModelPriceEditorTarget(
                                    modelID: row.modelID,
                                    payload: row.payload,
                                    locksModelID: true
                                )
                            },
                            onDelete: row.payload.map { payload in
                                {
                                    deletingRecord = RuntimeModelPriceRecord(
                                        modelID: row.priceKey,
                                        payload: payload
                                    )
                                    deleteConfirmationPresented = true
                                }
                            }
                        )
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private func syncPrices() {
        operationError = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.syncModelPrices(
                    models: modelsForSync,
                    using: deploymentStore
                )
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func delete(_ record: RuntimeModelPriceRecord) {
        operationError = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.deleteModelPrice(record, using: deploymentStore)
                deletingRecord = nil
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct ModelPricePresentation: Identifiable {
    /// The public model name (shown, and used for every new or edited price).
    let modelID: String
    /// The key the shown price is stored under (an internal id only for an older entry).
    let priceKey: String
    let payload: RuntimeModelPricePayload?
    let usage: RuntimeModelPriceUsageStat?

    var id: String { modelID }
    var isConfigured: Bool { payload != nil }
    var calls: Int { usage?.calls ?? 0 }
}

private struct ModelPriceEditorTarget: Identifiable {
    let id = UUID()
    let modelID: String
    let payload: RuntimeModelPricePayload?
    let locksModelID: Bool
}

private struct ModelPriceRow: View {
    let row: ModelPricePresentation
    let isSaving: Bool
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.payload == nil ? "dollarsign.circle" : "dollarsign.circle.fill")
                .font(.title3)
                .foregroundStyle(row.payload == nil ? Oases.Color.warning : Oases.Color.textSecondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.modelID)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                    if row.calls > 0 {
                        StatusPill(title: OasesLocalization.localizedFormat("调用 %lld", row.calls), tint: .oasesBlue, systemImage: "chart.bar")
                    }
                }
                Text(OasesLocalization.localized(priceSummary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(OasesLocalization.localized(metadataSummary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(row.payload == nil ? "补充价格" : "编辑", systemImage: "slider.horizontal.3") {
                onEdit()
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            if let onDelete {
                Menu {
                    Button("覆盖为手动价格", systemImage: "pencil", action: onEdit)
                    Divider()
                    Button("删除本地价格", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .disabled(isSaving)
                .help("更多价格操作")
            }
        }
        .padding(.vertical, 13)
    }

    private var priceSummary: String {
        guard let payload = row.payload else { return OasesLocalization.localized("尚未配置本地成本估算") }
        return [
            OasesLocalization.localizedFormat("输入 %@", Self.price(payload.prompt)),
            OasesLocalization.localizedFormat("输出 %@", Self.price(payload.completion)),
            OasesLocalization.localizedFormat("缓存 %@", Self.price(payload.cache))
        ]
        .joined(separator: " · ")
    }

    private var metadataSummary: String {
        guard let payload = row.payload else {
            return row.calls > 0 ? OasesLocalization.localized("已有调用记录，可同步公开价格或手动补价") : OasesLocalization.localized("可添加手动价格")
        }
        var parts = [payload.source.isEmpty ? OasesLocalization.localized("未标记来源") : OasesLocalization.localizedFormat("来源 %@", payload.source)]
        if !payload.sourceModelID.isEmpty {
            parts.append(OasesLocalization.localizedFormat("上游 %@", payload.sourceModelID))
        }
        if payload.contextTierCount > 0 {
            parts.append(OasesLocalization.localizedFormat("上下文阶梯 %lld", payload.contextTierCount))
        }
        if payload.serviceTierCount > 0 {
            parts.append(OasesLocalization.localizedFormat("服务层级 %lld", payload.serviceTierCount))
        }
        return parts.joined(separator: " · ")
    }

    private static func price(_ value: Double) -> String {
        String(format: "$%.4f / 1M", value)
    }
}

private struct ModelPriceEditorView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.dismiss) private var dismiss

    let target: ModelPriceEditorTarget

    @State private var draft: RuntimeModelPriceDraft
    @State private var saveConfirmationPresented = false
    @State private var operationError: String?

    init(target: ModelPriceEditorTarget) {
        self.target = target
        _draft = State(initialValue: RuntimeModelPriceDraft(modelID: target.modelID, payload: target.payload))
    }

    private var isReplacingSyncedMetadata: Bool {
        target.payload?.hasAdvancedMetadata == true
    }

    private var hasChanges: Bool {
        draft.hasChanges(relativeTo: target.payload)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("模型 ID", text: $draft.modelID, prompt: Text("例如 glm-4.6"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(target.locksModelID)
                    Text(target.locksModelID
                         ? "模型 ID 已锁定；如需新条目，请关闭后使用“添加手动价格”。"
                         : "模型 ID 与 CPA 实际请求模型名一致；可以是别名或内部模型名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("模型")
                }

                Section("基础价格（USD / 100 万 Token）") {
                    TextField("输入价格", text: $draft.prompt, prompt: Text("例如 1.25"))
                        .textFieldStyle(.roundedBorder)
                    TextField("输出价格", text: $draft.completion, prompt: Text("例如 10"))
                        .textFieldStyle(.roundedBorder)
                    TextField("缓存价格", text: $draft.cache, prompt: Text("留空时沿用输入价格"))
                        .textFieldStyle(.roundedBorder)
                    TextField("缓存读取（可选）", text: $draft.cacheRead, prompt: Text("例如 0.125"))
                        .textFieldStyle(.roundedBorder)
                    TextField("缓存写入 / Creation（可选）", text: $draft.cacheCreation, prompt: Text("例如 1.5"))
                        .textFieldStyle(.roundedBorder)
                    Text("留空表示未配置；填写 0 表示明确的零价格。缓存价格留空时会按 CPAMP 规则复制输入价格。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isReplacingSyncedMetadata {
                    Section {
                        Label(
                            "此条目含有同步来源、上下文阶梯或服务层级规则。保存手动价格会清除这些高级计价规则。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Color.oasesOrange)
                    }
                }

                if let validation = draft.validationMessage {
                    Section {
                        Label(validation, systemImage: "exclamationmark.triangle.fill")
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
                Text("手动价格只影响 CPAMP 本地成本估算，不改变真实路由或账单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.payload == nil ? "保存手动价格" : "覆盖为手动价格") {
                    saveConfirmationPresented = true
                }
                .buttonStyle(.oasesPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draft.validationMessage != nil ||
                    !hasChanges ||
                    runtimeDataStore.isSavingModelPrices
                )
            }
            .padding(18)
        }
        .frame(minWidth: 570, idealWidth: 620, minHeight: 540)
        .confirmationDialog(
            target.payload == nil ? OasesLocalization.localized("保存手动价格？") : OasesLocalization.localized("覆盖为手动价格？"),
            isPresented: $saveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认保存") {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(saveConfirmationMessage)
        }
    }

    private var saveConfirmationMessage: String {
        if isReplacingSyncedMetadata {
            return OasesLocalization.localizedFormat("会把 %@ 改为手动基础价格，并清除其同步上下文阶梯、服务层级和来源元数据。其它模型价格会在保存前重新读取后保留。", draft.normalizedModelID)
        }
        return OasesLocalization.localizedFormat("会把 %@ 的手动基础价格写入当前目标 CPAMP。其它模型价格会在保存前重新读取后保留。", draft.normalizedModelID)
    }

    private func save() {
        operationError = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.saveManualModelPrice(draft, using: deploymentStore)
                dismiss()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct ModelPriceSyncResultCard: View {
    let result: RuntimeModelPriceSyncResponse
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var pendingAdoption: PendingAdoption?
    @State private var adoptionError: String?

    private struct PendingAdoption: Identifiable {
        let model: String
        let candidate: RuntimeModelPriceCandidate
        var id: String { model + "\u{0}" + candidate.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(
                    title: "最近一次价格同步",
                    subtitle: result.source ?? OasesLocalization.localized("目标 CPAMP 已完成同步请求"),
                    icon: "arrow.triangle.2.circlepath"
                )
                Spacer()
                StatusPill(
                    title: OasesLocalization.localizedFormat("导入 %lld", result.imported),
                    tint: result.imported > 0 ? .oasesGreen : .oasesOrange,
                    systemImage: "arrow.down.circle"
                )
                if result.skipped > 0 {
                    StatusPill(title: OasesLocalization.localizedFormat("跳过 %lld", result.skipped), tint: .oasesOrange, systemImage: "forward.end")
                }
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !result.sourceResults.isEmpty {
                HStack(spacing: 8) {
                    ForEach(result.sourceResults, id: \.source) { source in
                        StatusPill(
                            title: source.error == nil ? "\(source.source) \(source.models)" : OasesLocalization.localizedFormat("%@ 失败", source.source),
                            tint: source.error == nil ? .oasesGreen : .oasesOrange,
                            systemImage: source.error == nil ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                    }
                }
            }

            if result.candidateSetCount > 0 || !result.unmatchedModels.isEmpty {
                Text("候选或未匹配模型未被自动写入，避免把不确定的公开价格错误套用到成本估算。核对下面的候选后，可逐个采用。")
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
            }

            ForEach(result.candidateSets) { set in
                candidateSetView(set)
            }

            if let adoptionError {
                Label(adoptionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .oasesCard()
        .confirmationDialog(
            pendingAdoption.map {
                OasesLocalization.localizedFormat("采用 %@ 作为 %@ 的价格？", $0.candidate.displaySourceModelID, InternalModelID.publicName($0.model))
            } ?? "",
            isPresented: Binding(
                get: { pendingAdoption != nil },
                set: { if !$0 { pendingAdoption = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAdoption
        ) { pending in
            Button("采用") { adopt(pending) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会替换该模型当前的价格。其它模型价格会在保存前重新读取后保留。")
        }
    }

    @ViewBuilder
    private func candidateSetView(_ set: RuntimeModelPriceCandidateSet) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            Text(verbatim: set.displayModel)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            if set.candidates.isEmpty {
                Text("没有可采用的候选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(set.candidates) { candidate in
                HStack(spacing: Oases.Space.m) {
                    VStack(alignment: .leading, spacing: Oases.Space.xs) {
                        Text(verbatim: candidate.displaySourceModelID)
                            .font(.system(.caption, design: .monospaced))
                        Text(verbatim: candidateDetail(candidate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("采用", systemImage: "checkmark.circle") {
                        adoptionError = nil
                        pendingAdoption = PendingAdoption(model: set.model, candidate: candidate)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtimeDataStore.isSavingModelPrices || deploymentStore.stage != .attached)
                }
            }
        }
        .padding(Oases.Space.m)
    }

    private func candidateDetail(_ candidate: RuntimeModelPriceCandidate) -> String {
        var parts = [
            OasesLocalization.localizedFormat("输入 %@", candidate.price.prompt.formatted()),
            OasesLocalization.localizedFormat("输出 %@", candidate.price.completion.formatted()),
            OasesLocalization.localizedFormat("匹配度 %@", candidate.score.formatted(.percent.precision(.fractionLength(0))))
        ]
        if !candidate.price.source.isEmpty {
            parts.append(OasesLocalization.localizedFormat("来源 %@", candidate.price.source))
        }
        if !candidate.reason.isEmpty {
            parts.append(InternalModelID.publicText(candidate.reason))
        }
        return parts.joined(separator: " · ")
    }

    private func adopt(_ pending: PendingAdoption) {
        Task {
            do {
                try await runtimeDataStore.adoptModelPriceCandidate(
                    pending.candidate,
                    for: pending.model,
                    using: deploymentStore
                )
            } catch {
                adoptionError = error.localizedDescription
            }
        }
    }

    private var summary: String {
        var parts = [OasesLocalization.localizedFormat("同步 %@", result.sources.isEmpty ? OasesLocalization.localized("公开目录") : result.sources.joined(separator: "、"))]
        if result.proxyUsed {
            parts.append(OasesLocalization.localized("使用目标代理"))
        }
        if result.candidateSetCount > 0 {
            parts.append(OasesLocalization.localizedFormat("%lld 组候选待核对", result.candidateSetCount))
        }
        if !result.unmatchedModels.isEmpty {
            parts.append(OasesLocalization.localizedFormat("%lld 个未匹配", result.unmatchedModels.count))
        }
        if !result.preservedModels.isEmpty {
            parts.append(OasesLocalization.localizedFormat("保留 %lld 个既有价格", result.preservedModels.count))
        }
        return parts.joined(separator: " · ")
    }
}
