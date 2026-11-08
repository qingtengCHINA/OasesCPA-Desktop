import AppKit
import Combine
import Foundation
import SwiftUI

final class TunnelProcessOwner: @unchecked Sendable {
    private(set) var process: Process?

    func attach(_ process: Process) {
        stop()
        self.process = process
    }

    func stop() {
        guard let process else { return }
        defer { self.process = nil }
        guard process.isRunning else { return }

        process.terminate()
        waitForExit(process)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(process)
        }
    }

    deinit {
        stop()
    }

    private func waitForExit(_ process: Process) {
        for _ in 0..<20 where process.isRunning {
            usleep(50_000)
        }
    }
}

@MainActor
final class DeploymentStore: ObservableObject {
    @Published var targetKind: DeploymentTargetKind = .local {
        didSet { enforceOperationSnapshot() }
    }
    @Published var deploymentMethod: DeploymentMethod = .native {
        didSet { enforceOperationSnapshot() }
    }
    @Published var remoteHost = "" {
        didSet { enforceOperationSnapshot() }
    }
    @Published var remoteUser = "root" {
        didSet { enforceOperationSnapshot() }
    }
    @Published var remotePort = "22" {
        didSet { enforceOperationSnapshot() }
    }
    @Published var privateKeyPath = "" {
        didSet { enforceOperationSnapshot() }
    }
    @Published var installDirectory = "~/.oases-cpa" {
        didSet { enforceOperationSnapshot() }
    }
    @Published var stage: DeploymentStage = .idle
    @Published var steps = DeploymentPlanFactory.makeSteps(target: .local, method: .native)
    @Published var planPresented = false
    @Published var statusMessage = OasesLocalization.localized("选择一个目标环境开始")
    @Published private(set) var probe: DeploymentProbe?
    @Published private(set) var probeError: String?
    @Published private(set) var isProbing = false
    @Published private(set) var isDeploying = false
    @Published private(set) var isDeploymentPaused = false
    @Published private(set) var isControllingDeployment = false
    @Published private(set) var isCancellingDeployment = false
    @Published private(set) var isRemovingDeployment = false
    @Published private(set) var removalError: String?
    @Published private(set) var managementKey = "" {
        didSet {
            // A different key gets its own first try against the gateway.
            if managementKey != oldValue { gatewayAuthLatch.clear() }
        }
    }
    /// The management key the gateway rejected (fingerprint only); see `GatewayAuthLatch`.
    @Published private var gatewayAuthLatch = GatewayAuthLatch()
    @Published private(set) var cpampAdminKey = ""
    /// The layout of the current target. Comes from the saved profile when a target is
    /// selected or attached; new targets start as `legacy` until a probe says otherwise.
    @Published private(set) var topology: DeploymentTopology = .legacy
    /// SHA-256 of the gateway's internal engine key of the active profile (never the key).
    private(set) var packEngineKeyFingerprint: String?
    @Published private(set) var hasLoadedSavedCredentials = false
    @Published private(set) var deploymentError: String?
    @Published private(set) var deploymentLog = ""
    @Published private(set) var deploymentLogSource = ""
    @Published private(set) var deploymentLogError: String?
    @Published private(set) var isLoadingDeploymentLog = false
    @Published private(set) var isMaintaining = false
    @Published private(set) var maintenanceError: String?
    @Published private(set) var maintenanceMessage: String?
    @Published private(set) var latestMaintenanceBackup: String?
    @Published private(set) var savedProfiles: [DeploymentProfile] = []
    @Published private(set) var activeProfileID: UUID? = nil
    @Published private(set) var healthState: DeploymentHealthState = .unknown
    @Published private(set) var lastHealthCheckAt: Date?
    @Published private(set) var healthError: String?
    @Published private(set) var isAutoRecovering = false
    @Published private(set) var pendingSSHHostKeyConfirmation: SSHHostKeyConfirmation?
    @Published var healthNotificationsEnabled = UserDefaults.standard.object(forKey: "oases.cpa.health-notifications") as? Bool ?? false

    private let tunnelProcessOwner = TunnelProcessOwner()
    private var healthMonitorTask: Task<Void, Never>?
    /// False in test processes and in runs launched with `-OasesDisableAutoProbe`: no automatic
    /// probe of the default install directory, no automatic adoption, and no 30 s patrol (which
    /// calls `ensureRunning`). Explicit user actions still work.
    let automaticActivityEnabled: Bool
    /// What the store runs against targets (`.live` in the app, fakes in store-level tests).
    private let services: DeploymentStoreServices

    /// Whether this process may run automatic deployment activity at all. A test process is
    /// recognised in two ways: the Xcode test host sets `XCTestConfigurationFilePath`, and
    /// `swift test` (which does not set it) has the XCTest framework loaded, so the
    /// `XCTestCase` class exists. A normal launch of the app links neither.
    nonisolated static var automaticActivityAllowed: Bool {
        automaticActivityAllowed(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            testFrameworkLoaded: NSClassFromString("XCTestCase") != nil
        )
    }

    nonisolated static func automaticActivityAllowed(
        environment: [String: String],
        arguments: [String],
        testFrameworkLoaded: Bool
    ) -> Bool {
        !testFrameworkLoaded
            && environment["XCTestConfigurationFilePath"] == nil
            && !arguments.contains("-OasesDisableAutoProbe")
    }

    var isHealthMonitorRunningForTesting: Bool {
        healthMonitorTask != nil
    }
    private var tunnelAttached = false
    private var cancellables = Set<AnyCancellable>()
    private var profileIsInstalled = false
    private var wantsRunning = true
    private var probeRequestID = UUID()
    private var logRequestID = UUID()
    private var maintenanceRequestID = UUID()
    private var healthIssueNotificationSent = false
    private var isApplyingProfileConfiguration = false
    private var deploymentTask: Task<Void, Never>?
    private var deploymentOperationID = UUID()
    private var deploymentControlToken: String?
    private var pendingSSHHostKeyRetryAction: SSHHostKeyRetryAction?
    private var activeOperationRequest: DeploymentExecutionRequest?

#if DEBUG
    func beginOperationSnapshotForTesting(_ request: DeploymentExecutionRequest) {
        activeOperationRequest = request
        isDeploying = true
    }

    func endOperationSnapshotForTesting() {
        activeOperationRequest = nil
        isDeploying = false
    }

    var operationRequestSnapshotForTesting: DeploymentExecutionRequest? {
        activeOperationRequest
    }

    /// Puts the store into the attached state with the given topology and credentials, without
    /// Keychain, network or saved profiles.
    func attachForTesting(
        topology: DeploymentTopology,
        managementKey: String,
        adminKey: String,
        method: DeploymentMethod = .native,
        installed: Bool = false
    ) {
        isApplyingProfileConfiguration = true
        deploymentMethod = method
        isApplyingProfileConfiguration = false
        self.topology = topology
        self.managementKey = managementKey
        cpampAdminKey = adminKey
        profileIsInstalled = installed
        stage = .attached
    }
#endif

    private enum SSHHostKeyRetryAction {
        case probe
        case deploymentPlan
        case reconnect
    }

    deinit {
        healthMonitorTask?.cancel()
        deploymentTask?.cancel()
        tunnelProcessOwner.stop()
    }

    /// - Parameters:
    ///   - autoProbe: run automatic deployment activity (see `automaticActivityEnabled`);
    ///     defaults to what the process allows. Tests pass `false`.
    ///   - services: the target-side operations; tests inject fakes.
    init(
        autoProbe: Bool = DeploymentStore.automaticActivityAllowed,
        services: DeploymentStoreServices = .live
    ) {
        automaticActivityEnabled = autoProbe
        self.services = services
        savedProfiles = DeploymentProfileStore.loadAll()
        if let profile = DeploymentProfileStore.load() {
            activeProfileID = profile.id
            targetKind = profile.targetKind
            deploymentMethod = profile.deploymentMethod
            remoteHost = profile.remoteHost
            remoteUser = profile.remoteUser
            remotePort = profile.remotePort
            privateKeyPath = profile.privateKeyPath
            installDirectory = profile.installDirectory
            topology = profile.topology
            packEngineKeyFingerprint = profile.packEngineKeyFingerprint
            profileIsInstalled = profile.isInstalled
            wantsRunning = loadWantsRunningPreference()
            stage = .idle
            statusMessage = profile.isInstalled
                ? OasesLocalization.localized("已保存上次的目标；点击“连接已保存目标”后才会读取钥匙串凭据")
                : OasesLocalization.localized("选择一个目标环境开始")
            steps = DeploymentPlanFactory.makeSteps(target: profile.targetKind, method: profile.deploymentMethod)
        }

        bindPersistence()
        if automaticActivityEnabled, targetKind == .local {
            // Local probing is read-only, so make the common first-run path
            // auto-adopt or reconnect a managed deployment without an early
            // Keychain read prompt.
            Task { [weak self] in
                self?.probeTarget()
            }
        }
    }

    var targetTitle: String { targetKind.title }

    func prepareForApplicationTermination() {
        stopHealthMonitor()
        deploymentTask?.cancel()
        stopTunnel()
    }

    /// The four loopback base URLs of the current target's topology.
    var endpoints: DeploymentEndpoints {
        DeploymentEndpoints(topology: topology)
    }

    var localPanelURL: String {
        targetKind == .local || tunnelAttached
            ? endpoints.cpampBaseURL.appendingPathComponent("management.html").absoluteString
            : OasesLocalization.localized("SSH 隧道建立后使用本机回环地址")
    }

    /// CPA Manager Plus (usage analytics and monitoring backend), as reached from this Mac.
    var cpampManagementURL: String {
        targetKind == .local || tunnelAttached
            ? endpoints.cpampBaseURL.absoluteString
            : OasesLocalization.localizedFormat("SSH 隧道建立后使用本机 %lld 端口", endpoints.cpampBaseURL.port ?? DeploymentPorts.cpamp)
    }

    var cpaManagementURL: String {
        targetKind == .local || tunnelAttached
            ? endpoints.engineBaseURL.absoluteString
            : OasesLocalization.localizedFormat("SSH 隧道建立后使用本机 %lld 端口", endpoints.engineBaseURL.port ?? DeploymentPorts.legacyEngine)
    }

    /// The forwarded loopback ports of the current topology, for display ("8317 / 18317").
    var tunnelPortList: String {
        DeploymentPorts.tunnelPorts(for: topology).map(String.init).joined(separator: " / ")
    }

    /// User-facing OpenAI-compatible endpoint (with `/v1`). Engine management requests use
    /// `engineBaseURL` without the suffix.
    var cpaClientURLString: String {
        endpoints.clientAPIBaseURL.absoluteString
    }

    var cpampBaseURL: URL {
        endpoints.cpampBaseURL
    }

    /// The engine (CLIProxyAPI) and its management API: 8317 for a legacy target, 18316 behind
    /// the gateway.
    var engineBaseURL: URL {
        endpoints.engineBaseURL
    }

    func setHealthNotificationsEnabled(_ enabled: Bool) {
        healthNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "oases.cpa.health-notifications")
        guard enabled else { return }

        Task { [weak self] in
            let authorized = await HealthNotificationService.shared.requestAuthorization()
            guard let self, !authorized else { return }
            self.healthNotificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "oases.cpa.health-notifications")
        }
    }

    var targetSummary: DeploymentTargetSummary {
        if let probe {
            return .init(
                operatingSystem: probe.operatingSystem,
                architecture: probe.architecture,
                shell: probe.shell,
                access: targetKind == .local ? OasesLocalization.localized("当前用户") : remoteUser
            )
        }

        switch targetKind {
        case .local:
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            return .init(operatingSystem: "macOS", architecture: architecture, shell: "zsh", access: OasesLocalization.localized("当前用户"))
        case .ssh:
            return .init(operatingSystem: OasesLocalization.localized("连接后检测"), architecture: OasesLocalization.localized("连接后检测"), shell: OasesLocalization.localized("登录后检测"), access: remoteUser.isEmpty ? OasesLocalization.localized("未填写用户") : remoteUser)
        }
    }

    func selectTarget(_ kind: DeploymentTargetKind) {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        stopHealthMonitor()
        stopTunnel()
        targetKind = kind
        if kind == .local {
            deploymentMethod = .native
            statusMessage = OasesLocalization.localized("本机目标已选择，可生成部署计划")
        } else {
            statusMessage = remoteHost.isEmpty ? OasesLocalization.localized("请填写 VPS 主机后生成计划") : OasesLocalization.localized("远程目标已选择，可生成部署计划")
        }
        steps = DeploymentPlanFactory.makeSteps(target: kind, method: deploymentMethod)
        stage = .idle
        planPresented = false
        invalidateProbe()
        clearLoadedCredentials()
        deploymentError = nil
        invalidateMaintenanceState()
        invalidateDeploymentLog()
        resetHealthState()
        profileIsInstalled = false
        wantsRunning = true
        setWantsRunningPreference(true)
        saveProfile()
        if automaticActivityEnabled, kind == .local {
            Task { [weak self] in
                self?.probeTarget()
            }
        }
    }

    func beginNewTarget() {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        guard !profileIsInstalled || !wantsRunning else {
        statusMessage = OasesLocalization.localized("请先停止当前目标服务，再添加新的目标环境")
            return
        }

        stopHealthMonitor()
        stopTunnel()
        isApplyingProfileConfiguration = true
        defer { isApplyingProfileConfiguration = false }
        activeProfileID = UUID()
        targetKind = .local
        deploymentMethod = .native
        remoteHost = ""
        remoteUser = "root"
        remotePort = "22"
        privateKeyPath = ""
        installDirectory = "~/.oases-cpa"
        topology = .legacy
        packEngineKeyFingerprint = nil
        profileIsInstalled = false
        wantsRunning = true
        setWantsRunningPreference(true)
        clearLoadedCredentials()
        stage = .idle
        statusMessage = OasesLocalization.localized("新目标已创建，选择本机或 SSH/VPS 开始")
        steps = DeploymentPlanFactory.makeSteps(target: .local, method: .native)
        invalidateProbe()
        deploymentError = nil
        invalidateMaintenanceState()
        invalidateDeploymentLog()
        resetHealthState()
        if automaticActivityEnabled {
            Task { [weak self] in
                self?.probeTarget()
            }
        }
    }

    func selectSavedProfile(_ profileID: UUID) {
        guard profileID != activeProfileID else { return }
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        guard !profileIsInstalled || (!wantsRunning && stage != .attached) else {
        statusMessage = OasesLocalization.localized("请先停止当前目标服务，再切换到其他目标")
            return
        }
        guard let profile = savedProfiles.first(where: { $0.id == profileID }) else { return }

        stopHealthMonitor()
        stopTunnel()
        isApplyingProfileConfiguration = true
        defer { isApplyingProfileConfiguration = false }
        activeProfileID = profile.id
        DeploymentProfileStore.setActive(profile.id)
        targetKind = profile.targetKind
        deploymentMethod = profile.deploymentMethod
        remoteHost = profile.remoteHost
        remoteUser = profile.remoteUser
        remotePort = profile.remotePort
        privateKeyPath = profile.privateKeyPath
        installDirectory = profile.installDirectory
        topology = profile.topology
        packEngineKeyFingerprint = profile.packEngineKeyFingerprint
        profileIsInstalled = profile.isInstalled
        wantsRunning = loadWantsRunningPreference()
        clearLoadedCredentials()
        steps = DeploymentPlanFactory.makeSteps(target: profile.targetKind, method: profile.deploymentMethod)
        planPresented = false
        invalidateProbe()
        deploymentError = nil
        invalidateMaintenanceState()
        invalidateDeploymentLog()
        resetHealthState()

        if profileIsInstalled {
            stage = .idle
            statusMessage = OasesLocalization.localizedFormat("已切换到 %@；点击“连接已保存目标”后才会读取钥匙串凭据", profile.displayName)
        } else {
            stage = .idle
            statusMessage = OasesLocalization.localizedFormat("已切换到 %@，可重新检测环境", profile.displayName)
            if automaticActivityEnabled, targetKind == .local {
                Task { [weak self] in
                    self?.probeTarget()
                }
            }
        }
    }

    func deleteSavedProfile(_ profileID: UUID) {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        guard let profile = savedProfiles.first(where: { $0.id == profileID }) else { return }
        guard !profile.isInstalled else {
        statusMessage = OasesLocalization.localized("已安装目标请使用“解除当前目标绑定”，避免留下未停止的服务")
            return
        }
        try? SSHKeyMaterialStore.delete(profileID: profileID)
        DeploymentProfileStore.remove(profileID)
        savedProfiles = DeploymentProfileStore.loadAll()
        if activeProfileID == profileID {
            activeProfileID = nil
            beginNewTarget()
        }
    }

    var canSwitchSavedProfile: Bool {
        !isDeploying && !isMaintaining && (!profileIsInstalled || !wantsRunning) && savedProfiles.count > 1
    }

    func selectMethod(_ method: DeploymentMethod) {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        deploymentMethod = method
        steps = DeploymentPlanFactory.makeSteps(target: targetKind, method: method)
        invalidateProbe()
    }

    func preparePlan() {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        guard targetKind == .local || !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        statusMessage = OasesLocalization.localized("先填写远程 VPS 主机名或 IP 地址")
            stage = .failed
            return
        }

        guard targetKind == .local || !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        statusMessage = OasesLocalization.localized("先选择 SSH 私钥文件")
            stage = .failed
            return
        }

        if targetKind == .ssh, !ensureSSHKeyMaterial() {
        statusMessage = OasesLocalization.localized("SSH 私钥无法读取，请重新选择私钥文件")
            stage = .failed
            return
        }

        if let preflightFailure = preflightFailureMessage {
            planPresented = false
            deploymentError = preflightFailure
            statusMessage = preflightFailure
            stage = .failed
            return
        }

        steps = DeploymentPlanFactory.makeSteps(target: targetKind, method: deploymentMethod)
        stage = .ready
        planPresented = true
        deploymentError = nil
        statusMessage = OasesLocalization.localized("计划已生成；确认后才会执行终端命令")
    }

    func probeTarget() {
        guard !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            probeError = OasesLocalization.localized("SSH 私钥无法读取，请重新选择私钥文件")
            stage = .failed
            return
        }
        probeError = nil
        isProbing = true
        stage = .connecting
        statusMessage = targetKind == .local ? OasesLocalization.localized("正在检测本机终端环境…") : OasesLocalization.localized("正在通过 SSH 检测远程终端环境…")

        let target = targetKind
        let method = deploymentMethod
        let host = remoteHost
        let user = remoteUser
        let port = remotePort
        let keyPath = privateKeyPath
        let directory = installDirectory
        let requestID = UUID()
        probeRequestID = requestID

        Task { [weak self] in
            do {
                if target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(
                        for: DeploymentExecutionRequest(
                            target: target,
                            method: method,
                            host: host,
                            user: user.isEmpty ? "root" : user,
                            port: port,
                            privateKeyPath: keyPath,
                            installDirectory: directory
                        ),
                        retryAction: .probe
                    )
                }
                guard let services = self?.services else { return }
                let result = try await services.probe(
                    DeploymentExecutionRequest(
                        target: target,
                        method: method,
                        host: host,
                        user: user,
                        port: port,
                        privateKeyPath: keyPath,
                        installDirectory: directory
                    )
                )
                guard let self, self.probeRequestID == requestID else { return }
                self.probe = result
                self.isProbing = false
                if result.hasManagedInstallation {
                    guard result.canAdopt(method: self.deploymentMethod) else {
                        self.stage = .failed
                        self.planPresented = false
                        let detail = result.hasRecoverableCredentials
                            ? OasesLocalization.localized("检测到现有部署，但运行时文件不完整；请查看日志后使用修复功能。")
                            : OasesLocalization.localized("检测到现有部署，但管理凭据不完整；请查看日志后使用修复功能。")
                        self.deploymentError = detail
                        self.statusMessage = detail
                        return
                    }
                    guard self.automaticActivityEnabled else {
                        self.stage = .idle
                        self.planPresented = false
                        self.statusMessage = OasesLocalization.localized("检测到现有部署；此次运行已停用自动接管与后台巡检。")
                        return
                    }
                    self.adoptExistingDeployment(request: self.currentExecutionRequest, requestID: requestID, probe: result)
                    return
                }
                self.stage = .ready
                self.statusMessage = OasesLocalization.localizedFormat("环境检测完成：%@", result.dependencySummary(for: self.deploymentMethod))
                self.preparePlan()
            } catch {
                guard let self, self.probeRequestID == requestID else { return }
                self.isProbing = false
                if self.isSSHHostKeyConfirmationRequired(error) {
                    self.stage = .failed
                    self.probeError = nil
                    self.statusMessage = OasesLocalization.localized("请先确认 SSH 主机指纹，然后重新检测目标环境")
                    return
                }
                self.stage = .failed
                self.probeError = error.localizedDescription
                self.statusMessage = OasesLocalization.localized("环境检测失败，请检查目标连接信息")
            }
        }
    }

    func confirmPendingSSHHostKey() {
        guard let confirmation = pendingSSHHostKeyConfirmation else { return }
        do {
            try SSHConnectionService.confirmHostKey(confirmation)
            let retryAction = pendingSSHHostKeyRetryAction
            pendingSSHHostKeyConfirmation = nil
            pendingSSHHostKeyRetryAction = nil
            deploymentError = nil
            statusMessage = OasesLocalization.localized("SSH 主机指纹已记录；正在继续之前的操作")

            switch retryAction {
            case .probe:
                probeTarget()
            case .deploymentPlan:
                stage = .ready
                planPresented = true
            case .reconnect:
                resumeServices()
            case nil:
                statusMessage = OasesLocalization.localized("SSH 主机指纹已记录；请重新执行之前的操作")
            }
        } catch {
            deploymentError = error.localizedDescription
            statusMessage = OasesLocalization.localized("SSH 主机指纹确认未完成；请重新核验")
        }
    }

    func rejectPendingSSHHostKey() {
        guard pendingSSHHostKeyConfirmation != nil else { return }
        pendingSSHHostKeyConfirmation = nil
        pendingSSHHostKeyRetryAction = nil
        statusMessage = OasesLocalization.localized("已取消 SSH 主机指纹确认；连接未开始")
    }

    func acknowledgePlan() {
        guard !isDeploying else { return }
        if let preflightFailure = preflightFailureMessage {
            planPresented = false
            deploymentError = preflightFailure
            stage = .failed
            statusMessage = preflightFailure
            return
        }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            deploymentError = OasesLocalization.localized("SSH 私钥无法读取，请重新选择私钥文件")
            stage = .failed
            return
        }

        let request = DeploymentExecutionRequest(
            target: targetKind,
            method: deploymentMethod,
            host: remoteHost,
            user: remoteUser.isEmpty ? "root" : remoteUser,
            port: remotePort,
            privateKeyPath: privateKeyPath,
            installDirectory: installDirectory
        )
        activeOperationRequest = request

        planPresented = false
        isDeploying = true
        isDeploymentPaused = false
        isControllingDeployment = false
        isCancellingDeployment = false
        removalError = nil
        deploymentError = nil
        invalidateDeploymentLog()
        stage = .installing
        statusMessage = targetKind == .local ? OasesLocalization.localized("正在本机终端部署…") : OasesLocalization.localized("正在通过 SSH 部署到远程目标…")
        steps = steps.enumerated().map { index, step in
            var updated = step
            updated.status = index == 0 ? .current : .pending
            return updated
        }

        let operationID = UUID()
        let controlToken = UUID().uuidString.lowercased()
        deploymentOperationID = operationID
        deploymentControlToken = controlToken
        deploymentTask?.cancel()
        deploymentTask = Task { [weak self] in
            defer {
                if self?.deploymentOperationID == operationID {
                    self?.activeOperationRequest = nil
                }
            }
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(
                        for: request,
                        retryAction: .deploymentPlan
                    )
                }
                guard let services = self?.services else { return }
                let result = try await services.execute(request, controlToken)
                guard let self,
                      self.deploymentOperationID == operationID,
                      !self.isCancellingDeployment,
                      !Task.isCancelled
                else { return }

                if self.activeProfileID == nil {
                    self.activeProfileID = UUID()
                }
                try self.saveActiveCredentials(
                    managementKey: result.cpaManagementKey,
                    adminKey: result.cpampAdminKey
                )
                // A native install lays out the gateway topology (engine on 18316, gateway on
                // 8317/18320): the tunnel and the health checks below must use it.
                self.topology = Self.topologyAfterInstall(method: request.method)
                self.packEngineKeyFingerprint = result.packEngineKeyFingerprint
                self.profileIsInstalled = true
                self.wantsRunning = true
                self.setWantsRunningPreference(true)
                self.stage = .connecting
                self.statusMessage = OasesLocalization.localized("安装完成，正在验证服务连接…")
                self.saveProfile()

                if request.target == .ssh {
                    try await self.startTunnel(for: request)
                }
                try await services.lifecycle(endpoints).waitForConnectionHealth(
                    cpaManagementKey: result.cpaManagementKey
                )

                guard self.deploymentOperationID == operationID,
                      !self.isCancellingDeployment,
                      !Task.isCancelled
                else { return }
                self.isDeploying = false
                self.isDeploymentPaused = false
                self.deploymentControlToken = nil
                self.deploymentTask = nil
                self.stage = .attached
                self.setHealthState(.healthy)
                self.lastHealthCheckAt = Date()
                self.statusMessage = request.target == .local
                    ? OasesLocalization.localized("部署完成，服务已绑定到本机回环地址")
                    : OasesLocalization.localized("部署完成，SSH 隧道已建立并连接到 App")
                self.steps = self.steps.map { step in
                    var updated = step
                    updated.status = .complete
                    return updated
                }
                self.saveProfile()
                self.startHealthMonitor()
            } catch {
                guard let self,
                      self.deploymentOperationID == operationID,
                      !self.isCancellingDeployment,
                      !Task.isCancelled
                else { return }
                self.stopTunnel()
                self.stopHealthMonitor()
                self.resetHealthState()
                self.isDeploying = false
                self.isDeploymentPaused = false
                self.deploymentControlToken = nil
                self.deploymentTask = nil
                if self.isSSHHostKeyConfirmationRequired(error) {
                    self.stage = .ready
                    self.planPresented = true
                    self.deploymentError = nil
                    self.statusMessage = OasesLocalization.localized("请先确认 SSH 主机指纹，然后重新确认部署")
                    return
                }
                self.stage = .failed
                self.deploymentError = error.localizedDescription
                self.statusMessage = OasesLocalization.localized("部署失败，请查看目标目录中的日志")
                self.refreshDeploymentLog()
            }
        }
    }

    var canPauseDeployment: Bool {
        isDeploying &&
        stage == .installing &&
        deploymentControlToken != nil &&
        !isDeploymentPaused &&
        !isControllingDeployment &&
        !isCancellingDeployment
    }

    var canResumeDeployment: Bool {
        isDeploying &&
        stage == .installing &&
        deploymentControlToken != nil &&
        isDeploymentPaused &&
        !isControllingDeployment &&
        !isCancellingDeployment
    }

    var canCancelDeployment: Bool {
        isDeploying &&
        (deploymentControlToken != nil || profileIsInstalled) &&
        !isCancellingDeployment
    }

    var canRemoveDeployment: Bool {
        !isDeploying &&
        !isMaintaining &&
        !isRemovingDeployment &&
        (profileIsInstalled || probe?.hasManagedRoot == true || stage == .cancelled || stage == .failed)
    }

    func pauseDeployment() {
        performDeploymentControl(.pause)
    }

    func resumeDeployment() {
        performDeploymentControl(.resume)
    }

    private func performDeploymentControl(_ action: DeploymentControlAction) {
        let canPerformAction = action == .pause ? canPauseDeployment : canResumeDeployment
        guard canPerformAction, let controlToken = deploymentControlToken else { return }

        let request = currentExecutionRequest
        let operationID = deploymentOperationID
        isControllingDeployment = true
        deploymentError = nil

        Task { [weak self] in
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                try await DeploymentControlService().perform(
                    action: action,
                    request: request,
                    controlToken: controlToken
                )
                guard let self,
                      self.deploymentOperationID == operationID,
                      self.isDeploying,
                      !self.isCancellingDeployment
                else { return }
                self.isControllingDeployment = false
                self.isDeploymentPaused = action == .pause
                self.statusMessage = action == .pause
                    ? OasesLocalization.localized("部署已暂停；可随时继续或取消")
                    : OasesLocalization.localized("部署已继续")
            } catch {
                guard let self, self.deploymentOperationID == operationID else { return }
                self.isControllingDeployment = false
                self.deploymentError = error.localizedDescription
                self.statusMessage = action == .pause
                    ? OasesLocalization.localized("暂停部署失败，部署仍在继续")
                    : OasesLocalization.localized("继续部署失败，请重试或取消部署")
            }
        }
    }

    func cancelDeployment(removeFilesAfterCancellation: Bool = false) {
        guard canCancelDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            deploymentError = OasesLocalization.localized("SSH 私钥无法读取，无法安全取消远程部署")
            return
        }

        let request = currentExecutionRequest
        let controlToken = deploymentControlToken
        let operationID = deploymentOperationID
        isCancellingDeployment = true
        isControllingDeployment = true
        deploymentError = nil
        statusMessage = removeFilesAfterCancellation
            ? OasesLocalization.localized("正在取消部署并删除全部部署文件…")
            : OasesLocalization.localized("正在安全取消部署…")

        Task { [weak self] in
            guard let self else { return }
            var cancellationCompleted = false
            do {
                try await self.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                if let controlToken, self.stage == .installing {
                    do {
                        try await DeploymentControlService().perform(
                            action: .cancel,
                            request: request,
                            controlToken: controlToken
                        )
                        cancellationCompleted = true
                    } catch {
                        // The installer can finish between the click and the
                        // control request. If it already became an installed
                        // target, fall through to the normal runtime stop.
                        guard self.profileIsInstalled else { throw error }
                    }
                }

                if !cancellationCompleted, self.profileIsInstalled {
                    try await services.lifecycle(endpoints).stop(
                        target: request.target,
                        method: request.method,
                        host: request.host,
                        user: request.user,
                        port: request.port,
                        privateKeyPath: request.privateKeyPath,
                        installDirectory: request.installDirectory
                    )
                    cancellationCompleted = true
                }

                guard cancellationCompleted else {
                    throw DeploymentExecutionError.commandFailed(
                        OasesLocalization.localized("未找到可验证的活动部署进程，未执行取消操作。")
                    )
                }

                self.deploymentTask?.cancel()
                self.deploymentTask = nil
                self.deploymentOperationID = UUID()
                self.deploymentControlToken = nil
                self.stopTunnel()
                self.stopHealthMonitor()

                if removeFilesAfterCancellation {
                    do {
                        try await DeploymentRemovalService().uninstall(request: request)
                        self.finishFullRemoval()
                    } catch {
                        self.finishCancelledDeployment()
                        self.removalError = error.localizedDescription
                        self.deploymentError = error.localizedDescription
                        self.statusMessage = OasesLocalization.localized("部署已取消，但彻底删除未完成；文件保持原状")
                    }
                } else {
                    self.finishCancelledDeployment()
                }
            } catch {
                guard self.deploymentOperationID == operationID else { return }
                self.isCancellingDeployment = false
                self.isControllingDeployment = false
                self.deploymentError = error.localizedDescription
                self.statusMessage = OasesLocalization.localized("取消部署失败；部署进程未被静默终止")
            }
        }
    }

    func removeDeployment() {
        guard canRemoveDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            removalError = OasesLocalization.localized("SSH 私钥无法读取，无法安全删除远程部署")
            return
        }

        let request = currentExecutionRequest
        activeOperationRequest = request
        stopHealthMonitor()
        wantsRunning = false
        setWantsRunningPreference(false)
        isRemovingDeployment = true
        removalError = nil
        deploymentError = nil
        statusMessage = OasesLocalization.localized("正在停止服务并彻底删除部署目录…")

        Task { [weak self] in
            defer { self?.activeOperationRequest = nil }
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                try await DeploymentRemovalService().uninstall(request: request)
                self?.finishFullRemoval()
            } catch {
                guard let self else { return }
                self.isRemovingDeployment = false
                self.stage = .failed
                self.removalError = error.localizedDescription
                self.deploymentError = error.localizedDescription
                self.statusMessage = OasesLocalization.localized("彻底删除未完成；未通过安全校验的目录不会被删除")
            }
        }
    }

    private func finishCancelledDeployment() {
        activeOperationRequest = nil
        isDeploying = false
        isDeploymentPaused = false
        isControllingDeployment = false
        isCancellingDeployment = false
        wantsRunning = false
        setWantsRunningPreference(false)
        stage = .cancelled
        resetHealthState()
        statusMessage = profileIsInstalled
            ? OasesLocalization.localized("部署连接已取消；服务已停止，部署文件和凭据已保留")
            : OasesLocalization.localized("部署已取消；已生成的文件保留，可重试或彻底删除")
        saveProfile()
        refreshDeploymentLog()
    }

    private func finishFullRemoval() {
        activeOperationRequest = nil
        let removedProfileID = activeProfileID
        stopTunnel()
        stopHealthMonitor()
        deleteActiveCredentials()
        if let removedProfileID {
            DeploymentProfileStore.remove(removedProfileID)
        }

        deploymentTask?.cancel()
        deploymentTask = nil
        deploymentOperationID = UUID()
        deploymentControlToken = nil
        profileIsInstalled = false
        isDeploying = false
        isDeploymentPaused = false
        isControllingDeployment = false
        isCancellingDeployment = false
        isRemovingDeployment = false
        wantsRunning = false
        stage = .idle
        planPresented = false
        removalError = nil
        deploymentError = nil
        resetHealthState()
        invalidateProbe()
        invalidateDeploymentLog()
        savedProfiles = DeploymentProfileStore.loadAll()
        activeProfileID = nil

        if let nextProfileID = savedProfiles.first?.id {
            selectSavedProfile(nextProfileID)
            statusMessage = OasesLocalization.localized("部署目录、服务、凭据与目标记录已彻底删除")
        } else {
            beginNewTarget()
            statusMessage = OasesLocalization.localized("部署目录、服务、凭据与目标记录已彻底删除；可以重新开始")
        }
    }

    func openPanel() {
        guard let url = URL(string: localPanelURL), localPanelURL.hasPrefix("http") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshDeploymentLog() {
        guard !isLoadingDeploymentLog else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
        deploymentLogError = OasesLocalization.localized("SSH 私钥无法读取，暂时无法读取远程日志。")
            return
        }

        let request = currentExecutionRequest
        let requestID = UUID()
        logRequestID = requestID
        isLoadingDeploymentLog = true
        deploymentLogError = nil

        Task { [weak self] in
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                let snapshot = try await DeploymentLogService().read(request: request)
                guard let self, self.logRequestID == requestID else { return }
                self.deploymentLog = snapshot.text
                self.deploymentLogSource = snapshot.source
                self.isLoadingDeploymentLog = false
            } catch {
                guard let self, self.logRequestID == requestID else { return }
                self.isLoadingDeploymentLog = false
                self.deploymentLogError = error.localizedDescription
            }
        }
    }

    func cleanupFailedDeployment() {
        guard !isDeploying, !profileIsInstalled else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
        deploymentError = OasesLocalization.localized("SSH 私钥无法读取，无法清理远程失败部署")
            stage = .failed
            return
        }

        let request = currentExecutionRequest
        let backupName = "failed-\(Int(Date().timeIntervalSince1970))-\(String(UUID().uuidString.prefix(8)).lowercased())"
        activeOperationRequest = request
        isDeploying = true
        deploymentError = nil
        stage = .installing
        statusMessage = OasesLocalization.localized("正在停止并备份失败部署…")

        Task { [weak self] in
            defer { self?.activeOperationRequest = nil }
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                let result = try await DeploymentRecoveryService().cleanupFailedDeployment(
                    request: request,
                    backupName: backupName
                )
                guard let self else { return }
                self.isDeploying = false
                self.profileIsInstalled = false
                self.wantsRunning = true
                self.setWantsRunningPreference(true)
                self.invalidateProbe()
                self.stage = .idle
                self.statusMessage = OasesLocalization.localizedFormat("失败部署已备份到目标目录的 backups/%@，现在可以重新检测并重试", result.backupName)
                self.deploymentLogSource = OasesLocalization.localizedFormat("失败部署已备份；原日志保留在 backups/%@", result.backupName)
                self.deploymentLogError = nil
                self.saveProfile()
            } catch {
                self?.isDeploying = false
                self?.stage = .failed
                self?.deploymentError = error.localizedDescription
                self?.statusMessage = OasesLocalization.localized("清理失败部署未完成；目标文件未被移除")
            }
        }
    }

    func upgradeDeployment() {
        performMaintenance(.upgrade)
    }

    func rollbackDeployment() {
        performMaintenance(.rollback)
    }

    func refreshLatestMaintenanceBackup() {
        guard profileIsInstalled, !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() { return }

        let request = currentExecutionRequest
        let requestID = UUID()
        maintenanceRequestID = requestID

        Task { [weak self] in
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                let backup = try await DeploymentMaintenanceService().latestBackup(request: request)
                guard let self, self.maintenanceRequestID == requestID else { return }
                self.latestMaintenanceBackup = backup
            } catch {
                guard let self, self.maintenanceRequestID == requestID else { return }
                self.latestMaintenanceBackup = nil
            }
        }
    }

    private enum MaintenanceAction: Equatable {
        case upgrade
        case rollback

        var title: String {
            switch self {
            case .upgrade: OasesLocalization.localized("升级")
            case .rollback: OasesLocalization.localized("回滚")
            }
        }
    }

    private func performMaintenance(_ action: MaintenanceAction) {
        guard profileIsInstalled, !isDeploying, !isMaintaining else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            maintenanceError = OasesLocalization.localized("SSH 私钥无法读取，请重新导入后再执行维护操作")
            stage = .failed
            return
        }

        let request = currentExecutionRequest
        activeOperationRequest = request
        // What a refused downgrade restores: it stopped and changed nothing on the target.
        let stageBefore = stage
        let healthBefore = healthState
        let healthErrorBefore = healthError
        let monitorWasRunning = healthMonitorTask != nil
        stopHealthMonitor()
        isMaintaining = true
        maintenanceError = nil
        maintenanceMessage = nil
        deploymentError = nil
        stage = .installing
        statusMessage = action == .upgrade ? OasesLocalization.localized("正在下载并切换到本应用固定的运行时版本…") : OasesLocalization.localized("正在恢复上一版运行时…")

        Task { [weak self] in
            defer { self?.activeOperationRequest = nil }
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                guard let services = self?.services else { return }
                let result: DeploymentMaintenanceResult
                switch action {
                case .upgrade:
                    result = try await services.upgrade(request)
                case .rollback:
                    result = try await services.rollback(request)
                }

                guard let self else { return }
                // An upgrade of a 0.1.x deployment ends in the gateway topology, a rollback of
                // it back in the legacy one: the tunnel and the health checks follow.
                let previousTopology = self.topology
                self.applyMaintenanceResult(result)
                if case .restart = Self.tunnelAction(previous: previousTopology, result: result.topology, target: request.target) {
                    self.stopTunnel()
                }
                if request.target == .ssh {
                    try await self.startTunnel(for: request)
                }
                let managementKey = self.managementKey
                try await services.lifecycle(endpoints).waitForConnectionHealth(
                    cpaManagementKey: managementKey
                )
                self.isMaintaining = false
                self.stage = .attached
                self.setHealthState(.healthy)
                self.lastHealthCheckAt = Date()
                self.statusMessage = result.detail
                self.maintenanceMessage = result.detail
                self.latestMaintenanceBackup = result.backupName
                self.saveProfile()
                self.startHealthMonitor()
            } catch DeploymentExecutionError.downgradeRefused(let component, let installed, let target) {
                // Exit 22 comes before anything is stopped or written: not a failed run. Stage
                // and health stay as they were; no degraded state, notification or log fetch.
                guard let self else { return }
                let refusal = DeploymentExecutionError.downgradeRefused(component: component, installed: installed, target: target)
                self.isMaintaining = false
                self.stage = stageBefore
                self.healthState = healthBefore
                self.healthError = healthErrorBefore
                self.maintenanceError = refusal.localizedDescription
                self.statusMessage = refusal.localizedDescription
                if monitorWasRunning { self.startHealthMonitor() }
            } catch {
                guard let self else { return }
                self.isMaintaining = false
                self.stage = .failed
                self.setHealthState(.degraded, error: error.localizedDescription)
                self.maintenanceError = error.localizedDescription
                if self.isSSHHostKeyConfirmationRequired(error) {
                    self.statusMessage = OasesLocalization.localized("请先确认 SSH 主机指纹，然后重新执行维护操作")
                    return
                }
                self.statusMessage = OasesLocalization.localizedFormat("%@失败；App 已尝试恢复原运行时，请查看目标日志", action.title)
                self.refreshDeploymentLog()
                self.startHealthMonitor()
            }
        }
    }

    var hasInstalledDeployment: Bool { profileIsInstalled }

    enum TunnelAction: Equatable {
        case none
        /// Stop the tunnel and open it again with the ports of this topology.
        case restart(DeploymentTopology)
    }

    /// After a maintenance run: an SSH target whose topology changed needs the tunnel of the
    /// new topology (otherwise 18316 and 18320 stay unreachable until the user reconnects).
    nonisolated static func tunnelAction(
        previous: DeploymentTopology,
        result: DeploymentTopology,
        target: DeploymentTargetKind
    ) -> TunnelAction {
        guard target == .ssh, previous != result else { return .none }
        return .restart(result)
    }

    /// Takes the topology (and the internal key's fingerprint) a maintenance run reports and
    /// saves the profile when they changed.
    private func applyMaintenanceResult(_ result: DeploymentMaintenanceResult) {
        var changed = false
        if result.topology != topology {
            topology = result.topology
            changed = true
        }
        if let fingerprint = result.packEngineKeyFingerprint, fingerprint != packEngineKeyFingerprint {
            packEngineKeyFingerprint = fingerprint
            changed = true
        }
        if changed { saveProfile() }
    }

    func stopServices() {
        guard profileIsInstalled, !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            deploymentError = OasesLocalization.localized("SSH 私钥无法读取，请重新导入后再停止服务")
            stage = .failed
            return
        }
        stopHealthMonitor()
        wantsRunning = false
        setWantsRunningPreference(false)
        isDeploying = true
        statusMessage = OasesLocalization.localized("正在停止目标环境服务…")
        let target = targetKind
        let method = deploymentMethod
        let host = remoteHost
        let user = remoteUser
        let port = remotePort
        let keyPath = privateKeyPath
        let root = installDirectory
        let request = DeploymentExecutionRequest(
            target: target,
            method: method,
            host: host,
            user: user.isEmpty ? "root" : user,
            port: port,
            privateKeyPath: keyPath,
            installDirectory: root
        )
        activeOperationRequest = request

        let lifecycle = services.lifecycle(endpoints)
        Task { [weak self] in
            defer { self?.activeOperationRequest = nil }
            do {
                if target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                try await lifecycle.stop(
                    target: target,
                    method: method,
                    host: host,
                    user: user,
                    port: port,
                    privateKeyPath: keyPath,
                    installDirectory: root
                )
                self?.stopTunnel()
                self?.isDeploying = false
                self?.stage = .idle
                self?.resetHealthState()
                self?.statusMessage = OasesLocalization.localized("服务已停止；部署文件和凭据已保留")
        } catch {
                if let self, self.isSSHHostKeyConfirmationRequired(error) {
                    self.stopTunnel()
                    self.isDeploying = false
                    self.stage = .failed
                    self.setHealthState(.degraded, error: error.localizedDescription)
                    self.deploymentError = error.localizedDescription
                    self.statusMessage = OasesLocalization.localized("请先确认 SSH 主机指纹，然后重新停止服务")
                    return
                }
                self?.stopTunnel()
                self?.isDeploying = false
                self?.stage = .failed
                self?.setHealthState(.degraded, error: error.localizedDescription)
                self?.deploymentError = error.localizedDescription
                self?.statusMessage = OasesLocalization.localized("停止服务失败")
                self?.refreshDeploymentLog()
            }
        }
    }

    func forgetCurrentDeployment() {
        guard profileIsInstalled, !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            deploymentError = OasesLocalization.localized("SSH 私钥无法读取，无法安全停止并解除远程目标绑定")
            stage = .failed
            return
        }

        let request = currentExecutionRequest
        let shouldStop = stage == .attached || wantsRunning
        activeOperationRequest = request
        stopHealthMonitor()
        wantsRunning = false
        setWantsRunningPreference(false)
        isDeploying = true
        deploymentError = nil
        statusMessage = shouldStop ? OasesLocalization.localized("正在停止服务并解除当前目标绑定…") : OasesLocalization.localized("正在解除当前目标绑定…")

        let lifecycle = services.lifecycle(endpoints)
        Task { [weak self] in
            defer { self?.activeOperationRequest = nil }
            do {
                if request.target == .ssh {
                    guard let store = self else { return }
                    try await store.ensureSSHHostKeyTrust(for: request, retryAction: nil)
                }
                if shouldStop {
                    try await lifecycle.stop(
                        target: request.target,
                        method: request.method,
                        host: request.host,
                        user: request.user,
                        port: request.port,
                        privateKeyPath: request.privateKeyPath,
                        installDirectory: request.installDirectory
                    )
                }

                self?.deleteActiveCredentials()

                guard let self else { return }
                self.stopTunnel()
                self.profileIsInstalled = false
                self.managementKey = ""
                self.cpampAdminKey = ""
                self.isDeploying = false
                self.stage = .idle
                self.resetHealthState()
                self.planPresented = false
                self.steps = DeploymentPlanFactory.makeSteps(target: self.targetKind, method: self.deploymentMethod)
                self.invalidateProbe()
                self.invalidateDeploymentLog()
                self.deploymentError = nil
                self.statusMessage = OasesLocalization.localized("已解除当前目标绑定；目标目录保留，可重新检测或切换到另一个目标")
                self.setWantsRunningPreference(false)
                if let activeProfileID = self.activeProfileID {
                    DeploymentProfileStore.remove(activeProfileID)
                }
                self.savedProfiles = DeploymentProfileStore.loadAll()
                let nextProfileID = self.savedProfiles.first?.id
                self.activeProfileID = nil
                if let nextProfileID {
                    self.selectSavedProfile(nextProfileID)
                } else {
                    self.beginNewTarget()
                }
            } catch {
                self?.isDeploying = false
                self?.stage = .failed
                self?.deploymentError = error.localizedDescription
                self?.statusMessage = OasesLocalization.localized("解除目标绑定未完成；服务和凭据状态未被静默清除")
            }
        }
    }

    func resumeServices() {
        guard profileIsInstalled, !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        if managementKey.isEmpty {
            do {
                try loadActiveCredentials()
            } catch {
                deploymentError = OasesLocalization.localizedFormat("无法读取已保存的钥匙串凭据：%@", error.localizedDescription)
                statusMessage = OasesLocalization.localized("未能读取已保存凭据；请在系统提示中授权，或重新配置目标")
                stage = .failed
                return
            }
        }
        guard !managementKey.isEmpty else {
            deploymentError = OasesLocalization.localized("没有找到该目标的 CLIProxyAPI 管理密钥。")
            statusMessage = OasesLocalization.localized("未找到已保存凭据；请重新部署或重新连接该目标")
            stage = .failed
            return
        }
        if targetKind == .ssh, !ensureSSHKeyMaterial() {
            deploymentError = OasesLocalization.localized("SSH 私钥无法读取，请重新选择私钥文件")
            stage = .failed
            return
        }
        stopHealthMonitor()
        wantsRunning = true
        setWantsRunningPreference(true)
        stage = .connecting
        statusMessage = OasesLocalization.localized("正在重新连接目标环境…")
        Task { [weak self] in
            await self?.restoreConnection()
        }
    }

    private func startTunnel(for request: DeploymentExecutionRequest) async throws {
        try await ensureSSHHostKeyTrust(
            for: request,
            retryAction: .reconnect
        )
        stopTunnel()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let arguments = try SSHConnectionService.tunnelArguments(
            host: request.host,
            user: request.user,
            port: request.port,
            privateKeyPath: request.privateKeyPath,
            topology: topology
        )
        try SSHConnectionService.verifyKnownHostsFileForConnection()
        process.arguments = arguments
        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = nullDevice
        process.standardError = nullDevice
        try process.run()
        tunnelProcessOwner.attach(process)
        tunnelAttached = false

        try await Task.sleep(nanoseconds: 500_000_000)
        guard process.isRunning else {
            stopTunnel()
            throw DeploymentExecutionError.commandFailed(OasesLocalization.localized("SSH 隧道未能建立，请检查远程端口和私钥权限。"))
        }

        tunnelAttached = true
    }

    private func stopTunnel() {
        tunnelProcessOwner.stop()
        tunnelAttached = false
    }

    func importSSHKey(from url: URL) {
        guard activeOperationRequest == nil else { return }
        do {
            if activeProfileID == nil {
                activeProfileID = UUID()
                saveProfile()
            }
            privateKeyPath = try SSHKeyMaterialStore.save(from: url, profileID: activeProfileID)
            deploymentError = nil
            statusMessage = OasesLocalization.localized("SSH 私钥已按当前目标保存到 Keychain，可用于连接检测和部署")
        } catch {
            deploymentError = error.localizedDescription
            statusMessage = OasesLocalization.localized("SSH 私钥导入失败")
        }
    }

    private func ensureSSHKeyMaterial() -> Bool {
        guard targetKind == .ssh else { return true }
        if let materializedPath = try? SSHKeyMaterialStore.materialize(
            profileID: activeProfileID,
            allowLegacyFallback: profileIsInstalled
        ) {
            privateKeyPath = materializedPath
            return true
        }
        return FileManager.default.isReadableFile(atPath: privateKeyPath)
    }

    private func ensureSSHHostKeyTrust(
        for request: DeploymentExecutionRequest,
        retryAction: SSHHostKeyRetryAction?
    ) async throws {
        guard request.target == .ssh else { return }
        if let pendingSSHHostKeyConfirmation {
            if pendingSSHHostKeyRetryAction == nil {
                pendingSSHHostKeyRetryAction = retryAction
            }
            throw SSHConnectionError.hostKeyConfirmationRequired(pendingSSHHostKeyConfirmation)
        }

        let host = request.host
        let port = request.port
        let inspection = try await Task.detached(priority: .userInitiated) {
            try SSHConnectionService.inspectHostKey(host: host, port: port)
        }.value

        switch inspection {
        case .trusted:
            return
        case .needsConfirmation(let confirmation):
            pendingSSHHostKeyConfirmation = confirmation
            pendingSSHHostKeyRetryAction = retryAction
            throw SSHConnectionError.hostKeyConfirmationRequired(confirmation)
        }
    }

    private func isSSHHostKeyConfirmationRequired(_ error: Error) -> Bool {
        if let sshError = error as? SSHConnectionError,
           case .hostKeyConfirmationRequired = sshError {
            return true
        }
        return false
    }

    private func bindPersistence() {
        $targetKind.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $deploymentMethod.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $remoteHost.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $remoteUser.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $remotePort.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $privateKeyPath.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
        $installDirectory.dropFirst().sink { [weak self] _ in self?.configurationDidChange() }.store(in: &cancellables)
    }

    private var preflightFailureMessage: String? {
        guard let probe else {
            return OasesLocalization.localized("请先连接并检测目标环境；部署前置检查不会执行安装或启动命令。")
        }
        guard probe.testedInstallDirectory == installDirectory else {
            return OasesLocalization.localized("安装目录已变化，请重新连接并检测环境。")
        }
        let missing = probe.missingDependencies(for: deploymentMethod)
        guard missing.isEmpty else {
            return OasesLocalization.localizedFormat("当前部署方式无法继续：缺少%@。", missing.joined(separator: "、"))
        }
        return nil
    }

    private func enforceOperationSnapshot() {
        guard !isApplyingProfileConfiguration,
              let activeOperationRequest else { return }
        restoreConfiguration(from: activeOperationRequest)
    }

    private func configurationDidChange() {
        guard !isApplyingProfileConfiguration else { return }
        if let activeOperationRequest {
            restoreConfiguration(from: activeOperationRequest)
            return
        }
        pendingSSHHostKeyConfirmation = nil
        pendingSSHHostKeyRetryAction = nil
        invalidateProbe()
        invalidateDeploymentLog()
        saveProfile()
    }

    private func restoreConfiguration(from request: DeploymentExecutionRequest) {
        isApplyingProfileConfiguration = true
        defer { isApplyingProfileConfiguration = false }
        targetKind = request.target
        deploymentMethod = request.method
        remoteHost = request.host
        remoteUser = request.user
        remotePort = request.port
        privateKeyPath = request.privateKeyPath
        installDirectory = request.installDirectory
    }

    private func invalidateProbe() {
        probeRequestID = UUID()
        probe = nil
        probeError = nil
        isProbing = false
    }

    private var currentExecutionRequest: DeploymentExecutionRequest {
        DeploymentExecutionRequest(
            target: targetKind,
            method: deploymentMethod,
            host: remoteHost,
            user: remoteUser.isEmpty ? "root" : remoteUser,
            port: remotePort,
            privateKeyPath: privateKeyPath,
            installDirectory: installDirectory
        )
    }

    private func invalidateDeploymentLog() {
        logRequestID = UUID()
        deploymentLog = ""
        deploymentLogSource = ""
        deploymentLogError = nil
        isLoadingDeploymentLog = false
    }

    private func invalidateMaintenanceState() {
        maintenanceRequestID = UUID()
        isMaintaining = false
        maintenanceError = nil
        maintenanceMessage = nil
        latestMaintenanceBackup = nil
    }

    private func saveProfile() {
        let id = activeProfileID ?? UUID()
        activeProfileID = id
        let profile = DeploymentProfile(
            id: id,
            targetKind: targetKind,
            deploymentMethod: deploymentMethod,
            remoteHost: remoteHost,
            remoteUser: remoteUser,
            remotePort: remotePort,
            privateKeyPath: privateKeyPath,
            installDirectory: installDirectory,
            isInstalled: profileIsInstalled,
            lastAttachedAt: profileIsInstalled ? Date() : nil,
            topology: topology,
            packEngineKeyFingerprint: packEngineKeyFingerprint
        )
        let canonical = DeploymentProfileStore.save(profile)
        if canonical.id != profile.id {
            activeProfileID = canonical.id
            topology = canonical.topology
            packEngineKeyFingerprint = canonical.packEngineKeyFingerprint
            profileIsInstalled = canonical.isInstalled
            wantsRunning = loadWantsRunningPreference()
        }
        savedProfiles = DeploymentProfileStore.loadAll()
    }

    /// The layout a fresh install of `method` creates: native deploys the gateway, Docker only
    /// the upstream engine and CPA Manager Plus.
    nonisolated static func topologyAfterInstall(method: DeploymentMethod) -> DeploymentTopology {
        method == .native ? .gateway : .legacy
    }

#if DEBUG
    /// Adopts the deployment the last probe found, as the automatic path would (tests run with
    /// automatic activity off and inject fake services).
    func adoptProbedDeploymentForTesting() {
        guard let probe else { return }
        adoptExistingDeployment(request: currentExecutionRequest, requestID: probeRequestID, probe: probe)
    }
#endif

    /// - Parameter probe: what the probe found; its topology decides the tunnel ports and the
    ///   health checks (a 0.1.x deployment stays legacy, a gateway deployment gets 18316/18320).
    private func adoptExistingDeployment(request: DeploymentExecutionRequest, requestID: UUID, probe: DeploymentProbe) {
        guard !isDeploying else { return }
        activeOperationRequest = request
        isDeploying = true
        deploymentError = nil
        planPresented = false
        stage = .connecting
        statusMessage = OasesLocalization.localized("发现现有 Oases CPA 部署，正在自动接管并恢复服务…")

        Task { [weak self] in
            guard let self else { return }
            defer { self.activeOperationRequest = nil }
            do {
                try await self.ensureSSHHostKeyTrust(for: request, retryAction: .probe)
                let credentials = try await self.services.readExistingCredentials(request)
                guard self.probeRequestID == requestID else { return }
                self.topology = probe.topology
                self.packEngineKeyFingerprint = credentials.packEngineKeyFingerprint

                if request.target == .ssh {
                    try await self.startTunnel(for: request)
                }
                try await services.lifecycle(endpoints).ensureRunning(
                    target: request.target,
                    method: request.method,
                    host: request.host,
                    user: request.user,
                    port: request.port,
                    privateKeyPath: request.privateKeyPath,
                    installDirectory: request.installDirectory,
                    cpaManagementKey: credentials.cpaManagementKey
                )
                guard self.probeRequestID == requestID else {
                    self.stopTunnel()
                    return
                }

                if self.activeProfileID == nil {
                    self.activeProfileID = UUID()
                }
                try self.saveActiveCredentials(
                    managementKey: credentials.cpaManagementKey,
                    adminKey: credentials.cpampAdminKey
                )
                self.profileIsInstalled = true
                self.wantsRunning = true
                self.setWantsRunningPreference(true)
                self.isDeploying = false
                self.stage = .attached
                self.setHealthState(.healthy)
                self.lastHealthCheckAt = Date()
                self.deploymentError = nil
                self.steps = self.steps.map { step in
                    var updated = step
                    updated.status = .complete
                    return updated
                }
                self.saveProfile()
                self.statusMessage = request.target == .local
                    ? OasesLocalization.localized("已接管现有本机部署并恢复连接")
                    : OasesLocalization.localized("已接管现有远程部署并恢复 SSH 连接")
                self.startHealthMonitor()
            } catch {
                guard self.probeRequestID == requestID else { return }
                self.stopTunnel()
                self.isDeploying = false
                self.stage = .failed
                self.setHealthState(.degraded, error: error.localizedDescription)
                self.deploymentError = error.localizedDescription
                if self.isSSHHostKeyConfirmationRequired(error) {
                    self.statusMessage = OasesLocalization.localized("请先确认 SSH 主机指纹，然后重新接管目标")
                    return
                }
                self.statusMessage = OasesLocalization.localized("发现现有部署，但自动接管失败；部署文件未被修改。")
                self.refreshDeploymentLog()
            }
        }
    }

    private func loadActiveCredentials() throws {
        let managementAccount = credentialAccount("cpa-management-key")
        let adminAccount = credentialAccount("cpamp-admin-key")
        managementKey = try KeychainStore.load(account: managementAccount) ?? ""
        cpampAdminKey = try KeychainStore.load(account: adminAccount) ?? ""

        if profileIsInstalled && activeProfileID != nil && managementKey.isEmpty {
            managementKey = try KeychainStore.loadLegacy(account: managementAccount) ?? ""
            if managementKey.isEmpty {
                managementKey = try KeychainStore.loadLegacy(account: "cpa-management-key") ?? ""
            }
            if !managementKey.isEmpty {
                try KeychainStore.save(managementKey, account: managementAccount)
            }
        }
        if profileIsInstalled && activeProfileID != nil && cpampAdminKey.isEmpty {
            cpampAdminKey = try KeychainStore.loadLegacy(account: adminAccount) ?? ""
            if cpampAdminKey.isEmpty {
                cpampAdminKey = try KeychainStore.loadLegacy(account: "cpamp-admin-key") ?? ""
            }
            if !cpampAdminKey.isEmpty {
                try KeychainStore.save(cpampAdminKey, account: adminAccount)
            }
        }
        hasLoadedSavedCredentials = true
    }

    private func saveActiveCredentials(managementKey: String, adminKey: String) throws {
        self.managementKey = managementKey
        self.cpampAdminKey = adminKey
        hasLoadedSavedCredentials = true
        // Propagate Keychain write failures instead of `try?` so callers'
        // existing catch blocks can surface `deploymentError` to the user
        // rather than silently proceeding as if credentials were persisted.
        try KeychainStore.save(managementKey, account: credentialAccount("cpa-management-key"))
        try KeychainStore.save(adminKey, account: credentialAccount("cpamp-admin-key"))
    }

    private func deleteActiveCredentials() {
        try? KeychainStore.delete(account: credentialAccount("cpa-management-key"))
        try? KeychainStore.delete(account: credentialAccount("cpamp-admin-key"))
        try? SSHKeyMaterialStore.delete(profileID: activeProfileID)
        if savedProfiles.count <= 1 {
            try? KeychainStore.delete(account: "cpa-management-key")
            try? KeychainStore.delete(account: "cpamp-admin-key")
            try? SSHKeyMaterialStore.deleteLegacy()
        }
        clearLoadedCredentials()
    }

    private func clearLoadedCredentials() {
        managementKey = ""
        cpampAdminKey = ""
        hasLoadedSavedCredentials = false
    }

    private func credentialAccount(_ base: String) -> String {
        guard let activeProfileID else { return base }
        return "\(base)-\(activeProfileID.uuidString)"
    }

    private func wantsRunningPreferenceKey() -> String {
        guard let activeProfileID else { return "oases.cpa.runtime.wants-running" }
        return "oases.cpa.runtime.wants-running.\(activeProfileID.uuidString)"
    }

    private func loadWantsRunningPreference() -> Bool {
        if let value = DeploymentProfileStore.defaults.object(forKey: wantsRunningPreferenceKey()) as? Bool {
            return value
        }
        return DeploymentProfileStore.defaults.object(forKey: "oases.cpa.runtime.wants-running") as? Bool ?? true
    }

    private func setWantsRunningPreference(_ value: Bool) {
        DeploymentProfileStore.defaults.set(value, forKey: wantsRunningPreferenceKey())
        DeploymentProfileStore.defaults.set(value, forKey: "oases.cpa.runtime.wants-running")
    }

    private func resetHealthState() {
        healthState = .unknown
        lastHealthCheckAt = nil
        healthError = nil
        isAutoRecovering = false
        healthIssueNotificationSent = false
    }

    private func setHealthState(_ state: DeploymentHealthState, error: String? = nil) {
        healthState = state
        if let error {
            healthError = error
        } else if state == .healthy || state == .checking || state == .recovering {
            healthError = nil
        }

        let target = targetKind == .local
            ? OasesLocalization.localized("本机 Mac")
            : (remoteHost.isEmpty ? OasesLocalization.localized("远程 SSH / VPS") : remoteHost)
        if state == .degraded, healthNotificationsEnabled, !healthIssueNotificationSent {
            healthIssueNotificationSent = true
            let detail = error ?? HealthNotificationService.healthCheckFailedDetail(topology: topology)
            let notify = services.notifyDegraded
            Task {
                await notify(target, detail)
            }
        } else if state == .healthy {
            let shouldNotify = healthNotificationsEnabled && healthIssueNotificationSent
            healthIssueNotificationSent = false
            if shouldNotify {
                let topology = self.topology
                let notify = services.notifyRecovered
                Task {
                    await notify(target, topology)
                }
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        isAutoRecovering = false
    }

    private func startHealthMonitor() {
        guard automaticActivityEnabled, profileIsInstalled, wantsRunning else { return }
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performHealthCheck()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func performHealthCheck() async {
        guard profileIsInstalled, wantsRunning, !isDeploying, !isMaintaining, !isRemovingDeployment else { return }
        guard !managementKey.isEmpty else {
            setHealthState(.degraded, error: OasesLocalization.localized("缺少 CLIProxyAPI 管理密钥，无法进行后台健康检查。"))
            return
        }

        setHealthState(.checking)
        let request = currentExecutionRequest
        let managementKey = self.managementKey
        let isHealthy = await services.lifecycle(endpoints).checkConnectionHealth(
            cpaManagementKey: managementKey
        )
        guard !Task.isCancelled, profileIsInstalled, wantsRunning else { return }

        lastHealthCheckAt = Date()
        if isHealthy {
            setHealthState(.healthy)
            deploymentError = nil
            if stage == .failed {
                stage = .attached
                statusMessage = targetKind == .local ? OasesLocalization.localized("本机服务已恢复连接") : OasesLocalization.localized("SSH 隧道与远程服务已恢复连接")
            }
            return
        }

        setHealthState(.degraded, error: HealthNotificationService.healthCheckFailedDetail(topology: topology))
        await attemptAutomaticRecovery(for: request, managementKey: managementKey)
    }

    private func attemptAutomaticRecovery(
        for request: DeploymentExecutionRequest,
        managementKey: String
    ) async {
        guard profileIsInstalled,
              wantsRunning,
              !isDeploying,
              !isMaintaining,
              !isRemovingDeployment,
              !managementKey.isEmpty,
              !Task.isCancelled else { return }

        isAutoRecovering = true
        setHealthState(.recovering)
        stage = .connecting
        statusMessage = OasesLocalization.localized("检测到服务不可用，正在自动恢复…")
        defer { isAutoRecovering = false }

        do {
            if request.target == .ssh {
                try await startTunnel(for: request)
            }
            try await services.lifecycle(endpoints).ensureRunning(
                target: request.target,
                method: request.method,
                host: request.host,
                user: request.user,
                port: request.port,
                privateKeyPath: request.privateKeyPath,
                installDirectory: request.installDirectory,
                cpaManagementKey: managementKey
            )
            guard !Task.isCancelled, profileIsInstalled, wantsRunning else { return }

            stage = .attached
            setHealthState(.healthy)
            deploymentError = nil
            lastHealthCheckAt = Date()
            statusMessage = request.target == .local ? OasesLocalization.localized("本机服务已自动恢复") : OasesLocalization.localized("SSH 隧道与远程服务已自动恢复")
        } catch {
            guard !Task.isCancelled, profileIsInstalled, wantsRunning else { return }
            stopTunnel()
            stage = .failed
            setHealthState(.degraded, error: error.localizedDescription)
            deploymentError = error.localizedDescription
            statusMessage = OasesLocalization.localized("自动恢复失败；App 会继续重试，或可手动重新启动")
        }
    }

    /// Re-reads the target's layout before attaching (an upgrade from another copy of the app
    /// may have moved a legacy deployment to the gateway topology). Read-only and best effort:
    /// a failed probe keeps the saved topology.
    private func refreshTopologyFromProbe(for request: DeploymentExecutionRequest) async {
        if request.target == .ssh {
            guard (try? await ensureSSHHostKeyTrust(for: request, retryAction: .reconnect)) != nil else { return }
        }
        guard let probe = try? await services.probe(request), probe.hasManagedInstallation,
              probe.testedInstallDirectory == request.installDirectory,
              probe.topology != topology else { return }
        topology = probe.topology
        saveProfile()
    }

    private func restoreConnection() async {
        guard profileIsInstalled, wantsRunning else { return }
        let request = currentExecutionRequest
        let managementKey = self.managementKey
        setHealthState(.checking)
        await refreshTopologyFromProbe(for: request)
        guard profileIsInstalled, wantsRunning else { return }
        do {
            if request.target == .ssh {
                try await startTunnel(for: request)
            }
            guard !managementKey.isEmpty else {
                throw DeploymentExecutionError.missingResult
            }
            let runtime = services.lifecycle(endpoints)
            try await runtime.ensureRunning(
                target: request.target,
                method: request.method,
                host: request.host,
                user: request.user,
                port: request.port,
                privateKeyPath: request.privateKeyPath,
                installDirectory: request.installDirectory,
                cpaManagementKey: managementKey
            )
            guard !Task.isCancelled, profileIsInstalled, wantsRunning else {
                stopTunnel()
                return
            }
            stage = .attached
            setHealthState(.healthy)
            lastHealthCheckAt = Date()
        statusMessage = request.target == .local ? OasesLocalization.localized("已恢复本机服务连接") : OasesLocalization.localized("已恢复 SSH 隧道与远程服务连接")
            steps = steps.map { step in
                var updated = step
                updated.status = .complete
                return updated
            }
            startHealthMonitor()
        } catch {
            stopTunnel()
            guard profileIsInstalled, wantsRunning else { return }
            stage = .failed
            setHealthState(.degraded, error: error.localizedDescription)
            deploymentError = error.localizedDescription
        statusMessage = OasesLocalization.localized("上次部署存在，但当前服务未能自动恢复")
            refreshDeploymentLog()
            startHealthMonitor()
        }
    }
}

// MARK: - Gateway admin access

extension DeploymentStore: GatewayClientProviding {
    var gatewayAvailability: GatewayAvailability {
        guard stage == .attached, !managementKey.isEmpty else { return .notAttached }
        switch topology {
        case .legacy:
            return deploymentMethod == .docker ? .dockerUnsupported : .needsUpgrade
        case .gateway:
            return gatewayAuthLatch.allows(key: managementKey) ? .ready : .credentialsRejected
        }
    }

    func gatewayAdminClient() -> GatewayAdminClient? {
        guard gatewayAvailability == .ready, let baseURL = endpoints.gatewayAdminBaseURL else { return nil }
        return GatewayAdminClient(baseURL: baseURL, managementKey: managementKey)
    }

    func reportGatewayUnauthorized(rejectedKey: String) {
        // A late 401 for a key the user has already replaced must not latch the new key.
        guard !rejectedKey.isEmpty, rejectedKey == managementKey else { return }
        gatewayAuthLatch.reject(key: rejectedKey)
    }

    func retryGatewayAuthentication() {
        gatewayAuthLatch.clear()
    }
}
