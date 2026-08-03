import XCTest
@testable import OasesCPA

final class PanelAndQuotaStateTests: XCTestCase {
    func testPanelLoadPolicyDoesNotReloadForTheSameTarget() {
        let target = EmbeddedPanelTarget(
            url: URL(string: "http://127.0.0.1:18317")!,
            apiBase: "http://127.0.0.1:8317/v1",
            managementKey: "test-key"
        )
        var policy = EmbeddedPanelLoadPolicy()

        XCTAssertTrue(policy.shouldLoad(target: target))
        XCTAssertFalse(policy.shouldLoad(target: target))
    }

    func testPanelLoadPolicyReloadsWhenTargetIdentityChanges() {
        let target = EmbeddedPanelTarget(
            url: URL(string: "http://127.0.0.1:18317")!,
            apiBase: "http://127.0.0.1:8317/v1",
            managementKey: "test-key"
        )
        var policy = EmbeddedPanelLoadPolicy()

        XCTAssertTrue(policy.shouldLoad(target: target))
        XCTAssertTrue(policy.shouldLoad(target: target.withManagementKey("rotated-key")))
        XCTAssertTrue(policy.shouldLoad(target: target.withAPIBase("http://127.0.0.1:9317/v1")))
        XCTAssertTrue(policy.shouldLoad(target: target.withURL(URL(string: "http://127.0.0.1:19317")!)))
    }

    func testQuotaResetStateKeepsTargetUntilAsyncOperationFinishes() {
        var state = QuotaResetState()

        XCTAssertTrue(state.beginConfirmation(for: "quota-1"))
        XCTAssertEqual(state.targetID, "quota-1")
        XCTAssertTrue(state.beginReset())
        XCTAssertTrue(state.isResetting)
        XCTAssertEqual(state.targetID, "quota-1")

        state.finishReset()

        XCTAssertNil(state.targetID)
        XCTAssertFalse(state.isResetting)
    }

    func testQuotaResetStateRejectsRepeatedStartWhileOperationIsInFlight() {
        var state = QuotaResetState()

        XCTAssertTrue(state.beginConfirmation(for: "quota-1"))
        XCTAssertTrue(state.beginReset())
        XCTAssertFalse(state.beginConfirmation(for: "quota-2"))
        XCTAssertFalse(state.beginReset())
        XCTAssertEqual(state.targetID, "quota-1")
    }
}
