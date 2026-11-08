import SwiftUI
import UniformTypeIdentifiers

struct ConnectionCenterView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isImportingKey = false
    @State private var confirmPlan = false
    @State private var confirmStop = false
    @State private var confirmCancelDeployment = false
    @State private var confirmRemoveDeployment = false
    @State private var confirmCleanup = false
    @State private var confirmForget = false
    @State private var confirmUpgrade = false
    @State private var confirmRollback = false
    @State private var confirmDeleteProfile = false
    @State private var profileToDeleteID: UUID?
    @State private var showAdvancedOptions = false
    @State private var showProblems = false
    @State private var startConfirmationAfterProbe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if deploymentStore.hasInstalledDeployment,
                   deploymentStore.healthState != .unknown {
                    healthCard
                }

                deploymentCard

                DisclosureGroup(isExpanded: $showAdvancedOptions) {
                    advancedOptions
                        .padding(.top, 10)
                } label: {
                    disclosureLabel(
                        title: "高级选项",
                        subtitle: "远程 VPS、Docker、已保存目标、安装目录和版本维护",
                        systemImage: "slider.horizontal.3"
                    )
                }

                DisclosureGroup(isExpanded: $showProblems) {
                    problemsSection
                        .padding(.top, 10)
                } label: {
                    disclosureLabel(
                        title: "遇到问题",
                        subtitle: "重新检测环境，或查看部署日志和诊断信息",
                        systemImage: "questionmark.circle"
                    )
                }
            }
            .padding(28)
        }
        .fileImporter(
            isPresented: $isImportingKey,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                deploymentStore.importSSHKey(from: url)
            }
        }
        .onChange(of: deploymentStore.planPresented) { _, isPresented in
            guard isPresented, startConfirmationAfterProbe else { return }
            startConfirmationAfterProbe = false
            confirmPlan = true
        }
        .onChange(of: deploymentStore.deploymentError) { _, error in
            if error != nil {
                showProblems = true
            }
        }
        .confirmationDialog(
            "确认授权部署",
            isPresented: $confirmPlan,
            titleVisibility: .visible
        ) {
            Button("确认并继续") {
                deploymentStore.acknowledgePlan()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.planConfirmationMessage(method: deploymentStore.deploymentMethod))
        }
        .modifier(SSHHostKeyConfirmationDialog(deploymentStore: deploymentStore))
        .confirmationDialog(
            "停止目标环境服务？",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("停止服务", role: .destructive) {
                deploymentStore.stopServices()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.stopMessage(topology: deploymentStore.topology))
        }
        .confirmationDialog(
            "取消当前部署？",
            isPresented: $confirmCancelDeployment,
            titleVisibility: .visible
        ) {
            Button("取消部署并保留文件", role: .destructive) {
                deploymentStore.cancelDeployment()
            }
            Button("取消并彻底删除全部文件", role: .destructive) {
                deploymentStore.cancelDeployment(removeFilesAfterCancellation: true)
            }
            Button("继续部署", role: .cancel) {}
        } message: {
            Text("取消会先验证本次部署的控制令牌，再停止目标机上的安装进程。保留文件可用于诊断或重试；彻底删除会同时移除整个安装目录、服务、凭据和目标记录。")
        }
        .confirmationDialog(
            "彻底删除当前部署？",
            isPresented: $confirmRemoveDeployment,
            titleVisibility: .visible
        ) {
            Button("删除整个部署目录", role: .destructive) {
                deploymentStore.removeDeployment()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.removalMessage(topology: deploymentStore.topology, directory: deploymentStore.installDirectory))
        }
        .confirmationDialog(
            "清理失败部署并重试？",
            isPresented: $confirmCleanup,
            titleVisibility: .visible
        ) {
            Button("停止并备份后清理", role: .destructive) {
                deploymentStore.cleanupFailedDeployment()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 会先停止由本次部署创建的进程或 Compose 服务，再把失败部署文件和日志移动到目标目录的 backups/failed-*，不会直接删除。")
        }
        .confirmationDialog(
            "停止并解除当前目标？",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("停止并解除绑定", role: .destructive) {
                deploymentStore.forgetCurrentDeployment()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 会停止当前目标服务并删除本机保存的 CPA / CPAMP 管理密钥，但不会删除目标目录、认证文件或远程部署文件。之后可以选择另一个本机或 VPS 目标。")
        }
        .confirmationDialog(
            MaintenanceLabels.upgradeConfirmationTitle(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology),
            isPresented: $confirmUpgrade,
            titleVisibility: .visible
        ) {
            Button(OasesLocalization.localized("下载并升级"), role: .destructive) {
                deploymentStore.upgradeDeployment()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.upgradeConfirmationMessage(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology))
        }
        .confirmationDialog(
            "回滚到上一版运行时？",
            isPresented: $confirmRollback,
            titleVisibility: .visible
        ) {
            Button("恢复上一版", role: .destructive) {
                deploymentStore.rollbackDeployment()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(MaintenanceLabels.rollbackMessage(ports: deploymentStore.tunnelPortList))
        }
        .confirmationDialog(
            "删除未部署目标？",
            isPresented: $confirmDeleteProfile,
            titleVisibility: .visible
        ) {
            Button("删除目标", role: .destructive) {
                if let profileToDeleteID {
                    deploymentStore.deleteSavedProfile(profileToDeleteID)
                }
                profileToDeleteID = nil
            }
            Button("取消", role: .cancel) {
                profileToDeleteID = nil
            }
        } message: {
            Text("只移除 App 保存的连接草稿和该目标的 SSH 私钥，不会删除任何远程目录或服务。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("准备好开始")
                    .font(.largeTitle.weight(.bold))
                Text(LocalizedStringKey(deploymentStore.targetKind == .local
                    ? "在这台 Mac 上部署你的 CPA Proxy API。"
                    : "连接远程目标并部署你的 CPA Proxy API。"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            StatusPill(
                title: connectionStatusTitle,
                tint: connectionStatusTint,
                systemImage: connectionStatusImage
            )
        }
    }

    private var connectionStatusTitle: String {
        if deploymentStore.hasInstalledDeployment,
           deploymentStore.healthState != .unknown {
            return deploymentStore.healthState.title
        }
        return deploymentStore.stage.title
    }

    private var connectionStatusTint: Color {
        switch deploymentStore.healthState {
        case .healthy:
            return .oasesGreen
        case .checking, .recovering:
            return .oasesBlue
        case .degraded:
            return .oasesRed
        case .unknown:
            return deploymentStore.stage == .attached ? .oasesGreen : .oasesOrange
        }
    }

    private var connectionStatusImage: String {
        switch deploymentStore.healthState {
        case .healthy:
            return "checkmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .recovering:
            return "wrench.and.screwdriver"
        case .degraded:
            return "exclamationmark.triangle"
        case .unknown:
            return deploymentStore.stage == .attached ? "checkmark.circle" : "circle.dashed"
        }
    }

    private var healthCard: some View {
        let lastCheck = deploymentStore.lastHealthCheckAt.map {
            $0.formatted(date: .omitted, time: .shortened)
        }
        let detail = lastCheck.map {
            OasesLocalization.localizedFormat("最近检查：%@", $0)
        } ?? OasesLocalization.localized("尚未完成检查")
        return InfoBanner(
            title: healthTitle,
            message: OasesLocalization.localizedFormat("%@（%@）", healthMessage, detail),
            systemImage: connectionStatusImage,
            tint: connectionStatusTint
        )
    }

    private var healthTitle: String {
        switch deploymentStore.healthState {
        case .healthy: OasesLocalization.localized("服务健康")
        case .checking: OasesLocalization.localized("正在检查连接")
        case .degraded: OasesLocalization.localized("目标服务不可用")
        case .recovering: OasesLocalization.localized("正在自动恢复连接")
        case .unknown: OasesLocalization.localized("等待连接检测")
        }
    }

    private var healthMessage: String {
        switch deploymentStore.healthState {
        case .healthy:
            return MaintenanceLabels.healthyMessage(topology: deploymentStore.topology)
        case .checking:
            return MaintenanceLabels.checkingMessage(topology: deploymentStore.topology)
        case .degraded:
            let detail = deploymentStore.healthError ?? OasesLocalization.localized("健康检查未通过")
            return OasesLocalization.localizedFormat("%@；保持运行时 App 会继续重试，手动停止后不会自动启动", detail)
        case .recovering:
            return OasesLocalization.localized("检测到服务不可用，App 正在重建服务或 SSH 隧道")
        case .unknown:
            return OasesLocalization.localized("等待 App 完成首次连接检查")
        }
    }

    /// The loopback ports of the current topology: the gateway (API / admin) when there is one,
    /// the engine, and CPA Manager Plus.
    @ViewBuilder
    private var runtimePortFacts: some View {
        if deploymentStore.topology == .gateway {
            DeploymentChoiceFact(
                title: "Oases 网关",
                value: "\(DeploymentPorts.gatewayAPI) / \(DeploymentPorts.gatewayAdmin)"
            )
        }
        DeploymentChoiceFact(
            title: "CLIProxyAPI",
            value: String(deploymentStore.endpoints.engineBaseURL.port ?? DeploymentPorts.legacyEngine)
        )
        DeploymentChoiceFact(title: "CPAMP 面板", value: String(DeploymentPorts.cpamp))
    }

    private var deploymentCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                CardTitle(
                    title: deploymentStore.targetKind == .local ? "部署到本机" : "部署到远程目标",
                    subtitle: deploymentStore.targetKind == .local
                        ? "自动检测环境，然后在当前 Mac 上安装 CLIProxyAPI 和 CPAMP。"
                        : "先检测远程目标，再通过 SSH 安装 CLIProxyAPI 和 CPAMP。",
                    icon: deploymentStore.targetKind == .local ? "laptopcomputer" : "server.rack"
                )
                Spacer()
            }

            HStack(spacing: 0) {
                runtimePortFacts
                DeploymentChoiceFact(
                    title: "部署方式",
                    value: deploymentStore.targetKind == .local ? "本机原生" : deploymentStore.deploymentMethod.title
                )
            }

            if deploymentStore.isProbing || deploymentStore.isDeploying || deploymentStore.isRemovingDeployment {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey(progressTitle))
                        .font(.subheadline.weight(.semibold))
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(connectionStatusTint)
                        .accessibilityLabel("部署进度")
                        .accessibilityValue(progressTitle)
                }
            }

            if deploymentStore.stage == .attached {
                Label("部署完成，服务已连接。你现在可以添加 AI 提供商和 API Key。", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.oasesGreen)
            } else if let deploymentError = deploymentStore.deploymentError {
                Label(deploymentError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else if deploymentStore.stage == .ready {
                Text("环境检查完成。确认后开始部署，安装过程不会展示复杂的终端步骤。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(deploymentStore.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    primaryDeploymentAction()
                } label: {
                    Label(LocalizedStringKey(primaryActionTitle), systemImage: primaryActionImage)
                }
                .buttonStyle(.oasesPrimary)
                .controlSize(.large)
                .disabled(primaryActionDisabled)

                if deploymentStore.canPauseDeployment {
                    Button("暂停", systemImage: "pause.fill") {
                        deploymentStore.pauseDeployment()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else if deploymentStore.canResumeDeployment {
                    Button("继续", systemImage: "play.fill") {
                        deploymentStore.resumeDeployment()
                    }
                    .buttonStyle(.oasesPrimary)
                    .controlSize(.large)
                }

                if deploymentStore.canCancelDeployment {
                    Button("取消部署", systemImage: "xmark.circle", role: .destructive) {
                        confirmCancelDeployment = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(deploymentStore.isControllingDeployment)
                } else if deploymentStore.canRemoveDeployment {
                    Button("彻底删除部署", systemImage: "trash", role: .destructive) {
                        confirmRemoveDeployment = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            if let removalError = deploymentStore.removalError {
                Label(removalError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .oasesCard()
    }

    private var progressTitle: String {
        if deploymentStore.isProbing {
            return OasesLocalization.localized("正在检查环境")
        }
        if deploymentStore.isRemovingDeployment {
            return OasesLocalization.localized("正在彻底删除部署")
        }
        if deploymentStore.isDeploying {
            if deploymentStore.isCancellingDeployment {
                return OasesLocalization.localized("正在取消部署")
            }
            if deploymentStore.isDeploymentPaused {
                return OasesLocalization.localized("部署已暂停")
            }
            return deploymentStore.stage == .installing
                ? OasesLocalization.localized("正在部署")
                : OasesLocalization.localized("正在连接")
        }
        return OasesLocalization.localized("环境已准备好")
    }

    private var primaryActionTitle: String {
        if deploymentStore.stage == .attached {
            return OasesLocalization.localized("添加 AI 提供商")
        }
        if deploymentStore.hasInstalledDeployment {
            return deploymentStore.hasLoadedSavedCredentials
                ? OasesLocalization.localized("重新启动服务")
                : OasesLocalization.localized("连接已保存目标")
        }
        if deploymentStore.isProbing {
            return OasesLocalization.localized("检测中…")
        }
        if deploymentStore.isDeploying {
            return OasesLocalization.localized("部署中…")
        }
        if deploymentStore.planPresented || deploymentStore.stage == .ready {
            return OasesLocalization.localized("确认并部署")
        }
        if deploymentStore.stage == .failed {
            return OasesLocalization.localized("重新检测")
        }
        return deploymentStore.targetKind == .local
            ? OasesLocalization.localized("部署到本机")
            : OasesLocalization.localized("检测并部署")
    }

    private var primaryActionImage: String {
        if deploymentStore.stage == .attached {
            return AppSection.aiProviders.systemImage
        }
        if deploymentStore.hasInstalledDeployment {
            return "play.circle"
        }
        if deploymentStore.isProbing || deploymentStore.isDeploying {
            return "hourglass"
        }
        if deploymentStore.stage == .failed {
            return "arrow.clockwise"
        }
        return deploymentStore.planPresented || deploymentStore.stage == .ready
            ? "checkmark"
            : "arrow.down.circle"
    }

    private var primaryActionDisabled: Bool {
        deploymentStore.isProbing || deploymentStore.isDeploying || deploymentStore.isMaintaining || deploymentStore.isRemovingDeployment
    }

    private func primaryDeploymentAction() {
        if deploymentStore.stage == .attached {
            appStore.selectSection(.aiProviders)
            return
        }

        if deploymentStore.hasInstalledDeployment {
            deploymentStore.resumeServices()
            return
        }

        if deploymentStore.planPresented {
            confirmPlan = true
            return
        }

        if deploymentStore.probe != nil {
            deploymentStore.preparePlan()
            if deploymentStore.planPresented {
                confirmPlan = true
            }
            return
        }

        startConfirmationAfterProbe = true
        deploymentStore.probeTarget()
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            savedTargetsCard
            targetPicker

            if deploymentStore.targetKind == .ssh {
                remoteForm
            } else {
                localSummary
            }

            deploymentOptions

            if deploymentStore.hasInstalledDeployment {
                targetManagementActions
                maintenanceCard
            }
        }
    }

    private var targetManagementActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(
                title: "当前目标管理",
                subtitle: "停止服务、打开高级面板或解除目标绑定",
                icon: "wrench.and.screwdriver"
            )
            HStack {
                if deploymentStore.stage == .attached {
                    Button("打开 CPAMP 面板", systemImage: "rectangle.portrait.and.arrow.right") {
                        deploymentStore.openPanel()
                    }
                    .buttonStyle(.bordered)

                    Button("停止服务", systemImage: "stop.circle") {
                        confirmStop = true
                    }
                    .buttonStyle(.bordered)
                }

                Button("解除当前目标绑定", systemImage: "rectangle.badge.xmark") {
                    confirmForget = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var problemsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            probeAction
            deploymentLogsSection

            if deploymentStore.stage == .failed && !deploymentStore.hasInstalledDeployment {
                Button("清理失败部署并重试", systemImage: "arrow.triangle.2.circlepath") {
                    confirmCleanup = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private func disclosureLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.oasesBlue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                Text(LocalizedStringKey(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var savedTargetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CardTitle(
                    title: "已保存目标",
                    subtitle: "本机或 VPS 的连接参数与管理凭据",
                    icon: "square.stack.3d.up"
                )
                Spacer()
                Button("添加目标", systemImage: "plus") {
                    deploymentStore.beginNewTarget()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)
            }

            if deploymentStore.savedProfiles.isEmpty {
                Text("还没有保存的目标；首次部署完成后会自动加入列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(deploymentStore.savedProfiles) { profile in
                        Button {
                            deploymentStore.selectSavedProfile(profile.id)
                        } label: {
                            SavedTargetRow(
                                profile: profile,
                                isActive: profile.id == deploymentStore.activeProfileID
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(profile.id == deploymentStore.activeProfileID)
                        .contextMenu {
                            if !profile.isInstalled {
                                Button("删除未部署目标", role: .destructive) {
                                    profileToDeleteID = profile.id
                                    confirmDeleteProfile = true
                                }
                            }
                        }
                    }
                }
            }

            if deploymentStore.savedProfiles.count > 1 {
                Label(
                    "切换目标前请先停止当前正在运行的服务，避免本机 \(deploymentStore.tunnelPortList) 端口或 SSH 隧道互相覆盖。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var targetPicker: some View {
        HStack(spacing: 14) {
            ForEach(DeploymentTargetKind.allCases) { kind in
                Button {
                    deploymentStore.selectTarget(kind)
                } label: {
                    TargetOptionCard(
                        kind: kind,
                        isSelected: deploymentStore.targetKind == kind
                    )
                }
                .buttonStyle(.plain)
                .disabled(deploymentStore.hasInstalledDeployment || deploymentStore.isDeploying)
            }
        }
    }

    private var localSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "本机目标详情", subtitle: "部署命令将在当前 Mac 的本地终端执行", icon: "laptopcomputer")

            HStack(spacing: 0) {
                TargetFact(title: "系统", value: deploymentStore.targetSummary.operatingSystem)
                TargetFact(title: "架构", value: deploymentStore.targetSummary.architecture)
                TargetFact(title: "Shell", value: deploymentStore.targetSummary.shell)
                TargetFact(title: "权限", value: deploymentStore.targetSummary.access)
            }

            Text(OasesLocalization.localizedFormat("安装目录：%@", deploymentStore.installDirectory))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .oasesCard()
    }

    private var remoteForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "远程目标", subtitle: "连接信息保存在本机；私钥内容进入 macOS Keychain", icon: "server.rack")

            HStack(spacing: 12) {
                LabeledField(title: "主机名 / IP", placeholder: "vps.example.com", text: $deploymentStore.remoteHost)
                LabeledField(title: "SSH 用户", placeholder: "root", text: $deploymentStore.remoteUser)
                    .frame(width: 150)
                LabeledField(title: "端口", placeholder: "22", text: $deploymentStore.remotePort)
                    .frame(width: 90)
            }

            HStack(spacing: 10) {
                LabeledField(title: "SSH 私钥路径", placeholder: "选择本机私钥文件", text: $deploymentStore.privateKeyPath)
                Button("选择…") {
                    isImportingKey = true
                }
                .buttonStyle(.bordered)
                .padding(.top, 19)
            }

            LabeledField(title: "远程安装目录", placeholder: "~/.oases-cpa", text: $deploymentStore.installDirectory)
        }
        .padding(20)
        .oasesCard()
        .disabled(deploymentStore.hasInstalledDeployment || deploymentStore.isDeploying)
    }

    private var deploymentOptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            CardTitle(title: "部署方式", subtitle: "原生二进制适合大多数用户；Docker 用于隔离部署", icon: "shippingbox")

            Picker("部署方式", selection: Binding(
                get: { deploymentStore.deploymentMethod },
                set: { deploymentStore.selectMethod($0) }
            )) {
                ForEach(DeploymentMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(deploymentStore.hasInstalledDeployment || deploymentStore.isDeploying)

            Text(deploymentStore.deploymentMethod.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if deploymentStore.deploymentMethod == .docker {
                Label(MaintenanceLabels.dockerGatewayNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                runtimePortFacts
                DeploymentChoiceFact(title: "管理访问", value: "本机回环 / SSH 隧道")
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var probeAction: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CardTitle(
                    title: "连接检测",
                    subtitle: "只读检查系统、架构、依赖和可写目录",
                    icon: "waveform.path.ecg"
                )

                Spacer()

                Button {
                    deploymentStore.probeTarget()
                } label: {
                    Label(
                        deploymentStore.isProbing ? "检测中…" : "重新检测",
                        systemImage: deploymentStore.isProbing ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(deploymentStore.isProbing || deploymentStore.isDeploying)
            }

            if let probe = deploymentStore.probe {
                HStack(spacing: 0) {
                    TargetFact(title: "系统", value: probe.operatingSystem)
                    TargetFact(title: "架构", value: probe.architecture)
                    TargetFact(title: "Shell", value: probe.shell)
                }

                let missingDependencies = probe.missingDependencies(for: deploymentStore.deploymentMethod)
                Label(
                    probe.dependencySummary(for: deploymentStore.deploymentMethod),
                    systemImage: missingDependencies.isEmpty ? "checkmark.shield" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(missingDependencies.isEmpty ? Color.oasesGreen : Color.oasesRed)
                .fixedSize(horizontal: false, vertical: true)

                if !missingDependencies.isEmpty {
                    Text("请处理这些前置条件后再重新检测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let probeError = deploymentStore.probeError {
                Label(probeError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("检测不会安装、覆盖或启动任何服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var deploymentLogsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(
                    title: "部署日志",
                    subtitle: deploymentStore.deploymentLogSource.isEmpty ? "部署失败后可读取目标目录中的日志" : deploymentStore.deploymentLogSource,
                    icon: "doc.text.magnifyingglass"
                )
                Spacer()
                Button {
                    deploymentStore.refreshDeploymentLog()
                } label: {
                    Label(
                        deploymentStore.isLoadingDeploymentLog ? "读取中…" : "读取日志",
                        systemImage: deploymentStore.isLoadingDeploymentLog ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(deploymentStore.isLoadingDeploymentLog)
            }

            if let deploymentLogError = deploymentStore.deploymentLogError {
                Text(deploymentLogError)
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
            } else if deploymentStore.isLoadingDeploymentLog && deploymentStore.deploymentLog.isEmpty {
                ProgressView("正在读取目标日志…")
                    .controlSize(.small)
            } else if deploymentStore.deploymentLog.isEmpty {
                Text("暂时没有可读取的日志内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(deploymentStore.deploymentLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 190)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(20)
        .oasesCard()
    }

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "版本维护",
                subtitle: "官方运行时升级会先留下可回滚备份",
                icon: "arrow.triangle.2.circlepath"
            )

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: deploymentStore.isMaintaining ? "arrow.triangle.2.circlepath" : "checkmark.shield")
                    .foregroundStyle(deploymentStore.isMaintaining ? Color.oasesBlue : Color.oasesGreen)
                    .symbolEffect(.pulse, isActive: deploymentStore.isMaintaining && !reduceMotion)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(deploymentStore.isMaintaining ? "正在维护目标运行时…" : "当前部署可安全升级或回滚"))
                        .font(.subheadline.weight(.semibold))
                    if let backup = deploymentStore.latestMaintenanceBackup {
                        Text(OasesLocalization.localizedFormat("最近备份：%@", backup))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未发现升级备份；首次升级会自动创建。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    deploymentStore.refreshLatestMaintenanceBackup()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("刷新升级备份")
                .disabled(deploymentStore.isMaintaining)
            }

            if let message = deploymentStore.maintenanceMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesGreen)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = deploymentStore.maintenanceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(
                    MaintenanceLabels.upgradeButtonTitle(method: deploymentStore.deploymentMethod, topology: deploymentStore.topology),
                    systemImage: "arrow.down.circle"
                ) {
                    confirmUpgrade = true
                }
                .buttonStyle(.oasesPrimary)
                .controlSize(.large)
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)

                Button("回滚上一版", systemImage: "arrow.uturn.backward.circle") {
                    confirmRollback = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(deploymentStore.isDeploying || deploymentStore.isMaintaining)

                if deploymentStore.deploymentMethod == .docker {
                    Text("Docker 回滚恢复 Compose 配置；镜像是否可回退取决于标签。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if deploymentStore.deploymentMethod == .docker {
                Label(MaintenanceLabels.dockerGatewayNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .oasesCard()
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
        OasesLocalization.localizedFormat("App 会使用目标目录中最近的 backups/upgrade-*：启动脚本、版本记录、引擎配置（config.yaml）和 Oases 网关数据（gateway-data，如有）都回到升级前的状态；升级后较新的这些文件保留在该备份的 *.after-upgrade 与 gateway-data-after-upgrade 中，不会删除。随后重新验证 %@。认证文件和 CPAMP 数据不变。", language: language, ports)
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

struct TargetOptionCard: View {
    let kind: DeploymentTargetKind
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.title2)
                .foregroundStyle(isSelected ? Color.oasesBlue : Color.secondary)
                .frame(width: 42, height: 42)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(kind.title))
                    .font(.headline)
                Text(LocalizedStringKey(kind.subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.oasesBlue : Color.secondary.opacity(0.5))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Oases.Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.oasesBlue.opacity(0.58) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        }
    }
}

struct SavedTargetRow: View {
    let profile: DeploymentProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.targetKind.systemImage)
                .foregroundStyle(isActive ? Color.oasesBlue : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    (isActive ? Color.oasesBlue : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(profile.endpointSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusPill(
                title: isActive ? (profile.isInstalled ? "当前目标" : "正在配置") : (profile.isInstalled ? "已保存" : "未部署"),
                tint: isActive ? Color.oasesBlue : (profile.isInstalled ? Color.oasesGreen : Color.secondary),
                systemImage: isActive ? "checkmark.circle.fill" : "circle"
            )
        }
        .padding(12)
        .background(
            isActive ? Color.oasesBlue.opacity(0.07) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Color.oasesBlue.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct SSHHostKeyConfirmationDialog: ViewModifier {
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
                    ? "当前记录：\(confirmation.previousFingerprint ?? "未知")；替换必须再次明确确认。"
                    : "这是该主机的首次记录。"
                Text("主机：\(confirmation.host):\(confirmation.port)\n算法：\(confirmation.algorithm)\nSHA-256：\(confirmation.fingerprint)\n\(changeDescription)")
            } else {
                Text("未发现待确认的 SSH 主机指纹。")
            }
        }
    }
}

struct TargetFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeploymentChoiceFact: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.oasesGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(value))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
