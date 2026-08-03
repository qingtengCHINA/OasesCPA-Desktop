import AppKit
import XCTest
@testable import OasesCPA

final class WindowLayoutPolicyTests: XCTestCase {
    func testMinimumContentSizeNeverExceedsVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 80, width: 900, height: 620)

        let size = WindowLayoutPolicy.minimumContentSize(for: visibleFrame)

        XCTAssertLessThanOrEqual(size.width, visibleFrame.width - WindowLayoutPolicy.screenMargin * 2)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height - WindowLayoutPolicy.screenMargin * 2)
        XCTAssertGreaterThanOrEqual(size.width, 480)
        XCTAssertGreaterThanOrEqual(size.height, 360)
    }

    func testClampedFrameFitsInsideVisibleScreenAboveDock() {
        let visibleFrame = NSRect(x: 0, y: 80, width: 1_440, height: 780)
        let oversized = NSRect(x: -100, y: 0, width: 1_800, height: 1_000)

        let clamped = WindowLayoutPolicy.clampedWindowFrame(oversized, to: visibleFrame)

        XCTAssertTrue(visibleFrame.contains(clamped), "\(clamped) must fit inside \(visibleFrame)")
        XCTAssertGreaterThanOrEqual(clamped.minY, visibleFrame.minY)
    }

    func testComfortableWindowFrameIsNotNeedlesslyExpanded() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let current = NSRect(x: 240, y: 160, width: 1_240, height: 760)

        XCTAssertEqual(WindowLayoutPolicy.clampedWindowFrame(current, to: visibleFrame), current)
    }
}
