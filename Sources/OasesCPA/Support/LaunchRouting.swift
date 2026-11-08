import Foundation

/// The first screen of the welcome gate.
enum WelcomeStep: Equatable, Sendable {
    /// Step 1: nothing is deployed; one "安装并启动".
    case install
    /// Step U: a 0.1.x deployment waits for its upgrade.
    case upgrade
    /// Step 3: a deployment runs; the endpoint and the two optional next steps.
    case ready
}

/// What the main window shows (design-direction 6.1).
enum LaunchRoute: Equatable, Sendable {
    /// The launch detection still runs ("正在检查这台 Mac…" after 300 ms).
    case checking
    /// The main window with the sidebar.
    case dashboard
    /// The main window with 连接与部署 selected: a deployment exists but needs the user.
    case needsAttention
    /// The welcome gate (no sidebar).
    case welcome(WelcomeStep)

    var welcomeStep: WelcomeStep? {
        if case .welcome(let step) = self { return step }
        return nil
    }
}

/// The facts the routing reads, taken from `OnboardingState`, `AppStore` and `DeploymentStore`.
struct LaunchDetection: Equatable, Sendable {
    var onboardingCompleted: Bool
    /// Help → 欢迎指南.
    var reopenedFromHelp = false
    /// `DeploymentStore.isDetectingOnLaunch` (false when automatic activity is off).
    var isDetecting = false
    /// The app manages an installed deployment (a saved, installed target or an adopted one).
    var hasInstalledDeployment = false
    /// The probe found an installed deployment the app could not adopt.
    var foundUnadoptedInstallation = false
    var stage: DeploymentStage = .idle
    var health: DeploymentHealthState = .unknown
    var method: DeploymentMethod = .native
    var topology: DeploymentTopology = .legacy

    @MainActor
    init(onboardingCompleted: Bool, reopenedFromHelp: Bool, deploymentStore: DeploymentStore) {
        self.onboardingCompleted = onboardingCompleted
        self.reopenedFromHelp = reopenedFromHelp
        isDetecting = deploymentStore.isDetectingOnLaunch
        hasInstalledDeployment = deploymentStore.hasInstalledDeployment
        foundUnadoptedInstallation = !deploymentStore.hasInstalledDeployment
            && deploymentStore.probe?.hasManagedInstallation == true
        stage = deploymentStore.stage
        health = deploymentStore.healthState
        method = deploymentStore.deploymentMethod
        topology = deploymentStore.topology
    }

    init(
        onboardingCompleted: Bool,
        reopenedFromHelp: Bool = false,
        isDetecting: Bool = false,
        hasInstalledDeployment: Bool = false,
        foundUnadoptedInstallation: Bool = false,
        stage: DeploymentStage = .idle,
        health: DeploymentHealthState = .unknown,
        method: DeploymentMethod = .native,
        topology: DeploymentTopology = .legacy
    ) {
        self.onboardingCompleted = onboardingCompleted
        self.reopenedFromHelp = reopenedFromHelp
        self.isDetecting = isDetecting
        self.hasInstalledDeployment = hasInstalledDeployment
        self.foundUnadoptedInstallation = foundUnadoptedInstallation
        self.stage = stage
        self.health = health
        self.method = method
        self.topology = topology
    }
}

/// Launch routing as a pure function, so every row of the table is a unit test.
///
/// | Detected | Route |
/// |---|---|
/// | welcome completed (and not reopened) | dashboard |
/// | detection still running | checking |
/// | installed 0.1.x native deployment | welcome step U (upgrade wizard) |
/// | installed deployment, attached and not degraded | dashboard (reopened: welcome step 3) |
/// | installed deployment otherwise, or found but not adoptable | dashboard on 连接与部署 |
/// | nothing | welcome step 1 |
enum LaunchRouting {
    static func route(_ detection: LaunchDetection) -> LaunchRoute {
        if detection.onboardingCompleted && !detection.reopenedFromHelp {
            return .dashboard
        }
        if detection.isDetecting {
            return .checking
        }
        if MaintenanceLabels.showsUpgradeCallout(
            method: detection.method,
            topology: detection.topology,
            hasInstalledDeployment: detection.hasInstalledDeployment
        ) {
            return .welcome(.upgrade)
        }
        if detection.hasInstalledDeployment {
            let healthy = detection.stage == .attached && detection.health != .degraded
            guard healthy else { return .needsAttention }
            return detection.reopenedFromHelp ? .welcome(.ready) : .dashboard
        }
        if detection.foundUnadoptedInstallation {
            return .needsAttention
        }
        return .welcome(.install)
    }
}
