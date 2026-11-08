import XCTest
@testable import OasesCPA

/// The welcome gate's decisions: launch routing, the welcome phases, the 连接与部署 state and
/// the language popup.
final class WelcomeGateTests: XCTestCase {
    // MARK: - Launch routing (design 6.1)

    func testRoutingTable() {
        // Completed and not reopened: always the dashboard, whatever the deployment does.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, isDetecting: true)), .dashboard)
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, hasInstalledDeployment: true, stage: .failed)), .dashboard)
        // The detection still runs: wait (no flash of the install screen).
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, isDetecting: true)), .checking)
        // Healthy full deployment: dashboard directly.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .attached, health: .healthy, topology: .gateway)), .dashboard)
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .attached, health: .checking, topology: .gateway)), .dashboard)
        // Unhealthy or partial: 连接与部署.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .attached, health: .degraded, topology: .gateway)), .needsAttention)
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .failed, topology: .gateway)), .needsAttention)
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .idle, topology: .gateway)), .needsAttention)
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, foundUnadoptedInstallation: true, stage: .failed)), .needsAttention)
        // Legacy 0.1.x native: the upgrade wizard, healthy or not.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .attached, health: .healthy, method: .native, topology: .legacy)), .welcome(.upgrade))
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .failed, method: .native, topology: .legacy)), .welcome(.upgrade))
        // A legacy Docker deployment has no gateway to upgrade to.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false, hasInstalledDeployment: true, stage: .attached, health: .healthy, method: .docker, topology: .legacy)), .dashboard)
        // Nothing found.
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: false)), .welcome(.install))
    }

    func testReopenedFromHelpShowsTheGateForTheCurrentState() {
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, reopenedFromHelp: true)), .welcome(.install))
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, reopenedFromHelp: true, hasInstalledDeployment: true, stage: .attached, health: .healthy, topology: .gateway)), .welcome(.ready))
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, reopenedFromHelp: true, hasInstalledDeployment: true, stage: .attached, topology: .legacy)), .welcome(.upgrade))
        XCTAssertEqual(LaunchRouting.route(.init(onboardingCompleted: true, reopenedFromHelp: true, hasInstalledDeployment: true, stage: .failed, topology: .gateway)), .needsAttention)
    }

    @MainActor
    func testDetectionFromAStoreWithoutAutomaticActivityIsNeverPending() {
        let store = DeploymentStore(autoProbe: false)
        let detection = LaunchDetection(onboardingCompleted: false, reopenedFromHelp: false, deploymentStore: store)
        XCTAssertFalse(detection.isDetecting, "-OasesDisableAutoProbe and tests must not wait for a probe")
        XCTAssertEqual(LaunchRouting.route(detection), .welcome(.install))
    }

    // MARK: - Welcome phases

    func testInstallPhasesFollowTheStore() {
        func phase(_ started: Bool, _ facts: WelcomePhase.Facts) -> WelcomePhase {
            WelcomePhase.resolve(initialStep: .install, startedInstall: started, startedUpgrade: false, facts: facts)
        }
        XCTAssertEqual(phase(false, .init()), .install)
        XCTAssertEqual(phase(false, .init(stage: .attached, hasInstalledDeployment: true)), .ready, "a late adoption")
        XCTAssertEqual(phase(true, .init(isPreparingOneClickInstall: true)), .installing(.preparing))
        XCTAssertEqual(phase(true, .init(stage: .connecting, isProbing: true)), .installing(.preparing))
        XCTAssertEqual(phase(true, .init(stage: .installing, isDeploying: true, installStage: "download-cli")), .installing(.running(stage: "download-cli")))
        XCTAssertEqual(phase(true, .init(stage: .installing, isDeploying: true)), .installing(.running(stage: nil)))
        XCTAssertEqual(phase(true, .init(stage: .connecting, isDeploying: true, hasInstalledDeployment: true)), .installing(.verifying))
        XCTAssertEqual(phase(true, .init(stage: .attached, hasInstalledDeployment: true)), .ready)
        XCTAssertEqual(phase(true, .init(stage: .failed, failedStage: "verify-cli")), .installing(.failed(stage: "verify-cli")))
        XCTAssertEqual(phase(true, .init(stage: .cancelled)), .install, "a cancelled install returns to step 1")
    }

    func testUpgradePhasesFollowTheMaintenance() throws {
        func phase(_ started: Bool, _ facts: WelcomePhase.Facts) -> WelcomePhase {
            WelcomePhase.resolve(initialStep: .upgrade, startedInstall: false, startedUpgrade: started, facts: facts)
        }
        XCTAssertEqual(phase(false, .init(stage: .attached, hasInstalledDeployment: true)), .upgrade)
        XCTAssertEqual(phase(true, .init(stage: .installing, isMaintaining: true)), .upgrading(.running))
        let failure = try XCTUnwrap(UpgradeFailure(standardError: "OASES_UPGRADE_FAILURE stage=node status=18\nOASES_UPGRADE_OUTCOME changes=restored running=yes\n"))
        XCTAssertEqual(phase(true, .init(stage: .failed, maintenanceFailure: .upgrade(failure))), .upgrading(.failed(stage: "node")))
        XCTAssertEqual(phase(true, .init(stage: .failed, maintenanceFailure: .other)), .upgrading(.failed(stage: nil)))
        XCTAssertEqual(phase(true, .init(stage: .attached, topology: .gateway)), .upgraded)
        XCTAssertEqual(WelcomePhase.resolve(initialStep: .ready, startedInstall: false, startedUpgrade: false, facts: .init()), .ready)
        let refused = phase(true, .init(stage: .attached, maintenanceFailure: .refused("newer engine")))
        XCTAssertEqual(refused, .upgrading(.failed(stage: nil)))
        XCTAssertEqual(refused.failureExit, .environments, "a refused upgrade has a way out")
    }

    /// I2: every failed step has a way out of the gate; the other phases lead on with their own
    /// buttons and show no extra exit.
    func testEveryFailedStepHasAWayOut() {
        XCTAssertEqual(WelcomePhase.upgrading(.failed(stage: "node")).failureExit, .environments)
        XCTAssertEqual(WelcomePhase.upgrading(.failed(stage: nil)).failureExit, .environments)
        XCTAssertEqual(WelcomePhase.installing(.failed(stage: "download-cli")).failureExit, .environments)
        for phase: WelcomePhase in [.install, .installing(.preparing), .installing(.verifying), .ready, .upgrade, .upgrading(.running), .upgraded] {
            XCTAssertNil(phase.failureExit, "\(phase)")
        }
    }

    // MARK: - 连接与部署 state

    func testConnectionPageStates() throws {
        func state(_ change: (inout ConnectionPageState.Facts) -> Void) -> ConnectionPageState {
            var facts = ConnectionPageState.Facts()
            change(&facts)
            return ConnectionPageState.resolve(facts)
        }
        XCTAssertEqual(state { _ in }, .notDeployed)
        XCTAssertEqual(state { $0.isProbing = true }, .checking)
        XCTAssertEqual(state { $0.isPreparingOneClickInstall = true }, .deploying(.preparing))
        XCTAssertEqual(state { $0.isDeploying = true; $0.stage = .installing; $0.installStage = "install-node" }, .deploying(.running(stage: "install-node")))
        XCTAssertEqual(state { $0.isDeploying = true; $0.stage = .connecting; $0.hasInstalledDeployment = true }, .deploying(.verifying))
        XCTAssertEqual(state { $0.isDeploying = true; $0.stage = .connecting }, .checking, "an adoption")
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.stage = .attached; $0.health = .healthy; $0.topology = .gateway }, .running)
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.stage = .attached; $0.health = .degraded; $0.topology = .gateway }, .needsAttention(.unhealthy))
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.stage = .idle; $0.topology = .gateway }, .needsAttention(.notConnected))
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.stage = .idle; $0.isStoppedByUser = true; $0.topology = .gateway }, .stopped)
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.stage = .attached; $0.topology = .legacy; $0.method = .native }, .legacy)
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.isMaintaining = true }, .maintaining)
        XCTAssertEqual(state { $0.hasInstalledDeployment = true; $0.isRemovingDeployment = true }, .removing)
        XCTAssertEqual(state { $0.stage = .failed; $0.probeFoundInstallation = true }, .needsAttention(.notAdoptable))
        let failure = DeploymentFailureClassifier.classify(message: "curl: (6) Could not resolve host: github.com\n[t] 部署在阶段 download-cli 失败（退出码 18）。")
        XCTAssertEqual(state { $0.stage = .failed; $0.installFailure = failure }, .error(failure))
    }

    /// Screenshot 9: a refused removal next to a running deployment is one state, never green
    /// success text and a red error at the same time.
    func testARefusedRemovalIsOneStateNotSuccessPlusError() {
        var facts = ConnectionPageState.Facts()
        facts.hasInstalledDeployment = true
        facts.stage = .attached
        facts.health = .healthy
        facts.topology = .gateway
        facts.hasRemovalError = true
        XCTAssertEqual(ConnectionPageState.resolve(facts), .needsAttention(.removalFailed))
        facts.hasRemovalError = false
        XCTAssertEqual(ConnectionPageState.resolve(facts), .running, "the stale error is gone once its cause is")
    }

    func testLanguagePickerNamesWhatTheSystemChoiceResolvesTo() {
        let title = WelcomeLanguagePicker.title(of: .system, in: .english)
        XCTAssertTrue(title.hasPrefix("System ("), title)
        XCTAssertEqual(WelcomeLanguagePicker.title(of: .english, in: .simplifiedChinese), "English")
        XCTAssertTrue(WelcomeLanguagePicker.title(of: .system, in: .simplifiedChinese).hasPrefix("跟随系统（"))
    }
}
