import XCTest
@testable import MenuTidyCore

final class AutoCollapsePolicyTests: XCTestCase {
    func testDelayClampPreservesValidValues() {
        XCTAssertEqual(AutoCollapsePolicy(delay: -10).delay, 3)
        XCTAssertEqual(AutoCollapsePolicy(delay: 0).delay, 3)
        XCTAssertEqual(AutoCollapsePolicy(delay: 3).delay, 3)
        XCTAssertEqual(AutoCollapsePolicy(delay: 12.5).delay, 12.5)
        XCTAssertEqual(AutoCollapsePolicy(delay: 300).delay, 300)
        XCTAssertEqual(AutoCollapsePolicy(delay: 301).delay, 300)
    }

    func testNonFiniteDelaysUseTheDefault() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(AutoCollapsePolicy(delay: value).delay, 15)
        }
    }

    func testCollapseStartsAtTheDeadline() {
        XCTAssertFalse(shouldCollapse(elapsed: 14.999))
        XCTAssertTrue(shouldCollapse(elapsed: 15))
        XCTAssertTrue(shouldCollapse(elapsed: 120))
    }

    func testEachInteractionIndependentlyPreventsCollapse() {
        XCTAssertFalse(shouldCollapse(isExpanded: false))
        XCTAssertFalse(shouldCollapse(isArranging: true))
        XCTAssertFalse(shouldCollapse(isPaused: true))
        XCTAssertFalse(shouldCollapse(pointerInMenuBar: true))
        XCTAssertFalse(shouldCollapse(mouseButtonDown: true))
        XCTAssertFalse(shouldCollapse(enabled: false))
    }

    func testInvalidElapsedTimeDoesNotCollapse() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(shouldCollapse(elapsed: value))
        }
    }

    private func shouldCollapse(
        elapsed: TimeInterval = 30,
        isExpanded: Bool = true,
        isArranging: Bool = false,
        isPaused: Bool = false,
        pointerInMenuBar: Bool = false,
        mouseButtonDown: Bool = false,
        enabled: Bool = true
    ) -> Bool {
        AutoCollapsePolicy().shouldCollapse(
            elapsed: elapsed,
            isExpanded: isExpanded,
            isArranging: isArranging,
            isPaused: isPaused,
            pointerInMenuBar: pointerInMenuBar,
            mouseButtonDown: mouseButtonDown,
            enabled: enabled
        )
    }
}
