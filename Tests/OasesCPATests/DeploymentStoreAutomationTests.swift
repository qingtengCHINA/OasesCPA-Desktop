import XCTest
@testable import OasesCPA

/// The automatic deployment activity of `DeploymentStore` (the first-run probe of the default
/// install directory, the adoption that follows it, and the 30 s patrol that restarts services)
/// must never run in a test process or in a run launched with `-OasesDisableAutoProbe`.
@MainActor
final class DeploymentStoreAutomationTests: XCTestCase {
    func testAutomaticActivityIsOffUnderXCTestOrWithTheLaunchFlag() {
        XCTAssertTrue(DeploymentStore.automaticActivityAllowed(environment: [:], arguments: ["Oases CPA"]))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            arguments: ["Oases CPA"]
        ))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: ["XCTestConfigurationFilePath": ""],
            arguments: ["Oases CPA"]
        ))
        XCTAssertFalse(DeploymentStore.automaticActivityAllowed(
            environment: [:],
            arguments: ["Oases CPA", "-OasesDisableAutoProbe"]
        ))
        XCTAssertTrue(DeploymentStore.automaticActivityAllowed(
            environment: [:],
            arguments: ["Oases CPA", "-OasesDisableAutoProbeX"]
        ))
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
