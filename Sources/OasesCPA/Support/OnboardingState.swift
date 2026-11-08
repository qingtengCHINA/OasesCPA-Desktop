import Foundation

/// Whether the first-run welcome gate was completed. Version 3 is the gate with the one-click
/// install and the legacy upgrade wizard: everyone who finished an older welcome passes the
/// launch routing once more (a healthy deployment goes straight to the dashboard, a 0.1.x
/// deployment gets the upgrade wizard).
struct OnboardingState {
    static let currentVersion = 3
    static let completionVersionKey = "oases.cpa.onboarding.completed-version"
    static let legacyCompletionKey = "oases.cpa.onboarding.completed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldPresentWelcome: Bool {
        defaults.integer(forKey: Self.completionVersionKey) < Self.currentVersion
    }

    func completeWelcome() {
        defaults.set(Self.currentVersion, forKey: Self.completionVersionKey)
    }

    func resetWelcome() {
        defaults.removeObject(forKey: Self.completionVersionKey)
    }
}
