import SwiftUI

/// The main window's content: the launch routing (`LaunchRouting`) decides between the welcome
/// gate and the dashboard. Once the gate is shown it stays until the user leaves it (installing
/// changes the deployment state, which must not swap the screen mid-step); leaving it completes
/// the onboarding, so going back never re-enters the gate. Help → 欢迎指南 reopens it.
struct MainWindowRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @AppStorage(OnboardingState.completionVersionKey) private var completedOnboardingVersion = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The gate step while the gate is shown (frozen when it first appears).
    @State private var gateStep: WelcomeStep?
    /// The detection gets 20 s; after that the route is taken from what is known.
    @State private var detectionTimedOut = false

    private var route: LaunchRoute {
        var detection = LaunchDetection(
            onboardingCompleted: completedOnboardingVersion >= OnboardingState.currentVersion,
            reopenedFromHelp: store.isWelcomeReopened,
            deploymentStore: deploymentStore
        )
        if detectionTimedOut { detection.isDetecting = false }
        return LaunchRouting.route(detection)
    }

    var body: some View {
        let route = route
        Group {
            if let step = gateStep ?? route.welcomeStep {
                WelcomeFlowView(initialStep: step) { section in
                    finishWelcome(selecting: section)
                }
                .id(step)
                .transition(.opacity)
            } else if route == .checking {
                LaunchCheckingView()
                    .transition(.opacity)
            } else {
                ContentView()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: gateStep ?? route.welcomeStep)
        .task(id: route) { apply(route) }
        .task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            detectionTimedOut = true
        }
        .onChange(of: store.isWelcomeReopened) { _, reopened in
            if reopened { gateStep = nil }
        }
    }

    private func apply(_ route: LaunchRoute) {
        guard gateStep == nil else { return }
        switch route {
        case .welcome(let step):
            gateStep = step
        case .dashboard where completedOnboardingVersion < OnboardingState.currentVersion:
            completedOnboardingVersion = OnboardingState.currentVersion
        case .needsAttention:
            store.selectSection(.environments)
            store.isWelcomeReopened = false
            completedOnboardingVersion = OnboardingState.currentVersion
        case .checking, .dashboard:
            break
        }
    }

    private func finishWelcome(selecting section: AppSection) {
        store.selectSection(section)
        store.isWelcomeReopened = false
        completedOnboardingVersion = OnboardingState.currentVersion
        gateStep = nil
    }
}

/// "正在检查这台 Mac…", shown only when the detection takes longer than 300 ms (no splash).
struct LaunchCheckingView: View {
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: Oases.Space.sm) {
            ProgressView()
                .controlSize(.small)
            Text("正在检查这台 Mac…")
                .foregroundStyle(.secondary)
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isVisible = true
        }
    }
}
