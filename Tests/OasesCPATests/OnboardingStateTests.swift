import XCTest
@testable import OasesCPA

final class OnboardingStateTests: XCTestCase {
    func testLegacyCompletionDoesNotSuppressTheCurrentWelcomeFlow() {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: OnboardingState.legacyCompletionKey)

        let state = OnboardingState(defaults: defaults)

        XCTAssertTrue(state.shouldPresentWelcome)
    }

    func testCompletingAndResettingTheCurrentWelcomeFlowPersistsItsVersion() {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = OnboardingState(defaults: defaults)

        state.completeWelcome()
        XCTAssertFalse(state.shouldPresentWelcome)
        XCTAssertEqual(
            defaults.integer(forKey: OnboardingState.completionVersionKey),
            OnboardingState.currentVersion
        )

        state.resetWelcome()
        XCTAssertTrue(state.shouldPresentWelcome)
    }

    func testCompletedVersionTwoPassesTheNewGateOnce() {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2, forKey: OnboardingState.completionVersionKey)
        XCTAssertTrue(OnboardingState(defaults: defaults).shouldPresentWelcome)
    }

    func testCompletedVersionOneIsShownAgainAfterHeroRefresh() {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1, forKey: OnboardingState.completionVersionKey)

        let state = OnboardingState(defaults: defaults)

        XCTAssertTrue(state.shouldPresentWelcome)
        XCTAssertEqual(OnboardingState.currentVersion, 3)
    }
}
