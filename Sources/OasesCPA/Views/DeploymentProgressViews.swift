import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The deployment checklist the welcome gate and 连接与部署 share (design 6.3): one row per real
/// step, the glyph says the state, the active or failed row carries one short line.
struct DeploymentChecklistView: View {
    let rows: [DeploymentChecklistRow]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
                    glyph(row.status)
                        .frame(width: 16, height: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                        Text(row.title)
                            .foregroundStyle(row.status == .pending ? .secondary : .primary)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(statusLabel(row.status))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func glyph(_ status: DeploymentChecklistRow.Status) -> some View {
        switch status {
        case .active:
            ProgressView()
                .controlSize(.small)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    private func statusLabel(_ status: DeploymentChecklistRow.Status) -> String {
        switch status {
        case .pending: OasesLocalization.localized("等待中")
        case .active: OasesLocalization.localized("进行中")
        case .done: OasesLocalization.localized("已完成")
        case .failed: OasesLocalization.localized("失败")
        }
    }
}

/// The actions under a failed checklist: what the machine looks like now, then the buttons.
/// "重试" is the view's primary action.
struct DeploymentFailureActions: View {
    let failure: DeploymentFailure
    var onRetry: () -> Void
    var onShowLog: () -> Void
    var onRevealInFinder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            Text(failure.machineStateSentence())
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Oases.Space.sm) {
                ForEach(failure.actions, id: \.self) { action in
                    switch action {
                    case .retry:
                        Button("重试", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    case .showLog:
                        Button("查看日志", action: onShowLog)
                            .buttonStyle(.bordered)
                    case .revealInFinder:
                        if let onRevealInFinder {
                            Button("在访达中显示", action: onRevealInFinder)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}

/// The deployment log in a sheet ("查看日志"): raw output stays here, never in the main copy.
struct DeploymentLogSheet: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            Text("部署日志")
                .font(.headline)
            if !deploymentStore.deploymentLogSource.isEmpty {
                Text(deploymentStore.deploymentLogSource)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Group {
                if let error = deploymentStore.deploymentLogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if deploymentStore.isLoadingDeploymentLog && deploymentStore.deploymentLog.isEmpty {
                    ProgressView("正在读取目标日志…")
                        .controlSize(.small)
                } else if deploymentStore.deploymentLog.isEmpty {
                    Text("暂时没有可读取的日志内容。")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(deploymentStore.deploymentLog)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Oases.Space.sm)
                    }
                    .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: Oases.Radius.row, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("刷新") {
                    deploymentStore.refreshDeploymentLog()
                }
                .disabled(deploymentStore.isLoadingDeploymentLog)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Oases.Space.l)
        .frame(width: 640, height: 440)
        .onAppear { deploymentStore.refreshDeploymentLog() }
    }
}

/// A value with a copy button that says "已复制" for 1.5 s (text swap, no scale).
struct CopyValueButton: View {
    let value: String
    @State private var copiedAt: Date?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            let now = Date()
            copiedAt = now
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copiedAt == now { copiedAt = nil }
            }
        } label: {
            Text(copiedAt == nil ? "复制" : "已复制")
                .frame(minWidth: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(copiedAt == nil ? Text("复制") : Text("已复制"))
    }
}

/// The endpoint as the hero value: monospaced `.title3`, selectable, one copy button.
struct EndpointHeroField: View {
    let endpoint: String

    var body: some View {
        HStack(spacing: Oases.Space.sm) {
            Text(endpoint)
                .font(.title3.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Oases.Space.m)
                .padding(.vertical, Oases.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: Oases.Radius.row, style: .continuous))
                .accessibilityLabel(Text("接入地址"))
                .accessibilityValue(endpoint)
            CopyValueButton(value: endpoint)
        }
    }
}

/// "已有远程服务器？连接 VPS…": the SSH target in a sheet. Connecting probes the server; an
/// existing Oases CPA deployment there is taken over, otherwise the same pinned components are
/// installed (the footer says so before the click).
struct RemoteTargetSheet: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @Environment(\.dismiss) private var dismiss
    var onConnect: () -> Void

    @State private var host = ""
    @State private var user = "root"
    @State private var port = "22"
    @State private var installDirectory = "~/.oases-cpa"
    @State private var keyURL: URL?
    @State private var isImportingKey = false

    private var missingReason: String? {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return OasesLocalization.localized("先填写主机名或 IP 地址。")
        }
        if keyURL == nil && deploymentStore.privateKeyPath.isEmpty {
            return OasesLocalization.localized("先选择 SSH 私钥。")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("主机名 / IP", text: $host, prompt: Text(verbatim: "vps.example.com"))
                    TextField("SSH 用户", text: $user, prompt: Text(verbatim: "root"))
                    TextField("端口", text: $port, prompt: Text(verbatim: "22"))
                    LabeledContent("SSH 私钥") {
                        HStack {
                            Text(keyURL?.lastPathComponent ?? (deploymentStore.privateKeyPath.isEmpty ? OasesLocalization.localized("未选择") : OasesLocalization.localized("已保存在钥匙串")))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("选择…") { isImportingKey = true }
                        }
                    }
                    TextField("安装目录", text: $installDirectory, prompt: Text(verbatim: "~/.oases-cpa"))
                } header: {
                    Text("连接 VPS")
                } footer: {
                    Text("连接后会先检测服务器。服务器上已有 Oases CPA 部署时直接接入；没有时会安装与本机相同的固定版本组件。私钥保存在 macOS 钥匙串中。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let missingReason {
                    Text(missingReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(missingReason != nil)
            }
            .padding(Oases.Space.l)
        }
        .frame(width: 520)
        .fileImporter(isPresented: $isImportingKey, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { keyURL = urls.first }
        }
        .onAppear {
            if deploymentStore.targetKind == .ssh {
                host = deploymentStore.remoteHost
                user = deploymentStore.remoteUser
                port = deploymentStore.remotePort
                installDirectory = deploymentStore.installDirectory
            }
        }
    }

    private func connect() {
        if deploymentStore.targetKind != .ssh {
            deploymentStore.selectTarget(.ssh)
        }
        deploymentStore.remoteHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        deploymentStore.remoteUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        deploymentStore.remotePort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        deploymentStore.installDirectory = installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keyURL {
            deploymentStore.importSSHKey(from: keyURL)
        }
        dismiss()
        onConnect()
    }
}

/// Asks before an SSH host key is trusted (shared by the welcome gate and 连接与部署).
struct SSHHostKeyConfirmationDialog: ViewModifier {
    @ObservedObject var deploymentStore: DeploymentStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "确认 SSH 主机指纹？",
            isPresented: Binding<Bool>(
                get: { deploymentStore.pendingSSHHostKeyConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        deploymentStore.rejectPendingSSHHostKey()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("确认并记录此指纹") {
                deploymentStore.confirmPendingSSHHostKey()
            }
            Button("拒绝", role: .cancel) {
                deploymentStore.rejectPendingSSHHostKey()
            }
        } message: {
            if let confirmation = deploymentStore.pendingSSHHostKeyConfirmation {
                let changeDescription = confirmation.reason == .changed
                    ? OasesLocalization.localizedFormat("当前记录：%@；替换必须再次明确确认。", confirmation.previousFingerprint ?? OasesLocalization.localized("未知"))
                    : OasesLocalization.localized("这是该主机的首次记录。")
                Text(OasesLocalization.localizedFormat(
                    "主机：%@:%lld\n算法：%@\nSHA-256：%@\n%@",
                    confirmation.host, confirmation.port, confirmation.algorithm, confirmation.fingerprint, changeDescription
                ))
            } else {
                Text("未发现待确认的 SSH 主机指纹。")
            }
        }
    }
}

/// Opens the install directory of a local target in Finder (the folder itself when it exists,
/// otherwise its nearest existing parent).
enum InstallDirectoryReveal {
    static func reveal(_ installDirectory: String) {
        var url = InstallProgressReader.expandedRoot(installDirectory)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
