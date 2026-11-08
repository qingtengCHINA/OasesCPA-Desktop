import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the top section of 连接与部署 shows (design 5a). One state at a time: success and an
/// error for the same deployment never appear together, and an error from an earlier attempt
/// is not shown once the deployment runs again.
enum ConnectionPageState: Equatable, Sendable {
    /// Probing, or connecting an existing deployment.
    case checking
    case notDeployed
    /// A fresh install (one-click or plan) runs.
    case deploying(InstallProgressPhase)
    case running
    /// The user stopped the installed deployment.
    case stopped
    /// An installed 0.1.x native deployment waits for its upgrade.
    case legacy
    /// An upgrade or rollback runs.
    case maintaining
    /// The deployment directory is being removed.
    case removing
    case needsAttention(Attention)
    /// A fresh install failed.
    case error(DeploymentFailure)

    enum Attention: Equatable, Sendable {
        /// Saved and installed, not connected in this run.
        case notConnected
        /// Installed, but the services do not answer (or the last maintenance failed).
        case unhealthy
        /// The probe found a deployment the app cannot take over.
        case notAdoptable
        /// A removal was refused or failed; nothing was deleted.
        case removalFailed
    }

    struct Facts: Equatable, Sendable {
        var stage: DeploymentStage = .idle
        var health: DeploymentHealthState = .unknown
        var method: DeploymentMethod = .native
        var topology: DeploymentTopology = .legacy
        var isProbing = false
        var isDeploying = false
        var isPreparingOneClickInstall = false
        var isMaintaining = false
        var isRemovingDeployment = false
        var hasInstalledDeployment = false
        var isStoppedByUser = false
        var probeFoundInstallation = false
        var hasRemovalError = false
        var installStage: String?
        var installFailure: DeploymentFailure?

        @MainActor
        init(_ store: DeploymentStore) {
            stage = store.stage
            health = store.healthState
            method = store.deploymentMethod
            topology = store.topology
            isProbing = store.isProbing
            isDeploying = store.isDeploying
            isPreparingOneClickInstall = store.isPreparingOneClickInstall
            isMaintaining = store.isMaintaining
            isRemovingDeployment = store.isRemovingDeployment
            hasInstalledDeployment = store.hasInstalledDeployment
            isStoppedByUser = store.isStoppedByUser
            probeFoundInstallation = store.probe?.hasManagedInstallation == true
            hasRemovalError = store.removalError != nil
            installStage = store.installProgress?.stage
            if let preflight = store.oneClickPreflightFailure {
                installFailure = preflight
            } else if store.stage == .failed, !store.hasInstalledDeployment {
                installFailure = DeploymentFailureClassifier.classify(
                    message: store.deploymentError ?? store.probeError ?? store.statusMessage
                )
            }
        }

        init() {}
    }

    static func resolve(_ facts: Facts) -> ConnectionPageState {
        if facts.isRemovingDeployment { return .removing }
        if facts.isMaintaining { return .maintaining }
        if facts.isPreparingOneClickInstall { return .deploying(.preparing) }
        if facts.isDeploying {
            switch facts.stage {
            case .installing:
                return facts.hasInstalledDeployment ? .maintaining : .deploying(.running(stage: facts.installStage))
            case .connecting:
                // After a fresh install the deployment counts as installed while the app
                // confirms the connection; an adoption is still "checking".
                return facts.hasInstalledDeployment ? .deploying(.verifying) : .checking
            default:
                return .checking
            }
        }
        if facts.isProbing { return .checking }

        if facts.hasInstalledDeployment {
            if facts.hasRemovalError { return .needsAttention(.removalFailed) }
            if MaintenanceLabels.showsUpgradeCallout(method: facts.method, topology: facts.topology, hasInstalledDeployment: true) {
                return .legacy
            }
            switch facts.stage {
            case .attached:
                return facts.health == .degraded ? .needsAttention(.unhealthy) : .running
            case .connecting:
                return .checking
            case .failed:
                return facts.isStoppedByUser ? .stopped : .needsAttention(.unhealthy)
            case .idle, .ready, .cancelled, .installing:
                return facts.isStoppedByUser ? .stopped : .needsAttention(.notConnected)
            }
        }
        if facts.probeFoundInstallation, facts.stage == .failed { return .needsAttention(.notAdoptable) }
        if let failure = facts.installFailure { return .error(failure) }
        return .notDeployed
    }
}

/// 连接与部署 (design 5a): one grouped Form. The top section depends on the state; then the
/// maintenance links, "高级" and "诊断" disclosure groups, and the destructive removal last.
struct ConnectionCenterView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @State private var isImportingKey = false
    @State private var confirmStop = false
    @State private var confirmCancelDeployment = false
    @State private var confirmRemoveDeployment = false
    @State private var confirmCleanup = false
    @State private var confirmForget = false
    @State private var confirmUpgrade = false
    @State private var confirmRollback = false
    @State private var confirmDeleteProfile = false
    @State private var profileToDeleteID: UUID?
    @State private var showsAdvanced = false
    @State private var showsDiagnostics = false
    @State private var showsLog = false
    /// For snapshots: a fixed state instead of the store's.
    private let stateOverride: ConnectionPageState?

    init(stateOverride: ConnectionPageState? = nil) {
        self.stateOverride = stateOverride
    }

    private var state: ConnectionPageState {
        stateOverride ?? ConnectionPageState.resolve(ConnectionPageState.Facts(deploymentStore))
    }

    var body: some View {
        let state = state
        Form {
            stateSection(state)
            maintenanceSection(state)
            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    advancedContent
                } label: {
                    Text("高级（远程 VPS、Docker、安装目录）")
                }
                DisclosureGroup(isExpanded: $showsDiagnostics) {
                    diagnosticsContent
                } label: {
                    Text("诊断（重新检测、部署日志）")
                }
            }
            removalSection(state)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        // A gateway page's "备份并升级…" routes here (`AppStore.requestDeploymentUpgrade`). The
        // legacy state above already shows the one upgrade button with its promise and backup
        // location, so the request is only consumed: nothing runs without this page's own click.
        .onAppear { appStore.deploymentUpgradeRequested = false }
        .onChange(of: appStore.deploymentUpgradeRequested) { _, requested in
            if requested { appStore.deploymentUpgradeRequested = false }
        }
        .fileImporter(isPresented: $isImportingKey, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                deploymentStore.importSSHKey(from: url)
            }
        }
        .sheet(isPresented: $showsLog) { DeploymentLogSheet() }
        .modifier(SSHHostKeyConfirmationDialog(deploymentStore: deploymentStore))
        .confirmationDialog("停止目标环境服务？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止服务", role: .destructive) { deploymentStore.stopServices() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.stopMessage(topology: deploymentStore.topology))
        }
        .confirmationDialog("取消安装？", isPresented: $confirmCancelDeployment, titleVisibility: .visible) {
            Button("取消安装", role: .destructive) {
                deploymentStore.cancelDeployment(moveAttemptToTrash: deploymentStore.targetKind == .local)
            }
            Button("继续安装", role: .cancel) {}
        } message: {
            Text(deploymentStore.targetKind == .local
                 ? LocalizedStringKey("这次已下载的文件会被移到废纸篓。")
                 : LocalizedStringKey("已下载的文件会保留在服务器上；下次安装时会先自动备份。"))
        }
        .confirmationDialog("彻底删除当前部署？", isPresented: $confirmRemoveDeployment, titleVisibility: .visible) {
            Button("删除整个部署目录", role: .destructive) { deploymentStore.removeDeployment() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.removalMessage(topology: deploymentStore.topology, directory: deploymentStore.installDirectory))
        }
        .confirmationDialog("清理失败部署并重试？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("停止并备份后清理", role: .destructive) { deploymentStore.cleanupFailedDeployment() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 会先停止由本次部署创建的进程或 Compose 服务，再把失败部署文件和日志移动到目标目录的 backups/failed-*，不会直接删除。")
        }
        .confirmationDialog("停止并解除当前目标？", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("停止并解除绑定", role: .destructive) { deploymentStore.forgetCurrentDeployment() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 会停止当前目标服务并删除本机保存的 CPA / CPAMP 管理密钥，但不会删除目标目录、认证文件或远程部署文件。之后可以选择另一个本机或 VPS 目标。")
        }
        .confirmationDialog(
            MaintenanceLabels.upgradeConfirmationTitle(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology),
            isPresented: $confirmUpgrade,
            titleVisibility: .visible
        ) {
            Button(OasesLocalization.localized("下载并升级"), role: .destructive) { deploymentStore.upgradeDeployment() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.upgradeConfirmationMessage(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology))
        }
        .confirmationDialog("回滚到上一版运行时？", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("恢复上一版", role: .destructive) { deploymentStore.rollbackDeployment() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.rollbackMessage(ports: deploymentStore.tunnelPortList))
        }
        .confirmationDialog("删除未部署目标？", isPresented: $confirmDeleteProfile, titleVisibility: .visible) {
            Button("删除目标", role: .destructive) {
                if let profileToDeleteID { deploymentStore.deleteSavedProfile(profileToDeleteID) }
                profileToDeleteID = nil
            }
            Button("取消", role: .cancel) { profileToDeleteID = nil }
        } message: {
            Text("只移除 App 保存的连接草稿和该目标的 SSH 私钥，不会删除任何远程目录或服务。")
        }
    }

    // MARK: State section

    private var notDeployedSentence: String {
        if deploymentStore.targetKind == .local {
            return OasesLocalization.localized("这台 Mac 上还没有部署网关。")
        }
        return deploymentStore.remoteHost.isEmpty
            ? OasesLocalization.localized("远程服务器上还没有部署网关。")
            : OasesLocalization.localizedFormat("%@ 上还没有部署网关。", deploymentStore.remoteHost)
    }

    @ViewBuilder
    private func stateSection(_ state: ConnectionPageState) -> some View {
        Section {
            switch state {
            case .checking:
                stateRow(tone: .info, word: "正在检查…", showsSpinner: true)
            case .notDeployed:
                notDeployedRows
            case .deploying(let progress):
                deployingRows(progress)
            case .running:
                runningRows
            case .stopped:
                stateRow(tone: .neutral, word: "已停止") {
                    Button("启动") { deploymentStore.resumeServices() }
                        .buttonStyle(.borderedProminent)
                }
                sentence("服务已停止，App 不会自动启动它。")
                endpointRow
            case .legacy:
                legacyRows
            case .maintaining:
                stateRow(tone: .info, word: "正在维护…", showsSpinner: true)
                if MaintenanceLabels.isMigration(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology) {
                    DeploymentChecklistView(rows: UpgradeChecklist.rows(phase: .running))
                        .padding(.vertical, Oases.Space.xs)
                }
                sentence("升级和回滚不报告分步进度；完成前请保持 App 打开。")
            case .removing:
                stateRow(tone: .info, word: "正在彻底删除部署…", showsSpinner: true)
            case .needsAttention(let attention):
                attentionRows(attention)
            case .error(let failure):
                errorRows(failure)
            }
        } header: {
            Text("运行状态")
        }
    }

    private var notDeployedRows: some View {
        Group {
            stateRow(tone: .neutral, word: "未部署")
            VStack(alignment: .leading, spacing: Oases.Space.xs) {
                Text(notDeployedSentence)
                Text(verbatim: "CLIProxyAPI \(DeploymentPinSet.current.engine.tag) · CPA Manager Plus \(DeploymentPinSet.current.cpamp.tag) · Node.js \(DeploymentPinSet.current.node.tag)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("全部为固定版本，逐个校验 SHA-256。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(OasesLocalization.localizedFormat("安装到 %@，只监听本机 127.0.0.1。", deploymentStore.installDirectory))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("安装并启动") { deploymentStore.startOneClickInstall() }
                    .buttonStyle(.borderedProminent)
                    .disabled(deploymentStore.targetKind == .ssh && deploymentStore.remoteHost.isEmpty)
            }
            if deploymentStore.targetKind == .ssh && deploymentStore.remoteHost.isEmpty {
                sentence("先在「高级」中填写远程服务器。")
            } else if deploymentStore.stage == .cancelled {
                sentence(verbatim: deploymentStore.statusMessage)
            }
        }
    }

    @ViewBuilder
    private func deployingRows(_ progress: InstallProgressPhase) -> some View {
        stateRow(tone: .info, word: "部署中") {
            if deploymentStore.canCancelDeployment {
                Button("取消") { confirmCancelDeployment = true }
                    .disabled(deploymentStore.isControllingDeployment)
            }
        }
        ProgressView()
            .progressViewStyle(.linear)
            .accessibilityLabel(Text("安装进度"))
        DeploymentChecklistView(
            rows: InstallChecklist.rows(phase: progress, receivedBytes: deploymentStore.installProgress?.receivedBytes)
        )
        .padding(.vertical, Oases.Space.xs)
        if case .running(nil) = progress {
            sentence(verbatim: deploymentStore.targetKind == .ssh
                     ? OasesLocalization.localized("远程服务器不报告分步进度；完成后会逐项确认。")
                     : OasesLocalization.localized("正在安装；这一步不报告分步进度。"))
        }
    }

    private var lastCheckText: String {
        guard let date = deploymentStore.lastHealthCheckAt else {
            return OasesLocalization.localized("尚未完成检查")
        }
        return OasesLocalization.localizedFormat("%@（每 30 秒）", date.formatted(date: .omitted, time: .shortened))
    }

    private var versionsText: String? {
        guard let versions = deploymentStore.probe?.installedVersions, !versions.isEmpty else { return nil }
        let parts: [String] = ["gateway", "engine", "cpamp"].compactMap { key in
            versions[key].map { "\(DeploymentExecutionError.componentName(key)) \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var runningRows: some View {
        stateRow(
            tone: deploymentStore.healthState == .recovering || deploymentStore.healthState == .checking ? .info : .success,
            word: deploymentStore.healthState == .recovering ? "正在恢复" : "运行中"
        ) {
            Button("停止") { confirmStop = true }
        }
        endpointRow
        if let versionsText {
            LabeledContent("版本") {
                Text(versionsText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        LabeledContent("最近检查") {
            Text(lastCheckText)
                .monospacedDigit()
        }
    }

    private var endpointRow: some View {
        valueRow("接入地址", value: deploymentStore.cpaClientURLString) {
            CopyValueButton(value: deploymentStore.cpaClientURLString)
        }
    }

    /// Label, a monospaced selectable value that keeps its full width, a trailing action.
    private func valueRow<Trailing: View>(
        _ title: LocalizedStringKey,
        value: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: Oases.Space.sm) {
            Text(title)
            Spacer(minLength: Oases.Space.m)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .layoutPriority(1)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var legacyRows: some View {
        stateRow(tone: .warning, word: "需要升级") {
            Button("备份并升级") { deploymentStore.upgradeDeployment() }
                .buttonStyle(.borderedProminent)
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)
        }
        sentence("这是旧版 0.1.x 部署，网关功能需要升级。升级会先自动备份，你的 AI 提供商、认证文件、API Key 和用量数据都会保留；如果升级没有完成，会自动恢复到原来的部署。")
        sentence(verbatim: OasesLocalization.localizedFormat("备份会保存在 %@ 中。", deploymentStore.installDirectory + "/backups"))
        if let failure = deploymentStore.lastMaintenanceFailure {
            maintenanceFailureRows(failure)
        }
        endpointRow
    }

    @ViewBuilder
    private func maintenanceFailureRows(_ failure: MaintenanceFailure) -> some View {
        switch failure {
        case .upgrade(let upgrade):
            Label(upgrade.reason(), systemImage: "xmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            sentence(verbatim: upgrade.outcome())
        case .refused(let message):
            sentence(verbatim: message)
        case .other:
            sentence("上次维护没有完成；日志里有详细原因。")
        }
        HStack {
            Spacer()
            Button("查看日志") { showsLog = true }
        }
    }

    @ViewBuilder
    private func attentionRows(_ attention: ConnectionPageState.Attention) -> some View {
        switch attention {
        case .notConnected:
            stateRow(tone: .neutral, word: "未连接") {
                Button("连接") { deploymentStore.resumeServices() }
                    .buttonStyle(.borderedProminent)
            }
            sentence("已保存这个部署；连接后才会读取钥匙串里的管理凭据。")
        case .unhealthy:
            stateRow(tone: .danger, word: "需要处理") {
                Button("重试") { deploymentStore.resumeServices() }
                    .buttonStyle(.borderedProminent)
                    .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)
            }
            if let failure = deploymentStore.lastMaintenanceFailure {
                maintenanceFailureRows(failure)
            } else {
                sentence("服务没有响应。App 会每 30 秒自动重试，也可以现在重试；部署文件没有被修改。")
                HStack {
                    Spacer()
                    Button("查看日志") { showsLog = true }
                }
            }
        case .notAdoptable:
            stateRow(tone: .danger, word: "需要处理") {
                Button("重新检测") { deploymentStore.probeTarget() }
                    .buttonStyle(.borderedProminent)
            }
            sentence(verbatim: OasesLocalization.localizedFormat("找到了已有部署，但 App 无法接入它：%@ 部署文件没有被修改。", deploymentStore.deploymentError ?? OasesLocalization.localized("原因见日志。")))
            HStack {
                Spacer()
                Button("查看日志") { showsLog = true }
            }
        case .removalFailed:
            stateRow(tone: .danger, word: "需要处理") {
                Button("连接") { deploymentStore.resumeServices() }
                    .buttonStyle(.borderedProminent)
            }
            sentence("彻底删除没有完成：没有通过安全校验的目录不会被删除，文件保持原样。")
            HStack {
                Spacer()
                Button("查看日志") { showsLog = true }
            }
        }
    }

    @ViewBuilder
    private func errorRows(_ failure: DeploymentFailure) -> some View {
        stateRow(tone: .danger, word: "安装没有完成")
        DeploymentChecklistView(rows: failedRows(failure))
            .padding(.vertical, Oases.Space.xs)
        DeploymentFailureActions(
            failure: failure,
            onRetry: { deploymentStore.startOneClickInstall() },
            onShowLog: { showsLog = true },
            onRevealInFinder: deploymentStore.targetKind == .local
                ? { InstallDirectoryReveal.reveal(deploymentStore.installDirectory) }
                : nil
        )
    }

    private func failedRows(_ failure: DeploymentFailure) -> [DeploymentChecklistRow] {
        var rows = InstallChecklist.rows(phase: .failed(stage: failure.stage ?? deploymentStore.installProgress?.stage))
        if let index = rows.firstIndex(where: { $0.status == .failed }) {
            rows[index].detail = failure.reason(installDirectory: deploymentStore.installDirectory)
        }
        return rows
    }

    /// The state line: an 8 pt dot and one word, an optional trailing control.
    private func stateRow<Trailing: View>(
        tone: Oases.Tone,
        word: LocalizedStringKey,
        showsSpinner: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: Oases.Space.sm) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                StatusDot(tone: tone)
            }
            Text(word)
                .font(.headline)
            Spacer()
            trailing()
        }
        .accessibilityElement(children: .contain)
    }

    private func sentence(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sentence(verbatim text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Maintenance

    @ViewBuilder
    private func maintenanceSection(_ state: ConnectionPageState) -> some View {
        let installed = deploymentStore.hasInstalledDeployment
        let busy = deploymentStore.isDeploying || deploymentStore.isMaintaining || deploymentStore.isRemovingDeployment
        let isLegacy = MaintenanceLabels.showsUpgradeCallout(
            method: deploymentStore.deploymentMethod,
            topology: deploymentStore.topology,
            hasInstalledDeployment: installed
        )
        if installed || deploymentStore.targetKind == .local {
            Section {
                if installed && !isLegacy {
                    Button(OasesLocalization.localized("升级运行时") + "…") { confirmUpgrade = true }
                        .disabled(busy)
                    Button("回滚到上一版…") { confirmRollback = true }
                        .disabled(busy)
                    if let backup = deploymentStore.latestMaintenanceBackup {
                        LabeledContent("最近备份") {
                            Text(backup)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                if deploymentStore.targetKind == .local {
                    Button("在访达中显示安装目录") { InstallDirectoryReveal.reveal(deploymentStore.installDirectory) }
                }
                if installed && deploymentStore.deploymentMethod == .docker {
                    sentence(verbatim: MaintenanceLabels.dockerGatewayNotice)
                }
            } header: {
                Text("维护")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedContent: some View {
        let locked = deploymentStore.hasInstalledDeployment || deploymentStore.isDeploying
        Picker("目标", selection: Binding(
            get: { deploymentStore.targetKind },
            set: { deploymentStore.selectTarget($0) }
        )) {
            ForEach(DeploymentTargetKind.allCases) { kind in
                Text(LocalizedStringKey(kind.title)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .disabled(locked)

        if deploymentStore.targetKind == .ssh {
            TextField("主机名 / IP", text: $deploymentStore.remoteHost, prompt: Text(verbatim: "vps.example.com"))
                .disabled(locked)
            TextField("SSH 用户", text: $deploymentStore.remoteUser, prompt: Text(verbatim: "root"))
                .disabled(locked)
            TextField("端口", text: $deploymentStore.remotePort, prompt: Text(verbatim: "22"))
                .disabled(locked)
            LabeledContent("SSH 私钥") {
                HStack {
                    Text(deploymentStore.privateKeyPath.isEmpty ? OasesLocalization.localized("未选择") : OasesLocalization.localized("已保存在钥匙串"))
                        .foregroundStyle(.secondary)
                    Button("选择…") { isImportingKey = true }
                        .disabled(locked)
                }
            }
        }
        TextField("安装目录", text: $deploymentStore.installDirectory, prompt: Text(verbatim: "~/.oases-cpa"))
            .font(.body.monospaced())
            .disabled(locked || deploymentStore.targetKind == .local)

        Picker("部署方式", selection: Binding(
            get: { deploymentStore.deploymentMethod },
            set: { deploymentStore.selectMethod($0) }
        )) {
            ForEach(DeploymentMethod.allCases) { method in
                Text(method.title).tag(method)
            }
        }
        .disabled(locked || deploymentStore.targetKind == .local)
        if deploymentStore.deploymentMethod == .docker {
            sentence(verbatim: MaintenanceLabels.dockerGatewayNotice)
        } else if deploymentStore.targetKind == .local {
            sentence("本机使用原生部署；Docker 只用于远程服务器。")
        }

        savedTargets

        if deploymentStore.hasInstalledDeployment {
            Button("解除当前目标绑定…") { confirmForget = true }
                .buttonStyle(.link)
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)
        }
    }

    @ViewBuilder
    private var savedTargets: some View {
        LabeledContent("已保存目标") {
            Button("添加目标") { deploymentStore.beginNewTarget() }
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)
        }
        if deploymentStore.savedProfiles.isEmpty {
            sentence("还没有保存的目标；首次部署完成后会自动加入列表。")
        } else {
            ForEach(deploymentStore.savedProfiles) { profile in
                let isActive = profile.id == deploymentStore.activeProfileID
                Button {
                    deploymentStore.selectSavedProfile(profile.id)
                } label: {
                    HStack(spacing: Oases.Space.sm) {
                        Image(systemName: isActive ? "checkmark" : profile.targetKind.systemImage)
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                            Text(profile.displayName)
                            Text(profile.endpointSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(LocalizedStringKey(profile.isInstalled ? "已部署" : "未部署"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isActive)
                .contextMenu {
                    if !profile.isInstalled {
                        Button("删除未部署目标…", role: .destructive) {
                            profileToDeleteID = profile.id
                            confirmDeleteProfile = true
                        }
                    }
                }
            }
            if deploymentStore.savedProfiles.count > 1 {
                sentence(verbatim: OasesLocalization.localizedFormat("切换目标前请先停止当前服务，避免本机 %@ 端口或 SSH 隧道互相覆盖。", deploymentStore.tunnelPortList))
            }
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnosticsContent: some View {
        LabeledContent("连接检测") {
            Button(deploymentStore.isProbing ? OasesLocalization.localized("检测中…") : OasesLocalization.localized("重新检测")) {
                deploymentStore.probeTarget()
            }
            .disabled(deploymentStore.isProbing || deploymentStore.isDeploying)
        }
        if let probe = deploymentStore.probe {
            LabeledContent("系统") { Text(verbatim: "\(probe.operatingSystem) · \(probe.architecture) · \(probe.shell)").monospaced() }
            let missing = probe.missingDependencies(for: deploymentStore.deploymentMethod)
            Label(probe.dependencySummary(for: deploymentStore.deploymentMethod), systemImage: missing.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let probeError = deploymentStore.probeError {
            sentence(verbatim: probeError)
        } else {
            sentence("检测只读取系统信息，不会安装、覆盖或启动任何服务。")
        }

        LabeledContent("部署日志") {
            Button("查看日志") { showsLog = true }
        }

        if deploymentStore.stage == .failed && !deploymentStore.hasInstalledDeployment {
            Button("清理失败部署并重试…") { confirmCleanup = true }
                .buttonStyle(.link)
                .disabled(deploymentStore.isDeploying)
        }
    }

    // MARK: Removal

    @ViewBuilder
    private func removalSection(_ state: ConnectionPageState) -> some View {
        if deploymentStore.hasInstalledDeployment || deploymentStore.probe?.hasManagedRoot == true {
            Section {
                if deploymentStore.managedRootPresent == false {
                    // The removal would refuse this root: no red error, one sentence instead.
                    sentence(verbatim: deploymentStore.topology == .legacy
                             ? OasesLocalization.localized("这个部署来自旧版本，没有 Oases 受管标记，App 不能删除它；升级到完整版后即可删除。")
                             : OasesLocalization.localized("安装目录缺少 Oases 受管标记，App 不会删除这个目录。"))
                } else {
                    Button("彻底删除部署…", role: .destructive) { confirmRemoveDeployment = true }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                        .disabled(!deploymentStore.canRemoveDeployment)
                }
            }
        }
    }
}

/// The texts of the maintenance actions, by deployment method and topology.
enum MaintenanceLabels {
    static var dockerGatewayNotice: String {
        dockerGatewayNotice(language: nil)
    }

    static func dockerGatewayNotice(language: AppLanguage?) -> String {
        OasesLocalization.localized("Oases 网关只支持原生部署；Docker 部署只包含上游 CLIProxyAPI 与 CPA Manager Plus", language: language)
    }

    /// A legacy native deployment is upgraded to the full edition (the gateway joins).
    static func isMigration(method: DeploymentMethod, topology: DeploymentTopology) -> Bool {
        method == .native && topology == .legacy
    }

    /// The main page offers the upgrade itself (not only the collapsed 高级选项) for an installed
    /// legacy native deployment, because every gateway page sends the user there.
    static func showsUpgradeCallout(method: DeploymentMethod, topology: DeploymentTopology, hasInstalledDeployment: Bool) -> Bool {
        hasInstalledDeployment && isMigration(method: method, topology: topology)
    }

    static func upgradeButtonTitle(method: DeploymentMethod, topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        isMigration(method: method, topology: topology)
            ? OasesLocalization.localized("升级到完整版（加入 Oases 网关）", language: language)
            : OasesLocalization.localized("升级运行时", language: language)
    }

    static func upgradeConfirmationTitle(method: DeploymentMethod, topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        isMigration(method: method, topology: topology)
            ? OasesLocalization.localized("升级到完整版？", language: language)
            : OasesLocalization.localized("升级当前目标运行时？", language: language)
    }

    static func upgradeConfirmationMessage(method: DeploymentMethod, topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch (method, topology) {
        case (.native, .legacy):
            OasesLocalization.localized("App 会先把启动脚本、引擎配置和运行时备份到目标目录的 backups/upgrade-*，再安装 Node 与 Oases 网关。端口会迁移：CLIProxyAPI 从 8317 改到 18316，8317 改由 Oases 网关提供 /v1，网关管理口是 18320；SSH 隧道会按新端口重新建立。认证文件、客户端 Key 和 CPAMP 数据会保留，之后可以回滚。", language: language)
        case (.native, .gateway):
            OasesLocalization.localized("App 会先把启动脚本、版本记录、运行时和 gateway-data 备份到目标目录的 backups/upgrade-*，再升级到本应用固定的 CLIProxyAPI、CPA Manager Plus、Node 与 Oases 网关版本；目标上已有更新的版本时会拒绝降级。配置、认证文件和 CPAMP 数据会保留。", language: language)
        case (.docker, _):
            OasesLocalization.localized("App 会先保存 Compose 文件和版本记录到目标目录的 backups/upgrade-*，再拉取本应用固定的 CLIProxyAPI 与 CPA Manager Plus 镜像。Oases 网关只支持原生部署；Docker 部署只包含上游 CLIProxyAPI 与 CPA Manager Plus。", language: language)
        }
    }

    static func stopMessage(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localized("停止 Oases 网关、CLIProxyAPI 与 CPAMP（网关先停，最多等待 30 秒让进行中的请求完成），不删除安装目录、认证文件或 Keychain 凭据。", language: language)
        case .legacy:
            OasesLocalization.localized("只停止 CLIProxyAPI 与 CPAMP，不删除安装目录、认证文件或 Keychain 凭据。", language: language)
        }
    }

    static func removalMessage(topology: DeploymentTopology, directory: String, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localizedFormat("将先停止 Oases 网关、CLIProxyAPI 与 CPAMP，再删除 %@ 中的全部文件、备份和日志（含网关数据），同时清除该目标的 Keychain 凭据与保存记录。此操作不可撤销。", language: language, directory)
        case .legacy:
            OasesLocalization.localizedFormat("将先停止 CLIProxyAPI 与 CPAMP，再删除 %@ 中的全部文件、备份和日志，同时清除该目标的 Keychain 凭据与保存记录。此操作不可撤销。", language: language, directory)
        }
    }

    static func rollbackMessage(ports: String, language: AppLanguage? = nil) -> String {
        OasesLocalization.localizedFormat("App 会使用目标目录中最近的 backups/upgrade-*：启动脚本、版本记录、引擎配置（config.yaml）和 Oases 网关数据（gateway-data，如有）都回到升级前的状态；升级后较新的这些文件保留在该备份的 *.after-upgrade 与 gateway-data-after-upgrade 中，不会删除。随后重新验证 %@。认证文件不变；secrets 回到升级前的备份（较新的保留在 secrets-after-upgrade）；如果回滚换回了旧版 CPA Manager Plus，用量数据也恢复到升级前的备份，较新的保留在 cpamp-data-after-upgrade。", language: language, ports)
    }

    static func healthyMessage(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localized("Oases 网关、CLIProxyAPI、CPAMP 和 SSH 隧道（如适用）均可访问；App 会每 30 秒自动检查", language: language)
        case .legacy:
            OasesLocalization.localized("CLIProxyAPI、CPAMP 和 SSH 隧道（如适用）均可访问；App 会每 30 秒自动检查", language: language)
        }
    }

    static func checkingMessage(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localized("App 正在确认 Oases 网关、CLIProxyAPI、CPAMP 和 SSH 隧道状态", language: language)
        case .legacy:
            OasesLocalization.localized("App 正在确认 CLIProxyAPI、CPAMP 和 SSH 隧道状态", language: language)
        }
    }

    static func planConfirmationMessage(method: DeploymentMethod, language: AppLanguage? = nil) -> String {
        let base = OasesLocalization.localized("后续执行器会在你选择的目标终端中运行下载、配置和启动命令。已有配置不会被静默覆盖。", language: language)
        guard method == .docker else { return base }
        return base + "\n" + dockerGatewayNotice(language: language)
    }
}

struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
