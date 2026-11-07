import SwiftUI

struct ModelPricesView: View {
    @EnvironmentObject private var appStore: AppStore
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
        for statistic in runtimeDataStore.modelPriceUsageSummary?.models ?? [] {
            let existing = output[statistic.model]
            output[statistic.model] = RuntimeModelPriceUsageStat(
                model: statistic.model,
                calls: (existing?.calls ?? 0) + statistic.calls,
                requestedCalls: (existing?.requestedCalls ?? 0) + statistic.requestedCalls,
                resolvedCalls: (existing?.resolvedCalls ?? 0) + statistic.resolvedCalls
            )
        }
        return output
    }

    private var rows: [ModelPricePresentation] {
        let models = Set(runtimeDataStore.modelPrices.keys).union(Set(usageByModel.keys))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.compactMap { modelID in
            let payload = runtimeDataStore.modelPrices[modelID]
            let usage = usageByModel[modelID]
            let row = ModelPricePresentation(modelID: modelID, payload: payload, usage: usage)
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
        runtimeDataStore.modelPrices.count
    }

    private var missingCount: Int {
        rows.filter { !$0.isConfigured }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageHeader(section: .modelPrices)
                    Spacer()
                    if runtimeDataStore.isLoadingModelPrices {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("高级 CPAMP 面板", systemImage: "rectangle.on.rectangle") {
                        appStore.selectSection(.panel)
                    }
                    .buttonStyle(.bordered)
                    Button("刷新", systemImage: "arrow.clockwise") {
                        runtimeDataStore.refreshModelPrices(using: deploymentStore)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        deploymentStore.stage != .attached ||
                        runtimeDataStore.isLoadingModelPrices ||
                        runtimeDataStore.isSavingModelPrices ||
                        runtimeDataStore.isSyncingModelPrices
                    )
                    Button("立即同步", systemImage: "arrow.triangle.2.circlepath") {
                        syncConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        deploymentStore.stage != .attached ||
                        modelsForSync.isEmpty ||
                        runtimeDataStore.isSavingModelPrices ||
                        runtimeDataStore.isSyncingModelPrices
                    )
                    Button("添加手动价格", systemImage: "plus") {
                        editorTarget = ModelPriceEditorTarget(modelID: "", payload: nil, locksModelID: false)
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(
                        deploymentStore.stage != .attached ||
                        runtimeDataStore.isSavingModelPrices ||
                        runtimeDataStore.isSyncingModelPrices
                    )
                }

                HStack(spacing: 12) {
                    StatusPill(
                        title: "\(configuredCount) 个已计价",
                        tint: configuredCount == 0 ? .oasesOrange : .oasesGreen,
                        systemImage: "dollarsign.circle"
                    )
                    StatusPill(
                        title: "\(usageByModel.count) 个已调用",
                        tint: .oasesBlue,
                        systemImage: "chart.bar"
                    )
                    StatusPill(
                        title: runtimeDataStore.isSyncingModelPrices ? "正在自动计价" : "自动计价已开启",
                        tint: runtimeDataStore.isSyncingModelPrices ? .oasesBlue : .oasesGreen,
                        systemImage: runtimeDataStore.isSyncingModelPrices ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                    )
                    if missingCount > 0 {
                        StatusPill(
                            title: "\(missingCount) 个待补价",
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
                        message: "已保存的价格仍可管理；当前 CPAMP 版本可能尚未提供轻量 usage-summary 接口。\n\(error)",
                        systemImage: "chart.bar.xaxis",
                        tint: .oasesOrange
                    )
                }

                if let error = runtimeDataStore.automaticModelPriceSyncError {
                    InfoBanner(
                        title: "公开价格暂时无法更新",
                        message: "当前成本继续使用最近一次可用价格，App 稍后会自动重试。\n\(error)",
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
            .padding(28)
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
            Text("当前目标 CPAMP 会为 \(modelsForSync.count) 个已配置或已调用模型查询 models.dev、LiteLLM 和 OpenRouter 公开元数据。同步不会自动覆盖存在歧义的模型，且不会修改 CPA 路由或真实 Provider 账单。")
        }
        .confirmationDialog(
            "删除 \(deletingRecord?.modelID ?? "") 的价格？",
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
                                        modelID: row.modelID,
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
    let modelID: String
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
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.modelID)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                    if row.calls > 0 {
                        StatusPill(title: "调用 \(row.calls)", tint: .oasesBlue, systemImage: "chart.bar")
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
        guard let payload = row.payload else { return "尚未配置本地成本估算" }
        return [
            "输入 \(Self.price(payload.prompt))",
            "输出 \(Self.price(payload.completion))",
            "缓存 \(Self.price(payload.cache))"
        ]
        .joined(separator: " · ")
    }

    private var metadataSummary: String {
        guard let payload = row.payload else {
            return row.calls > 0 ? "已有调用记录，可同步公开价格或手动补价" : "可添加手动价格"
        }
        var parts = [payload.source.isEmpty ? "未标记来源" : "来源 \(payload.source)"]
        if !payload.sourceModelID.isEmpty {
            parts.append("上游 \(payload.sourceModelID)")
        }
        if payload.contextTierCount > 0 {
            parts.append("上下文阶梯 \(payload.contextTierCount)")
        }
        if payload.serviceTierCount > 0 {
            parts.append("服务层级 \(payload.serviceTierCount)")
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
            target.payload == nil ? "保存手动价格？" : "覆盖为手动价格？",
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
            return "会把 \(draft.normalizedModelID) 改为手动基础价格，并清除其同步上下文阶梯、服务层级和来源元数据。其它模型价格会在保存前重新读取后保留。"
        }
        return "会把 \(draft.normalizedModelID) 的手动基础价格写入当前目标 CPAMP。其它模型价格会在保存前重新读取后保留。"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(
                    title: "最近一次价格同步",
                    subtitle: result.source ?? "目标 CPAMP 已完成同步请求",
                    icon: "arrow.triangle.2.circlepath"
                )
                Spacer()
                StatusPill(
                    title: "导入 \(result.imported)",
                    tint: result.imported > 0 ? .oasesGreen : .oasesOrange,
                    systemImage: "arrow.down.circle"
                )
                if result.skipped > 0 {
                    StatusPill(title: "跳过 \(result.skipped)", tint: .oasesOrange, systemImage: "forward.end")
                }
            }

            Text(OasesLocalization.localized(summary))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !result.sourceResults.isEmpty {
                HStack(spacing: 8) {
                    ForEach(result.sourceResults, id: \.source) { source in
                        StatusPill(
                            title: source.error == nil ? "\(source.source) \(source.models)" : "\(source.source) 失败",
                            tint: source.error == nil ? .oasesGreen : .oasesOrange,
                            systemImage: source.error == nil ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                    }
                }
            }

            if result.candidateSetCount > 0 || !result.unmatchedModels.isEmpty {
                Text("候选或未匹配模型未被自动写入，避免把不确定的公开价格错误套用到成本估算。可在高级 CPAMP 面板复核候选后再确认。")
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var summary: String {
        var parts = ["同步 \(result.sources.isEmpty ? "公开目录" : result.sources.joined(separator: "、"))"]
        if result.proxyUsed {
            parts.append("使用目标代理")
        }
        if result.candidateSetCount > 0 {
            parts.append("\(result.candidateSetCount) 组候选待核对")
        }
        if !result.unmatchedModels.isEmpty {
            parts.append("\(result.unmatchedModels.count) 个未匹配")
        }
        if !result.preservedModels.isEmpty {
            parts.append("保留 \(result.preservedModels.count) 个既有价格")
        }
        return parts.joined(separator: " · ")
    }
}
