import SwiftUI

/// The gateway's models with their latest health results (#4). Internal `pin-x/…` ids never
/// reach this page (`ModelsWorkbenchStore` drops them).
struct ModelsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var store: ModelsWorkbenchStore
    @State private var search = ""
    @State private var modelToTest: String?
    @State private var testAllConfirmationPresented = false

    init(deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: ModelsWorkbenchStore(provider: deploymentStore))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Oases.Space.l) {
                    header
                    content
                }
                .padding(Oases.Space.page)
            }
            .oasesCanvas()
            .navigationDestination(for: String.self) { modelID in
                ModelDetailPlaceholderView(modelID: modelID)
            }
        }
        .task(id: reloadKey) {
            if store.isActive { store.refreshNow() } else { store.activate() }
        }
        .onDisappear { store.deactivate() }
        .confirmationDialog(
            OasesLocalization.localizedFormat("测试 %@？", modelToTest ?? ""),
            isPresented: Binding(get: { modelToTest != nil }, set: { if !$0 { modelToTest = nil } }),
            titleVisibility: .visible
        ) {
            Button("测试") {
                if let model = modelToTest {
                    Task { await store.test(model) }
                }
                modelToTest = nil
            }
            Button("取消", role: .cancel) { modelToTest = nil }
        } message: {
            Text("测活会向上游发送真实请求并产生费用")
        }
        .confirmationDialog("测试全部模型？", isPresented: $testAllConfirmationPresented, titleVisibility: .visible) {
            Button("全部测活") {
                Task { await store.testAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("测活会向上游发送真实请求并产生费用：每个模型一次请求，图像、向量和语音类模型不测。")
        }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            PageHeader(section: .models)
            Spacer()
            if store.phase == .loading || store.isMutating {
                ProgressView().controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                store.refreshNow()
            }
            .buttonStyle(.bordered)
            .disabled(store.phase == .loading || !isReady)

            Button("全部测活", systemImage: "waveform.path.ecg") {
                testAllConfirmationPresented = true
            }
            .buttonStyle(.oasesPrimary)
            .disabled(!canTest || store.rows.isEmpty || runInProgress)
        }
    }

    private var isReady: Bool {
        if case .unavailable = store.phase { return false }
        return true
    }

    private var canTest: Bool {
        store.phase == .loaded && !store.isMutating && !store.engineKeyMissing
    }

    private var runInProgress: Bool {
        store.run.map { !$0.isFinished } ?? false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) {
                store.retryAuthentication()
            }
        case .loading:
            ProgressView("正在读取网关模型…")
                .frame(maxWidth: .infinity, minHeight: 220)
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        statusStrip
        if store.engineKeyMissing {
            InfoBanner(
                title: "无法测活",
                message: OasesLocalization.localized("网关缺少内部引擎 Key，无法测试模型；请检查部署是否完整。"),
                systemImage: "key.slash",
                tint: Oases.Color.danger
            )
        } else if let error = store.actionError {
            InfoBanner(
                title: "操作未完成",
                message: error,
                systemImage: "exclamationmark.triangle",
                tint: Oases.Color.danger
            )
        }
        if let run = store.run {
            runCard(run)
        }
        modelsCard
    }

    private var statusStrip: some View {
        let counts = healthCounts
        return HStack(spacing: Oases.Space.m) {
            StatusPill(
                title: OasesLocalization.localizedFormat("%lld 个模型", store.rows.count),
                tint: store.rows.isEmpty ? Oases.Color.warning : Oases.Color.accent,
                systemImage: "cpu"
            )
            StatusPill(title: OasesLocalization.localizedFormat("可用 %lld", counts.up), tint: Oases.Color.success)
            StatusPill(title: OasesLocalization.localizedFormat("不可用 %lld", counts.down), tint: Oases.Color.danger)
            StatusPill(title: OasesLocalization.localizedFormat("未测 %lld", counts.untested), tint: Oases.Color.neutral)
            Spacer()
        }
    }

    private var healthCounts: (up: Int, down: Int, untested: Int) {
        var up = 0, down = 0, untested = 0
        for row in store.rows {
            switch row.health?.status {
            case .up?: up += 1
            case .down?: down += 1
            case nil: untested += 1
            default: break
            }
        }
        return (up, down, untested)
    }

    private func runCard(_ run: GatewayTestRun) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            CardTitle(
                title: run.isFinished ? "上次全部测活" : "正在全部测活",
                subtitle: run.isFinished
                    ? OasesLocalization.localizedFormat("完成于 %@", (run.finishedAt ?? run.startedAt).formatted(date: .abbreviated, time: .shortened))
                    : OasesLocalization.localized("结果会每隔几秒自动刷新；离开这一页后测活仍在网关上继续。"),
                icon: "waveform.path.ecg"
            )
            ProgressView(value: Double(min(run.done, max(run.total, 1))), total: Double(max(run.total, 1)))
            Text(OasesLocalization.localizedFormat("已完成 %lld / %lld · 可用 %lld · 不可用 %lld · 不适用 %lld", run.done, run.total, run.up, run.down, run.skipped))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
        }
        .padding(Oases.Space.l)
        .oasesCard()
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            HStack(alignment: .top) {
                CardTitle(
                    title: "网关模型",
                    subtitle: "来自网关的模型目录；测活结果是最近一次请求的结果",
                    icon: "cpu"
                )
                Spacer()
                TextField("筛选模型", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            if store.rows.isEmpty {
                OasesEmptyState(
                    systemImage: "cpu",
                    title: "网关还没有可用模型",
                    message: "添加 AI 提供商或认证文件后，模型会出现在这里。"
                )
            } else if filteredRows.isEmpty {
                Text("没有匹配的模型。")
                    .font(.callout)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredRows) { row in
                        modelRow(row)
                        if row.id != filteredRows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(Oases.Space.l)
        .oasesCard()
    }

    private var filteredRows: [GatewayModelRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.rows }
        return store.rows.filter { row in
            row.id.localizedCaseInsensitiveContains(query) || row.groups.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func modelRow(_ row: GatewayModelRow) -> some View {
        HStack(spacing: Oases.Space.m) {
            NavigationLink(value: row.id) {
                HStack(spacing: Oases.Space.m) {
                    ModelHealthDot(status: row.health?.status)
                    VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                        Text(row.id)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Oases.Color.textPrimary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Text(row.groups.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Oases.Color.textSecondary)
                            .lineLimit(1)
                        if let error = row.health?.error, row.health?.status == .down {
                            Text(SecretRedactor.redact(InternalModelID.publicText(error), secrets: []))
                                .font(.caption)
                                .foregroundStyle(Oases.Color.dangerText)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: Oases.Space.m)
                    healthSummary(row.health)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.testingModel == row.id {
                ProgressView().controlSize(.small)
            }
            Button("测活") {
                modelToTest = row.id
            }
            .buttonStyle(.bordered)
            .disabled(!canTest || runInProgress)
        }
        .padding(.vertical, Oases.Space.m)
    }

    private func healthSummary(_ health: GatewayHealthResult?) -> some View {
        VStack(alignment: .trailing, spacing: Oases.Space.xxs) {
            Text(statusTitle(health?.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ModelHealthDot.tone(for: health?.status).text)
            if let health {
                Text(health.latencyMs.map { OasesLocalization.localizedFormat("%lld 毫秒", $0) } ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
                Text(health.testedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(Oases.Color.textTertiary)
            }
        }
    }

    private func statusTitle(_ status: GatewayHealthStatus?) -> String {
        switch status {
        case .up?: OasesLocalization.localized("可用")
        case .down?: OasesLocalization.localized("不可用")
        case .skipped?: OasesLocalization.localized("不适用")
        case .other(let value)?: value
        case nil: OasesLocalization.localized("未测")
        }
    }
}

/// Health dot: up green, down red, skipped grey, no result hollow.
struct ModelHealthDot: View {
    let status: GatewayHealthStatus?

    static func tone(for status: GatewayHealthStatus?) -> Oases.Tone {
        switch status {
        case .up?: .success
        case .down?: .danger
        case .other?: .warning
        case .skipped?, nil: .neutral
        }
    }

    var body: some View {
        if status == nil {
            Circle()
                .strokeBorder(Oases.Color.textTertiary, lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        } else {
            StatusDot(tone: Self.tone(for: status), size: 9)
        }
    }
}

/// The model detail page arrives with Task 15.
private struct ModelDetailPlaceholderView: View {
    let modelID: String

    var body: some View {
        OasesEmptyState(
            systemImage: "cpu",
            title: modelID,
            message: "模型详情（供应商顺序、调用与花费）将在后续版本提供。"
        )
        .padding(Oases.Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .oasesCanvas()
    }
}
