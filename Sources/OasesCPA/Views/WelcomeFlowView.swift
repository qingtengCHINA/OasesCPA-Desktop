import AppKit
import SwiftUI

/// What the welcome gate shows right now, from its first step, what the user started and the
/// deployment state. Pure, so each transition is a unit test.
enum WelcomePhase: Equatable, Sendable {
    /// Step 1: "安装并启动".
    case install
    /// Step 2: the checklist (preparing, running, verifying, failed).
    case installing(InstallProgressPhase)
    /// Step 3: the endpoint and the two optional next steps.
    case ready
    /// Step U: the upgrade wizard.
    case upgrade
    /// Step U running or failed.
    case upgrading(UpgradeChecklist.Phase)
    /// Step U finished.
    case upgraded

    struct Facts: Equatable, Sendable {
        var stage: DeploymentStage = .idle
        var isDeploying = false
        var isProbing = false
        var isPreparingOneClickInstall = false
        var isMaintaining = false
        var hasInstalledDeployment = false
        var topology: DeploymentTopology = .legacy
        /// `DeploymentStore.installProgress?.stage`.
        var installStage: String?
        /// The stage a failed install stopped in (from the classifier).
        var failedStage: String?
        var maintenanceFailure: MaintenanceFailure?

        @MainActor
        init(_ store: DeploymentStore, failedStage: String?) {
            stage = store.stage
            isDeploying = store.isDeploying
            isProbing = store.isProbing
            isPreparingOneClickInstall = store.isPreparingOneClickInstall
            isMaintaining = store.isMaintaining
            hasInstalledDeployment = store.hasInstalledDeployment
            topology = store.topology
            installStage = store.installProgress?.stage
            self.failedStage = failedStage
            maintenanceFailure = store.lastMaintenanceFailure
        }

        init(
            stage: DeploymentStage = .idle,
            isDeploying: Bool = false,
            isProbing: Bool = false,
            isPreparingOneClickInstall: Bool = false,
            isMaintaining: Bool = false,
            hasInstalledDeployment: Bool = false,
            topology: DeploymentTopology = .legacy,
            installStage: String? = nil,
            failedStage: String? = nil,
            maintenanceFailure: MaintenanceFailure? = nil
        ) {
            self.stage = stage
            self.isDeploying = isDeploying
            self.isProbing = isProbing
            self.isPreparingOneClickInstall = isPreparingOneClickInstall
            self.isMaintaining = isMaintaining
            self.hasInstalledDeployment = hasInstalledDeployment
            self.topology = topology
            self.installStage = installStage
            self.failedStage = failedStage
            self.maintenanceFailure = maintenanceFailure
        }
    }

    /// The way out of a failed step (the bottom bar's "进入控制台"): a failed install and a
    /// failed or refused upgrade both lead to 连接与部署, which shows what is on the machine now
    /// (for an upgrade: the old deployment and its legacy state), so the user is never stuck
    /// between 重试 and 查看日志. Nil for every other phase (their own buttons lead on).
    var failureExit: AppSection? {
        switch self {
        case .installing(.failed), .upgrading(.failed): .environments
        default: nil
        }
    }

    static func resolve(initialStep: WelcomeStep, startedInstall: Bool, startedUpgrade: Bool, facts: Facts) -> WelcomePhase {
        switch initialStep {
        case .ready:
            return .ready
        case .upgrade:
            guard startedUpgrade else { return .upgrade }
            if facts.isMaintaining { return .upgrading(.running) }
            if case .upgrade(let failure) = facts.maintenanceFailure { return .upgrading(.failed(stage: failure.stage)) }
            if facts.maintenanceFailure != nil { return .upgrading(.failed(stage: nil)) }
            if facts.topology == .gateway && facts.stage == .attached { return .upgraded }
            return .upgrade
        case .install:
            guard startedInstall else {
                // A deployment that came up while step 1 was shown (a late adoption).
                return facts.hasInstalledDeployment && facts.stage == .attached ? .ready : .install
            }
            if facts.isPreparingOneClickInstall || facts.isProbing { return .installing(.preparing) }
            if facts.isDeploying {
                switch facts.stage {
                case .installing: return .installing(.running(stage: facts.installStage))
                case .connecting: return .installing(facts.hasInstalledDeployment ? .verifying : .preparing)
                default: return .installing(.preparing)
                }
            }
            switch facts.stage {
            case .attached: return .ready
            case .failed: return .installing(.failed(stage: facts.failedStage))
            case .connecting: return .installing(facts.hasInstalledDeployment ? .verifying : .preparing)
            default: return .install
            }
        }
    }
}

/// The welcome gate in the main window (no sidebar until a deployment runs): Step 1 installs
/// with one action, Step 2 shows the real checklist, Step 3 shows the endpoint; a 0.1.x
/// deployment gets the one-screen upgrade wizard instead. Leaving calls `onFinish` with the
/// section to show (design-direction 6.2-6.8).
struct WelcomeFlowView: View {
    let initialStep: WelcomeStep
    let onFinish: (AppSection) -> Void

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startedInstall: Bool
    @State private var startedUpgrade: Bool
    @State private var confirmsCancel = false
    @State private var showsLog = false
    @State private var showsRemoteSheet = false
    /// For snapshots and previews: a fixed phase instead of the store's.
    private let phaseOverride: WelcomePhase?
    private let failureOverride: DeploymentFailure?
    private let maintenanceFailureOverride: MaintenanceFailure?

    init(
        initialStep: WelcomeStep,
        phaseOverride: WelcomePhase? = nil,
        failureOverride: DeploymentFailure? = nil,
        maintenanceFailureOverride: MaintenanceFailure? = nil,
        onFinish: @escaping (AppSection) -> Void
    ) {
        self.initialStep = initialStep
        self.onFinish = onFinish
        self.phaseOverride = phaseOverride
        self.failureOverride = failureOverride
        self.maintenanceFailureOverride = maintenanceFailureOverride
        _startedInstall = State(initialValue: false)
        _startedUpgrade = State(initialValue: false)
    }

    private var maintenanceFailure: MaintenanceFailure? {
        maintenanceFailureOverride ?? deploymentStore.lastMaintenanceFailure
    }

    private var installFailure: DeploymentFailure? {
        if let failureOverride { return failureOverride }
        if let preflight = deploymentStore.oneClickPreflightFailure { return preflight }
        guard deploymentStore.stage == .failed else { return nil }
        let message = deploymentStore.deploymentError ?? deploymentStore.probeError ?? deploymentStore.statusMessage
        return DeploymentFailureClassifier.classify(message: message, installed: deploymentStore.hasInstalledDeployment)
    }

    private var phase: WelcomePhase {
        if let phaseOverride { return phaseOverride }
        return WelcomePhase.resolve(
            initialStep: initialStep,
            startedInstall: startedInstall,
            startedUpgrade: startedUpgrade,
            facts: WelcomePhase.Facts(deploymentStore, failedStage: installFailure?.stage)
        )
    }

    var body: some View {
        let phase = phase
        VStack(spacing: 0) {
            // The 440 pt column is centred; it scrolls only when it is taller than the window.
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Oases.Space.xl) {
                        content(for: phase)
                    }
                    .frame(width: 440, alignment: .leading)
                    .padding(.vertical, Oases.Space.xxl)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .id(phaseIdentity(phase))
                    .transition(.opacity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            bottomBar(for: phase)
        }
        .controlSize(.large)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phaseIdentity(phase))
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showsLog) {
            DeploymentLogSheet()
                .controlSize(.regular)
        }
        .sheet(isPresented: $showsRemoteSheet) {
            RemoteTargetSheet {
                startedInstall = true
                deploymentStore.startOneClickInstall()
            }
            .controlSize(.regular)
        }
        .confirmationDialog("取消安装？", isPresented: $confirmsCancel, titleVisibility: .visible) {
            Button("取消安装", role: .destructive) {
                deploymentStore.cancelDeployment(moveAttemptToTrash: true)
            }
            Button("继续安装", role: .cancel) {}
        } message: {
            Text("这次已下载的文件会被移到废纸篓。")
        }
        .modifier(SSHHostKeyConfirmationDialog(deploymentStore: deploymentStore))
    }

    /// One identity per screen, so a step change cross-fades but row updates inside a step do not.
    private func phaseIdentity(_ phase: WelcomePhase) -> String {
        switch phase {
        case .install: "install"
        case .installing: "installing"
        case .ready: "ready"
        case .upgrade: "upgrade"
        case .upgrading: "upgrading"
        case .upgraded: "upgraded"
        }
    }

    @ViewBuilder
    private func content(for phase: WelcomePhase) -> some View {
        switch phase {
        case .install:
            installStep
        case .installing(let progress):
            installingStep(progress)
        case .ready:
            readyStep
        case .upgrade:
            upgradeStep
        case .upgrading(let progress):
            upgradingStep(progress)
        case .upgraded:
            upgradedStep
        }
    }

    // MARK: Step 1

    private var pins: DeploymentPinSet { .current }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xl) {
            VStack(alignment: .leading, spacing: Oases.Space.m) {
                OasesMark(size: 48)
                    .accessibilityHidden(true)
                Text("欢迎使用 Oases CPA")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("在这台 Mac 上运行你自己的 AI API 网关。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Oases.Space.xs) {
                Text("将下载并校验：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(verbatim: "CLIProxyAPI \(pins.engine.tag) · CPA Manager Plus \(pins.cpamp.tag) · Node.js \(pins.node.tag)")
                    .font(.callout)
                    .textSelection(.enabled)
                Text("全部为固定版本，逐个校验 SHA-256。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(OasesLocalization.localizedFormat("安装到 %@，只监听本机 127.0.0.1。", deploymentStore.installDirectory))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Oases.Space.sm) {
                Button("安装并启动") {
                    startedInstall = true
                    deploymentStore.startOneClickInstall()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(installDisabledReason != nil)

                if let reason = installDisabledReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if deploymentStore.stage == .cancelled {
                    Text(deploymentStore.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A disabled "安装并启动" always says why.
    private var installDisabledReason: String? {
        if deploymentStore.isMaintaining || deploymentStore.isRemovingDeployment {
            return OasesLocalization.localized("另一个维护操作正在进行，完成后才能安装。")
        }
        if deploymentStore.isDeploying || deploymentStore.isProbing {
            return OasesLocalization.localized("正在检查这台 Mac…")
        }
        return nil
    }

    // MARK: Step 2

    @ViewBuilder
    private func installingStep(_ progress: InstallProgressPhase) -> some View {
        let failure: DeploymentFailure? = if case .failed = progress { installFailure } else { nil }
        VStack(alignment: .leading, spacing: Oases.Space.l) {
            Text(failure == nil ? LocalizedStringKey("正在安装…") : LocalizedStringKey("安装没有完成"))
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if failure == nil {
                VStack(alignment: .leading, spacing: Oases.Space.xs) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("安装进度"))
                    if case .running(nil) = progress {
                        Text(deploymentStore.targetKind == .ssh
                             ? LocalizedStringKey("远程服务器不报告分步进度；完成后会逐项确认。")
                             : LocalizedStringKey("正在安装；这一步不报告分步进度。"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DeploymentChecklistView(rows: installRows(progress, failure: failure))

            if let failure {
                DeploymentFailureActions(
                    failure: failure,
                    onRetry: retryInstall,
                    onShowLog: { showsLog = true },
                    onRevealInFinder: deploymentStore.targetKind == .local
                        ? { InstallDirectoryReveal.reveal(deploymentStore.installDirectory) }
                        : nil
                )
            } else if deploymentStore.canCancelDeployment {
                Button("取消") { confirmsCancel = true }
                    .buttonStyle(.bordered)
                    .disabled(deploymentStore.isControllingDeployment)
            }
        }
    }

    private func installRows(_ progress: InstallProgressPhase, failure: DeploymentFailure?) -> [DeploymentChecklistRow] {
        var rows = InstallChecklist.rows(phase: progress, receivedBytes: deploymentStore.installProgress?.receivedBytes)
        if let failure, let index = rows.firstIndex(where: { $0.status == .failed }) {
            rows[index].detail = failure.reason(installDirectory: deploymentStore.installDirectory)
        }
        return rows
    }

    private func retryInstall() {
        if deploymentStore.hasInstalledDeployment {
            deploymentStore.resumeServices()
        } else {
            startedInstall = true
            deploymentStore.startOneClickInstall()
        }
    }

    // MARK: Step 3

    private var providerCount: Int { runtimeDataStore.openAICompatibility.count }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xl) {
            VStack(alignment: .leading, spacing: Oases.Space.m) {
                Label {
                    Text("网关已就绪")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                Text("把下面的地址填到客户端的 Base URL：")
                    .foregroundStyle(.secondary)
                EndpointHeroField(endpoint: deploymentStore.cpaClientURLString)
            }

            VStack(alignment: .leading, spacing: Oases.Space.m) {
                Text("接下来")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                nextStepRow(
                    number: 1,
                    title: "添加 AI 提供商",
                    detail: providerCount > 0
                        ? OasesLocalization.localizedFormat("已添加 %lld 个提供商。", providerCount)
                        : OasesLocalization.localized("填入上游的接口地址和 API Key。"),
                    isDone: providerCount > 0,
                    actionTitle: "添加",
                    isPrimary: providerCount == 0
                ) {
                    store.openProviderEditor(.createOpenAICompatibility)
                    openWindow(id: ProviderEditorWindowScene.id)
                }
                Divider()
                nextStepRow(
                    number: 2,
                    title: "创建 API Key",
                    detail: OasesLocalization.localized("给 Cursor、Claude Code 等客户端使用（可选）。"),
                    isDone: false,
                    actionTitle: "创建",
                    isPrimary: false
                ) {
                    store.createKeyRequested = true
                    onFinish(.accessKeys)
                }
            }

            HStack {
                Spacer()
                if providerCount > 0 {
                    Button("进入控制台") { onFinish(.dashboard) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("进入控制台") { onFinish(.dashboard) }
                        .buttonStyle(.link)
                }
            }
        }
        .task {
            runtimeDataStore.refresh(using: deploymentStore, includingGatewayModels: false)
        }
    }

    private func nextStepRow(
        number: Int,
        title: LocalizedStringKey,
        detail: String,
        isDone: Bool,
        actionTitle: LocalizedStringKey,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Oases.Space.m) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(verbatim: "\(number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Oases.Space.m)
            if isPrimary {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Step U

    private var upgradeStep: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xl) {
            VStack(alignment: .leading, spacing: Oases.Space.m) {
                OasesMark(size: 48)
                    .accessibilityHidden(true)
                Text("升级到完整版")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("检测到旧版 Oases CPA 0.1.x 部署。升级会先自动备份，你的 AI 提供商、认证文件、API Key 和用量数据都会保留；如果升级没有完成，会自动恢复到原来的部署。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(OasesLocalization.localizedFormat("备份会保存在 %@ 中。", deploymentStore.installDirectory + "/backups"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: Oases.Space.m) {
                Button("备份并升级") {
                    startedUpgrade = true
                    deploymentStore.upgradeDeployment()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(upgradeDisabledReason != nil)
                if let reason = upgradeDisabledReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("暂不升级，继续使用旧版") { onFinish(.dashboard) }
                    .buttonStyle(.link)
            }
        }
    }

    private var upgradeDisabledReason: String? {
        if deploymentStore.isDeploying || deploymentStore.isMaintaining || deploymentStore.isRemovingDeployment {
            return OasesLocalization.localized("另一个维护操作正在进行，完成后才能升级。")
        }
        return nil
    }

    @ViewBuilder
    private func upgradingStep(_ progress: UpgradeChecklist.Phase) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.l) {
            Text(upgradeTitle(progress))
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

            if case .running = progress {
                VStack(alignment: .leading, spacing: Oases.Space.xs) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("升级进度"))
                    Text("升级不报告分步进度；完成前请保持 App 打开。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            DeploymentChecklistView(rows: upgradeRows(progress))

            if case .failed = progress {
                VStack(alignment: .leading, spacing: Oases.Space.m) {
                    Text(upgradeOutcome)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Oases.Space.sm) {
                        if case .refused = maintenanceFailure {
                            EmptyView()
                        } else {
                            Button("重试") { deploymentStore.upgradeDeployment() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(upgradeDisabledReason != nil)
                        }
                        Button("查看日志") { showsLog = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func upgradeTitle(_ progress: UpgradeChecklist.Phase) -> String {
        guard case .failed = progress else { return OasesLocalization.localized("正在升级…") }
        switch maintenanceFailure {
        case .upgrade(let failure):
            switch (failure.changes, failure.running) {
            case (.restoreIncomplete, _):
                return OasesLocalization.localized("升级没有完成，自动恢复也不完整。")
            case (_, .yes):
                return OasesLocalization.localized("升级没有完成，已恢复到原来的部署。")
            default:
                return OasesLocalization.localized("升级没有完成。")
            }
        case .refused:
            return OasesLocalization.localized("没有升级")
        case .other, nil:
            return OasesLocalization.localized("升级没有完成。")
        }
    }

    private var upgradeOutcome: String {
        switch maintenanceFailure {
        case .upgrade(let failure):
            failure.outcome()
        case .refused(let refusal):
            refusal.message()
        case .other, nil:
            OasesLocalization.localized("原部署现在的状态需要确认；日志里有详细原因。")
        }
    }

    private func upgradeRows(_ progress: UpgradeChecklist.Phase) -> [DeploymentChecklistRow] {
        var rows = UpgradeChecklist.rows(phase: progress)
        if case .upgrade(let failure) = maintenanceFailure,
           let index = rows.firstIndex(where: { $0.status == .failed }) {
            rows[index].detail = failure.reason()
        }
        return rows
    }

    private var upgradedStep: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xl) {
            VStack(alignment: .leading, spacing: Oases.Space.m) {
                Label {
                    Text("升级完成")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                EndpointHeroField(endpoint: deploymentStore.cpaClientURLString)
                Text("接入地址没有变化，客户端不用改。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("进入控制台") { onFinish(.dashboard) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(for phase: WelcomePhase) -> some View {
        HStack(spacing: Oases.Space.m) {
            WelcomeLanguagePicker()
            Spacer()
            switch phase {
            case .install:
                Button("已有远程服务器？连接 VPS…") { showsRemoteSheet = true }
                    .buttonStyle(.link)
                    .disabled(installDisabledReason != nil)
            default:
                if let exit = phase.failureExit {
                    Button("进入控制台") { onFinish(exit) }
                        .buttonStyle(.link)
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, Oases.Space.l)
        .padding(.vertical, Oases.Space.m)
        .overlay(alignment: .top) { Divider() }
    }
}

/// "语言：跟随系统（简体中文）▾" on the first screen; applies at once (the whole window
/// re-renders through `OasesLanguageObserver`).
struct WelcomeLanguagePicker: View {
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue

    private var current: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .system }

    var body: some View {
        Picker("语言", selection: $languageRaw) {
            ForEach(AppLanguage.allCases) { language in
                Text(Self.title(of: language, in: current)).tag(language.rawValue)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    /// "跟随系统（简体中文）" names the language the system choice resolves to.
    nonisolated static func title(of language: AppLanguage, in interface: AppLanguage) -> String {
        guard language == .system else { return language.displayTitle(in: interface) }
        return OasesLocalization.localizedFormat(
            "跟随系统（%@）",
            language: interface,
            language.resolved.displayTitle(in: interface)
        )
    }
}

/// The welcome diagram's labels follow the deployment topology: in the gateway topology the
/// `/v1` port 8317 belongs to the Oases gateway, in the legacy one to CLIProxyAPI.
enum WelcomeRuntimeLabels {
    /// The topology the diagram describes. With nothing attached the store's topology is only a
    /// placeholder (`legacy`), while a new native install deploys the gateway: show what the
    /// selected method would install. An attached deployment shows its own topology.
    static func displayedTopology(
        topology: DeploymentTopology,
        hasInstalledDeployment: Bool,
        method: DeploymentMethod
    ) -> DeploymentTopology {
        guard !hasInstalledDeployment else { return topology }
        return method == .native ? .gateway : .legacy
    }

    static func apiRowName(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway: OasesLocalization.localized("Oases 网关", language: language)
        case .legacy: "CLIProxyAPI"
        }
    }

    static func diagramAccessibilityLabel(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localized("控制面连接本机或 SSH，再管理 Oases 网关、CLIProxyAPI 与 CPA Manager Plus", language: language)
        case .legacy:
            OasesLocalization.localized("控制面连接本机或 SSH，再管理 CLIProxyAPI 与 CPA Manager Plus", language: language)
        }
    }
}
