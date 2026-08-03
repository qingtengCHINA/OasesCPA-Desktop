import XCTest
@testable import OasesCPA

final class OasesAppearanceTests: XCTestCase {
    func testAppearanceOptionsExposeStableUserDefaultsValues() {
        XCTAssertEqual(
            OasesAppearance.allCases.map(\.rawValue),
            ["system", "light", "dark"]
        )
        XCTAssertEqual(OasesAppearance.defaultsKey, "oases.cpa.appearance")
    }

    func testAppearanceMapsToExpectedColorScheme() {
        XCTAssertNil(OasesAppearance.system.colorScheme)
        XCTAssertEqual(OasesAppearance.light.colorScheme, .light)
        XCTAssertEqual(OasesAppearance.dark.colorScheme, .dark)
    }
}
