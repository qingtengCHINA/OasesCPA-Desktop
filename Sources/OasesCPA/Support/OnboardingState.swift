import Foundation

struct OnboardingState {
    static let currentVersion = 2
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
