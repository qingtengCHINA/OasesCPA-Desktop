import SwiftUI

struct InspectionView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var search = ""
    @State private var resultFilter: InspectionResultFilter = .all
    @State private var showLogs = true
    @State private var selectedResult: RuntimeCodexInspectionResult?
    @State private var pendingConfirmation: InspectionConfirmation?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !isConnected {
                    InfoBanner(
                        title: "连接目标环境后使用凭证健康巡检",
                        message: "巡检由当前目标的 CPA Manager Plus Full Mode 执行。请先连接本机或 SSH / VPS 上的 CLIProxyAPI 与 CPAMP。",
                        systemImage: "link.badge.plus",
                        tint: .oasesOrange
                    )
                } else {
                    safetyBanner
                    policyCard

                    if let error = runtimeDataStore.codexInspectionErrorMessage {
                        InfoBanner(
                            title: "巡检数据读取或操作失败",
                            message: error,
                            systemImage: "exclamationmark.triangle",
                            tint: .oasesOrange
                        )
                    }

                    inspectionContent
                }
            }
            .padding(28)
        }
        .task(id: connectionTaskID) {
            guard isConnected else { return }
            runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
            runtimeDataStore.refreshCodexInspectionRuns(using: deploymentStore)
        }
        .task(id: activePollingKey) {
            guard activePollingRunID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                runtimeDataStore.refreshCodexInspectionRuns(
                    using: deploymentStore,
                    silently: true
                )
            }
        }
        .sheet(item: $selectedResult) { result in
            InspectionResultDetailSheet(result: result)
        }
        .alert(
            pendingConfirmation?.title ?? OasesLocalization.localized("确认操作"),
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button(
                confirmation.confirmTitle,
                role: confirmation.isDestructive ? .destructive : nil
            ) {
                apply(confirmation)
            }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("凭证健康巡检操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? OasesLocalization.localized("未知错误"))
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageHeader(section: .codexInspection)
            Spacer()

            Button("巡检策略", systemImage: "slider.horizontal.3") {
                store.selectSection(.config)
            }
            .buttonStyle(.bordered)
            .help("在原生配置页调整巡检范围、定时策略和自动处理规则")

            Button("刷新", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshManagerConfiguration(using: deploymentStore)
                runtimeDataStore.refreshCodexInspectionRuns(using: deploymentStore)
            }
            .buttonStyle(.bordered)
            .disabled(
                !isConnected ||
                    runtimeDataStore.isLoadingCodexInspectionRuns ||
                    runtimeDataStore.isStartingCodexInspection ||
                    runtimeDataStore.isCancellingCodexInspection
            )

            Button("开始巡检", systemImage: "play.fill") {
                pendingConfirmation = .start(policy: inspectionPolicy)
            }
            .buttonStyle(.oasesPrimary)
            .tint(inspectionPolicy.isMutationCapable ? .oasesOrange : .oasesBlue)
            .disabled(!canStart)
        }
    }

    private var safetyBanner: some View {
        InfoBanner(
            title: "打开本页不会主动探测 Provider",
            message: "这里只读取 CPAMP 已保存的巡检历史、结果与日志。只有在你确认“开始巡检”后，目标服务才会使用认证文件向 Codex / xAI 等 Provider 进行真实健康检查。",
            systemImage: "checkmark.shield",
            tint: .oasesBlue
        )
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "当前巡检策略",
                    subtitle: inspectionPolicy.subtitle,
                    icon: inspectionPolicy.isMutationCapable
                        ? "exclamationmark.shield"
                        : "eye"
                )
                Spacer()
                if runtimeDataStore.isLoadingManagerConfiguration {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    StatusPill(
                        title: inspectionPolicy.title,
                        tint: inspectionPolicy.tint,
                        systemImage: inspectionPolicy.isMutationCapable
                            ? "exclamationmark.triangle"
                            : "eye"
                    )
                }
            }

            if inspectionPolicy.isLoaded {
                HStack(alignment: .top, spacing: 20) {
                    InspectionPolicyFact(
                        title: "巡检目标",
                        value: inspectionPolicy.targets.isEmpty
                            ? "Codex"
                            : inspectionPolicy.targets.joined(separator: " · ")
                    )
                    InspectionPolicyFact(
                        title: "并发检查",
                        value: inspectionPolicy.workers > 0
                            ? OasesLocalization.localizedFormat("%lld 个", inspectionPolicy.workers)
                            : "服务端默认"
                    )
                    InspectionPolicyFact(
                        title: "采样",
                        value: inspectionPolicy.sampleSize > 0
                            ? OasesLocalization.localizedFormat("%lld 个账号", inspectionPolicy.sampleSize)
                            : "全部账号"
                    )
                    InspectionPolicyFact(
                        title: "自动恢复",
                        value: inspectionPolicy.autoRecoverEnabled ? OasesLocalization.localized("已开启") : OasesLocalization.localized("未开启")
                    )
                }

                if inspectionPolicy.isMutationCapable {
                    Label(
                        inspectionPolicy.mutationWarning,
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(inspectionPolicy.tint)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("当前策略为仅记录。仍会向 Provider 发送健康检查请求，但不会按策略自动禁用、启用或删除认证文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("正在读取 CPAMP Manager Config。为避免在未知自动动作策略下运行巡检，读取完成前不能启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .oasesCard()
    }

    @ViewBuilder
    private var inspectionContent: some View {
        if runtimeDataStore.codexInspectionRuns.isEmpty,
           !runtimeDataStore.isLoadingCodexInspectionRuns {
            ContentUnavailableView {
                Label("还没有巡检历史", systemImage: "checkmark.shield")
            } description: {
                Text("开始一次手动巡检后，CPAMP 会保存结果、建议和运行日志；本页随后会自动跟踪其状态。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .padding(24)
            .oasesCard()
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    historyCard
                        .frame(minWidth: 274, idealWidth: 300, maxWidth: 332)
                    detailCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 18) {
                    historyCard
                    detailCard
                }
            }
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "运行历史",
                    subtitle: OasesLocalization.localizedFormat("%lld 个最近任务", runtimeDataStore.codexInspectionRuns.count),
                    icon: "clock.arrow.circlepath"
                )
                Spacer()
                if runtimeDataStore.isLoadingCodexInspectionRuns {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if runtimeDataStore.codexInspectionRuns.isEmpty {
                Text("正在读取历史记录…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                VStack(spacing: 8) {
                    ForEach(runtimeDataStore.codexInspectionRuns) { run in
                        InspectionRunRow(
                            run: run,
                            isSelected: run.id == runtimeDataStore.selectedCodexInspectionRunID
                        ) {
                            runtimeDataStore.selectCodexInspectionRun(
                                run.id,
                                using: deploymentStore
                            )
                        }
                    }
                }
            }
        }
        .padding(18)
        .oasesCard()
    }

    @ViewBuilder
    private var detailCard: some View {
        if runtimeDataStore.isLoadingCodexInspectionDetail,
           runtimeDataStore.codexInspectionDetail == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取巡检详情")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .padding(20)
            .oasesCard()
        } else if let detail = runtimeDataStore.codexInspectionDetail {
            InspectionRunDetailView(
                detail: detail,
                search: $search,
                filter: $resultFilter,
                showLogs: $showLogs,
                selectedResult: $selectedResult,
                onOpenAuthFiles: {
                    store.selectSection(.authFiles)
                },
                onCancel: detail.run.isCancellable
                    ? { pendingConfirmation = .cancel(run: detail.run) }
                    : nil,
                isCancelling: runtimeDataStore.isCancellingCodexInspection &&
                    runtimeDataStore.codexInspectionMutatingRunID == detail.run.id
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("选择一条历史记录")
                    .font(.headline)
                Text("运行详情会展示 Provider 结果、配额窗口、建议动作和服务端日志。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .padding(20)
            .oasesCard()
        }
    }

    private var isConnected: Bool {
        deploymentStore.stage == .attached && !deploymentStore.cpampAdminKey.isEmpty
    }

    private var connectionTaskID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpampBaseURL.absoluteString)"
    }

    private var inspectionPolicy: InspectionPolicyPresentation {
        InspectionPolicyPresentation(
            config: runtimeDataStore.managerConfiguration?.config.codexInspection,
            isLoaded: runtimeDataStore.managerConfiguration != nil &&
                runtimeDataStore.managerConfigurationErrorMessage == nil &&
                !runtimeDataStore.isLoadingManagerConfiguration
        )
    }

    private var canStart: Bool {
        isConnected &&
            inspectionPolicy.isLoaded &&
            !runtimeDataStore.hasActiveCodexInspectionRun &&
            !runtimeDataStore.isStartingCodexInspection &&
            !runtimeDataStore.isCancellingCodexInspection
    }

    private var activePollingRunID: Int64? {
        if let detail = runtimeDataStore.codexInspectionDetail, detail.run.isActive {
            return detail.run.id
        }
        return runtimeDataStore.codexInspectionRuns.first(where: \.isActive)?.id
    }

    private var activePollingKey: String {
        guard let activePollingRunID else { return "\(connectionTaskID)|idle" }
        return "\(connectionTaskID)|\(activePollingRunID)"
    }

    private func apply(_ confirmation: InspectionConfirmation) {
        Task {
            do {
                switch confirmation {
                case .start:
                    _ = try await runtimeDataStore.startCodexInspection(
                        using: deploymentStore
                    )
                case .cancel(let run):
                    _ = try await runtimeDataStore.cancelCodexInspectionRun(
                        run,
                        using: deploymentStore
                    )
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private enum InspectionResultFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case actions
    case quota
    case handled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: OasesLocalization.localized("全部")
        case .attention: OasesLocalization.localized("需关注")
        case .actions: OasesLocalization.localized("待处理建议")
        case .quota: OasesLocalization.localized("配额")
        case .handled: OasesLocalization.localized("已处理")
        }
    }
}

private enum InspectionConfirmation: Identifiable {
    case start(policy: InspectionPolicyPresentation)
    case cancel(run: RuntimeCodexInspectionRun)

    var id: String {
        switch self {
        case .start: "start"
        case .cancel(let run): "cancel-\(run.id)"
        }
    }

    var title: String {
        switch self {
        case .start: OasesLocalization.localized("开始凭证健康巡检？")
        case .cancel: OasesLocalization.localized("取消正在运行的巡检？")
        }
    }

    var confirmTitle: String {
        switch self {
        case .start: OasesLocalization.localized("开始巡检")
        case .cancel: OasesLocalization.localized("确认取消")
        }
    }

    var isDestructive: Bool {
        switch self {
        case .start(let policy): policy.isDestructive
        case .cancel: true
        }
    }

    var message: String {
        switch self {
        case .start(let policy):
            let baseline = OasesLocalization.localized("CPAMP 会在当前目标上使用已有认证文件向对应 Provider 发起真实健康检查；认证令牌不会回传到 App。")
            if policy.isMutationCapable {
                return OasesLocalization.localizedFormat("%@\n\n%@\n\n请确认这是你希望操作的目标环境后继续。", baseline, policy.mutationWarning)
            }
            return OasesLocalization.localizedFormat("%@\n\n当前策略为仅记录，不会按巡检策略自动修改认证文件。", baseline)
        case .cancel(let run):
            return OasesLocalization.localizedFormat("将向 CPAMP 请求取消运行 #%lld。已经发出的 Provider 检查可能会完成，已有日志和结果会保留在历史记录中。", run.id)
        }
    }
}

private struct InspectionPolicyPresentation: Equatable {
    let isLoaded: Bool
    let mode: String
    let autoRecoverEnabled: Bool
    let targets: [String]
    let workers: Int
    let sampleSize: Int

    init(config: RuntimeCodexInspectionConfig?, isLoaded: Bool) {
        self.isLoaded = isLoaded
        mode = config?.autoActionMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "none"
        autoRecoverEnabled = config?.autoRecoverEnabled ?? false
        let configuredTargets = config?.targetTypes.filter { !$0.isEmpty } ?? []
        if configuredTargets.isEmpty,
           let target = config?.targetType.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            targets = [target]
        } else {
            targets = configuredTargets
        }
        workers = config?.workers ?? 0
        sampleSize = config?.sampleSize ?? 0
    }

    var normalizedMode: String {
        ["none", "enable", "disable", "delete"].contains(mode) ? mode : "none"
    }

    var hasUnknownMode: Bool {
        !mode.isEmpty && !["none", "enable", "disable", "delete"].contains(mode)
    }

    var title: String {
        guard isLoaded else { return OasesLocalization.localized("正在读取策略") }
        if hasUnknownMode { return OasesLocalization.localized("未知自动动作") }
        if normalizedMode == "delete" { return OasesLocalization.localized("自动删除已配置") }
        if normalizedMode == "disable" { return OasesLocalization.localized("自动禁用已配置") }
        if normalizedMode == "enable" || autoRecoverEnabled { return OasesLocalization.localized("自动恢复已配置") }
        return OasesLocalization.localized("仅记录")
    }

    var subtitle: String {
        guard isLoaded else { return OasesLocalization.localized("读取成功后才允许启动，避免未知的自动动作策略。") }
        if isMutationCapable {
            return OasesLocalization.localized("这次巡检可能按 CPAMP 当前策略修改认证文件状态。")
        }
        return OasesLocalization.localized("只保存健康检查结果、建议和日志。")
    }

    var isMutationCapable: Bool {
        hasUnknownMode || normalizedMode != "none" || autoRecoverEnabled
    }

    var isDestructive: Bool {
        normalizedMode == "delete"
    }

    var tint: Color {
        if normalizedMode == "delete" { return .oasesRed }
        if isMutationCapable { return .oasesOrange }
        return .oasesGreen
    }

    var mutationWarning: String {
        var actions: [String] = []
        switch normalizedMode {
        case "delete":
            actions.append(OasesLocalization.localized("删除符合 CPAMP 规则且通过稳定身份核验的认证文件"))
        case "disable":
            actions.append(OasesLocalization.localized("禁用符合 CPAMP 规则的认证文件"))
        case "enable":
            actions.append(OasesLocalization.localized("启用满足恢复条件的认证文件"))
        default:
            if hasUnknownMode {
                actions.append(OasesLocalization.localized("执行当前 CPAMP 版本定义的未知自动动作"))
            }
            break
        }
        if autoRecoverEnabled {
            actions.append(OasesLocalization.localized("恢复由巡检自身禁用且已明确恢复的认证文件"))
        }
        let detail = actions.isEmpty ? OasesLocalization.localized("修改认证文件状态") : actions.joined(separator: "；")
        return OasesLocalization.localizedFormat("当前策略允许 CPAMP 在巡检中%@。服务端仍会核验账号稳定身份，但此操作并非只读。", detail)
    }
}

private struct InspectionPolicyFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .textSelection(.enabled)
        }
        .frame(minWidth: 90, alignment: .leading)
    }
}

private struct InspectionRunRow: View {
    let run: RuntimeCodexInspectionRun
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(
                        title: run.statusTitle,
                        tint: runTint,
                        systemImage: runStatusSymbol
                    )
                    Spacer()
                    Text("#\(run.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(run.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? OasesLocalization.localized("时间未知"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(OasesLocalization.localizedFormat("%@ · 抽样 %lld / %lld", run.triggerTitle, run.sampledCount, run.totalFiles))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if run.actionCount > 0 {
                    Text(actionSummary)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(run.actionCount > 0 ? runTint : .secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.oasesBlue.opacity(0.10) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.oasesBlue.opacity(0.55) : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            OasesLocalization.localizedFormat("%@，运行 #%lld，%@", run.statusTitle, run.id, run.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? OasesLocalization.localized("时间未知"))
        )
    }

    private var runTint: Color {
        switch run.normalizedStatus {
        case "completed": .oasesGreen
        case "failed", "interrupted": .oasesRed
        case "cancelled", "cancelling": .oasesOrange
        case "running": .oasesBlue
        default: .secondary
        }
    }

    private var runStatusSymbol: String {
        switch run.normalizedStatus {
        case "completed": "checkmark.circle"
        case "failed", "interrupted": "xmark.octagon"
        case "cancelled", "cancelling": "stop.circle"
        case "running": "arrow.triangle.2.circlepath"
        default: "questionmark.circle"
        }
    }

    private var actionSummary: String {
        [
            run.deleteCount > 0 ? OasesLocalization.localizedFormat("删除 %lld", run.deleteCount) : nil,
            run.disableCount > 0 ? OasesLocalization.localizedFormat("禁用 %lld", run.disableCount) : nil,
            run.enableCount > 0 ? OasesLocalization.localizedFormat("启用 %lld", run.enableCount) : nil,
            run.reauthCount > 0 ? OasesLocalization.localizedFormat("授权 %lld", run.reauthCount) : nil
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private struct InspectionRunDetailView: View {
    let detail: RuntimeCodexInspectionRunDetail
    @Binding var search: String
    @Binding var filter: InspectionResultFilter
    @Binding var showLogs: Bool
    @Binding var selectedResult: RuntimeCodexInspectionResult?
    let onOpenAuthFiles: () -> Void
    let onCancel: (() -> Void)?
    let isCancelling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            detailHeader
            metrics

            if !detail.run.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                InfoBanner(
                    title: "该巡检报告了错误",
                    message: detail.run.error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesOrange
                )
            }

            if detail.run.isActive {
                InfoBanner(
                    title: detail.run.normalizedStatus == "cancelling" ? OasesLocalization.localized("正在请求取消") : OasesLocalization.localized("巡检正在运行"),
                    message: "本页会每 3 秒刷新一次历史和详情。完成后将自动显示最新结果与日志。",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .oasesBlue
                )
            }

            resultsPanel
            logsPanel
        }
        .padding(20)
        .oasesCard()
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            CardTitle(
                title: OasesLocalization.localizedFormat("运行 #%lld", detail.run.id),
                subtitle: "\(detail.run.triggerTitle) · \(dateText(detail.run.startedAtMs))",
                icon: "checkmark.shield"
            )
            Spacer()
            StatusPill(
                title: detail.run.statusTitle,
                tint: runTint,
                systemImage: runStatusSymbol
            )
            if let onCancel {
                Button(
                    detail.run.normalizedStatus == "cancelling" ? OasesLocalization.localized("正在取消") : OasesLocalization.localized("取消巡检"),
                    systemImage: "stop.fill",
                    action: onCancel
                )
                .buttonStyle(.bordered)
                .tint(.oasesRed)
                .disabled(isCancelling || detail.run.normalizedStatus == "cancelling")
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            InspectionMetric(
                title: "认证文件",
                value: detail.run.totalFiles.formatted(),
                caption: OasesLocalization.localized("本次纳入巡检"),
                tint: .oasesBlue,
                icon: "doc.on.doc"
            )
            InspectionMetric(
                title: "已探测",
                value: detail.run.sampledCount.formatted(),
                caption: OasesLocalization.localizedFormat("探测集合 %lld", detail.run.probeSetCount),
                tint: .oasesMint,
                icon: "waveform.path.ecg"
            )
            InspectionMetric(
                title: "需处理",
                value: detail.run.actionCount.formatted(),
                caption: OasesLocalization.localized("建议或重新授权"),
                tint: detail.run.actionCount > 0 ? .oasesOrange : .oasesGreen,
                icon: "exclamationmark.shield"
            )
            InspectionMetric(
                title: "日志",
                value: detail.logs.count.formatted(),
                caption: detail.run.finishedAt.map { OasesLocalization.localizedFormat("完成 %@", dateText(Int64($0.timeIntervalSince1970 * 1_000))) } ?? OasesLocalization.localized("持续更新"),
                tint: .oasesPurple,
                icon: "text.alignleft"
            )
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "账号结果",
                    subtitle: OasesLocalization.localizedFormat("%lld / %lld 项符合当前筛选", visibleResults.count, detail.results.count),
                    icon: "person.crop.circle.badge.checkmark"
                )
                Spacer()
                Button("认证文件", systemImage: "doc.badge.gearshape", action: onOpenAuthFiles)
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                TextField("搜索账号、认证文件、错误或建议", text: $search)
                    .textFieldStyle(.roundedBorder)

                Picker("筛选结果", selection: $filter) {
                    ForEach(InspectionResultFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize() // the label keeps its width in every language
            }

            if visibleResults.isEmpty {
                Text(emptyResultsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ForEach(visibleResults) { result in
                        InspectionResultCard(
                            result: result,
                            onShowDetails: { selectedResult = result },
                            onOpenAuthFiles: onOpenAuthFiles
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var logsPanel: some View {
        DisclosureGroup(isExpanded: $showLogs) {
            VStack(alignment: .leading, spacing: 8) {
                if detail.logs.isEmpty {
                    Text(detail.run.isActive ? "等待服务端写入第一条巡检日志…" : "该运行没有返回日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(detail.logs) { entry in
                        InspectionLogRow(entry: entry)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            CardTitle(
                title: "服务端日志",
                subtitle: OasesLocalization.localizedFormat("%lld 条 · 由 CPAMP 保存的脱敏运行记录", detail.logs.count),
                icon: "text.alignleft"
            )
        }
        .padding(16)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var visibleResults: [RuntimeCodexInspectionResult] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return detail.results.filter { result in
            let matchesSearch = query.isEmpty || result.searchText.contains(query)
            guard matchesSearch else { return false }
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .attention:
                matchesFilter = !result.failureMessage.isEmpty ||
                    result.normalizedActionStatus == "needs_review" ||
                    result.normalizedActionStatus == "failed"
            case .actions:
                matchesFilter = ["pending", "failed"].contains(result.normalizedActionStatus) &&
                    result.normalizedAction != "keep"
            case .quota:
                matchesFilter = result.isQuota || result.usedPercent != nil || !result.quotaWindows.isEmpty
            case .handled:
                matchesFilter = ["success", "skipped"].contains(result.normalizedActionStatus)
            }
            return matchesFilter
        }
        .sorted { lhs, rhs in
            if lhs.normalizedActionStatus != rhs.normalizedActionStatus {
                return lhs.normalizedActionStatus == "pending"
            }
            return lhs.id < rhs.id
        }
    }

    private var emptyResultsText: String {
        if detail.run.isActive {
            return OasesLocalization.localized("巡检仍在运行，结果会随着 Provider 检查完成而出现。")
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return OasesLocalization.localized("没有匹配的结果；可以清除搜索或切换筛选。")
        }
        return OasesLocalization.localized("该运行未返回可展示的账号结果。")
    }

    private var runTint: Color {
        switch detail.run.normalizedStatus {
        case "completed": .oasesGreen
        case "failed", "interrupted": .oasesRed
        case "cancelled", "cancelling": .oasesOrange
        case "running": .oasesBlue
        default: .secondary
        }
    }

    private var runStatusSymbol: String {
        switch detail.run.normalizedStatus {
        case "completed": "checkmark.circle"
        case "failed", "interrupted": "xmark.octagon"
        case "cancelled", "cancelling": "stop.circle"
        case "running": "arrow.triangle.2.circlepath"
        default: "questionmark.circle"
        }
    }

    private func dateText(_ value: Int64) -> String {
        guard value > 0 else { return OasesLocalization.localized("暂无") }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct InspectionMetric: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(OasesLocalization.localized(caption))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InspectionResultCard: View {
    let result: RuntimeCodexInspectionResult
    let onShowDetails: () -> Void
    let onOpenAuthFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        StatusPill(
                            title: result.provider.isEmpty ? OasesLocalization.localized("未知 Provider") : result.provider.uppercased(),
                            tint: .oasesBlue,
                            systemImage: "network"
                        )
                        StatusPill(
                            title: result.stateTitle,
                            tint: result.disabled ? .oasesOrange : .oasesGreen,
                            systemImage: result.disabled ? "pause.circle" : "checkmark.circle"
                        )
                    }

                    Text(result.accountTitle)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(result.fileName.isEmpty ? OasesLocalization.localized("未返回认证文件名") : result.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    StatusPill(
                        title: result.actionTitle,
                        tint: actionTint,
                        systemImage: actionSymbol
                    )
                    Text(result.actionStatusTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(actionStatusTint)
                }
            }

            if !result.actionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(result.actionReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 18) {
                InspectionResultFact(
                    title: "探测",
                    value: probeText
                )
                InspectionResultFact(
                    title: "配额",
                    value: quotaText
                )
                InspectionResultFact(
                    title: "计划",
                    value: result.planType?.isEmpty == false ? result.planType! : "暂无"
                )
                InspectionResultFact(
                    title: "身份索引",
                    value: result.authIndex.isEmpty ? OasesLocalization.localized("暂无") : result.authIndex
                )
            }

            quotaContent

            if !result.failureMessage.isEmpty {
                Label(result.failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if result.actionRequiresAuthFileReview {
                Label(
                    "建议动作尚未在此页执行。请先查看证据，再在“认证文件”中逐项复核和确认。",
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("查看详情", systemImage: "doc.text.magnifyingglass", action: onShowDetails)
                    .buttonStyle(.bordered)
                if result.actionRequiresAuthFileReview {
                    Button("认证文件", systemImage: "arrow.right", action: onOpenAuthFiles)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if !result.quotaWindows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(result.quotaWindows) { window in
                    HStack(spacing: 8) {
                        Text(window.title)
                            .font(.caption)
                            .frame(minWidth: 94, alignment: .leading)
                        if let progress = window.progress {
                            ProgressView(value: progress)
                                .tint(quotaTint(for: progress))
                            Text(window.usedPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? OasesLocalization.localized("暂无"))
                                .font(.caption.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        } else {
                            Text("未返回用量")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !window.resetLabel.isEmpty {
                            Text(window.resetLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else if let progress = result.progress {
            HStack(spacing: 8) {
                Text("额度使用")
                    .font(.caption)
                    .frame(minWidth: 94, alignment: .leading)
                ProgressView(value: progress)
                    .tint(quotaTint(for: progress))
                Text(result.usedPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? OasesLocalization.localized("暂无"))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var probeText: String {
        if let statusCode = result.statusCode {
            return "HTTP \(statusCode)"
        }
        return result.status.isEmpty ? (result.state.isEmpty ? OasesLocalization.localized("未返回") : result.state) : result.status
    }

    private var quotaText: String {
        guard let usedPercent = result.usedPercent else {
            return result.isQuota ? OasesLocalization.localized("有配额证据") : OasesLocalization.localized("暂无")
        }
        return "\(usedPercent.formatted(.number.precision(.fractionLength(0))))%"
    }

    private var actionTint: Color {
        switch result.normalizedAction {
        case "delete": .oasesRed
        case "disable", "reauth", "review": .oasesOrange
        case "enable": .oasesMint
        case "keep": .oasesGreen
        default: .secondary
        }
    }

    private var actionSymbol: String {
        switch result.normalizedAction {
        case "delete": "trash"
        case "disable": "pause.circle"
        case "enable": "play.circle"
        case "reauth": "person.badge.key"
        case "review": "eye"
        case "keep": "checkmark.circle"
        default: "questionmark.circle"
        }
    }

    private var actionStatusTint: Color {
        switch result.normalizedActionStatus {
        case "success": .oasesGreen
        case "failed": .oasesRed
        case "pending", "needs_review": .oasesOrange
        case "skipped": .secondary
        default: .secondary
        }
    }

    private func quotaTint(for progress: Double) -> Color {
        if progress >= 0.95 { return .oasesRed }
        if progress >= 0.75 { return .oasesOrange }
        return .oasesMint
    }
}

private struct InspectionResultFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(minWidth: 74, alignment: .leading)
    }
}

private struct InspectionLogRow: View {
    let entry: RuntimeCodexInspectionLog

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: levelSymbol)
                .foregroundStyle(levelTint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.levelTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(levelTint)
                    Text(entry.createdAt?.formatted(date: .omitted, time: .standard) ?? OasesLocalization.localized("时间未知"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(entry.message.isEmpty ? OasesLocalization.localized("未返回日志消息") : entry.message)
                    .font(.caption)
                    .textSelection(.enabled)
                if let detail = entry.detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var levelTint: Color {
        switch entry.normalizedLevel {
        case "error", "failed": .oasesRed
        case "warning", "warn": .oasesOrange
        case "success": .oasesGreen
        default: .oasesBlue
        }
    }

    private var levelSymbol: String {
        switch entry.normalizedLevel {
        case "error", "failed": "xmark.octagon.fill"
        case "warning", "warn": "exclamationmark.triangle.fill"
        case "success": "checkmark.circle.fill"
        default: "info.circle.fill"
        }
    }
}

private struct InspectionResultDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: RuntimeCodexInspectionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                CardTitle(
                    title: result.accountTitle,
                    subtitle: result.fileName.isEmpty ? OasesLocalization.localized("巡检结果") : result.fileName,
                    icon: "person.crop.circle.badge.checkmark"
                )
                Spacer()
                Button("完成") {
                    dismiss()
                }
                    .buttonStyle(.oasesPrimary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        InspectionSheetRow(title: "Provider", value: result.provider)
                        InspectionSheetRow(title: "账号键", value: result.accountKey)
                        InspectionSheetRow(title: "认证索引", value: result.authIndex)
                        InspectionSheetRow(title: "账号 ID", value: result.accountID)
                        InspectionSheetRow(title: "认证状态", value: result.stateTitle)
                        InspectionSheetRow(title: "HTTP 状态", value: result.statusCode.map { "HTTP \($0)" } ?? OasesLocalization.localized("暂无"))
                        InspectionSheetRow(title: "建议动作", value: result.actionTitle)
                        InspectionSheetRow(title: "动作状态", value: result.actionStatusTitle)
                        InspectionSheetRow(title: "原因", value: result.actionReason)
                        InspectionSheetRow(title: "错误类型", value: result.errorKind)
                        InspectionSheetRow(title: "错误详情", value: result.failureMessage)
                    }

                    if !result.quotaWindows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("配额窗口")
                                .font(.headline)
                            ForEach(result.quotaWindows) { window in
                                InspectionSheetRow(
                                    title: window.title,
                                    value: [
                                        window.usedPercent.map {
                                            "\($0.formatted(.number.precision(.fractionLength(0))))%"
                                        },
                                        window.resetLabel.isEmpty ? nil : window.resetLabel
                                    ]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                                )
                            }
                        }
                    }
                }
                .padding(18)
                .oasesCard()
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 530)
    }
}

private struct InspectionSheetRow: View {
    let title: String
    let value: String

    var body: some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent(LocalizedStringKey(title)) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}
