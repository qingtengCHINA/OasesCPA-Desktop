import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.system.rawValue

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.l) {
                hero

                if let errorMessage = runtimeDataStore.errorMessage {
                    InfoBanner(
                        title: "已接入，但实时数据读取失败",
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                } else if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "尚未连接目标环境",
                        message: "先在“连接与部署”中选择本机终端或 SSH / VPS；连接完成后，这里只显示当前目标环境的真实数据。",
                        systemImage: "info.circle",
                        tint: .oasesBlue
                    )
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(runtimeMetrics) { metric in
                        MetricCard(metric: metric)
                    }
                }

                GatewayAccessSummaryCard()

                AdaptiveDashboardRow {
                    TrafficChartCard(points: runtimeTraffic)
                    HealthTimelineCard(dashboard: runtimeDataStore.dashboard)
                }
                .frame(minHeight: 300)

                AdaptiveDashboardRow {
                    TokenBreakdownCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 310)
                    ModelCostCard(dashboard: runtimeDataStore.dashboard)
                    ChannelHealthCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 310)
                }

                AdaptiveDashboardRow {
                    RecentFailuresCard(dashboard: runtimeDataStore.dashboard)
                    CollectorStatusCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 320)
                }
            }
            .padding(Oases.Space.page)
        }
        .background(Oases.Color.background)
        .task(id: liveRefreshTaskID) {
            guard scenePhase == .active, deploymentStore.stage == .attached else { return }

            while !Task.isCancelled {
                runtimeDataStore.refreshDashboard(using: deploymentStore)

                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var liveRefreshTaskID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpaClientURLString)|\(scenePhase == .active)"
    }

    private var heroTone: Oases.Tone {
        if runtimeDataStore.errorMessage != nil { return .warning }
        if runtimeDataStore.isLive { return .success }
        return deploymentStore.stage == .attached ? .info : .neutral
    }

    private var heroTitle: String {
        if runtimeDataStore.errorMessage != nil { return "已接入，但实时数据读取失败" }
        if runtimeDataStore.isLive { return "网关运行中 · 实时数据" }
        return deploymentStore.stage == .attached ? "已接入，正在读取数据" : "尚未连接目标环境"
    }

    /// One-line status bar: state, target and Base URL, last refresh, primary action.
    private var hero: some View {
        HStack(alignment: .center, spacing: Oases.Space.md) {
            StatusDot(tone: heroTone, size: 9)

            VStack(alignment: .leading, spacing: Oases.Space.xs) {
                Text(LocalizedStringKey(heroTitle))
                    .font(.headline)
                    .foregroundStyle(heroTone == .warning ? heroTone.text : Oases.Color.textPrimary)
                HStack(spacing: Oases.Space.sm) {
                    Text(deploymentStore.targetTitle)
                        .foregroundStyle(Oases.Color.textSecondary)
                    Text("·").foregroundStyle(Oases.Color.textTertiary)
                    OasesMonoValue(text: deploymentStore.cpaClientURLString, copyValue: deploymentStore.cpaClientURLString)
                        .fixedSize()
                }
                .font(.callout)
            }
            .layoutPriority(1)

            Spacer(minLength: Oases.Space.md)

            VStack(alignment: .trailing, spacing: 2) {
                Text("最近刷新")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textTertiary)
                Text(localizedTime(runtimeDataStore.lastDashboardRefreshAt ?? store.lastRefreshed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
            }

            if deploymentStore.stage == .attached {
                Button {
                    store.selectSection(.monitoring)
                } label: {
                    Label("查看请求监控", systemImage: "arrow.right")
                }
                .buttonStyle(.oasesPrimary)
            } else {
                Button {
                    store.selectSection(.environments)
                } label: {
                    Label("连接与部署", systemImage: "arrow.right")
                }
                .buttonStyle(.oasesPrimary)
            }
        }
        .padding(.horizontal, Oases.Space.l)
        .padding(.vertical, Oases.Space.md)
        .oasesCard(fill: heroTone == .warning ? Oases.Color.warningBg : Oases.Color.surface)
    }

    private var runtimeMetrics: [MetricSummary] {
        guard let dashboard = runtimeDataStore.dashboard else {
            return deploymentStore.stage == .attached ? loadingMetrics : emptyMetrics
        }
        let today = dashboard.today
        let rolling = dashboard.rolling30m
        let latency = today.averageLatencyMs.map {
            OasesLocalization.localizedFormat("%.1f 秒", $0 / 1_000)
        } ?? "暂无"
        return [
            .init(title: "今日请求", value: today.totalCalls.formatted(), caption: OasesLocalization.localizedFormat("失败 %@ 次", today.failureCalls.formatted()), systemImage: "arrow.down.circle", tint: .oasesBlue),
            .init(title: "RPM（30 分钟）", value: rolling.rpm.formatted(.number.precision(.fractionLength(1))), caption: OasesLocalization.localizedFormat("%@ 次请求", rolling.totalCalls.formatted()), systemImage: "chart.line.uptrend.xyaxis", tint: .oasesPurple),
            .init(title: "TPM（30 分钟）", value: compactToken(rolling.tpm), caption: "\(compactToken(Double(rolling.totalTokens))) Token", systemImage: "chart.bar.fill", tint: .oasesMint),
            .init(title: "今日成本", value: today.totalCost.formatted(.currency(code: "USD")), caption: OasesLocalization.localizedFormat("总 Token %@", compactToken(Double(today.totalTokens))), systemImage: "dollarsign.circle", tint: .oasesOrange),
            .init(title: "成功率", value: today.successRate.formatted(.percent.precision(.fractionLength(2))), caption: "\(today.successCalls.formatted()) / \(today.totalCalls.formatted())", systemImage: "checkmark.shield", tint: .oasesGreen),
            .init(title: "平均延迟", value: latency, caption: OasesLocalization.localizedFormat("零 Token %@ 次", today.zeroTokenCalls.formatted()), systemImage: "gauge.with.dots.needle.67percent", tint: .oasesRed)
        ]
    }

    private var runtimeTraffic: [TrafficPoint] {
        guard let points = runtimeDataStore.dashboard?.trafficTimeline, !points.isEmpty else { return [] }
        return points.map { point in
            TrafficPoint(
                label: localizedTime(Date(timeIntervalSince1970: TimeInterval(point.bucketMs) / 1_000)),
                requests: Double(point.calls),
                tokens: Double(point.tokens) / 1_000
            )
        }
    }

    private var loadingMetrics: [MetricSummary] {
        [
            .init(title: "今日请求", value: "暂无", caption: "正在读取 CPAMP", systemImage: "arrow.down.circle", tint: .oasesBlue),
            .init(title: "RPM（30 分钟）", value: "暂无", caption: "等待真实摘要", systemImage: "chart.line.uptrend.xyaxis", tint: .oasesPurple),
            .init(title: "TPM（30 分钟）", value: "暂无", caption: "等待真实摘要", systemImage: "chart.bar.fill", tint: .oasesMint),
            .init(title: "今日成本", value: "暂无", caption: "等待真实摘要", systemImage: "dollarsign.circle", tint: .oasesOrange),
            .init(title: "成功率", value: "暂无", caption: "等待真实摘要", systemImage: "checkmark.shield", tint: .oasesGreen),
            .init(title: "平均延迟", value: "暂无", caption: "等待真实摘要", systemImage: "gauge.with.dots.needle.67percent", tint: .oasesRed)
        ]
    }

    private var emptyMetrics: [MetricSummary] {
        [
            .init(title: "今日请求", value: "暂无", caption: "连接目标后读取", systemImage: "arrow.down.circle", tint: .oasesBlue),
            .init(title: "RPM（30 分钟）", value: "暂无", caption: "连接目标后读取", systemImage: "chart.line.uptrend.xyaxis", tint: .oasesPurple),
            .init(title: "TPM（30 分钟）", value: "暂无", caption: "连接目标后读取", systemImage: "chart.bar.fill", tint: .oasesMint),
            .init(title: "今日成本", value: "暂无", caption: "连接目标后读取", systemImage: "dollarsign.circle", tint: .oasesOrange),
            .init(title: "成功率", value: "暂无", caption: "连接目标后读取", systemImage: "checkmark.shield", tint: .oasesGreen),
            .init(title: "平均延迟", value: "暂无", caption: "连接目标后读取", systemImage: "gauge.with.dots.needle.67percent", tint: .oasesRed)
        ]
    }

    private func compactToken(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    private var interfaceLanguage: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .system
    }

    private func localizedTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(interfaceLanguage.locale)
        )
    }
}

private struct AdaptiveDashboardRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14, content: content)
            VStack(alignment: .leading, spacing: 14, content: content)
        }
    }
}

private struct DashboardHeroFact<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
                .lineLimit(1)
        }
    }
}

struct TrafficChartCard: View {
    let points: [TrafficPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "流量趋势（今日）", subtitle: "调用与 Token 的小时级变化", icon: "chart.xyaxis.line", destination: .usageAnalytics)

            if points.isEmpty {
                Text("连接成功后显示真实流量趋势")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("时间", point.label),
                        y: .value("调用", point.requests)
                    )
                    .foregroundStyle(Oases.Color.accent.opacity(0.55))
                    .cornerRadius(3)

                    LineMark(
                        x: .value("时间", point.label),
                        y: .value("Token", point.tokens)
                    )
                    .foregroundStyle(Oases.Color.violet)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
                .chartLegend(position: .top, alignment: .trailing)
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis { AxisMarks(values: .automatic) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .oasesCard()
    }
}

struct HealthTimelineCard: View {
    let dashboard: RuntimeDashboardSummary?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 18)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CardTitle(title: "请求健康时间线", subtitle: "今日请求健康状态，按 10 分钟聚合", icon: "square.grid.3x3", destination: .monitoring)
                Spacer()
                Text(successRate)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Oases.Color.successText)
            }

            Group {
                if points.isEmpty {
                    Text(dashboard == nil ? "连接目标环境后显示真实时间线" : "当前摘要未返回时间线数据")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                } else {
                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color(for: point))
                                .frame(height: 15)
                        }
                    }
                }
            }
            .padding(.top, 6)

            HStack(spacing: 13) {
                LegendDot(title: "无请求", color: Oases.Color.track)
                LegendDot(title: "成功", color: .oasesGreen)
                LegendDot(title: "警告", color: .oasesOrange)
                LegendDot(title: "失败", color: .oasesRed)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private var points: [RuntimeRequestHealthPoint] {
        dashboard?.todayRequestHealthTimeline?.points ?? []
    }

    private var successRate: String {
        guard let timeline = dashboard?.todayRequestHealthTimeline else { return "暂无" }
        return timeline.successRate.formatted(.percent.precision(.fractionLength(1)))
    }

    private func color(for point: RuntimeRequestHealthPoint) -> Color {
        if point.future || point.tone == "future" { return Oases.Color.wash }
        if point.calls == 0 || point.tone == "empty" { return Oases.Color.track }
        switch point.tone {
        case "bad": return .oasesRed
        case "warn": return .oasesOrange
        default: return .oasesGreen.opacity(point.intensity > 0 ? max(0.45, point.intensity) : 0.82)
        }
    }
}

struct TokenBreakdownCard: View {
    let dashboard: RuntimeDashboardSummary?

    private struct TokenRow: Identifiable {
        let id: String
        let title: String
        let value: String
        let share: Double
        let tint: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            CardTitle(title: "Token 构成", subtitle: "今日请求的用量分布", icon: "chart.pie")

            Text(totalTokens)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())

            if rows.isEmpty {
                Text(dashboard == nil ? "连接目标环境后显示真实构成" : "当前摘要未返回 Token 构成")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                VStack(spacing: 15) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(LocalizedStringKey(row.title))
                                Spacer()
                                Text(row.value).fontWeight(.semibold)
                                Text(row.share.formatted(.percent.precision(.fractionLength(1))))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .trailing)
                            }
                            .font(.caption)

                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Oases.Color.track)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(row.tint)
                                            .frame(width: max(6, proxy.size.width * row.share))
                                    }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var totalTokens: String {
        guard let total = dashboard?.today.totalTokens else { return "暂无" }
        return compactToken(Double(total))
    }

    private var rows: [TokenRow] {
        (dashboard?.tokenMix ?? []).map { segment in
            TokenRow(
                id: segment.key,
                title: tokenTitle(segment.key),
                value: compactToken(Double(segment.tokens)),
                share: segment.share,
                tint: tokenTint(segment.key)
            )
        }
    }

    private func tokenTitle(_ key: String) -> String {
        switch key {
        case "input": return "输入"
        case "output": return "输出"
        case "reasoning": return "推理"
        case "cached", "cache_read": return "缓存读取"
        case "cache_creation": return "缓存创建"
        default: return key
        }
    }

    private func tokenTint(_ key: String) -> Color {
        switch key {
        case "input": return Oases.Color.accent
        case "output": return Oases.Color.violet
        case "reasoning": return Oases.Color.textSecondary
        default: return Oases.Color.textTertiary
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

struct ModelCostCard: View {
    let dashboard: RuntimeDashboardSummary?

    private struct ModelCost: Identifiable {
        let id = UUID()
        let rank: Int
        let name: String
        let cost: String
        let weight: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            CardTitle(title: "模型成本排行", subtitle: "今日估算成本", icon: "arrow.up.right", destination: .modelPrices)

            if models.isEmpty {
                Text(dashboard == nil ? "连接目标环境后显示真实排行" : "当前摘要未返回模型成本数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(models) { model in
                    modelRow(model)
                }
            }

            Spacer(minLength: 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private var models: [ModelCost] {
        let entries: [(String, Double)]
        if let ranked = dashboard?.modelCostRank, !ranked.isEmpty {
            entries = ranked.map { ($0.model, $0.cost) }
        } else {
            entries = (dashboard?.topModelsToday ?? []).map { ($0.model, $0.cost) }
        }
        let maxCost = entries.map(\.1).max() ?? 0
        return entries.prefix(4).enumerated().map { index, entry in
            ModelCost(
                rank: index + 1,
                name: entry.0,
                cost: entry.1.formatted(.currency(code: "USD")),
                weight: maxCost > 0 ? max(0.06, entry.1 / maxCost) : 0.06
            )
        }
    }

    private func modelRow(_ model: ModelCost) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text("\(model.rank)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(model.rank == 1 ? Oases.Color.inkContrast : Oases.Color.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(model.rank == 1 ? Oases.Color.ink : Oases.Color.washStrong, in: RoundedRectangle(cornerRadius: Oases.Radius.small, style: .continuous))
                Text(model.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(model.cost)
                    .font(.callout.weight(.semibold).monospacedDigit())
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Oases.Color.track)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Oases.Color.accent)
                            .frame(width: proxy.size.width * model.weight)
                    }
            }
            .frame(height: 6)
        }
    }
}

struct ChannelHealthCard: View {
    let dashboard: RuntimeDashboardSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "渠道健康状态", subtitle: "当前 Provider 路由", icon: "point.3.connected.trianglepath.dotted", destination: .authFiles)

            if channels.isEmpty {
                Text(dashboard == nil ? "连接目标环境后显示真实渠道" : "当前摘要未返回渠道健康数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(Array(channels.prefix(4).enumerated()), id: \.offset) { _, channel in
                    HStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(tint(for: channel.tone))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channelTitle(channel))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("调用 \(channel.calls.formatted()) · 失败 \(channel.failures.formatted())")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(statusTitle(channel.tone))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: channel.tone))
                    }
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var channels: [RuntimeChannelHealth] {
        dashboard?.channelHealth ?? []
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
}

struct RecentFailuresCard: View {
    @EnvironmentObject private var store: AppStore
    let dashboard: RuntimeDashboardSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CardTitle(title: "最近请求", subtitle: "脱敏后的最近活动", icon: "clock.arrow.circlepath", destination: .monitoring)
                Spacer()
                Button("查看全部") {
                    store.selectSection(.monitoring)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if failures.isEmpty {
                Text(dashboard == nil ? "连接目标环境后显示真实请求" : "当前没有最近失败请求")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(Array(failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                    eventRow(failure)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private var failures: [RuntimeRecentFailure] {
        dashboard?.recentFailures ?? []
    }

    private func eventRow(_ event: RuntimeRecentFailure) -> some View {
        let source = event.authLabel ?? event.account ?? event.channel ?? event.source ?? event.authIndex
        let status = event.failStatusCode.map { "HTTP \($0)" } ?? "失败"
        let latency = event.durationMs.map { String(format: "%.1f 秒", $0 / 1_000) } ?? "暂无"
        let time = Date(timeIntervalSince1970: TimeInterval(event.timestampMs) / 1_000)
            .formatted(date: .omitted, time: .standard)
        return HStack(spacing: 12) {
            Circle()
                .fill(Color.oasesRed)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(source)
                    .font(.callout.weight(.medium))
                Text("\(event.model) · \(time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.oasesRed)
                Text(latency)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CollectorStatusCard: View {
    let dashboard: RuntimeDashboardSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            CardTitle(title: "采集器状态", subtitle: "Manager Server 数据采集", icon: "antenna.radiowaves.left.and.right")

            LabeledContent("模式") { Text(dashboard == nil ? "等待连接" : "实时 Management API") }
            LabeledContent("队列状态") {
                Text(dashboard == nil ? "待接入" : "已刷新")
                    .foregroundStyle(dashboard == nil ? Color.oasesOrange : Color.oasesGreen)
                    .fontWeight(.semibold)
            }
            LabeledContent("数据源") { Text("CPAMP 18317") }
            LabeledContent("最近数据") {
                Text(dashboard?.lastUpdated.formatted(date: .omitted, time: .shortened) ?? "暂无")
            }
            LabeledContent("隐私") {
                Text("摘要与脱敏标识")
                    .foregroundStyle(Color.oasesGreen)
            }
        }
        .font(.callout)
        .padding(20)
        .oasesCard()
    }
}

/// Card heading: neutral icon, title, one-line subtitle. With `destination`, the title
/// becomes a "›" link to that section so dashboard cards are never dead ends.
struct CardTitle: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let subtitle: String
    let icon: String
    var destination: AppSection?

    var body: some View {
        HStack(alignment: .top, spacing: Oases.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Oases.Color.textTertiary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let destination {
                    Button {
                        store.selectSection(destination)
                    } label: {
                        HStack(spacing: Oases.Space.xs) {
                            Text(LocalizedStringKey(title))
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.headline)
                    .foregroundStyle(Oases.Color.textPrimary)
                    .help(OasesLocalization.localizedFormat("打开%@", destination.title))
                } else {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                        .foregroundStyle(Oases.Color.textPrimary)
                }
                Text(LocalizedStringKey(subtitle))
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }
}

struct LegendDot: View {
    let title: String
    let color: Color

    var body: some View {
        Label(LocalizedStringKey(title), systemImage: "square.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, .clear)
    }
}
