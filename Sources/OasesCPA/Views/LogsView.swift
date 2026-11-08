import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @EnvironmentObject private var store: AppStore
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if deploymentStore.stage != .attached {
                    InfoBanner(
                        title: "连接目标后读取日志",
                        message: "日志来自当前目标上的 CLIProxyAPI，不读取或混合其他本机项目的日志。",
                        systemImage: "lock.shield",
                        tint: .oasesOrange
                    )
                } else if let error = runtimeDataStore.logsErrorMessage {
                    InfoBanner(
                        title: "日志读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                    if fileLoggingDisabled {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(Color.oasesOrange)
                            Text("CLIProxyAPI 当前未写入文件日志。启用后，App 才能读取运行日志。")
                                .font(.callout)
                            Spacer()
                            Button("启用文件日志") {
                                runtimeDataStore.enableFileLogging(using: deploymentStore)
                            }
                            .buttonStyle(.oasesPrimary)
                            .disabled(runtimeDataStore.isLoadingLogs)
                        }
                        .padding(14)
                        .background(Color.oasesOrange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                logCard

                InfoBanner(
                    title: "日志中的密钥会由目标服务脱敏",
                    message: "App 只显示 CLIProxyAPI 返回的脱敏运行日志；如需完整请求错误文件、下载或按请求查看证据，请打开同一目标的 CPAMP 面板。",
                    systemImage: "eye.slash",
                    tint: .oasesBlue
                )
            }
            .padding(28)
        }
        .task {
            runtimeDataStore.refreshLogs(using: deploymentStore)
        }
        .onChange(of: deploymentStore.stage) { _, _ in
            runtimeDataStore.refreshLogs(using: deploymentStore)
        }
        .confirmationDialog(
            "清空当前目标日志？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空日志", role: .destructive) {
                runtimeDataStore.clearLogs(using: deploymentStore)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会清空当前目标 CLIProxyAPI 的运行日志，不会删除认证文件、配置或部署目录。")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PageHeader(section: .logs)
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshLogs(using: deploymentStore)
            }
            .buttonStyle(.bordered)
            .disabled(runtimeDataStore.isLoadingLogs || deploymentStore.stage != .attached)

            Button("清空", systemImage: "trash") {
                confirmClear = true
            }
            .buttonStyle(.bordered)
            .tint(.oasesRed)
            .disabled(runtimeDataStore.isLoadingLogs || deploymentStore.stage != .attached)

            Button("打开 CPAMP", systemImage: "rectangle.on.rectangle") {
                store.selectSection(.panel)
            }
            .buttonStyle(.oasesPrimary)
            .disabled(deploymentStore.stage != .attached)
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(
                    title: "CLIProxyAPI 运行日志",
                    subtitle: "当前目标的 /v0/management/logs API",
                    icon: "text.alignleft"
                )
                Spacer()
                if runtimeDataStore.isLoadingLogs {
                    ProgressView()
                        .controlSize(.small)
                }
                if let logs = runtimeDataStore.logs {
                    StatusPill(
                        title: "\(logs.lineCount) 行",
                        tint: .oasesBlue,
                        systemImage: "list.number"
                    )
                }
            }

            if let logs = runtimeDataStore.logs {
                if logs.lines.isEmpty {
                    ContentUnavailableView {
                        Label("当前没有日志", systemImage: "text.alignleft")
                    } description: {
                        Text("服务产生请求后，日志会出现在这里。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(InternalModelID.publicText(logs.lines.joined(separator: "\n")))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(minHeight: 300, maxHeight: 640)
                    .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else if deploymentStore.stage == .attached && runtimeDataStore.isLoadingLogs {
                ProgressView("正在读取当前目标日志…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Text("尚未读取日志。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var fileLoggingDisabled: Bool {
        runtimeDataStore.logsErrorMessage?.localizedCaseInsensitiveContains("logging to file disabled") == true
    }
}
