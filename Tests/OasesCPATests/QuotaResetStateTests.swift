import XCTest
@testable import OasesCPA

final class QuotaResetStateTests: XCTestCase {
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
