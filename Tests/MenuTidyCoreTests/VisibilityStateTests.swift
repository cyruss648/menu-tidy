import XCTest
@testable import MenuTidyCore

final class VisibilityStateTests: XCTestCase {
    func testInitialStateAndToggleCycle() {
        var state = VisibilityState()
        XCTAssertEqual(state.mode, .expanded)
        state.toggle()
        XCTAssertEqual(state.mode, .collapsed)
        state.toggle()
        XCTAssertEqual(state.mode, .expanded)
    }

    func testExplicitTransitionsAreIdempotent() {
        var state = VisibilityState()
        state.collapse()
        state.collapse()
        XCTAssertEqual(state.mode, .collapsed)
        state.expand()
        state.expand()
        XCTAssertEqual(state.mode, .expanded)
    }

    func testArrangementCannotBeInterruptedByClicksOrTimers() {
        var state = VisibilityState()
        state.collapse()
        state.beginArrangement()
        XCTAssertEqual(state.mode, .arranging)

        state.toggle()
        state.collapse()
        state.expand()
        state.beginArrangement()
        XCTAssertEqual(state.mode, .arranging)

        state.finishArrangement(collapse: true)
        XCTAssertEqual(state.mode, .collapsed)
    }

    func testArrangementMayFinishExpanded() {
        var state = VisibilityState()
        state.beginArrangement()
        state.finishArrangement(collapse: false)
        XCTAssertEqual(state.mode, .expanded)
    }

    func testStaleArrangementCompletionDoesNotChangeVisibility() {
        var state = VisibilityState()
        state.finishArrangement(collapse: true)
        XCTAssertEqual(state.mode, .expanded)
        state.collapse()
        state.finishArrangement(collapse: false)
        XCTAssertEqual(state.mode, .collapsed)
    }
}
