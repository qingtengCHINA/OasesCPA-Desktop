import SwiftUI

struct SystemInfoView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageHeader(section: .system)
                    Spacer()
                    StatusPill(
                        title: runtimeDataStore.systemStatus == nil ? "连接后读取" : "实时状态",
                        tint: runtimeDataStore.systemStatus == nil ? .oasesOrange : .oasesGreen,
                        systemImage: runtimeDataStore.systemStatus == nil ? "link.badge.plus" : "checkmark.circle"
                    )
                    Button {
                        runtimeDataStore.refresh(using: deploymentStore)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                if let status = runtimeDataStore.systemStatus {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ForEach(metrics(for: status)) { metric in
                            MetricCard(metric: metric)
                        }
                    }

                    HStack(alignment: .top, spacing: 14) {
                        runtimeCard(status)
                        collectorCard(status.collector)
                    }

                    if let migration = status.dataMigration {
                        migrationCard(migration)
                    }

                    if let lastError = status.collector?.lastError, !lastError.isEmpty {
                        InfoBanner(
                            title: "采集器报告错误",
                            message: lastError,
                            systemImage: "exclamationmark.triangle",
                            tint: .oasesRed
                        )
                    }
                } else {
                    InfoBanner(
                        title: deploymentStore.stage == .attached ? "系统状态暂时不可用" : "先连接一个目标环境",
                        message: runtimeDataStore.systemStatusErrorMessage
                            ?? "连接成功后，这里会显示 CPAMP 服务、采集器、事件和数据迁移状态。",
                        systemImage: deploymentStore.stage == .attached ? "exclamationmark.triangle" : "link.badge.plus",
                        tint: deploymentStore.stage == .attached ? .oasesOrange : .oasesBlue
                    )
                }

                HStack(spacing: 12) {
                    Button("打开 CPAMP 面板", systemImage: "rectangle.on.rectangle") {
                        store.selectSection(.panel)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("前往连接与部署", systemImage: "arrow.triangle.branch") {
                        store.selectSection(.environments)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
    }

    private func metrics(for status: RuntimeSystemStatus) -> [MetricSummary] {
        let collector = status.collector?.collector ?? "暂无"
        let collectorTint: Color = collector == "running" ? .oasesGreen : .oasesOrange
        return [
            .init(
                title: "Manager Server",
                value: status.service,
                caption: "CPAMP Full Mode",
                systemImage: "server.rack",
                tint: .oasesBlue
            ),
            .init(
                title: "采集器",
                value: collector,
                caption: status.collector?.transport ?? "未报告传输方式",
                systemImage: "waveform.path.ecg",
                tint: collectorTint
            ),
            .init(
                title: "累计事件",
                value: status.events?.formatted() ?? "暂无",
                caption: "已写入 Manager 数据库",
                systemImage: "tray.full",
                tint: .oasesMint
            ),
            .init(
                title: "死信",
                value: status.deadLetters?.formatted() ?? "暂无",
                caption: status.deadLetters == 0 ? "没有待处理死信" : "需要排查采集失败",
                systemImage: "exclamationmark.bubble",
                tint: status.deadLetters == 0 ? .oasesGreen : .oasesRed
            )
        ]
    }

    private func runtimeCard(_ status: RuntimeSystemStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "运行时", subtitle: "当前目标的 CPAMP Full Mode 信息", icon: "server.rack")
            LabeledContent("服务") { Text(status.service) }
            LabeledContent("数据库") {
                Text(status.dbPath ?? "暂无")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("目标地址") {
                Text(deploymentStore.cpaManagementURL)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .font(.callout)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private func collectorCard(_ collector: RuntimeCollectorStatus?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "请求采集器", subtitle: "CLIProxyAPI → CPAMP 的数据通道", icon: "arrow.triangle.branch")
            LabeledContent("状态") { Text(collector?.collector ?? "暂无") }
            LabeledContent("模式") { Text(collector?.mode ?? "暂无") }
            LabeledContent("队列") { Text(collector?.queue ?? "暂无") }
            LabeledContent("最近写入") { Text(timestamp(collector?.lastInsertedAt)) }
        }
        .font(.callout)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private func migrationCard(_ migration: RuntimeDataMigrationStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "数据迁移", subtitle: migration.name ?? "Manager 数据迁移状态", icon: "arrow.triangle.2.circlepath")
            HStack {
                StatusPill(title: migration.status ?? "未知", tint: migration.status == "completed" ? .oasesGreen : .oasesOrange)
                Spacer()
                Text("已处理 \(migration.processedRows?.formatted() ?? "暂无") 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let target = migration.targetEventId, target > 0 {
                ProgressView(
                    value: Double(migration.processedRows ?? 0),
                    total: Double(target)
                )
                .tint(.oasesBlue)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private func timestamp(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "暂无" }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
