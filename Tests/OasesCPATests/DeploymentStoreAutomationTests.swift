import XCTest
@testable import OasesCPA

/// The automatic deployment activity of `DeploymentStore` (the first-run probe of the default
/// install directory, the adoption that follows it, and the 30 s patrol that restarts services)
/// must never run in a test process or in a run launched with `-OasesDisableAutoProbe`.
@MainActor
final class DeploymentStoreAutomationTests: XCTestCase {
    func testAutomaticActivityIsOffUnderXCTestOrWithTheLaunchFlag() {
        XCTAssertTrue(DeploymentStore.automaticActivityAllowed(
            environment: [:], arguments: ["Oases CPA"], testFrameworkLoaded: false
        ))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            arguments: ["Oases CPA"],
            testFrameworkLoaded: false
        ))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: ["XCTestConfigurationFilePath": ""],
            arguments: ["Oases CPA"],
            testFrameworkLoaded: false
        ))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: [:],
            arguments: ["Oases CPA", "-OasesDisableAutoProbe"],
            testFrameworkLoaded: false
        ))
        XCTAssertTrue(DeploymentStore.automaticActivityAllowed(
            environment: [:],
            arguments: ["Oases CPA", "-OasesDisableAutoProbeX"],
            testFrameworkLoaded: false
        ))
    }

    /// `swift test` sets no environment variable; a loaded XCTest framework alone is enough.
    func testLoadedTestFrameworkAloneDisablesAutomaticActivity() {
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: [:], arguments: ["Oases CPA"], testFrameworkLoaded: true
        ))
    }

    /// The live value inside this test process. `swift test` does not set
    /// `XCTestConfigurationFilePath` (only the Xcode test host does), so the guard must also
    /// recognise a process that has XCTest loaded.
    func testLiveTestProcessNeverAllowsAutomaticActivity() {
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed)
    }

    func testStoreWithoutAutoProbeNeverProbesOnInit() async {
        let store = DeploymentStore(autoProbe: false)
        XCTAssertFalse(store.automaticActivityEnabled)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(store.isProbing)
        XCTAssertNil(store.probe)
        XCTAssertFalse(store.isHealthMonitorRunningForTesting)
    }
}
