import AppKit
import SwiftUI

struct SystemInfoView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var modelSearch = ""
    @State private var copiedModelID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let status = runtimeDataStore.systemStatus {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ForEach(metrics(for: status)) { metric in
                            MetricCard(metric: metric)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            runtimeCard(status)
                            collectorCard(status.collector)
                        }
                        VStack(spacing: 14) {
                            runtimeCard(status)
                            collectorCard(status.collector)
                        }
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
                        title: deploymentStore.stage == .attached ? OasesLocalization.localized("系统状态暂时不可用") : OasesLocalization.localized("先连接一个目标环境"),
                        message: runtimeDataStore.systemStatusErrorMessage
                            ?? OasesLocalization.localized("连接成功后，这里会显示 CPAMP 服务、采集器、事件和数据迁移状态。"),
                        systemImage: deploymentStore.stage == .attached ? "exclamationmark.triangle" : "link.badge.plus",
                        tint: deploymentStore.stage == .attached ? .oasesOrange : .oasesBlue
                    )
                }

                quickLinksCard
                modelDirectoryCard

                HStack(spacing: 12) {
                    Button("前往连接与部署", systemImage: "arrow.triangle.branch") {
                        store.selectSection(.environments)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            PageHeader(section: .system)
            Spacer()
            StatusPill(
                title: runtimeDataStore.systemStatus == nil ? OasesLocalization.localized("连接后读取") : OasesLocalization.localized("实时状态"),
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
    }

    private var quickLinksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "快捷链接",
                subtitle: "访问项目仓库与官方文档，获取帮助和更新",
                icon: "link"
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                QuickLinkButton(
                    title: "CLIProxyAPI",
                    subtitle: "核心网关项目",
                    systemImage: "shippingbox",
                    url: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                )
                QuickLinkButton(
                    title: "CPA-Manager-Plus",
                    subtitle: "用量统计与请求监控后端",
                    systemImage: "rectangle.on.rectangle",
                    url: URL(string: "https://github.com/seakee/CPA-Manager-Plus")!
                )
                QuickLinkButton(
                    title: "使用教程",
                    subtitle: "官方配置与使用说明",
                    systemImage: "book.closed",
                    url: URL(string: "https://help.router-for.me/introduction/quick-start.html")!
                )
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var modelDirectoryCard: some View {
        let groups = SystemModelDirectory.groups(
            for: runtimeDataStore.gatewayModels,
            query: modelSearch
        )

        return VStack(alignment: .leading, spacing: 15) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    modelDirectoryTitle
                    Spacer(minLength: 12)
                    modelDirectoryRefresh
                }
                VStack(alignment: .leading, spacing: 10) {
                    modelDirectoryTitle
                    modelDirectoryRefresh
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modelDirectoryStatus(groups: groups)
                    Spacer()
                    modelSearchField
                }
                VStack(alignment: .leading, spacing: 10) {
                    modelDirectoryStatus(groups: groups)
                    modelSearchField
                }
            }

            if deploymentStore.stage != .attached {
                ContentUnavailableView {
                    Label("连接目标后读取模型目录", systemImage: "link.badge.plus")
                } description: {
                    Text("请先在连接与部署中接入本机或 SSH / VPS 目标。")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if let error = runtimeDataStore.gatewayModelsErrorMessage {
                InfoBanner(
                    title: "模型目录读取失败",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesOrange
                )
            } else if runtimeDataStore.isLoadingGatewayModels && runtimeDataStore.gatewayModels.isEmpty {
                ProgressView("正在读取当前网关模型…")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label(
                        modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "当前网关没有返回可调用模型"
                            : "没有匹配的模型",
                        systemImage: "cpu"
                    )
                } description: {
                    Text(
                        modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "请检查认证文件、AI 提供商或模型映射。"
                            : "尝试搜索其他模型 ID、名称或提供商。"
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        modelGroup(group)
                    }
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var modelDirectoryTitle: some View {
        CardTitle(
            title: "当前网关模型目录",
            subtitle: deploymentStore.topology == .gateway
                ? "从 Oases 网关读取模型目录（不含内部供应商 id）；不会展示静态演示数据"
                : "从旧版部署引擎的 /v1/models 读取模型目录；不会展示静态演示数据",
            icon: "cpu"
        )
    }

    private var modelDirectoryRefresh: some View {
        HStack(spacing: 8) {
            if runtimeDataStore.isLoadingGatewayModels {
                ProgressView()
                    .controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshGatewayModels(using: deploymentStore)
            }
            .buttonStyle(.bordered)
            .disabled(deploymentStore.stage != .attached || runtimeDataStore.isLoadingGatewayModels)
        }
    }

    private func modelDirectoryStatus(groups: [SystemModelDirectoryGroup]) -> some View {
        HStack(spacing: 12) {
            StatusPill(
                title: OasesLocalization.localizedFormat("%lld 个模型", runtimeDataStore.gatewayModels.count),
                tint: runtimeDataStore.gatewayModels.isEmpty ? .oasesOrange : .oasesGreen,
                systemImage: "cpu"
            )
            if !groups.isEmpty {
                Text(OasesLocalization.localizedFormat("%lld 个提供商 / 家族分组", groups.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let copiedModelID {
                Label(OasesLocalization.localizedFormat("已复制 %@", copiedModelID), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.oasesGreen)
                    .lineLimit(1)
            }
        }
    }

    private var modelSearchField: some View {
        TextField("搜索模型 ID、名称或提供商", text: $modelSearch)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: .infinity)
    }

    private func modelGroup(_ group: SystemModelDirectoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.title, systemImage: "square.stack.3d.up")
                    .font(.headline)
                Text("\(group.models.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.oasesBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.oasesBlue.opacity(0.1), in: Capsule())
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 235), spacing: 9)],
                alignment: .leading,
                spacing: 9
            ) {
                ForEach(group.models) { model in
                    modelRow(model)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modelRow(_ model: RuntimeGatewayModel) -> some View {
        Button {
            copyModelID(model.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(Color.oasesPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.id)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.title != model.id || !(model.ownedBy ?? "").isEmpty {
                        Text([model.title == model.id ? nil : model.title, model.ownedBy]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点击复制模型 ID")
        .contextMenu {
            Button("复制模型 ID", systemImage: "doc.on.doc") {
                copyModelID(model.id)
            }
        }
    }

    private func copyModelID(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedModelID = value
    }

    private func metrics(for status: RuntimeSystemStatus) -> [MetricSummary] {
        let collector = status.collector?.collector ?? OasesLocalization.localized("暂无")
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
                caption: status.collector?.transport ?? OasesLocalization.localized("未报告传输方式"),
                systemImage: "waveform.path.ecg",
                tint: collectorTint
            ),
            .init(
                title: "累计事件",
                value: status.events?.formatted() ?? OasesLocalization.localized("暂无"),
                caption: "已写入 Manager 数据库",
                systemImage: "tray.full",
                tint: .oasesMint
            ),
            .init(
                title: "死信",
                value: status.deadLetters?.formatted() ?? OasesLocalization.localized("暂无"),
                caption: status.deadLetters == 0 ? OasesLocalization.localized("没有待处理死信") : OasesLocalization.localized("需要排查采集失败"),
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
                Text(status.dbPath ?? OasesLocalization.localized("暂无"))
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
            LabeledContent("状态") { Text(collector?.collector ?? OasesLocalization.localized("暂无")) }
            LabeledContent("模式") { Text(collector?.mode ?? OasesLocalization.localized("暂无")) }
            LabeledContent("队列") { Text(collector?.queue ?? OasesLocalization.localized("暂无")) }
            LabeledContent("最近写入") { Text(timestamp(collector?.lastInsertedAt)) }
        }
        .font(.callout)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private func migrationCard(_ migration: RuntimeDataMigrationStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "数据迁移", subtitle: migration.name ?? OasesLocalization.localized("Manager 数据迁移状态"), icon: "arrow.triangle.2.circlepath")
            HStack {
                StatusPill(title: migration.status ?? OasesLocalization.localized("未知"), tint: migration.status == "completed" ? .oasesGreen : .oasesOrange)
                Spacer()
                Text(OasesLocalization.localizedFormat("已处理 %@ 行", migration.processedRows?.formatted() ?? OasesLocalization.localized("暂无")))
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
        guard let value, value > 0 else { return OasesLocalization.localized("暂无") }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct QuickLinkButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .oasesIconTile()
                VStack(alignment: .leading, spacing: 3) {
                    Text(OasesLocalization.localized(title))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(OasesLocalization.localized(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("在浏览器中打开 \(title)")
    }
}
