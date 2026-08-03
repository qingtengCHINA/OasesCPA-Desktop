import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.system.rawValue

    private let columns = [
        GridItem(.flexible(minimum: 180), spacing: 12),
        GridItem(.flexible(minimum: 180), spacing: 12),
        GridItem(.flexible(minimum: 180), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero

                if let errorMessage = runtimeDataStore.errorMessage {
                    InfoBanner(
                        title: "已接入，但实时数据读取失败",
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                } else if !runtimeDataStore.isLive {
                    InfoBanner(
                        title: deploymentStore.stage == .attached ? "正在等待目标数据" : "尚未连接目标环境",
                        message: deploymentStore.stage == .attached
                            ? "正在等待 CPAMP 仪表盘摘要；数据会自动更新。"
                            : "先在“连接与部署”中选择本机终端或 SSH / VPS；连接完成后，这里只显示当前目标环境的真实数据。",
                        systemImage: "info.circle",
                        tint: .oasesOrange
                    )
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(runtimeMetrics) { metric in
                        MetricCard(metric: metric)
                    }
                }

                GatewayAccessSummaryCard()

                HStack(alignment: .top, spacing: 14) {
                    TrafficChartCard(points: runtimeTraffic)
                    HealthTimelineCard(dashboard: runtimeDataStore.dashboard)
                }
                .frame(minHeight: 300)

                HStack(alignment: .top, spacing: 14) {
                    TokenBreakdownCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 310)
                    ModelCostCard(dashboard: runtimeDataStore.dashboard)
                    ChannelHealthCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 310)
                }

                HStack(alignment: .top, spacing: 14) {
                    RecentFailuresCard(dashboard: runtimeDataStore.dashboard)
                    CollectorStatusCard(dashboard: runtimeDataStore.dashboard)
                        .frame(minWidth: 250, maxWidth: 320)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Text("CPA 网关概览")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .tracking(-0.5)

                        StatusPill(
                            title: runtimeDataStore.isLive ? "实时数据" : (deploymentStore.stage == .attached ? "已接入" : "未连接"),
                            tint: runtimeDataStore.isLive ? .oasesGreen : .oasesOrange,
                            systemImage: runtimeDataStore.isLive ? "waveform.path.ecg" : (deploymentStore.stage == .attached ? "checkmark.circle" : "link.badge.plus")
                        )
                    }

                    Text("CLIProxyAPI 网关与 CPA Manager Plus 的桌面总览")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Text("最近刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(localizedTime(runtimeDataStore.lastDashboardRefreshAt ?? store.lastRefreshed))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 28) {
                DashboardHeroFact(title: "连接状态") {
                    Text(deploymentStore.stage == .attached ? "已接入" : "待接入")
                        .foregroundStyle(deploymentStore.stage == .attached ? Color.oasesGreen : Color.oasesOrange)
                        .fontWeight(.semibold)
                }

                DashboardHeroFact(title: "目标环境") {
                    Text(deploymentStore.targetTitle)
                        .font(.system(.body, design: .monospaced))
                }

                DashboardHeroFact(title: "客户端 Base URL") {
                    Text(deploymentStore.cpaClientURLString)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .layoutPriority(1)

                Spacer()

                Button {
                    store.selectSection(.monitoring)
                } label: {
                    Label("查看请求监控", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .font(.callout)
        }
        .padding(22)
        .oasesCard(cornerRadius: 18)
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
            CardTitle(title: "流量趋势（今日）", subtitle: "调用与 Token 的小时级变化", icon: "chart.xyaxis.line")

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
                    .foregroundStyle(Color.oasesMint.gradient)
                    .cornerRadius(5)

                    LineMark(
                        x: .value("时间", point.label),
                        y: .value("Token", point.tokens)
                    )
                    .foregroundStyle(Color.oasesBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .symbol(Circle())
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
                CardTitle(title: "请求健康时间线", subtitle: "今日请求健康状态，按 10 分钟聚合", icon: "square.grid.3x3")
                Spacer()
                Text(successRate)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.oasesGreen)
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
                LegendDot(title: "无请求", color: .secondary.opacity(0.22))
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
        if point.future || point.tone == "future" { return .secondary.opacity(0.12) }
        if point.calls == 0 || point.tone == "empty" { return .secondary.opacity(0.16) }
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
                .font(.system(size: 28, weight: .bold, design: .rounded))

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
                                    .fill(row.tint.opacity(0.12))
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
        case "input": return .oasesBlue
        case "output": return .oasesMint
        case "reasoning": return .oasesPurple
        default: return .oasesOrange
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
            CardTitle(title: "模型成本排行", subtitle: "今日估算成本", icon: "arrow.up.right")

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
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(model.rank == 1 ? Color.oasesOrange : Color.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(model.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(model.cost)
                    .font(.callout.weight(.semibold))
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.oasesBlue.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.oasesBlue)
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
            CardTitle(title: "渠道健康状态", subtitle: "当前 Provider 路由", icon: "point.3.connected.trianglepath.dotted")

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
                CardTitle(title: "最近请求", subtitle: "脱敏后的最近活动", icon: "clock.arrow.circlepath")
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

struct CardTitle: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.oasesBlue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                Text(LocalizedStringKey(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
