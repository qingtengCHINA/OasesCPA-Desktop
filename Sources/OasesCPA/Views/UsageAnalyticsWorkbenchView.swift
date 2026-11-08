import Charts
import SwiftUI

@MainActor
struct UsageAnalyticsWorkbenchView: View {
    @ObservedObject private var deploymentStore: DeploymentStore
    @StateObject private var store: UsageAnalyticsWorkbenchStore
    @State private var customFrom = Date().addingTimeInterval(-24 * 60 * 60)
    @State private var customTo = Date()
    @State private var advancedFiltersExpanded = false

    init(deploymentStore: DeploymentStore) {
        self.deploymentStore = deploymentStore
        _store = StateObject(wrappedValue: UsageAnalyticsWorkbenchStore(deploymentStore: deploymentStore))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBar
                tabBar
                filterBar

                if !store.isAttached {
                    ContentUnavailableView {
                        Label("连接目标后查看用量", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("请先在连接与部署中接入本机或 SSH / VPS 目标。数据只来自当前目标的 CPAMP 监控接口。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .oasesCard()
                } else if store.isLoading && store.response == nil {
                    ProgressView("正在读取用量分析…")
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if let errorMessage = store.errorMessage, store.response == nil {
                    ContentUnavailableView {
                        Label("用量分析读取失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试", systemImage: "arrow.clockwise") { store.refreshNow() }
                            .buttonStyle(.oasesPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .oasesCard()
                } else if let response = store.response {
                    content(response)
                } else {
                    ContentUnavailableView("暂无用量数据", systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .oasesCard()
                }
            }
            .padding(28)
        }
        .task {
            store.activate()
        }
        .onDisappear {
            store.deactivate()
        }
        .onChange(of: deploymentStore.stage) { _, _ in
            store.refreshNow()
        }
        .onChange(of: store.selectedTab) { _, _ in store.refreshNow() }
        .onChange(of: store.range) { _, _ in store.refreshNow() }
        .onChange(of: store.granularity) { _, _ in store.refreshNow() }
        .onChange(of: store.status) { _, _ in store.refreshNow() }
        .onChange(of: store.cacheStatus) { _, _ in store.refreshNow() }
        .onChange(of: store.minimumLatencyMS) { _, _ in store.refreshNow() }
        .onChange(of: store.searchQuery) { _, _ in store.refreshNow() }
    }

    private var titleBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                analyticsTitle
                Spacer()
                titleActions
            }
            VStack(alignment: .leading, spacing: 12) {
                analyticsTitle
                titleActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var analyticsTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("用量分析")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("请求、Token、成本与成功率在同一时间范围内联动展示")
                .foregroundStyle(.secondary)
        }
    }

    private var titleActions: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let updated = store.lastUpdated {
                VStack(alignment: .leading, spacing: 5) {
                    Text("实时更新")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.oasesGreen)
                    Text(updated, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button("刷新", systemImage: "arrow.clockwise") { store.refreshNow() }
                .buttonStyle(.bordered)
                .disabled(store.isLoading || !store.isAttached)
        }
    }

    /// Geist-style tabs: plain labels, the selected one in primary text over an ink underline.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Oases.Space.l) {
                ForEach(RuntimeUsageAnalyticsTab.allCases) { tab in
                    let isSelected = store.selectedTab == tab
                    Button {
                        store.selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Oases.Color.textPrimary : Oases.Color.textSecondary)
                            .lineLimit(1)
                            .padding(.vertical, Oases.Space.sm)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isSelected ? Oases.Color.ink : Color.clear)
                                    .frame(height: 2)
                                    .offset(y: 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Oases.Space.xs)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Oases.Color.border).frame(height: 1)
        }
        .animation(Oases.Motion.stateChange, value: store.selectedTab)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rangePicker
                    granularityPicker
                    analyticsSearchField
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        rangePicker
                        granularityPicker
                    }
                    analyticsSearchField
                }
            }

            if case .custom = store.range {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        customDateControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        customDateControls
                    }
                }
            }

            DisclosureGroup("高级筛选", isExpanded: $advancedFiltersExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            selectionMenu("模型", values: store.filterOptions?.publicModels ?? [], selection: store.selectedModels) { value in
                                toggle(value, in: \UsageAnalyticsWorkbenchStore.selectedModels)
                            }
                            selectionMenu("Provider", values: store.filterOptions?.providers ?? [], selection: store.selectedProviders) { value in
                                toggle(value, in: \UsageAnalyticsWorkbenchStore.selectedProviders)
                            }
                            selectionMenu("凭证", values: store.filterOptions?.authFiles ?? [], selection: store.selectedCredentials) { value in
                                toggle(value, in: \UsageAnalyticsWorkbenchStore.selectedCredentials)
                            }
                            selectionMenu("调用 Key", values: store.filterOptions?.apiKeyHashes ?? [], selection: store.selectedAPIKeys) { value in
                                toggle(value, in: \UsageAnalyticsWorkbenchStore.selectedAPIKeys)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            secondaryFilterControls
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            secondaryFilterControls
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(16)
        .oasesCard()
    }

    private var rangePicker: some View {
        Picker("时间范围", selection: Binding(
            get: { rangePreset(for: store.range) },
            set: { preset in
                if preset == .custom {
                    store.range = .custom(from: customFrom, to: customTo)
                } else {
                    store.range = preset.range
                }
            }
        )) {
            ForEach(AnalyticsRangePreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.menu)
    }

    private var granularityPicker: some View {
        Picker("粒度", selection: $store.granularity) {
            ForEach(RuntimeUsageAnalyticsGranularity.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 230)
    }

    private var analyticsSearchField: some View {
        TextField("搜索请求 ID、模型、Provider、Key 或错误原因", text: $store.searchQuery)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: .infinity)
    }

    @ViewBuilder
    private var customDateControls: some View {
        DatePicker("开始", selection: $customFrom, displayedComponents: [.date, .hourAndMinute])
        DatePicker("结束", selection: $customTo, displayedComponents: [.date, .hourAndMinute])
        Button("应用") {
            store.range = .custom(from: customFrom, to: customTo)
        }
        .buttonStyle(.oasesPrimary)
    }

    @ViewBuilder
    private var secondaryFilterControls: some View {
        Picker("状态", selection: $store.status) {
            ForEach(RuntimeUsageAnalyticsStatusFilter.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.menu)
        Picker("缓存", selection: $store.cacheStatus) {
            ForEach(RuntimeUsageAnalyticsCacheStatus.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.menu)
        TextField("最小延迟 ms", value: $store.minimumLatencyMS, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 130)
        Button("清除筛选", systemImage: "xmark.circle") { store.resetFilters() }
            .buttonStyle(.bordered)
    }

    private func content(_ response: RuntimeUsageAnalyticsResponse) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let errorMessage = store.errorMessage {
                InfoBanner(title: "本次刷新失败", message: errorMessage, systemImage: "exclamationmark.triangle", tint: .oasesOrange)
            }
            summaryCards(response.summary)
            switch store.selectedTab {
            case .overview:
                overview(response)
            case .trends:
                trends(response)
            case .modelRanks:
                ranks(title: "模型调用排行", subtitle: "按请求次数排序；同次数按成本和名称稳定排序", models: response.publicModelStats)
            case .apiKeyRanks:
                apiKeyRanks(response.apiKeyStats)
            case .credentialRanks:
                credentialRanks(response.credentialStats)
            case .heatmap:
                heatmap(response.heatmap)
            }
        }
    }

    private func summaryCards(_ summary: RuntimeUsageAnalyticsSummary?) -> some View {
        let cards: [(String, String, String, Color)] = [
            ("请求数", summary.map { "\($0.totalCalls)" } ?? OasesLocalization.localized("暂无"), "arrow.down.circle", .oasesBlue),
            ("成功率", summary.map { RuntimeUsageAnalyticsPresentation.percentage($0.successRate) } ?? OasesLocalization.localized("暂无"), "checkmark.circle", .oasesGreen),
            ("总 Token", summary.map { formatTokens($0.totalTokens) } ?? OasesLocalization.localized("暂无"), "number", .oasesMint),
            ("预计成本", summary.map { String(format: "$%.4f", $0.totalCost) } ?? OasesLocalization.localized("暂无"), "dollarsign.circle", .oasesOrange),
            ("P95 延迟", summary.flatMap { $0.p95LatencyMS }.map { String(format: "%.0f ms", $0) } ?? OasesLocalization.localized("暂无"), "gauge.with.dots.needle.33percent", .oasesPurple),
            ("RPM / TPM", summary.map { String(format: "%.1f / %@", $0.rpm30M, formatTokens(Int64($0.tpm30M))) } ?? OasesLocalization.localized("暂无"), "waveform.path.ecg", .oasesRed)
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(cards, id: \.0) { card in
                VStack(alignment: .leading, spacing: 8) {
                    Label(OasesLocalization.localized(card.0), systemImage: card.2)
                        .foregroundStyle(card.3)
                        .font(.callout.weight(.semibold))
                    Text(card.1)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(summarySubtitle(card.0, summary: summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .oasesCard(cornerRadius: 13)
            }
        }
    }

    private func overview(_ response: RuntimeUsageAnalyticsResponse) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            trendCard(response.timeline, title: "用量趋势", subtitle: "请求数与 Token 随时间变化")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    anomalyCard(response.anomalyPoints)
                    drilldownCard(response.drilldownPreview ?? RuntimeUsageAnalyticsEventsResponse(items: [], nextBeforeMs: 0, nextBeforeId: 0, hasMore: false, totalCount: 0))
                }
                VStack(spacing: 18) {
                    anomalyCard(response.anomalyPoints)
                    drilldownCard(response.drilldownPreview ?? RuntimeUsageAnalyticsEventsResponse(items: [], nextBeforeMs: 0, nextBeforeId: 0, hasMore: false, totalCount: 0))
                }
            }
        }
    }

    private func trends(_ response: RuntimeUsageAnalyticsResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            trendCard(response.timeline, title: "趋势分析", subtitle: "点击筛选条件后每 5 秒读取最新窗口")
            if response.timeline.isEmpty {
                emptyCard("当前时间范围没有趋势数据")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: "分桶明细", subtitle: "请求、Token、成功率和成本", icon: "tablecells")
                    ForEach(response.timeline) { point in
                        HStack {
                            Text(point.label.isEmpty ? formatDate(point.bucketMs) : point.label)
                                .frame(width: 150, alignment: .leading)
                            Text(OasesLocalization.localizedFormat("%lld 次", point.calls))
                            Text(formatTokens(point.totalTokens))
                            Text(RuntimeUsageAnalyticsPresentation.percentage(point.successRate))
                                .foregroundStyle(point.failure > 0 ? Color.oasesOrange : Color.oasesGreen)
                            Spacer()
                            Text(String(format: "$%.4f", point.cost))
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
                .padding(18)
                .oasesCard()
            }
        }
    }

    private func trendCard(_ points: [RuntimeUsageAnalyticsTimelinePoint], title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: title, subtitle: subtitle, icon: "chart.xyaxis.line")
            if points.isEmpty {
                Text("当前时间范围暂无数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 230)
            } else {
                Chart(points) { point in
                    AreaMark(
                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(point.bucketMs) / 1_000)),
                        y: .value("请求", point.calls)
                    )
                    .foregroundStyle(Color.oasesBlue.opacity(0.12))
                    LineMark(
                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(point.bucketMs) / 1_000)),
                        y: .value("请求", point.calls)
                    )
                    .foregroundStyle(Color.oasesBlue)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("时间", Date(timeIntervalSince1970: TimeInterval(point.bucketMs) / 1_000)),
                        y: .value("请求", point.calls)
                    )
                    .foregroundStyle(Color.oasesBlue)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 250)
            }
        }
        .padding(18)
        .oasesCard()
    }

    private func ranks(title: String, subtitle: String, models: [RuntimeUsageAnalyticsModelStat]) -> some View {
        let rows = RuntimeUsageAnalyticsPresentation.sortedModels(models)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: title, subtitle: subtitle, icon: "square.3.layers.3d")
            if rows.isEmpty {
                Text("当前时间范围暂无模型数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rankRow(rank: index + 1, title: row.model, calls: row.calls, tokens: row.totalTokens, rate: row.successRate, cost: row.cost)
                }
            }
        }
        .padding(18)
        .oasesCard()
    }

    private func apiKeyRanks(_ values: [RuntimeUsageAnalyticsAPIKeyStat]) -> some View {
        let rows = RuntimeUsageAnalyticsPresentation.sortedAPIKeys(values)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "调用 API Key 排行", subtitle: "按客户端调用量查看使用分布，Key 仅显示脱敏哈希", icon: "key.horizontal")
            if rows.isEmpty {
                Text("当前时间范围暂无客户端 Key 数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rankRow(rank: index + 1, title: row.apiKeyHash.isEmpty ? row.id : row.apiKeyHash, calls: row.calls, tokens: row.totalTokens, rate: row.successRate, cost: row.cost)
                }
            }
        }
        .padding(18)
        .oasesCard()
    }

    private func credentialRanks(_ values: [RuntimeUsageAnalyticsCredentialStat]) -> some View {
        let rows = RuntimeUsageAnalyticsPresentation.sortedCredentials(values)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "凭证调用排行", subtitle: "查看上游认证文件的请求与成本分布", icon: "person.crop.circle.badge.key")
            if rows.isEmpty {
                Text("当前时间范围暂无凭证数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rankRow(rank: index + 1, title: row.authFileSnapshot.isEmpty ? row.id : row.authFileSnapshot, calls: row.calls, tokens: row.totalTokens, rate: row.successRate, cost: row.cost)
                }
            }
        }
        .padding(18)
        .oasesCard()
    }

    private func rankRow(rank: Int, title: String, calls: Int64, tokens: Int64, rate: Double, cost: Double) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? OasesLocalization.localized("未标记") : title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(OasesLocalization.localizedFormat("%lld 次 · %@ Token", calls, formatTokens(tokens)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(RuntimeUsageAnalyticsPresentation.percentage(rate))
                .foregroundStyle(rate >= 0.99 ? Color.oasesGreen : Color.oasesOrange)
                .frame(width: 70, alignment: .trailing)
            Text(String(format: "$%.4f", cost))
                .font(.callout.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
        }
        .padding(11)
        .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func heatmap(_ points: [RuntimeUsageAnalyticsHeatmapPoint]) -> some View {
        let maximum = max(1, points.map(\.calls).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "用量热力图", subtitle: "按本地时区显示一周内不同小时的请求密度", icon: "square.grid.3x3")
            if points.isEmpty {
                Text("当前时间范围暂无热力图数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 230)
            } else {
                Chart(points) { point in
                    RectangleMark(
                        x: .value("小时", point.hour),
                        y: .value("星期", point.weekday),
                        width: .ratio(0.88),
                        height: .ratio(0.88)
                    )
                    .foregroundStyle(by: .value("请求数", point.calls))
                    .opacity(0.35 + 0.65 * Double(point.calls) / Double(maximum))
                }
                .chartForegroundStyleScale(range: Gradient(colors: [Color.oasesBlue.opacity(0.15), Color.oasesBlue]))
                .chartXScale(domain: 0...23)
                .chartYScale(domain: 0...6)
                .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) }
                .chartYAxis { AxisMarks(values: Array(0...6)) }
                .frame(height: 310)
            }
        }
        .padding(18)
        .oasesCard()
    }

    private func anomalyCard(_ values: [RuntimeUsageAnalyticsAnomalyPoint]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "异常提示", subtitle: "服务端根据趋势变化标记需要关注的时间段", icon: "waveform.path.ecg.rectangle")
            if values.isEmpty {
                Label("当前没有明显异常", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.oasesGreen)
                    .padding(.vertical, 12)
            } else {
                ForEach(values.prefix(5)) { anomaly in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: anomaly.severity.lowercased() == "high" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(anomaly.severity.lowercased() == "high" ? Color.oasesRed : Color.oasesOrange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(anomaly.label)
                                .font(.callout.weight(.semibold))
                            Text(anomaly.metricKeys.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .oasesCard()
    }

    private func drilldownCard(_ events: RuntimeUsageAnalyticsEventsResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "请求预览", subtitle: "当前筛选条件下的最近请求", icon: "list.bullet.rectangle")
            if events.items.isEmpty {
                Text("暂无请求记录")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(events.items.prefix(5)) { event in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(event.failed ? Color.oasesRed : Color.oasesGreen)
                            .frame(width: 7, height: 7)
                        Text(event.model.isEmpty ? event.endpoint : event.displayModel)
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(event.totalTokens))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .oasesCard()
    }

    private func emptyCard(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(18)
            .oasesCard()
    }

    private func selectionMenu(
        _ title: String,
        values: [String],
        selection: Set<String>,
        toggle: @escaping (String) -> Void
    ) -> some View {
        Menu {
            if values.isEmpty {
                Text("暂无可选项")
            } else {
                ForEach(values.sorted(), id: \.self) { value in
                    Button {
                        toggle(value)
                    } label: {
                        Label(value, systemImage: selection.contains(value) ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Label(selection.isEmpty ? title : "\(title) · \(selection.count)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.bordered)
        .disabled(values.isEmpty)
    }

    private func toggle(_ value: String, in keyPath: ReferenceWritableKeyPath<UsageAnalyticsWorkbenchStore, Set<String>>) {
        if store[keyPath: keyPath].contains(value) {
            store[keyPath: keyPath].remove(value)
        } else {
            store[keyPath: keyPath].insert(value)
        }
        store.refreshNow()
    }

    private func rangePreset(for range: RuntimeUsageAnalyticsRange) -> AnalyticsRangePreset {
        switch range {
        case .recentHour: .recentHour
        case .today: .today
        case .yesterday: .yesterday
        case .last7Days: .last7Days
        case .last30Days: .last30Days
        case .custom: .custom
        }
    }

    private func summarySubtitle(_ title: String, summary: RuntimeUsageAnalyticsSummary?) -> String {
        guard let summary else { return OasesLocalization.localized("连接目标后读取") }
        switch title {
        case "请求数": return OasesLocalization.localizedFormat("失败 %lld 次", summary.failureCalls)
        case "成功率": return OasesLocalization.localizedFormat("成功 %lld 次", summary.successCalls)
        case "总 Token": return OasesLocalization.localizedFormat(
            "输入 %@ · 输出 %@",
            formatTokens(summary.inputTokens),
            formatTokens(summary.outputTokens)
        )
        case "预计成本": return OasesLocalization.localizedFormat(
            "每次 %@",
            String(format: "$%.5f", summary.averageCostPerCall)
        )
        case "P95 延迟": return OasesLocalization.localizedFormat(
            "平均 %@",
            summary.averageLatencyMS.map { String(format: "%.0f ms", $0) }
                ?? OasesLocalization.localized("暂无")
        )
        default: return OasesLocalization.localized("最近 30 分钟")
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        switch abs(value) {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private func formatDate(_ bucketMs: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(bucketMs) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}

private enum AnalyticsRangePreset: String, CaseIterable, Identifiable {
    case recentHour
    case today
    case yesterday
    case last7Days
    case last30Days
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentHour: OasesLocalization.localized("最近 1 小时")
        case .today: OasesLocalization.localized("今天")
        case .yesterday: OasesLocalization.localized("昨天")
        case .last7Days: OasesLocalization.localized("最近 7 天")
        case .last30Days: OasesLocalization.localized("最近 30 天")
        case .custom: OasesLocalization.localized("自定义")
        }
    }

    var range: RuntimeUsageAnalyticsRange {
        switch self {
        case .recentHour: .recentHour
        case .today: .today
        case .yesterday: .yesterday
        case .last7Days: .last7Days
        case .last30Days: .last30Days
        case .custom: .today
        }
    }
}
