import SwiftUI

/// The gateway's models with their latest health results (#4), as a table with a filter, a
/// search field and an inspector for the selected model. Internal `pin-x/…` ids never reach
/// this page (`ModelsWorkbenchStore` drops them).
struct ModelsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var appStore: AppStore
    @StateObject private var store: ModelsWorkbenchStore
    @State private var search = ""
    @State private var filter: ModelHealthFilter = .all
    @State private var selection: GatewayModelRow.ID?
    @State private var sortOrder = [KeyPathComparator(\GatewayModelRow.id)]
    @State private var modelToTest: String?
    @State private var testAllConfirmationPresented = false
    @State private var path: [String] = []

    init(deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: ModelsWorkbenchStore(provider: deploymentStore))
    }

    var body: some View {
        NavigationStack(path: $path) {
            DetailPaneSplit(
                showsPane: selectedRow != nil,
                paneTitle: "模型详情",
                onClose: { selection = nil }
            ) {
                content
            } pane: {
                if let row = selectedRow {
                    ModelInspector(
                        row: row,
                        isTesting: store.testingModel == row.id,
                        canTest: canTest && !runInProgress,
                        testDisabledReason: testDisabledReason,
                        onTest: { modelToTest = row.id },
                        onOpenDetail: {
                            selection = nil
                            path.append(row.id)
                        }
                    )
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: Text("搜索模型"))
            .toolbar { toolbar }
            .navigationDestination(for: String.self) { modelID in
                ModelDetailView(modelID: modelID, deploymentStore: deploymentStore)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("筛选", selection: $filter) {
                ForEach(ModelHealthFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(store.phase != .loaded || store.rows.isEmpty)
            .help("按测活结果筛选")
        }
        ToolbarItem(placement: .automatic) {
            Button { testAllConfirmationPresented = true } label: {
                Label("全部测活", systemImage: "waveform.path.ecg")
            }
            .disabled(!canTest || store.rows.isEmpty || runInProgress)
            .help(testDisabledReason ?? OasesLocalization.localized("测试全部模型？"))
        }
    }

    private var canTest: Bool {
        store.phase == .loaded && !store.isMutating && !store.engineKeyMissing
    }

    private var runInProgress: Bool {
        store.run.map { !$0.isFinished } ?? false
    }

    /// Why 测活 is unavailable, shown next to the disabled button.
    private var testDisabledReason: String? {
        if store.engineKeyMissing { return OasesLocalization.localized("网关缺少内部引擎 Key，无法测试模型；请检查部署是否完整。") }
        if runInProgress { return OasesLocalization.localized("正在全部测活") }
        return nil
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) {
                store.retryAuthentication()
            }
            .padding(Oases.Space.page)
        case .loading:
            GatewayLoadingView(title: "正在读取网关模型…")
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
            OasesEmptyState(
                systemImage: "cpu",
                title: "网关还没有可用模型",
                message: "先添加一个 AI 提供商。",
                actionTitle: "添加提供商",
                action: { appStore.selectSection(.aiProviders) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                statusLines
                if visibleRows.isEmpty {
                    Text("没有匹配的模型。")
                        .foregroundStyle(Oases.Color.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ModelsTable(rows: visibleRows, selection: $selection, sortOrder: $sortOrder, testingModel: store.testingModel)
                }
            }
        }
    }

    /// The state lines above the table: a problem, the running test, the counts.
    @ViewBuilder
    private var statusLines: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            if store.engineKeyMissing {
                InlineProblem(message: OasesLocalization.localized("网关缺少内部引擎 Key，无法测试模型；请检查部署是否完整。"))
            } else if let error = store.actionError {
                InlineProblem(message: error)
            }
            if let run = store.run {
                ModelTestRunLine(run: run)
            }
            Text(countsText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
        }
        .padding(.horizontal, Oases.Space.page)
        .padding(.vertical, Oases.Space.sm)
        Divider()
    }

    private var countsText: String {
        var up = 0, down = 0, untested = 0
        for row in store.rows {
            switch row.health?.status {
            case .up?: up += 1
            case .down?: down += 1
            case nil: untested += 1
            default: break
            }
        }
        return OasesLocalization.localizedFormat("%lld 个模型 · 可用 %lld · 不可用 %lld · 未测 %lld", store.rows.count, up, down, untested)
    }

    private var visibleRows: [GatewayModelRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.rows
            .filter { filter.includes($0.health?.status) }
            .filter { row in
                query.isEmpty
                    || row.id.localizedCaseInsensitiveContains(query)
                    || row.groups.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted(using: sortOrder)
    }

    private var selectedRow: GatewayModelRow? {
        guard let selection else { return nil }
        return store.rows.first { $0.id == selection }
    }
}

/// The segmented filter of the models page.
enum ModelHealthFilter: String, CaseIterable, Identifiable {
    case all, up, down

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: OasesLocalization.localized("全部")
        case .up: OasesLocalization.localized("可用")
        case .down: OasesLocalization.localized("失败")
        }
    }

    func includes(_ status: GatewayHealthStatus?) -> Bool {
        switch self {
        case .all: true
        case .up: status == .up
        case .down: status == .down
        }
    }
}

extension GatewayModelRow {
    /// The providers (model groups) as one line, for the table and for sorting.
    var providersText: String { groups.joined(separator: ", ") }
    /// Sort rank of the health result: available, failed, other, not applicable, untested.
    var healthRank: Int {
        switch health?.status {
        case .up?: 0
        case .down?: 1
        case .other?: 2
        case .skipped?: 3
        case nil: 4
        }
    }
    var testedAtSortKey: Date { health?.testedAt ?? .distantPast }
}

/// The models table: id (monospaced), providers, status dot + word, latency, last test.
struct ModelsTable: View {
    let rows: [GatewayModelRow]
    @Binding var selection: GatewayModelRow.ID?
    @Binding var sortOrder: [KeyPathComparator<GatewayModelRow>]
    var testingModel: String?

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("模型 ID", value: \.id) { row in
                Text(row.id)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.id)
            }
            .width(min: 160, ideal: 260)
            TableColumn("提供商", value: \.providersText) { row in
                Text(row.providersText)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
                    .help(row.providersText)
            }
            .width(min: 100, ideal: 180)
            TableColumn("状态", value: \.healthRank) { row in
                HStack(spacing: Oases.Space.s) {
                    if testingModel == row.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        ModelHealthDot(status: row.health?.status)
                    }
                    Text(ModelHealthDot.title(for: row.health?.status))
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 90, ideal: 130)
            TableColumn("延迟") { row in
                Text(row.health?.latencyMs.map { OasesLocalization.localizedFormat("%lld 毫秒", $0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("最近测试", value: \.testedAtSortKey) { row in
                if let testedAt = row.health?.testedAt {
                    Text(testedAt, style: .relative)
                        .monospacedDigit()
                        .foregroundStyle(Oases.Color.textSecondary)
                } else {
                    Text("—").foregroundStyle(Oases.Color.textTertiary)
                }
            }
            .width(min: 80, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
    }
}

/// The running or last "全部测活": one line with a determinate bar.
struct ModelTestRunLine: View {
    let run: GatewayTestRun

    var body: some View {
        HStack(spacing: Oases.Space.m) {
            Text(run.isFinished
                 ? OasesLocalization.localizedFormat("上次全部测活完成于 %@", (run.finishedAt ?? run.startedAt).oasesShortDateTime)
                 : OasesLocalization.localized("正在全部测活"))
            if !run.isFinished {
                ProgressView(value: Double(min(run.done, max(run.total, 1))), total: Double(max(run.total, 1)))
                    .frame(maxWidth: 160)
            }
            Text(OasesLocalization.localizedFormat("已完成 %lld / %lld · 可用 %lld · 不可用 %lld · 不适用 %lld", run.done, run.total, run.up, run.down, run.skipped))
                .monospacedDigit()
                .foregroundStyle(Oases.Color.textSecondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// The selected model: label-above-value rows, the last test in one line, 测试 and 打开详情.
struct ModelInspector: View {
    let row: GatewayModelRow
    var isTesting = false
    var canTest = true
    var testDisabledReason: String?
    var onTest: () -> Void = {}
    var onOpenDetail: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.md) {
                InspectorField(label: "模型 ID") {
                    Text(row.id)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InspectorField(label: "提供商") {
                    VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                        ForEach(row.groups, id: \.self) { group in
                            Text(group).textSelection(.enabled)
                        }
                    }
                }
                InspectorField(label: "最近测试") {
                    VStack(alignment: .leading, spacing: Oases.Space.xs) {
                        HStack(spacing: Oases.Space.s) {
                            ModelHealthDot(status: row.health?.status)
                            Text(lastTestText)
                                .monospacedDigit()
                        }
                        if let error = row.health?.error, row.health?.status == .down {
                            Text(SecretRedactor.redact(InternalModelID.publicText(error), secrets: []))
                                .font(.callout)
                                .foregroundStyle(Oases.Color.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: Oases.Space.sm) {
                    Button("测试", action: onTest)
                        .disabled(!canTest || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("打开详情", action: onOpenDetail)
                }
                if let testDisabledReason, !canTest {
                    Text(testDisabledReason)
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("测活会向上游发送真实请求并产生费用")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            .padding(Oases.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lastTestText: String {
        guard let health = row.health else { return OasesLocalization.localized("未测") }
        var parts = [ModelHealthDot.title(for: health.status)]
        if let latency = health.latencyMs { parts.append(OasesLocalization.localizedFormat("%lld 毫秒", latency)) }
        parts.append(health.testedAt.oasesShortDateTime)
        return parts.joined(separator: " · ")
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

    static func title(for status: GatewayHealthStatus?) -> String {
        switch status {
        case .up?: OasesLocalization.localized("可用")
        case .down?: OasesLocalization.localized("不可用")
        case .skipped?: OasesLocalization.localized("不适用")
        case .other(let value)?: value
        case nil: OasesLocalization.localized("未测")
        }
    }

    var body: some View {
        if status == nil {
            Circle()
                .strokeBorder(Oases.Color.textTertiary, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        } else {
            StatusDot(tone: Self.tone(for: status))
        }
    }
}
