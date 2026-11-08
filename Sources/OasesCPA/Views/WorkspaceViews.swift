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
                    PageHeader(section: .usageAnalytics)
                    Spacer()
                    StatusPill(
                        title: isRangeLive ? "实时数据" : (runtimeDataStore.isLoadingAnalytics ? "读取中" : "连接后显示"),
                        tint: isRangeLive ? .oasesGreen : .oasesOrange,
                        systemImage: isRangeLive ? "waveform.path.ecg" : "link.badge.plus"
                    )
                    Picker("时间范围", selection: $range) {
                        ForEach(RuntimeDashboardRange.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 310)
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
            .init(title: "缓存占比", value: cachedShare?.formatted(.percent.precision(.fractionLength(1))) ?? "暂无", caption: "摘要返回的 Token 构成", systemImage: "externaldrive.fill", tint: .oasesMint),
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
    @State private var accountHistoryCatchUpConfirmationPresented = false
    @State private var retainedMonitoringEvents: [RuntimeMonitoringEvent] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageHeader(section: .monitoring)
                    Spacer()
                    Button("账号待办", systemImage: "person.crop.circle.badge.exclamationmark") {
                        store.selectSection(.accountActions)
                    }
                    .buttonStyle(.bordered)
                    Button("成本与价格", systemImage: "dollarsign.arrow.circlepath") {
                        store.selectSection(.modelPrices)
                    }
                    .buttonStyle(.bordered)
                    Button("高级 CPAMP 面板", systemImage: "rectangle.on.rectangle") {
                        store.selectSection(.panel)
                    }
                    .buttonStyle(.bordered)
                    StatusPill(
                        title: isRangeLive ? "实时数据" : (runtimeDataStore.isLoadingMonitoring ? "读取中" : "连接后显示"),
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
                    .frame(width: 180)

                    Button {
                        store.refresh()
                        runtimeDataStore.refresh(using: deploymentStore)
                        runtimeDataStore.refreshMonitoring(using: deploymentStore, range: range)
                        runtimeDataStore.refreshMonitoringEvents(
                            using: deploymentStore,
                            range: range,
                            searchQuery: appliedSearch,
                            failedOnly: appliedFailedOnly
                        )
                        runtimeDataStore.refreshMonitoringHeaderSnapshots(using: deploymentStore)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .oasesCard(cornerRadius: 14)

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
                        message: "连接成功后，这里显示所选范围内的 CPAMP 摘要与脱敏请求事件；原始响应和完整高级筛选仍可在 CPAMP 面板中查看。",
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

                    Text("只展示 CPAMP 返回的已知事件字段；原始响应元数据、错误文件和完整高级筛选保留在 CPAMP 面板。")
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
        appliedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedFailedOnly = failedOnly
        runtimeDataStore.refreshMonitoringEvents(
            using: deploymentStore,
            range: range,
            searchQuery: appliedSearch,
            failedOnly: appliedFailedOnly
        )
    }

    private var monitoringRefreshTaskID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpampBaseURL.absoluteString)|\(range.rawValue)|\(appliedSearch)|\(appliedFailedOnly)|\(scenePhase == .active)"
    }

    private var visibleMonitoringEvents: [RuntimeMonitoringEvent] {
        if runtimeDataStore.isLoadingMonitoringEvents && runtimeDataStore.monitoringEvents.isEmpty {
            return retainedMonitoringEvents
        }
        return runtimeDataStore.monitoringEvents
    }

    private var eventSubtitle: String {
        var parts = [range.title, appliedFailedOnly ? "仅失败" : "全部状态"]
        if !appliedSearch.isEmpty {
            parts.append("已应用搜索")
        }
        if let total = runtimeDataStore.monitoringEventsTotalCount {
            parts.append(OasesLocalization.localizedFormat("共 %@ 条", total.formatted()))
        }
        return parts.joined(separator: " · ")
    }

    private var eventStatusTitle: String {
        if runtimeDataStore.isLoadingMonitoringEvents {
            return "读取中"
        }
        return isEventListLive ? "已接入" : "待接入"
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
        event.model.isEmpty ? "未标记模型" : event.displayModel
    }

    private var requestTarget: String {
        let path = !event.path.isEmpty ? event.path : event.endpoint
        guard !event.method.isEmpty else { return path.isEmpty ? "未标记路径" : path }
        return path.isEmpty ? event.method : "\(event.method) \(path)"
    }

    private var eventTime: String {
        guard event.timestampMs > 0 else { return "时间未知" }
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
            Text(title)
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
            return "读取中"
        }
        return hasLoaded ? "已接入" : "待接入"
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
            return "补齐中"
        }
        if isLoading {
            return "读取中"
        }
        if checkpoint?.pending == true {
            return "待补齐"
        }
        return hasLoaded ? "已接入" : "待接入"
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
        .background(Color.oasesOrange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountHistoryCompletion(
        _ checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.oasesGreen)
            Text(OasesLocalization.localizedFormat("本次已在当前 CPAMP 本地监控数据库中补齐 %@ 条记录的聚合。", checkpoint.processed.formatted()))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.oasesGreen.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func warningText(
        _ checkpoint: RuntimeMonitoringAccountHistoryCheckpoint
    ) -> String {
        if checkpoint.processed > 0 {
            return OasesLocalization.localizedFormat("仍有监控记录待汇总；本次已处理 %@ 条，当前聚合可能尚不完整。", checkpoint.processed.formatted())
        }
        return "CPAMP 仍有监控记录待汇总，当前聚合可能不完整。确认“补齐历史汇总”后，最多处理 5,000 条本地记录。"
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
                                .formatted(.percent.precision(.fractionLength(1))) ?? "未记录"
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
            return "数据不完整"
        }
        return item.syncStatus.title
    }

    private var secondaryStatus: String {
        guard let item = entry.item, item.matched else {
            return "暂无"
        }
        return OasesLocalization.localizedFormat("调用 %@", item.totalRequests.formatted())
    }

    private var summarySubtitle: String {
        guard let item = entry.item else {
            return "请稍后重试"
        }
        if !item.matched {
            return unmatchedDescription(for: item)
        }
        let successRate = item.successRate?
            .formatted(.percent.precision(.fractionLength(1))) ?? "成功率未记录"
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
            return "未记录"
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
        return "已记录响应信号"
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

struct ProvidersView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.openWindow) private var openWindow
    @State private var deletingProvider: RuntimeOpenAICompatibility?
    @State private var deleteConfirmationPresented = false
    @State private var advancedToolsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    PageHeader(section: .aiProviders)
                    Spacer()
                    Button("添加 AI 服务", systemImage: "plus") {
                        presentProviderEditor(.createOpenAICompatibility)
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingProviders)
                }

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "先连接你的电脑或服务器",
                        message: "连接成功后，就能在这里添加 AI 服务地址和密钥。Oases CPA 会自动读取模型并帮你检查是否可用。",
                        systemImage: "link.badge.plus",
                        tint: .oasesOrange
                    )
                } else {
                    openAICompatibilityCard
                }

                if deploymentStore.stage == .attached {
                    advancedTools
                }
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshProviders(using: deploymentStore)
        }
        .confirmationDialog(
            "删除兼容 Provider？",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let provider = deletingProvider {
                Button(OasesLocalization.localizedFormat("删除 %@", provider.name), role: .destructive) {
                    Task {
                        do {
                            try await runtimeDataStore.deleteOpenAICompatibility(
                                provider,
                                using: deploymentStore
                            )
                            deletingProvider = nil
                        } catch {
                            // RuntimeDataStore exposes the localized failure in
                            // the Provider card and keeps the target visible.
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会从当前目标 CLIProxyAPI 的兼容 Provider 列表中删除该条目。")
        }
    }

    private var advancedTools: some View {
        DisclosureGroup(isExpanded: $advancedToolsExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                DirectProviderCredentialsCard()

                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(
                            title: "运行概况",
                            subtitle: "需要排查调用问题时再查看",
                            icon: "waveform.path.ecg"
                        )
                        VStack(spacing: 0) {
                            ForEach(Array(channels.enumerated()), id: \.offset) { _, channel in
                                HStack(spacing: 12) {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                        .foregroundStyle(tint(for: channel.tone))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(channelTitle(channel))
                                            .font(.subheadline.weight(.semibold))
                                        Text(OasesLocalization.localizedFormat("调用 %@ · 失败 %@ · Token %@", channel.calls.formatted(), channel.failures.formatted(), compactToken(Double(channel.tokens))))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusPill(title: statusTitle(channel.tone), tint: tint(for: channel.tone))
                                }
                                .padding(.vertical, 10)
                                if channel.authIndex != channels.last?.authIndex { Divider() }
                            }
                        }
                    }
                    .padding(20)
                    .oasesCard()
                }

                ProviderConnectivityCard()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("需要完整控制？")
                            .font(.headline)
                        Text("打开 CPAMP 查看原始配置和诊断工具。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开高级面板", systemImage: "rectangle.on.rectangle") {
                        store.selectSection(.panel)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
                .oasesCard()
            }
            .padding(.top, 16)
        } label: {
            Label("高级工具", systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
        .padding(20)
        .oasesCard()
    }

    private var openAICompatibilityCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                CardTitle(
                    title: "我的 AI 服务",
                    subtitle: "添加服务地址和密钥，其余交给 Oases CPA",
                    icon: "sparkles"
                )
                Spacer()
                if runtimeDataStore.isLoadingProviders {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    runtimeDataStore.refreshProviders(using: deploymentStore)
                }
                .buttonStyle(.bordered)
                .disabled(deploymentStore.stage != .attached || runtimeDataStore.isLoadingProviders)
            }

            if deploymentStore.stage != .attached {
                Text("连接本机或服务器后，这里会显示你添加的 AI 服务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let error = runtimeDataStore.providerErrorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.oasesRed)
            } else if runtimeDataStore.openAICompatibility.isEmpty && !runtimeDataStore.isLoadingProviders {
                ContentUnavailableView {
                    Label("还没有 AI 服务", systemImage: "sparkles")
                } description: {
                    Text("粘贴服务地址和 API Key，App 会自动读取模型并检查连接。")
                } actions: {
                    Button("添加第一个 AI 服务", systemImage: "plus") {
                        presentProviderEditor(.createOpenAICompatibility)
                    }
                    .buttonStyle(.oasesPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runtimeDataStore.openAICompatibility.enumerated()), id: \.element.id) { index, provider in
                        HStack(spacing: 14) {
                            Image(systemName: provider.disabled ? "pause.circle" : "arrow.left.arrow.right.circle.fill")
                                .font(.title3)
                                .foregroundStyle(provider.disabled ? Color.oasesOrange : Color.oasesMint)
                                .frame(width: 36, height: 36)
                                .oasesIconTile()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(provider.name.isEmpty ? "未命名服务" : provider.name)
                                        .font(.headline)
                                    if provider.disabled {
                                        StatusPill(title: "已停用", tint: .oasesOrange, systemImage: "pause")
                                    }
                                }
                                Text(provider.baseURL.isEmpty ? "未填写服务地址" : provider.baseURL)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(summary(for: provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("编辑", systemImage: "slider.horizontal.3") {
                                presentProviderEditor(.editOpenAICompatibility(providerID: provider.id))
                            }
                            .buttonStyle(.bordered)

                            Menu {
                                Button("编辑", systemImage: "slider.horizontal.3") {
                                    presentProviderEditor(.editOpenAICompatibility(providerID: provider.id))
                                }
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    deletingProvider = provider
                                    deleteConfirmationPresented = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .help("更多操作")
                        }
                        .padding(.vertical, 13)

                        if index < runtimeDataStore.openAICompatibility.count - 1 {
                            Divider()
                        }
                    }
                }
            }

        }
        .padding(20)
        .oasesCard()
    }

    private func summary(for provider: RuntimeOpenAICompatibility) -> String {
        let keySummary = provider.apiKeyEntries.isEmpty ? "无密钥" : OasesLocalization.localizedFormat("密钥 %lld 个", provider.apiKeyEntries.count)
        let modelSummary = provider.models.isEmpty ? "跟随上游模型" : OasesLocalization.localizedFormat("模型映射 %lld 个", provider.models.count)
        let prefixSummary = provider.prefix.isEmpty ? "无前缀" : OasesLocalization.localizedFormat("前缀 %@", provider.prefix)
        return "\(keySummary) · \(modelSummary) · \(prefixSummary)"
    }

    private func presentProviderEditor(_ route: ProviderEditorRoute) {
        store.openProviderEditor(route)
        openWindow(id: ProviderEditorWindowScene.id)
    }

    private var channels: [RuntimeChannelHealth] {
        runtimeDataStore.dashboard?.channelHealth ?? []
    }

    private func channelTitle(_ channel: RuntimeChannelHealth) -> String {
        channel.authLabel ?? channel.channel ?? channel.source ?? channel.authIndex
    }

    private func statusTitle(_ tone: String) -> String {
        switch tone {
        case "bad": return "异常"
        case "warn": return "关注"
        default: return "正常"
        }
    }

    private func tint(for tone: String) -> Color {
        switch tone {
        case "bad": return .oasesRed
        case "warn": return .oasesOrange
        default: return .oasesGreen
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

struct AuthFilesView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var editingFile: RuntimeAuthFile?
    @State private var creatingFile = false
    @State private var importingFile = false
    @State private var exportingFile = false
    @State private var exportDocument = RuntimeAuthJSONDocument()
    @State private var exportFileName = "auth.json"
    @State private var deletingFile: RuntimeAuthFile?
    @State private var deleteConfirmationPresented = false
    @State private var importConfirmationPresented = false
    @State private var pendingImportName: String?
    @State private var pendingImportData: Data?
    @State private var operationErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageHeader(section: .authFiles)
                    Spacer()
                    if runtimeDataStore.isLoadingAuthFiles {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("高级 CPAMP 面板", systemImage: "rectangle.on.rectangle") {
                        store.selectSection(.panel)
                    }
                    .buttonStyle(.bordered)
                    Menu("添加", systemImage: "plus") {
                        Button("导入 JSON", systemImage: "square.and.arrow.down") {
                            importingFile = true
                        }
                        Button("新建 JSON", systemImage: "doc.badge.plus") {
                            creatingFile = true
                        }
                    }
                    .menuStyle(.borderedButton)
                    .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingAuthFiles)
                }

                HStack(spacing: 12) {
                    StatusPill(title: OasesLocalization.localizedFormat("%lld 个认证文件", runtimeDataStore.authFiles.count), tint: .oasesBlue, systemImage: "folder")
                    StatusPill(title: OasesLocalization.localizedFormat("%lld 个健康", healthyCount), tint: .oasesGreen, systemImage: "checkmark.circle")
                    StatusPill(title: OasesLocalization.localizedFormat("%lld 个需关注", attentionCount), tint: .oasesOrange, systemImage: "exclamationmark.triangle")
                }

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "连接后读取认证池",
                        message: "认证文件只从当前目标环境读取。完成本机或 SSH 部署后，这里会显示文件名、类型和启用状态，并可直接导入、编辑、下载、删除和启停认证文件。",
                        systemImage: "lock.shield",
                        tint: .oasesOrange
                    )
                } else if let error = runtimeDataStore.authFilesErrorMessage {
                    InfoBanner(
                        title: "认证文件读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                } else if runtimeDataStore.authFiles.isEmpty {
                    InfoBanner(
                        title: "当前没有认证文件",
                        message: "可以通过“添加”导入 JSON，或打开 CPAMP 面板开始 OAuth 授权。",
                        systemImage: "doc.badge.plus",
                        tint: .oasesBlue
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(runtimeDataStore.authFiles) { file in
                            RuntimeAuthFileRow(
                                file: file,
                                onEdit: { editingFile = file },
                                onExport: { exportFile(file) },
                                onToggle: { toggleFile(file) },
                                onDelete: {
                                    deletingFile = file
                                    deleteConfirmationPresented = true
                                }
                            )
                            if file.id != runtimeDataStore.authFiles.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 20)
                    .oasesCard()
                }

                if let operationErrorMessage {
                    InfoBanner(
                        title: "认证文件操作失败",
                        message: operationErrorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                }

                OAuthModelPoliciesCard()

                InfoBanner(
                    title: "原生操作直连 CLIProxyAPI",
                    message: "认证文件导入、JSON 替换、下载、删除、启停，以及 OAuth 模型排除和别名规则都会直接调用当前目标的 Management API；OAuth 授权和其它高级流程仍可在 CPAMP 面板继续完成。",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .oasesBlue
                )
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshAuthFiles(using: deploymentStore)
            runtimeDataStore.refreshOAuthModelPolicies(using: deploymentStore)
        }
        .sheet(item: $editingFile) { file in
            AuthFileEditorView(file: file)
        }
        .sheet(isPresented: $creatingFile) {
            AuthFileEditorView(file: nil)
        }
        .fileImporter(
            isPresented: $importingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $exportingFile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                operationErrorMessage = OasesLocalization.localizedFormat("导出认证文件失败：%@", error.localizedDescription)
            }
        }
        .confirmationDialog(
            "删除认证文件？",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let file = deletingFile {
                Button(OasesLocalization.localizedFormat("删除 %@", file.name), role: .destructive) {
                    deleteFile(file)
                    deletingFile = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会从当前目标 CLIProxyAPI 的认证目录中删除该 JSON 文件。删除前请确认你仍保留必要的凭证备份。")
        }
        .confirmationDialog(
            "替换同名认证文件？",
            isPresented: $importConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let name = pendingImportName {
                Button(OasesLocalization.localizedFormat("替换 %@", name), role: .destructive) {
                    uploadPendingImport()
                }
            }
            Button("取消", role: .cancel) {
                pendingImportName = nil
                pendingImportData = nil
            }
        } message: {
            Text("目标中已存在同名文件。替换会立即更新 CLIProxyAPI 当前使用的认证内容。")
        }
    }

    private var healthyCount: Int {
        runtimeDataStore.authFiles.filter { $0.statusTint == .healthy }.count
    }

    private var attentionCount: Int {
        runtimeDataStore.authFiles.count - healthyCount
    }

    private func exportFile(_ file: RuntimeAuthFile) {
        operationErrorMessage = nil
        Task { @MainActor in
            do {
                let data = try await runtimeDataStore.downloadAuthFileData(file, using: deploymentStore)
                exportDocument = RuntimeAuthJSONDocument(data: data)
                exportFileName = file.name
                exportingFile = true
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("读取认证文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func toggleFile(_ file: RuntimeAuthFile) {
        let disabled = file.disabled != true
        operationErrorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.setAuthFileDisabled(
                    file,
                    disabled: disabled,
                    using: deploymentStore
                )
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("更新认证文件状态失败：%@", error.localizedDescription)
            }
        }
    }

    private func deleteFile(_ file: RuntimeAuthFile) {
        operationErrorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.deleteAuthFile(file, using: deploymentStore)
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("删除认证文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            operationErrorMessage = OasesLocalization.localizedFormat("选择认证文件失败：%@", error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let name = url.lastPathComponent
                guard name.lowercased().hasSuffix(".json"),
                      !name.contains("/"),
                      !name.contains("\\") else {
                    throw RuntimeDataStoreError.invalidAuthFileName
                }
                let data = try Data(contentsOf: url)
                guard let canonicalData = canonicalJSONData(from: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if runtimeDataStore.authFiles.contains(where: { $0.name == name }) {
                    pendingImportName = name
                    pendingImportData = canonicalData
                    importConfirmationPresented = true
                } else {
                    uploadImportedFile(name: name, data: canonicalData)
                }
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("导入认证文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func uploadPendingImport() {
        guard let name = pendingImportName, let data = pendingImportData else { return }
        pendingImportName = nil
        pendingImportData = nil
        uploadImportedFile(name: name, data: data)
    }

    private func uploadImportedFile(name: String, data: Data) {
        operationErrorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.uploadAuthFile(
                    name: name,
                    data: data,
                    using: deploymentStore
                )
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("保存导入文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func canonicalJSONData(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ),
        object is [String: Any],
        JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

struct RuntimeAuthFileRow: View {
    let file: RuntimeAuthFile
    let onEdit: (() -> Void)?
    let onExport: (() -> Void)?
    let onToggle: (() -> Void)?
    let onDelete: (() -> Void)?

    init(
        file: RuntimeAuthFile,
        onEdit: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil,
        onToggle: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.file = file
        self.onEdit = onEdit
        self.onExport = onExport
        self.onToggle = onToggle
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.badge.gearshape")
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(file.name).font(.headline)
                    if let provider = file.provider ?? file.type, !provider.isEmpty {
                        Text(provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.oasesBlue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.oasesBlue.opacity(0.10), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(file.displayStatus)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            if hasActions {
                Menu {
                    if let onEdit {
                        Button("编辑 JSON", systemImage: "pencil", action: onEdit)
                    }
                    if let onExport {
                        Button("下载 JSON", systemImage: "square.and.arrow.down", action: onExport)
                    }
                    if let onToggle {
                        Button(
                            file.disabled == true ? "启用认证文件" : "停用认证文件",
                            systemImage: file.disabled == true ? "checkmark.circle" : "pause.circle",
                            action: onToggle
                        )
                    }
                    if let onDelete {
                        Divider()
                        Button("删除认证文件", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Label("操作", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("认证文件操作")
            }
        }
        .padding(.vertical, 14)
    }

    private var hasActions: Bool {
        onEdit != nil || onExport != nil || onToggle != nil || onDelete != nil
    }

    private var tint: Color {
        file.statusTint == .healthy ? .oasesGreen : .oasesOrange
    }

    private var detail: String {
        var parts: [String] = []
        if let size = file.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let authIndex = file.authIndex, !authIndex.isEmpty { parts.append("auth-index \(authIndex)") }
        if file.runtimeOnly == true { parts.append("运行时凭证") }
        if let message = file.statusMessage, !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? "CLIProxyAPI 认证文件" : parts.joined(separator: " · ")
    }
}

struct AccountRow: View {
    let account: AccountHealth

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(account.tint)
                .frame(width: 34, height: 34)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(account.name).font(.headline)
                    Text(account.provider)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.oasesBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.oasesBlue.opacity(0.10), in: Capsule())
                }
                Text(OasesLocalization.localizedFormat("%@ · 脱敏状态摘要", account.plan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if account.remaining > 0 {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(OasesLocalization.localizedFormat("额度剩余 %lld%%", account.remaining))
                        .font(.caption.weight(.semibold))
                    ProgressView(value: Double(account.remaining), total: 100)
                        .tint(account.tint)
                        .frame(width: 120)
                }
            }

            Text(account.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(account.tint)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 14)
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
                    PageHeader(section: .quota)
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

                Button("打开 CPAMP 完整面板", systemImage: "rectangle.on.rectangle") {
                    store.selectSection(.panel)
                }
                .buttonStyle(.bordered)
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
            Text(actionError ?? "未知错误")
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
        deploymentStore.stage == .attached ? "已连接目标" : "未连接目标"
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
                title: stage == .attached ? "已连接目标" : "未连接目标",
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
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(cooldown.authFileName)
                        .font(.headline)
                    if let provider = cooldown.provider, !provider.isEmpty {
                        Text(provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.oasesBlue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.oasesBlue.opacity(0.1), in: Capsule())
                    }
                }
                Text(cooldownDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(OasesLocalization.localizedFormat("恢复时间：%@ · %@", cooldown.recoverAt.formatted(date: .abbreviated, time: .shortened), recoveryHint))
                    .font(.caption)
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
                    .oasesIconTile()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(evidence.fileName).font(.headline)
                        Text(evidence.provider.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(statusTint.opacity(0.1), in: Capsule())
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
                            .font(.caption.weight(.semibold))
                        .foregroundStyle(percent >= 90 ? Color.oasesOrange : Color.secondary)
                } else if let used = window.used, let limit = window.limit {
                    Text("\(used.formatted(.number.precision(.fractionLength(0)))) / \(limit.formatted(.number.precision(.fractionLength(0))))")
                        .font(.caption.weight(.semibold))
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
                .font(.system(size: 27, weight: .bold, design: .rounded))

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

struct GenericWorkspaceView: View {
    let section: AppSection
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(section: section)

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        CardTitle(title: "原生工作区已就绪", subtitle: "保留 CPAMP 的业务边界，改用 macOS 交互模型", icon: section.systemImage)

                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("打开 CPAMP 面板", systemImage: "rectangle.on.rectangle") {
                            store.selectSection(.panel)
                        }
                        .buttonStyle(.oasesPrimary)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .oasesCard()

                    VStack(alignment: .leading, spacing: 13) {
                        Text("下一阶段")
                            .font(.headline)
                        ForEach(nextSteps, id: \.self) { step in
                            Label(step, systemImage: "circle.dashed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(22)
                    .frame(width: 300, alignment: .leading)
                    .oasesCard()
                }

                InfoBanner(
                    title: deploymentStore.stage == .attached ? "当前工作区直连 CPAMP" : "连接目标环境后可用",
                    message: deploymentStore.stage == .attached
                        ? "Oases CPA 负责目标连接、生命周期和安全存储；此功能的实际读写由当前目标上的 CPA Manager Plus 面板完成。"
                        : "先在连接与部署页选择本机终端或 SSH / VPS，完成部署后即可从 App 内打开对应目标的 CPAMP 面板。",
                    systemImage: deploymentStore.stage == .attached ? "checkmark.circle" : "info.circle",
                    tint: deploymentStore.stage == .attached ? .oasesGreen : .oasesOrange
                )
            }
            .padding(28)
        }
    }

    private var description: String {
        switch section {
        case .config: "这里会承接 config.yaml 的可视化编辑、Diff、重启策略以及未保存变更保护。"
        case .plugins: "这里会承接插件资源、插件页面和 OAuth 能力，保留 CPAMP 的扩展边界。"
        case .oauth: "这里会承接 OpenRouter、GitHub Copilot 等第三方授权流程，并把凭证写入对应 Provider。"
        case .logs: "这里会承接运行日志、版本化证据和脱敏错误详情，方便从请求一路追到服务。"
        case .system: "这里会承接 CPA Base URL、面板版本、引擎版本、连接测试与本机运行信息。"
        default: section.subtitle
        }
    }

    private var nextSteps: [String] {
        switch section {
        case .config: ["接入 config API", "加入 YAML Diff", "保存前重启确认"]
        case .plugins: ["读取插件目录", "加载资源页面", "支持插件 OAuth"]
        case .oauth: ["接入授权回调", "安全存储凭证", "补齐失败恢复"]
        case .logs: ["接入日志端点", "按请求关联", "导出脱敏证据"]
        case .system: ["Keychain 管理密钥", "连接健康检查", "原生通知反馈"]
        default: ["API 契约映射", "真实数据刷新", "状态持久化"]
        }
    }
}

struct InfoBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title)).font(.callout.weight(.semibold))
                Text(LocalizedStringKey(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Oases.Space.md)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Oases.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Oases.Radius.panel, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }
}
