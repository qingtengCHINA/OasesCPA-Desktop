import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @StateObject private var errorFiles = RequestErrorLogsStore()
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
                    }
                }

                logCard

                if deploymentStore.stage == .attached {
                    requestErrorFilesCard
                }

                InfoBanner(
                    title: "日志中的密钥会被脱敏",
                    message: "运行日志由 CLIProxyAPI 脱敏后返回；保存请求错误文件时，App 会再把密钥形状的内容和当前目标的密钥替换成 ••••，并去掉内部路由前缀。",
                    systemImage: "eye.slash",
                    tint: .oasesBlue
                )
            }
            .padding(28)
        }
        .task {
            runtimeDataStore.refreshLogs(using: deploymentStore)
            await loadErrorFiles()
        }
        .onChange(of: deploymentStore.stage) { _, _ in
            runtimeDataStore.refreshLogs(using: deploymentStore)
            Task { await loadErrorFiles() }
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
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshLogs(using: deploymentStore)
                Task { await loadErrorFiles() }
            }
            .buttonStyle(.bordered)
            .disabled(runtimeDataStore.isLoadingLogs || deploymentStore.stage != .attached)

            Button("清空", systemImage: "trash") {
                confirmClear = true
            }
            .buttonStyle(.bordered)
            .tint(.oasesRed)
            .disabled(runtimeDataStore.isLoadingLogs || deploymentStore.stage != .attached)
        }
    }

    private var requestErrorFilesCard: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            HStack {
                CardTitle(
                    title: "请求错误文件",
                    subtitle: "当前目标的 /v0/management/request-error-logs，每个失败请求一份",
                    icon: "doc.badge.ellipsis"
                )
                Spacer()
                if errorFiles.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if errorFiles.hasLoaded, errorFiles.errorMessage == nil {
                    StatusPill(
                        title: OasesLocalization.localizedFormat("%lld 个文件", errorFiles.files.count),
                        tint: .oasesBlue,
                        systemImage: "doc.on.doc"
                    )
                }
            }

            if let error = errorFiles.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !errorFiles.hasLoaded {
                ProgressView("正在读取请求错误文件…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if errorFiles.files.isEmpty {
                ContentUnavailableView {
                    Label("没有请求错误文件", systemImage: "checkmark.circle")
                } description: {
                    Text("关闭“请求日志”时，引擎为每个失败请求保存一份错误文件；开启“请求日志”时引擎保存完整请求日志，这里的列表为空。")
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 0) {
                    ForEach(errorFiles.files) { file in
                        errorFileRow(file)
                        if file.id != errorFiles.files.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if let message = errorFiles.saveMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(errorFiles.saveFailed ? Color.oasesRed : Color.oasesGreen)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Oases.Space.l)
        .oasesCard()
    }

    private func errorFileRow(_ file: RuntimeRequestErrorLog) -> some View {
        HStack(spacing: Oases.Space.m) {
            VStack(alignment: .leading, spacing: Oases.Space.xs) {
                Text(verbatim: file.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: errorFileDetail(file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if errorFiles.savingName == file.name {
                ProgressView()
                    .controlSize(.small)
            }
            Button("下载…", systemImage: "square.and.arrow.down") {
                chooseDestination(for: file)
            }
            .buttonStyle(.bordered)
            .disabled(errorFiles.savingName != nil)
        }
        .padding(.vertical, Oases.Space.sm)
    }

    private func errorFileDetail(_ file: RuntimeRequestErrorLog) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)]
        if let modified = file.modifiedAt {
            parts.append(modified.formatted(date: .abbreviated, time: .standard))
        }
        return parts.joined(separator: " · ")
    }

    private func loadErrorFiles() async {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else {
            errorFiles.reset()
            return
        }
        await errorFiles.load(baseURL: deploymentStore.engineBaseURL, managementKey: deploymentStore.managementKey)
    }

    private func chooseDestination(for file: RuntimeRequestErrorLog) {
        guard deploymentStore.stage == .attached else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = OasesLocalization.localized("保存的副本中，密钥会被替换成 ••••。")
        let baseURL = deploymentStore.engineBaseURL
        let managementKey = deploymentStore.managementKey
        let secrets = [deploymentStore.cpampAdminKey]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                await errorFiles.save(
                    file,
                    to: destination,
                    baseURL: baseURL,
                    managementKey: managementKey,
                    secrets: secrets
                )
            }
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
                        title: OasesLocalization.localizedFormat("%lld 行", logs.lineCount),
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
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(minHeight: 300, maxHeight: 640)
                    .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: Oases.Radius.row, style: .continuous))
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
