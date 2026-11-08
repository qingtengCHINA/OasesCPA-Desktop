import Charts
import SwiftUI
import UniformTypeIdentifiers

struct UsageAnalyticsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: RuntimeDashboardRange = .today

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    Spacer()
                    StatusPill(
                        title: isRangeLive ? "实时数据" : (runtimeDataStore.isLoadingAnalytics ? OasesLocalization.localized("读取中") : OasesLocalization.localized("连接后显示")),
                        tint: isRangeLive ? .oasesGreen : .oasesOrange,
                        systemImage: isRangeLive ? "waveform.path.ecg" : "link.badge.plus"
                    )
                    Picker("时间范围", selection: $range) {
                        ForEach(RuntimeDashboardRange.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize() // the label keeps its width in every language
                }

                if let error = runtimeDataStore.analyticsErrorMessage {
                    InfoBanner(
                        title: "分析数据读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 15) {
                        CardTitle(title: "Token 趋势", subtitle: "按时间范围聚合", icon: "chart.xyaxis.line")
                        if traffic.isEmpty {
                            Text("连接目标环境后显示真实趋势")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
                        } else {
                            Chart(traffic) { point in
                                AreaMark(
                                    x: .value("时间", point.label),
                                    y: .value("Token", point.tokens)
                                )
                                .foregroundStyle(Color.oasesBlue.opacity(0.14).gradient)

                                LineMark(
                                    x: .value("时间", point.label),
                                    y: .value("Token", point.tokens)
                                )
                                .foregroundStyle(Color.oasesBlue)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            }
                            .chartYAxis { AxisMarks(position: .leading) }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
                    .oasesCard()

                    AnalyticsBreakdownCard(dashboard: activeDashboard)
                        .frame(minWidth: 280, maxWidth: 340)
                }
            }
            .padding(28)
        }
        .task(id: analyticsRefreshTaskID) {
            guard scenePhase == .active, deploymentStore.stage == .attached else { return }

            while !Task.isCancelled {
                if !runtimeDataStore.isLoadingAnalytics {
                    runtimeDataStore.refreshAnalytics(using: deploymentStore, range: range)
                }

                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var analyticsRefreshTaskID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpampBaseURL.absoluteString)|\(range.rawValue)|\(scenePhase == .active)"
    }

    private var metrics: [MetricSummary] {
        guard let dashboard = activeDashboard else {
            return [
                .init(title: "总 Token", value: "暂无", caption: "连接后读取", systemImage: "number", tint: .oasesBlue),
                .init(title: "预估成本", value: "暂无", caption: "连接后读取", systemImage: "dollarsign.circle", tint: .oasesOrange),
                .init(title: "缓存占比", value: "暂无", caption: "连接后读取", systemImage: "externaldrive.fill", tint: .oasesMint),
                .init(title: "平均延迟", value: "暂无", caption: "连接后读取", systemImage: "timer", tint: .oasesPurple)
            ]
        }

        let cachedShare = dashboard.tokenMix?.first(where: { $0.key == "cached" || $0.key == "cache_read" })?.share
        let latency = dashboard.today.averageLatencyMs.map { OasesLocalization.localizedFormat("%.1f 秒", $0 / 1_000) } ?? OasesLocalization.localized("暂无")
        return [
            .init(title: "总 Token", value: compactToken(Double(dashboard.today.totalTokens)), caption: OasesLocalization.localizedFormat("%@累计", range.title), systemImage: "number", tint: .oasesBlue),
            .init(title: "预估成本", value: dashboard.today.totalCost.formatted(.currency(code: "USD")), caption: OasesLocalization.localizedFormat("%@ · 当前计价模型", range.title), systemImage: "dollarsign.circle", tint: .oasesOrange),
            .init(title: "缓存占比", value: cachedShare?.formatted(.percent.precision(.fractionLength(1))) ?? OasesLocalization.localized("暂无"), caption: "摘要返回的 Token 构成", systemImage: "externaldrive.fill", tint: .oasesMint),
            .init(title: "平均延迟", value: latency, caption: OasesLocalization.localizedFormat("零 Token %@ 次", dashboard.today.zeroTokenCalls.formatted()), systemImage: "timer", tint: .oasesPurple)
        ]
    }

    private var traffic: [TrafficPoint] {
        dashboardTraffic(activeDashboard)
    }

    private var activeDashboard: RuntimeDashboardSummary? {
        if range == .today {
            return runtimeDataStore.analyticsDashboard ?? runtimeDataStore.dashboard
        }
        return runtimeDataStore.analyticsDashboard
    }

    private var isRangeLive: Bool { activeDashboard != nil }

    private func dashboardTraffic(_ dashboard: RuntimeDashboardSummary?) -> [TrafficPoint] {
        (dashboard?.trafficTimeline ?? []).map { point in
            TrafficPoint(
                label: Date(timeIntervalSince1970: TimeInterval(point.bucketMs) / 1_000)
                    .formatted(date: .omitted, time: .shortened),
                requests: Double(point.calls),
                tokens: Double(point.tokens) / 1_000
            )
        }
    }

    private func compactToken(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return value.formatted(.number.precision(.fractionLength(0)))
        }
    }
}

struct AnalyticsBreakdownCard: View {
    let dashboard: RuntimeDashboardSummary?

    private struct ModelRow: Identifiable {
        let id: String
        let name: String
        let tokens: String
        let cost: String
        let tint: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "按模型拆解", subtitle: "Token 与估算成本", icon: "square.stack.3d.up")

            if rows.isEmpty {
                Text(dashboard == nil ? "连接后显示真实模型拆解" : "当前摘要未返回模型拆解")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                ForEach(rows) { row in
                HStack(spacing: 10) {
                    Circle().fill(row.tint)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.callout.weight(.medium))
                        Text(row.tokens).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.cost).font(.callout.weight(.semibold))
                }
                }
            }

            Divider()

            LabeledContent("计价源") { Text("models.dev") }
            LabeledContent("缓存折扣") { Text("已计入") }
        }
        .font(.callout)
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private var rows: [ModelRow] {
        let values: [(String, Int64, Double)]
        if let rank = dashboard?.publicModelCostRank, !rank.isEmpty {
            values = rank.map { ($0.model, $0.tokens, $0.cost) }
        } else {
            values = (dashboard?.publicTopModels ?? []).map { ($0.model, $0.tokens, $0.cost) }
        }
        let colors: [Color] = [.oasesBlue, .oasesPurple, .oasesMint, .oasesOrange]
        return values.prefix(4).enumerated().map { index, value in
            ModelRow(
                id: value.0,
                name: value.0,
                tokens: compactToken(Double(value.1)),
                cost: value.2.formatted(.currency(code: "USD")),
                tint: colors[index % colors.count]
            )
        }
    }

    private func compactToken(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return value.formatted(.number.precision(.fractionLength(0)))
        }
    }
}

struct MonitoringView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var appliedSearch = ""
    @State private var failedOnly = false
    @State private var appliedFailedOnly = false
    @State private var range: RuntimeDashboardRange = .today
    @State private var filterDraft = RuntimeMonitoringFilterDraft()
    @State private var appliedFilterDraft = RuntimeMonitoringFilterDraft()
    @State private var showsAdvancedFilters = false
    @State private var accountHistoryCatchUpConfirmationPresented = false
    @State private var retainedMonitoringEvents: [RuntimeMonitoringEvent] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    Spacer()
                    Button("账号待办", systemImage: "person.crop.circle.badge.exclamationmark") {
                        store.selectSection(.accountActions)
                    }
                    .buttonStyle(.bordered)
                    Button("成本与价格", systemImage: "dollarsign.arrow.circlepath") {
                        store.selectSection(.modelPrices)
                    }
                    .buttonStyle(.bordered)
                    StatusPill(
                        title: isRangeLive ? "实时数据" : (runtimeDataStore.isLoadingMonitoring ? OasesLocalization.localized("读取中") : OasesLocalization.localized("连接后显示")),
                        tint: isRangeLive ? .oasesGreen : .oasesOrange,
                        systemImage: isRangeLive ? "waveform.path.ecg" : "link.badge.plus"
                    )
                }

                HStack(spacing: 10) {
                    TextField("搜索账号、模型、API Key 或路径", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyMonitoringFilters)

                    Toggle("仅失败", isOn: $failedOnly)
                        .toggleStyle(.switch)
                        .fixedSize()

                    Button("应用筛选", systemImage: "line.3.horizontal.decrease.circle") {
                        applyMonitoringFilters()
                    }
                    .buttonStyle(.bordered)

                    Picker("范围", selection: $range) {
                        ForEach(RuntimeDashboardRange.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .fixedSize() // the label keeps its width in every language

                    Button {
                        store.refresh()
                        runtimeDataStore.refresh(using: deploymentStore)
                        runtimeDataStore.refreshMonitoring(using: deploymentStore, range: range)
                        runtimeDataStore.refreshMonitoringEvents(
                            using: deploymentStore,
                            range: range,
                            searchQuery: appliedSearch,
                            failedOnly: appliedFailedOnly,
                            filters: appliedFilters
                        )
                        runtimeDataStore.refreshMonitoringHeaderSnapshots(using: deploymentStore)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .oasesCard()

                advancedFilterBar

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }

                if let error = runtimeDataStore.monitoringErrorMessage {
                    InfoBanner(
                        title: "监控数据读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                } else if !isRangeLive {
                    InfoBanner(
                        title: "请求监控尚未接入目标环境",
                        message: "连接成功后，这里显示所选范围内的 CPAMP 摘要与脱敏请求事件，可按模型、供应商、账号、Key 指纹等高级条件筛选，并展开每个事件的原始字段。",
                        systemImage: "waveform.path.ecg",
                        tint: .oasesOrange
                    )
                }

                if let error = runtimeDataStore.monitoringEventsErrorMessage {
                    InfoBanner(
                        title: "请求事件读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                if let warning = runtimeDataStore.monitoringEventsPaginationWarning {
                    InfoBanner(
                        title: "请求事件未完整加载",
                        message: warning,
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .oasesOrange
                    )
                }

                if let error = runtimeDataStore.monitoringHeaderSnapshotsErrorMessage {
                    InfoBanner(
                        title: "认证响应信号读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                MonitoringHeaderSnapshotsCard(
                    snapshots: runtimeDataStore.monitoringHeaderSnapshots,
                    isLoading: runtimeDataStore.isLoadingMonitoringHeaderSnapshots,
                    hasLoaded: runtimeDataStore.hasLoadedMonitoringHeaderSnapshots
                )

                if let error = runtimeDataStore.monitoringAccountHistoryErrorMessage {
                    InfoBanner(
                        title: "认证历史读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                MonitoringAccountHistoryCard(
                    entries: runtimeDataStore.monitoringAccountHistory,
                    checkpoint: runtimeDataStore.monitoringAccountHistoryCheckpoint,
                    isLoading: runtimeDataStore.isLoadingMonitoringAccountHistory,
                    isCatchingUp: runtimeDataStore.isCatchingUpMonitoringAccountHistory,
                    hasLoaded: runtimeDataStore.hasLoadedMonitoringAccountHistory,
                    canCatchUp: runtimeDataStore.canCatchUpMonitoringAccountHistory
                ) {
                    accountHistoryCatchUpConfirmationPresented = true
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        CardTitle(
                            title: "请求事件",
                            subtitle: eventSubtitle,
                            icon: "list.bullet.rectangle.portrait"
                        )
                        Spacer()
                        StatusPill(
                            title: eventStatusTitle,
                            tint: isEventListLive ? .oasesGreen : .oasesOrange
                        )
                    }

                    if runtimeDataStore.isLoadingMonitoringEvents && visibleMonitoringEvents.isEmpty {
                        ProgressView("正在读取请求事件…")
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    } else if visibleMonitoringEvents.isEmpty {
                        Text(
                            isEventListLive
                                ? "当前筛选范围内没有请求事件"
                                : "连接目标环境后显示请求事件"
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    } else {
                        ForEach(visibleMonitoringEvents) { event in
                            MonitoringEventRow(event: event)
                        }
                    }

                    if runtimeDataStore.monitoringEventsHasMore {
                        Button {
                            runtimeDataStore.loadMoreMonitoringEvents(using: deploymentStore)
                        } label: {
                            if runtimeDataStore.isLoadingMoreMonitoringEvents {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("加载更多", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(runtimeDataStore.isLoadingMoreMonitoringEvents)
                    } else if !runtimeDataStore.monitoringEvents.isEmpty {
                        Text(eventCountCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Text("展开事件可查看 CPAMP 返回的原始字段（凭证字段不显示）；请求错误文件在“日志查看”中下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .oasesCard()
            }
            .padding(28)
        }
        .task(id: monitoringRefreshTaskID) {
            guard scenePhase == .active, deploymentStore.stage == .attached else { return }

            retainedMonitoringEvents = []
            runtimeDataStore.refreshMonitoringHeaderSnapshots(using: deploymentStore)

            while !Task.isCancelled {
                if !runtimeDataStore.isLoadingMonitoring {
                    runtimeDataStore.refreshMonitoring(using: deploymentStore, range: range)
                }

                if !runtimeDataStore.isLoadingMonitoringEvents {
                    runtimeDataStore.refreshMonitoringEvents(
                        using: deploymentStore,
                        range: range,
                        searchQuery: appliedSearch,
                        failedOnly: appliedFailedOnly,
                        filters: appliedFilters,
                        silently: true
                    )
                }

                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
            }
        }
        .onChange(of: runtimeDataStore.isLoadingMonitoringEvents) { _, isLoading in
            guard !isLoading else { return }
            retainedMonitoringEvents = runtimeDataStore.monitoringEvents
        }
        .onChange(of: runtimeDataStore.monitoringEvents) { _, events in
            guard !events.isEmpty else { return }
            retainedMonitoringEvents = events
        }
        .confirmationDialog(
            "补齐认证历史汇总？",
            isPresented: $accountHistoryCatchUpConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("补齐最多 5,000 条记录") {
                runtimeDataStore.refreshMonitoringAccountHistory(
                    using: deploymentStore,
                    catchUp: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会在当前 CPAMP 的本地监控数据库中补齐认证聚合与计价，不会请求 Provider，也不会修改认证文件或密钥。")
        }
    }

    private func applyMonitoringFilters() {
        guard filterDraft.isValid else { return }
        appliedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedFailedOnly = failedOnly
        appliedFilterDraft = filterDraft
        runtimeDataStore.refreshMonitoringEvents(
            using: deploymentStore,
            range: range,
            searchQuery: appliedSearch,
            failedOnly: appliedFailedOnly,
            filters: appliedFilters
        )
    }

    /// The applied filter bar as CPAMP filters; models are queried under every routing prefix.
    private var appliedFilters: RuntimeMonitoringEventsRequest.Filters {
        appliedFilterDraft.filters(prefixes: runtimeDataStore.openAICompatibility.map(\.prefix))
    }

    private var monitoringRefreshTaskID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpampBaseURL.absoluteString)|\(range.rawValue)|\(appliedSearch)|\(appliedFailedOnly)|\(String(describing: appliedFilterDraft))|\(scenePhase == .active)"
    }

    private var advancedFilterBar: some View {
        DisclosureGroup(isExpanded: $showsAdvancedFilters) {
            VStack(alignment: .leading, spacing: Oases.Space.m) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Oases.Space.m)], spacing: Oases.Space.m) {
                    filterField("模型（公开名）", text: $filterDraft.model, suggestions: observedValues(\.displayModel))
                    filterField("供应商", text: $filterDraft.provider, suggestions: observedValues(\.authProviderSnapshot))
                    filterField("账号", text: $filterDraft.account, suggestions: observedValues(\.accountSnapshot))
                    filterField("Key 指纹", text: $filterDraft.apiKeyHash, suggestions: observedValues(\.apiKeyHash))
                    filterField("请求类型", text: $filterDraft.requestType, suggestions: observedValues(\.executorType))
                    filterField("头部错误类型", text: $filterDraft.headerErrorKind, suggestions: observedValues(\.headerErrorKind))
                    VStack(alignment: .leading, spacing: Oases.Space.xs) {
                        Text("最小延迟（毫秒）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("例如 500", text: $filterDraft.minLatencyText)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .onSubmit(applyMonitoringFilters)
                        if !filterDraft.isValid {
                            Text("请输入不小于 0 的整数毫秒。")
                                .font(.caption2)
                                .foregroundStyle(Color.oasesRed)
                        }
                    }
                    VStack(alignment: .leading, spacing: Oases.Space.xs) {
                        Text("缓存状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("缓存状态", selection: $filterDraft.cacheStatus) {
                            ForEach(RuntimeMonitoringFilterDraft.CacheStatus.allCases) { status in
                                Text(status.title).tag(status)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                HStack(spacing: Oases.Space.m) {
                    Text("多个值用逗号分隔；模型按公开名筛选，也会匹配带路由前缀的记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除高级筛选", systemImage: "xmark.circle") {
                        filterDraft = RuntimeMonitoringFilterDraft()
                        applyMonitoringFilters()
                    }
                    .buttonStyle(.bordered)
                    .disabled(filterDraft == RuntimeMonitoringFilterDraft() && appliedFilterDraft == RuntimeMonitoringFilterDraft())
                    Button("应用筛选", systemImage: "line.3.horizontal.decrease.circle") {
                        applyMonitoringFilters()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!filterDraft.isValid)
                }
            }
            .padding(.top, Oases.Space.sm)
        } label: {
            Label {
                Text(
                    appliedFilterDraft.activeCount > 0
                        ? OasesLocalization.localizedFormat("高级筛选（已启用 %lld 项）", appliedFilterDraft.activeCount)
                        : OasesLocalization.localized("高级筛选")
                )
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .font(.callout.weight(.medium))
        }
        .padding(Oases.Space.m)
        .oasesCard()
    }

    private func filterField(_ title: String, text: Binding<String>, suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Oases.Space.xs) {
                TextField(LocalizedStringKey(title), text: text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyMonitoringFilters)
                Menu {
                    if suggestions.isEmpty {
                        Text("已加载的事件里没有可选值")
                    }
                    ForEach(suggestions, id: \.self) { value in
                        Button(value) { text.wrappedValue = value }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("从已加载的事件中选择")
                .accessibilityLabel(OasesLocalization.localizedFormat("%@ 的可选值", OasesLocalization.localized(title)))
            }
        }
    }

    /// Distinct non-empty values of one field among the loaded events (at most 15).
    private func observedValues(_ field: KeyPath<RuntimeMonitoringEvent, String>) -> [String] {
        var result: [String] = []
        for event in runtimeDataStore.monitoringEvents {
            let value = event[keyPath: field].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !result.contains(value) { result.append(value) }
            if result.count == 15 { break }
        }
        return result.sorted()
    }

    private var visibleMonitoringEvents: [RuntimeMonitoringEvent] {
        if runtimeDataStore.isLoadingMonitoringEvents && runtimeDataStore.monitoringEvents.isEmpty {
            return retainedMonitoringEvents
        }
        return runtimeDataStore.monitoringEvents
    }

    private var eventSubtitle: String {
        var parts = [range.title, appliedFailedOnly ? OasesLocalization.localized("仅失败") : OasesLocalization.localized("全部状态")]
        if !appliedSearch.isEmpty {
            parts.append(OasesLocalization.localized("已应用搜索"))
        }
        if let total = runtimeDataStore.monitoringEventsTotalCount {
            parts.append(OasesLocalization.localizedFormat("共 %@ 条", total.formatted()))
        }
        return parts.joined(separator: " · ")
    }

    private var eventStatusTitle: String {
        if runtimeDataStore.isLoadingMonitoringEvents {
            return OasesLocalization.localized("读取中")
        }
        return isEventListLive ? OasesLocalization.localized("已接入") : OasesLocalization.localized("待接入")
    }

    private var isEventListLive: Bool {
        runtimeDataStore.monitoringEventsTotalCount != nil
    }

    private var eventCountCaption: String {
        guard let total = runtimeDataStore.monitoringEventsTotalCount else {
            return OasesLocalization.localizedFormat("已加载 %@ 条", runtimeDataStore.monitoringEvents.count.formatted())
        }
        return OasesLocalization.localizedFormat("已加载 %@ / %@ 条", runtimeDataStore.monitoringEvents.count.formatted(), total.formatted())
    }

    private var metrics: [MetricSummary] {
        guard let dashboard = activeDashboard else {
            return [
                .init(title: "总调用", value: "暂无", caption: "连接后读取", systemImage: "arrow.down.circle", tint: .oasesBlue),
                .init(title: "调用成功率", value: "暂无", caption: "连接后读取", systemImage: "checkmark.circle", tint: .oasesGreen),
                .init(title: "失败总数", value: "暂无", caption: "连接后读取", systemImage: "xmark.circle", tint: .oasesRed),
                .init(title: "预估花费", value: "暂无", caption: "连接后读取", systemImage: "dollarsign.circle", tint: .oasesOrange)
            ]
        }
        let latency = dashboard.today.averageLatencyMs.map { OasesLocalization.localizedFormat("%.1f 秒", $0 / 1_000) } ?? OasesLocalization.localized("暂无")
        return [
            .init(title: "总调用", value: dashboard.today.totalCalls.formatted(), caption: OasesLocalization.localizedFormat("%@累计", range.title), systemImage: "arrow.down.circle", tint: .oasesBlue),
            .init(title: "调用成功率", value: dashboard.today.successRate.formatted(.percent.precision(.fractionLength(2))), caption: OasesLocalization.localizedFormat("平均 %@", latency), systemImage: "checkmark.circle", tint: .oasesGreen),
            .init(title: "失败总数", value: dashboard.today.failureCalls.formatted(), caption: OasesLocalization.localizedFormat("最近失败 %lld 条", dashboard.recentFailures?.count ?? 0), systemImage: "xmark.circle", tint: .oasesRed),
            .init(title: "预估花费", value: dashboard.today.totalCost.formatted(.currency(code: "USD")), caption: OasesLocalization.localizedFormat("%@ · 当前计价模型", range.title), systemImage: "dollarsign.circle", tint: .oasesOrange)
        ]
    }

    private var activeDashboard: RuntimeDashboardSummary? {
        if range == .today {
            return runtimeDataStore.monitoringDashboard ?? runtimeDataStore.dashboard
        }
        return runtimeDataStore.monitoringDashboard
    }

    private var isRangeLive: Bool { activeDashboard != nil }
}

struct MonitoringEventRow: View {
    let event: RuntimeMonitoringEvent

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                MonitoringEventDetail(title: "时间", value: eventTime)
                MonitoringEventDetail(title: "请求", value: requestTarget)
                MonitoringEventDetail(title: "来源", value: event.sourceTitle)

                if !event.accountSnapshot.isEmpty {
                    MonitoringEventDetail(title: "账号快照", value: event.accountSnapshot)
                }
                if !event.authProviderSnapshot.isEmpty || !event.authIndex.isEmpty {
                    MonitoringEventDetail(
                        title: "认证",
                        value: [event.authProviderSnapshot, event.authIndex]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    )
                }
                if !event.authFileSnapshot.isEmpty {
                    MonitoringEventDetail(title: "认证文件", value: event.authFileSnapshot)
                }
                if !event.resolvedModel.isEmpty && event.displayResolvedModel != event.displayModel {
                    MonitoringEventDetail(title: "解析模型", value: event.displayResolvedModel)
                }
                if !event.authProjectIdSnapshot.isEmpty {
                    MonitoringEventDetail(title: "项目", value: event.authProjectIdSnapshot)
                }
                if !event.apiKeyHash.isEmpty {
                    MonitoringEventDetail(title: "API Key 哈希", value: event.apiKeyHash)
                }
                if !event.sourceHash.isEmpty {
                    MonitoringEventDetail(title: "来源哈希", value: event.sourceHash)
                }
                if !event.reasoningEffort.isEmpty || !event.serviceTier.isEmpty || !event.executorType.isEmpty {
                    MonitoringEventDetail(
                        title: "执行选项",
                        value: [event.reasoningEffort, event.serviceTier, event.executorType]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    )
                }

                MonitoringEventDetail(
                    title: "Token",
                    value: OasesLocalization.localizedFormat("输入 %@ · 输出 %@ · 总计 %@", event.inputTokens.formatted(), event.outputTokens.formatted(), event.totalTokens.formatted())
                )
                MonitoringEventDetail(
                    title: "耗时",
                    value: latencyDetail
                )

                if event.failed {
                    if !event.headerErrorKind.isEmpty || !event.headerErrorCode.isEmpty {
                        MonitoringEventDetail(
                            title: "错误标记",
                            value: [event.headerErrorKind, event.headerErrorCode]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                        )
                    }
                    if !event.headerTraceId.isEmpty {
                        MonitoringEventDetail(title: "Trace ID", value: event.headerTraceId)
                    }
                    if let summary = event.safeFailureSummary {
                        MonitoringEventDetail(title: "错误摘要（已截断）", value: summary)
                    }
                }

                if !event.rawFields.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: Oases.Space.xs) {
                            ForEach(event.rawFields) { field in
                                HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
                                    Text(verbatim: field.key)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 220, alignment: .leading)
                                        .lineLimit(2)
                                    Text(verbatim: field.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(6)
                                    Spacer(minLength: 0)
                                }
                            }
                            Text("CPAMP 返回的全部字段；认证头、Cookie、管理密钥等凭证字段不显示，其余值中的密钥已替换成 ••••。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, Oases.Space.xs)
                    } label: {
                        Text(OasesLocalization.localizedFormat("原始字段（%lld）", event.rawFields.count))
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                }
            }
            .padding(.leading, 35)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: event.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(event.failed ? Color.oasesRed : Color.oasesGreen)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.sourceTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(modelTitle) · \(eventTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(event.statusTitle)
                        .foregroundStyle(event.failed ? Color.oasesRed : Color.oasesGreen)
                        .font(.caption.weight(.semibold))
                    Text(latencyTitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 82, alignment: .trailing)
            }
            .padding(.vertical, 7)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private var modelTitle: String {
        event.model.isEmpty ? OasesLocalization.localized("未标记模型") : event.displayModel
    }

    private var requestTarget: String {
        let path = !event.path.isEmpty ? event.path : event.endpoint
        guard !event.method.isEmpty else { return path.isEmpty ? OasesLocalization.localized("未标记路径") : path }
        return path.isEmpty ? event.method : "\(event.method) \(path)"
    }

    private var eventTime: String {
        guard event.timestampMs > 0 else { return OasesLocalization.localized("时间未知") }
        return Date(timeIntervalSince1970: TimeInterval(event.timestampMs) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private var latencyTitle: String {
        guard let latency = event.latencyMs else { return OasesLocalization.localized("暂无") }
        return OasesLocalization.localizedFormat("%.1f 秒", Double(latency) / 1_000)
    }

    private var latencyDetail: String {
        var parts = [OasesLocalization.localizedFormat("总耗时 %@", latencyTitle)]
        if let ttft = event.ttftMs {
            parts.append(OasesLocalization.localizedFormat("首字节 %@", OasesLocalization.localizedFormat("%.1f 秒", Double(ttft) / 1_000)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct MonitoringEventDetail: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}

struct MonitoringHeaderSnapshotsCard: View {
    let snapshots: [RuntimeMonitoringHeaderSnapshot]
    let isLoading: Bool
    let hasLoaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "认证响应信号",
                    subtitle: "最近 30 天 · 每个认证身份仅显示最新一条",
                    icon: "waveform.path.ecg.rectangle"
                )
                Spacer()
                StatusPill(
                    title: statusTitle,
                    tint: hasLoaded ? .oasesGreen : .oasesOrange,
                    systemImage: hasLoaded ? "checkmark.circle" : "link.badge.plus"
                )
            }

            if isLoading {
                ProgressView("正在读取认证响应信号…")
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else if snapshots.isEmpty {
                Text(
                    hasLoaded
                        ? "最近 30 天没有可归一化的认证响应信号"
                        : "连接目标环境后显示每个认证身份最新的额度、恢复时间和结构化错误信号"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                ForEach(snapshots) { snapshot in
                    MonitoringHeaderSnapshotRow(snapshot: snapshot)
                }
            }

            Text("只显示 CPAMP 从响应头归一化出的额度、恢复时间、错误码与 trace；不会显示原始 response metadata、响应正文或 Provider 密钥。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .oasesCard()
    }

    private var statusTitle: String {
        if isLoading {
            return OasesLocalization.localized("读取中")
        }
        return hasLoaded ? OasesLocalization.localized("已接入") : OasesLocalization.localized("待接入")
    }
}

struct MonitoringAccountHistoryCard: View {
    let entries: [RuntimeMonitoringAccountHistoryEntry]
    let checkpoint: RuntimeMonitoringAccountHistoryCheckpoint?
    let isLoading: Bool
    let isCatchingUp: Bool
    let hasLoaded: Bool
    let canCatchUp: Bool
    let onCatchUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "认证历史概览",
                    subtitle: "由最近 30 天的安全身份信号关联 · 聚合可覆盖更早历史",
                    icon: "chart.line.uptrend.xyaxis"
                )
                Spacer()
                StatusPill(
                    title: statusTitle,
                    tint: statusTint,
                    systemImage: statusImage
                )
                Button {
                    onCatchUp()
                } label: {
                    if isCatchingUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("补齐历史汇总", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canCatchUp || isLoading)
                .help("仅在确认后补齐当前 CPAMP 本地监控数据库中的聚合。")
            }

            if isLoading {
                ProgressView(
                    isCatchingUp
                        ? "正在补齐本地认证历史汇总…"
                        : "正在读取认证历史汇总…"
                )
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else if entries.isEmpty {
                Text(
                    hasLoaded
                        ? "最近 30 天的认证响应信号中，没有可用于关联历史的身份字段。"
                        : "连接目标环境后，会显示每个安全认证身份的调用、Token、估算花费与成功率聚合。"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                if let checkpoint, checkpoint.pending {
                    accountHistoryWarning(checkpoint)
                } else if let checkpoint, checkpoint.processed > 0 {
                    accountHistoryCompletion(checkpoint)
                }

                ForEach(entries) { entry in
                    MonitoringAccountHistoryRow(entry: entry)
                }
            }

            Text("仅显示请求次数、Token、估算花费、成功率与时间范围；不会显示 account key、原始 response metadata、响应正文或 Provider 密钥。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .oasesCard()
    }

    private var statusTitle: String {
        if isCatchingUp {
            return OasesLocalization.localized("补齐中")
        }
        if isLoading {
            return OasesLocalization.localized("读取中")
        }
        if checkpoint?.pending == true {
            return OasesLocalization.localized("待补齐")
        }
        return hasLoaded ? OasesLocalization.localized("已接入") : OasesLocalization.localized("待接入")
    }

    private var statusTint: Color {
        if checkpoint?.pending == true {
            return .oasesOrange
        }
        return hasLoaded ? .oasesGreen : .oasesOrange
    }

    private var statusImage: String {
        if checkpoint?.pending == true {
            return "clock.arrow.circlepath"
        }
        return hasLoaded ? "checkmark.circle" : "link.badge.plus"
    }

    private func accountHistoryWarning(
        _ checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.oasesOrange)
            Text(warningText(checkpoint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func accountHistoryCompletion(
        _ checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.oasesGreen)
            Text(OasesLocalization.localizedFormat("本次已在当前 CPAMP 本地监控数据库中补齐 %@ 条记录的聚合。", checkpoint.processed.formatted()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func warningText(
        _ checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    ) -> String {
        if checkpoint.processed > 0 {
            return OasesLocalization.localizedFormat("仍有监控记录待汇总；本次已处理 %@ 条，当前聚合可能尚不完整。", checkpoint.processed.formatted())
        }
        return OasesLocalization.localized("CPAMP 仍有监控记录待汇总，当前聚合可能不完整。确认“补齐历史汇总”后，最多处理 5,000 条本地记录。")
    }
}

struct MonitoringAccountHistoryRow: View {
    let entry: RuntimeMonitoringAccountHistoryEntry

    var body: some View {
        DisclosureGroup {
            if let item = entry.item {
                VStack(alignment: .leading, spacing: 8) {
                    MonitoringEventDetail(title: "汇总状态", value: item.syncStatus.title)
                    if item.matched {
                        MonitoringEventDetail(
                            title: "调用",
                            value: OasesLocalization.localizedFormat("总计 %@ · 成功 %@ · 失败 %@", item.totalRequests.formatted(), item.successCalls.formatted(), item.failureCalls.formatted())
                        )
                        MonitoringEventDetail(
                            title: "Token",
                            value: item.totalTokens.formatted()
                        )
                        MonitoringEventDetail(
                            title: "估算花费",
                            value: item.totalCost.formatted(.currency(code: "USD"))
                        )
                        MonitoringEventDetail(
                            title: "成功率",
                            value: item.successRate?
                                .formatted(.percent.precision(.fractionLength(1))) ?? OasesLocalization.localized("未记录")
                        )
                        MonitoringEventDetail(title: "首次记录", value: timestamp(item.firstSeenMs))
                        MonitoringEventDetail(title: "最近记录", value: timestamp(item.lastSeenMs))
                    } else {
                        Text(unmatchedDescription(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 35)
                .padding(.top, 8)
            } else {
                Text("当前目标返回的此身份汇总项不完整；请稍后再试。")
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
                    .padding(.leading, 35)
                    .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: rowIcon)
                    .foregroundStyle(rowTint)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.target.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(primaryStatus)
                        .foregroundStyle(rowTint)
                        .font(.caption.weight(.semibold))
                    Text(secondaryStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 116, alignment: .trailing)
            }
            .padding(.vertical, 7)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private var rowIcon: String {
        guard let item = entry.item else {
            return "exclamationmark.triangle.fill"
        }
        if item.syncStatus == .pending {
            return "clock.arrow.circlepath"
        }
        if !item.matched {
            return "tray"
        }
        return "chart.line.uptrend.xyaxis"
    }

    private var rowTint: Color {
        guard let item = entry.item else {
            return .oasesOrange
        }
        if item.syncStatus == .pending {
            return .oasesOrange
        }
        return item.matched ? .oasesBlue : .secondary
    }

    private var primaryStatus: String {
        guard let item = entry.item else {
            return OasesLocalization.localized("数据不完整")
        }
        return item.syncStatus.title
    }

    private var secondaryStatus: String {
        guard let item = entry.item, item.matched else {
            return OasesLocalization.localized("暂无")
        }
        return OasesLocalization.localizedFormat("调用 %@", item.totalRequests.formatted())
    }

    private var summarySubtitle: String {
        guard let item = entry.item else {
            return OasesLocalization.localized("请稍后重试")
        }
        if !item.matched {
            return unmatchedDescription(for: item)
        }
        let successRate = item.successRate?
            .formatted(.percent.precision(.fractionLength(1))) ?? OasesLocalization.localized("成功率未记录")
        return "Token \(item.totalTokens.formatted()) · \(successRate)"
    }

    private func unmatchedDescription(
        for item: RuntimeMonitoringAccountHistoryItem
    ) -> String {
        item.syncStatus == .pending
            ? "该身份的历史汇总仍待补齐。"
            : "当前目标中尚无此身份的历史汇总。"
    }

    private func timestamp(_ milliseconds: Int64?) -> String {
        guard let milliseconds, milliseconds > 0 else {
            return OasesLocalization.localized("未记录")
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }
}

struct MonitoringHeaderSnapshotRow: View {
    let snapshot: RuntimeMonitoringHeaderSnapshot

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                MonitoringEventDetail(title: "时间", value: snapshotTime)
                MonitoringEventDetail(title: "认证来源", value: snapshot.sourceTitle)

                if !snapshot.providerTitle.isEmpty {
                    MonitoringEventDetail(title: "认证", value: snapshot.providerTitle)
                }
                if !snapshot.accountSnapshot.isEmpty {
                    MonitoringEventDetail(title: "账号快照", value: snapshot.accountSnapshot)
                }
                if !snapshot.authFileSnapshot.isEmpty {
                    MonitoringEventDetail(title: "认证文件", value: snapshot.authFileSnapshot)
                }
                if !snapshot.authProjectIdSnapshot.isEmpty {
                    MonitoringEventDetail(title: "项目", value: snapshot.authProjectIdSnapshot)
                }
                if !snapshot.source.isEmpty {
                    MonitoringEventDetail(title: "来源", value: snapshot.source)
                }
                if !snapshot.sourceHash.isEmpty {
                    MonitoringEventDetail(title: "来源哈希", value: snapshot.sourceHash)
                }
                if let quota = snapshot.quotaUsedPercentTitle {
                    MonitoringEventDetail(title: "额度已用", value: quota)
                }
                if !snapshot.headerQuotaPlanType.isEmpty {
                    MonitoringEventDetail(title: "套餐", value: snapshot.headerQuotaPlanType)
                }
                if let recoveryTime {
                    MonitoringEventDetail(title: "预计恢复", value: recoveryTime)
                }
                if let errorTitle = snapshot.errorTitle {
                    MonitoringEventDetail(title: "错误标记", value: errorTitle)
                }
                if !snapshot.headerTraceId.isEmpty {
                    MonitoringEventDetail(title: "Trace ID", value: snapshot.headerTraceId)
                }
            }
            .padding(.leading, 35)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: signalIcon)
                    .foregroundStyle(signalTint)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.sourceTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(primaryStatus)
                        .foregroundStyle(signalTint)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let recoveryTime {
                        Text(OasesLocalization.localizedFormat("恢复 %@", recoveryTime))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(snapshotTime)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 156, alignment: .trailing)
            }
            .padding(.vertical, 7)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private var signalIcon: String {
        if snapshot.hasErrorSignal {
            return "exclamationmark.triangle.fill"
        }
        if let quota = snapshot.headerQuotaUsedPercent, quota >= 90 {
            return "gauge.with.dots.needle.67percent"
        }
        return "waveform.path.ecg"
    }

    private var signalTint: Color {
        if snapshot.hasErrorSignal {
            return .oasesRed
        }
        if let quota = snapshot.headerQuotaUsedPercent, quota >= 90 {
            return .oasesOrange
        }
        return .oasesBlue
    }

    private var primaryStatus: String {
        if let errorTitle = snapshot.errorTitle {
            return errorTitle
        }
        if let quota = snapshot.quotaUsedPercentTitle {
            return OasesLocalization.localizedFormat("额度已用 %@", quota)
        }
        return OasesLocalization.localized("已记录响应信号")
    }

    private var summarySubtitle: String {
        [snapshot.providerTitle, snapshotTime]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var snapshotTime: String {
        Date(timeIntervalSince1970: TimeInterval(snapshot.timestampMs) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private var recoveryTime: String? {
        guard let milliseconds = snapshot.headerQuotaRecoverAtMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }
}

struct QuotaResetState: Equatable {
    private(set) var targetID: String?
    private(set) var isResetting = false

    mutating func beginConfirmation(for targetID: String) -> Bool {
        guard self.targetID == nil, !isResetting else { return false }
        self.targetID = targetID
        return true
    }

    mutating func cancelConfirmation() {
        guard !isResetting else { return }
        targetID = nil
    }

    mutating func beginReset() -> Bool {
        guard targetID != nil, !isResetting else { return false }
        isResetting = true
        return true
    }

    mutating func finishReset() {
        targetID = nil
        isResetting = false
    }
}

struct QuotaView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var cooldownToReset: RuntimeQuotaCooldown?
    @State private var quotaResetState = QuotaResetState()
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    Spacer()
                    Button("刷新证据", systemImage: "arrow.clockwise") {
                        runtimeDataStore.refreshQuota(using: deploymentStore)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtimeDataStore.isLoadingQuota || deploymentStore.stage != .attached)
                }

                QuotaStatusStrip(
                    authFileCount: runtimeDataStore.authFiles.count,
                    cooldownCount: runtimeDataStore.quotaCooldowns.count,
                    evidenceCount: runtimeDataStore.quotaEvidence.count,
                    stage: deploymentStore.stage
                )

                InfoBanner(
                    title: "原生读取真实 Provider 额度",
                    message: quotaInfoMessage,
                    systemImage: "lock.shield",
                    tint: .oasesGreen
                )

                if let error = runtimeDataStore.quotaErrorMessage {
                    InfoBanner(
                        title: "部分配额证据读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                if runtimeDataStore.isLoadingQuota {
                    ProgressView("正在读取目标额度与冷却状态…")
                        .padding(.vertical, 8)
                }

                if !runtimeDataStore.quotaCooldowns.isEmpty {
                    QuotaSectionCard(
                        title: "当前冷却",
                        subtitle: "CPAMP usage service 的真实 cooldown 记录",
                        icon: "hourglass"
                    ) {
                        ForEach(runtimeDataStore.quotaCooldowns) { cooldown in
                            QuotaCooldownRow(
                                cooldown: cooldown,
                                isResetting: cooldownIsResetting(cooldown)
                            ) {
                                guard quotaResetState.beginConfirmation(for: cooldown.id) else { return }
                                cooldownToReset = cooldown
                            }
                        }
                    }
                }

                if runtimeDataStore.quotaEvidence.isEmpty {
                    QuotaSectionCard(
                        title: "Provider 额度证据",
                        subtitle: "支持的认证文件会在这里显示窗口与重置时间",
                        icon: "chart.bar.xaxis"
                    ) {
                        Text(deploymentStore.stage == .attached
                            ? "当前目标没有可读取的 Codex、Claude、Kimi 或 xAI 认证文件，或尚未完成读取。"
                            : "连接目标环境后，这里会显示 Provider 返回的真实额度窗口。"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(
                            title: "Provider 额度证据",
                            subtitle: "由目标内 CLIProxyAPI 代理请求，响应只在本次 App 会话内展示",
                            icon: "chart.bar.xaxis"
                        )
                        ForEach(sortedEvidence) { evidence in
                            QuotaEvidenceCard(evidence: evidence)
                        }
                    }
                }
            }
            .padding(28)
        }
        .task {
            runtimeDataStore.refreshQuota(using: deploymentStore)
        }
        .onChange(of: deploymentStore.stage) { _, stage in
            guard stage == .attached else { return }
            runtimeDataStore.refreshQuota(using: deploymentStore)
        }
        .onChange(of: runtimeDataStore.authFiles.count) { _, _ in
            guard deploymentStore.stage == .attached else { return }
            runtimeDataStore.refreshQuota(using: deploymentStore)
        }
        .confirmationDialog(
            "清除额度冷却？",
            isPresented: Binding(
                get: { cooldownToReset != nil },
                set: {
                    if !$0 && !quotaResetState.isResetting {
                        cooldownToReset = nil
                        quotaResetState.cancelConfirmation()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let cooldown = cooldownToReset {
                Button(resetButtonTitle(for: cooldown), role: .destructive) {
                    resetQuota(cooldown)
                }
                .disabled(quotaResetState.isResetting)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会调用 CLIProxyAPI 的 reset-quota，清除该 auth_index 的运行时配额状态。Provider 真实额度不会被修改。")
        }
        .alert("配额操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? OasesLocalization.localized("未知错误"))
        }
    }

    private func resetQuota(_ cooldown: RuntimeQuotaCooldown) {
        guard quotaResetState.beginReset() else { return }
        Task { @MainActor in
            defer {
                quotaResetState.finishReset()
                cooldownToReset = nil
            }
            do {
                try await runtimeDataStore.resetQuota(cooldown, using: deploymentStore)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func cooldownIsResetting(_ cooldown: RuntimeQuotaCooldown) -> Bool {
        quotaResetState.isResetting && quotaResetState.targetID == cooldown.id
    }

    private var connectionTitle: String {
        deploymentStore.stage == .attached ? OasesLocalization.localized("已连接目标") : OasesLocalization.localized("未连接目标")
    }

    private var connectionTint: Color {
        deploymentStore.stage == .attached ? .oasesGreen : .oasesOrange
    }

    private var connectionImage: String {
        deploymentStore.stage == .attached ? "checkmark.circle" : "link.badge.plus"
    }

    private var quotaInfoMessage: String {
        deploymentStore.stage == .attached
            ? "App 通过 CLIProxyAPI 的管理 API 代理额度请求，按 auth_index 选择凭证；明文 token 留在目标环境内。cooldown 则直接读取 CPAMP 的 usage service。"
            : "连接本机或 VPS 后，Oases CPA 会读取目标环境中的认证状态、cooldown 与 Provider 返回的额度窗口。"
    }

    private var sortedEvidence: [RuntimeQuotaEvidence] {
        runtimeDataStore.quotaEvidence.values.sorted { $0.fileName < $1.fileName }
    }

    private func resetButtonTitle(for cooldown: RuntimeQuotaCooldown) -> String {
        OasesLocalization.localizedFormat("清除 %@ 的冷却", cooldown.authFileName)
    }
}

struct QuotaStatusStrip: View {
    let authFileCount: Int
    let cooldownCount: Int
    let evidenceCount: Int
    let stage: DeploymentStage

    var body: some View {
        HStack(spacing: 12) {
            StatusPill(title: OasesLocalization.localizedFormat("%lld 个认证文件", authFileCount), tint: .oasesBlue, systemImage: "folder")
            StatusPill(title: OasesLocalization.localizedFormat("%lld 个冷却中", cooldownCount), tint: .oasesOrange, systemImage: "hourglass")
            StatusPill(title: OasesLocalization.localizedFormat("%lld 个额度证据", evidenceCount), tint: .oasesPurple, systemImage: "chart.bar.xaxis")
            StatusPill(
                title: stage == .attached ? OasesLocalization.localized("已连接目标") : OasesLocalization.localized("未连接目标"),
                tint: stage == .attached ? .oasesGreen : .oasesOrange,
                systemImage: stage == .attached ? "checkmark.circle" : "link.badge.plus"
            )
        }
    }
}

struct QuotaSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: title, subtitle: subtitle, icon: icon)
            content
        }
        .padding(20)
        .oasesCard()
    }
}

struct QuotaCooldownRow: View {
    let cooldown: RuntimeQuotaCooldown
    let isResetting: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.oasesOrange)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(cooldown.authFileName)
                        .font(.headline)
                    if let provider = cooldown.provider, !provider.isEmpty {
                        Text(provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Oases.Color.textSecondary)
                    }
                }
                Text(cooldownDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(OasesLocalization.localizedFormat("恢复时间：%@ · %@", cooldown.recoverAt.formatted(date: .abbreviated, time: .shortened), recoveryHint))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("清除冷却", systemImage: "arrow.counterclockwise") {
                onReset()
            }
            .buttonStyle(.bordered)
            .disabled(isResetting || cooldown.authIndex == nil)
            if isResetting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private var cooldownDetail: String {
        var parts: [String] = []
        if let windowKind = cooldown.windowKind, !windowKind.isEmpty { parts.append(windowKind) }
        if let reason = cooldown.reasonCode, !reason.isEmpty { parts.append(reason) }
        if let owner = cooldown.owner, !owner.isEmpty { parts.append(owner) }
        return parts.isEmpty ? "Provider quota cooldown" : parts.joined(separator: " · ")
    }

    private var recoveryHint: String {
        let seconds = cooldown.recoverAt.timeIntervalSinceNow
        if seconds <= 0 { return OasesLocalization.localized("已到恢复时间") }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return OasesLocalization.localizedFormat("约 %lld 分钟后", minutes) }
        return OasesLocalization.localizedFormat("约 %lld 小时后", Int(ceil(Double(minutes) / 60)))
    }
}

struct QuotaEvidenceCard: View {
    let evidence: RuntimeQuotaEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusTint)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(evidence.fileName).font(.headline)
                        Text(evidence.provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusTint)
                    }
                    Text(evidenceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(evidence.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
            }

            if let message = evidence.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(evidence.status == .failed ? .red : .secondary)
                    .textSelection(.enabled)
            }

            ForEach(evidence.windows) { window in
                QuotaWindowRow(window: window)
            }
        }
        .padding(18)
        .oasesCard()
    }

    private var statusTint: Color {
        switch evidence.status {
        case .success: return .oasesGreen
        case .failed: return .oasesOrange
        case .unsupported: return .secondary
        }
    }

    private var statusIcon: String {
        switch evidence.status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .unsupported: return "questionmark.circle"
        }
    }

    private var evidenceSummary: String {
        var parts = [OasesLocalization.localizedFormat("%lld 个窗口", evidence.windows.count)]
        if let plan = evidence.plan, !plan.isEmpty { parts.append(plan) }
        parts.append(OasesLocalization.localizedFormat("读取于 %@", evidence.observedAt.formatted(date: .omitted, time: .shortened)))
        return parts.joined(separator: " · ")
    }
}

struct QuotaWindowRow: View {
    let window: RuntimeQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.label)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let percent = window.normalizedUsedPercent {
                        Text(OasesLocalization.localizedFormat("已用 %@%%", percent.formatted(.number.precision(.fractionLength(0)))))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(percent >= 90 ? Color.oasesOrange : Color.secondary)
                } else if let used = window.used, let limit = window.limit {
                    Text("\(used.formatted(.number.precision(.fractionLength(0)))) / \(limit.formatted(.number.precision(.fractionLength(0))))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let percent = window.normalizedUsedPercent {
                ProgressView(value: percent, total: 100)
                    .tint(percent >= 90 ? .oasesOrange : .oasesBlue)
            } else if let used = window.used, let limit = window.limit, limit > 0 {
                ProgressView(value: used, total: limit)
                    .tint(.oasesBlue)
            }

            HStack(spacing: 12) {
                if let remaining = window.normalizedRemainingPercent {
                    Text(OasesLocalization.localizedFormat("剩余约 %@%%", remaining.formatted(.number.precision(.fractionLength(0)))))
                }
                if let resetAt = window.resetAt {
                    Text(OasesLocalization.localizedFormat("重置 %@", resetAt.formatted(date: .abbreviated, time: .shortened)))
                } else if let resetAfter = window.resetAfterSeconds {
                    Text(OasesLocalization.localizedFormat("约 %lld 分钟后重置", Int(ceil(resetAfter / 60))))
                }
                if let seconds = window.limitWindowSeconds, seconds > 0 {
                    Text(OasesLocalization.localizedFormat("窗口 %@", windowLength(seconds)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private func windowLength(_ seconds: Double) -> String {
        let hours = seconds / 3_600
        if hours >= 24 { return OasesLocalization.localizedFormat("%lld 天", Int(hours / 24)) }
        if hours >= 1 { return OasesLocalization.localizedFormat("%lld 小时", Int(hours)) }
        return OasesLocalization.localizedFormat("%lld 分钟", Int(max(1, seconds / 60)))
    }
}

struct QuotaCard: View {
    let quota: QuotaSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(quota.tint)
                Spacer()
                Text(quota.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(quota.tint)
            }

            Text(quota.title)
                .font(.headline)
            Text(OasesLocalization.localizedFormat("剩余 %@", quota.remaining.formatted(.percent.precision(.fractionLength(0)))))
                .font(.title2.weight(.semibold).monospacedDigit())

            ProgressView(value: quota.remaining)
                .tint(quota.tint)
            Text(quota.reset)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .oasesCard()
    }
}

/// Compatibility shim for the former tinted banner: an inline row of an SF Symbol in the
/// status colour and the text. No fill, no border.
struct InfoBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Oases.Color.textPrimary)
                Text(LocalizedStringKey(message))
                    .font(.callout)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Oases.Space.xs)
        .accessibilityElement(children: .combine)
    }
}
