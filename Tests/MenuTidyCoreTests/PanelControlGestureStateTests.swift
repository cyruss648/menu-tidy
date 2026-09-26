import XCTest
@testable import MenuTidyCore

final class PanelControlGestureStateTests: XCTestCase {
    private typealias State = PanelControlGestureState
    private func down(_ time: Double, button: Int = 0) -> State.MouseEvent {
        .init(button: button, phase: .down, timestamp: time, eventNumber: Int(time * 100))
    }
    private func up(_ time: Double, button: Int = 0) -> State.MouseEvent {
        .init(button: button, phase: .up, timestamp: time, eventNumber: Int(time * 100))
    }

    func testControlPressClosesEvenAfterOutsideMouseUpClosedPanel() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.observe(down(2))
        state.beginControlPress(down(2))
        state.observe(up(3))
        XCTAssertTrue(state.shouldDismiss(for: up(3)))
        state.presentationChanged(isPresented: false, at: 3.1)
        XCTAssertEqual(state.controlRelease(up(3)), .close)
    }

    func testFocusDismissalBeforeDelayedDownRetainsOriginalCloseIntent() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.presentationChanged(isPresented: false, at: 2.1)
        state.observe(down(2))
        state.beginControlPress(down(2))
        XCTAssertEqual(state.controlRelease(up(3)), .close)
    }

    func testUpCopyCanArriveBeforeDownCopyWithoutLosingPressIntent() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.observe(up(3))
        state.presentationChanged(isPresented: false, at: 3.1)
        state.observe(down(2))
        state.beginControlPress(down(2))
        XCTAssertTrue(state.hasControlPress(for: up(3)))
        XCTAssertEqual(state.controlRelease(up(3)), .close)
    }

    func testOpeningMouseUpCannotDismissNewPanelWhenDeliveredLate() {
        var state = State()
        state.beginControlPress(down(1))
        XCTAssertEqual(state.controlRelease(up(2)), .show)
        state.presentationChanged(isPresented: true, at: 2.1)
        state.observe(up(2))
        XCTAssertFalse(state.shouldDismiss(for: up(2)))
    }

    func testRemoteHostSyntheticReleaseDoesNotMakePhysicalReleaseAnOutsideClick() {
        var state = State()
        state.observe(down(1))
        state.beginControlPress(down(1.01))
        XCTAssertEqual(state.controlRelease(up(1.010004)), .show)
        state.presentationChanged(isPresented: true, at: 1.02)
        // Observed on macOS 27: the physical up arrives about 100ms after the
        // hosted button has already invoked its synthetic mouse-up action.
        state.observe(up(1.12))
        XCTAssertFalse(state.shouldDismiss(for: up(1.12)))
        // No timeout/debounce: the immediately following outside gesture works.
        state.observe(down(1.13))
        state.observe(up(1.14))
        XCTAssertTrue(state.shouldDismiss(for: up(1.14)))
    }

    func testNextControlGestureClosesAfterRemoteHostAndPhysicalRelease() {
        var state = State()
        state.beginControlPress(down(1))
        XCTAssertEqual(state.controlRelease(up(1.000004)), .show)
        state.presentationChanged(isPresented: true, at: 1.01)
        state.observe(up(1.1))
        state.observe(down(2))
        state.beginControlPress(down(2.01))
        XCTAssertEqual(state.controlRelease(up(2.010004)), .close)
        state.presentationChanged(isPresented: false, at: 2.02)
        state.observe(up(2.1))
        XCTAssertFalse(state.shouldDismiss(for: up(2.1)))
    }

    func testNewPhysicalPressOpensAfterPreviousClose() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.beginControlPress(down(2))
        state.presentationChanged(isPresented: false, at: 2.1)
        XCTAssertEqual(state.controlRelease(up(3)), .close)
        state.beginControlPress(down(4))
        XCTAssertEqual(state.controlRelease(up(5)), .show)
    }

    func testNewSameButtonDownInvalidatesAbandonedControlPress() {
        var state = State()
        state.beginControlPress(down(1))
        state.observe(down(2))
        XCTAssertFalse(state.hasControlPress(for: up(3)))
        XCTAssertEqual(state.controlRelease(up(3)), .ignore)
    }

    func testLateOlderDownCannotReplaceCurrentControlPress() {
        var state = State()
        state.beginControlPress(down(3))
        state.observe(down(1))
        state.observe(up(2))
        XCTAssertTrue(state.hasControlPress(for: up(4)))
        XCTAssertEqual(state.controlRelease(up(4)), .show)
    }

    func testDifferentButtonsDoNotConsumeLeftControlPress() {
        var state = State()
        state.beginControlPress(down(1))
        state.observe(down(2, button: 1))
        state.observe(up(3, button: 1))
        XCTAssertFalse(state.hasControlPress(for: up(3, button: 1)))
        XCTAssertEqual(state.controlRelease(up(4)), .show)
    }

    func testFreshKeyboardPresentationIsNotClosedByOlderHeldPress() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.beginControlPress(down(2))
        state.presentationChanged(isPresented: false, at: 3)
        state.presentationChanged(isPresented: true, at: 4)
        state.observe(up(5))
        XCTAssertFalse(state.shouldDismiss(for: up(5)))
        XCTAssertEqual(state.controlRelease(up(5)), .ignore)
    }

    func testLongHoldDoesNotExpireUsingADebounceWindow() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.beginControlPress(down(2))
        state.presentationChanged(isPresented: false, at: 3)
        XCTAssertEqual(state.controlRelease(up(10_000)), .close)
    }

    func testHistoryPruningCannotTurnOldPressIntoActionForNewPanel() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.beginControlPress(down(2))
        for number in 3...150 {
            state.presentationChanged(isPresented: number.isMultiple(of: 2), at: Double(number))
        }
        XCTAssertEqual(state.controlRelease(up(151)), .ignore)
    }

    func testAccessibilityActionDoesNotBorrowPreviousOutsideClick() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 1)
        state.observe(down(2))
        state.observe(up(3))
        state.presentationChanged(isPresented: false, at: 3.1)
        XCTAssertFalse(state.hasControlPress(for: up(3)))
        XCTAssertEqual(state.controlRelease(nil), .show)
    }

    func testAccessibilityActivationCanCloseAndReopenIndependently() {
        var state = State()
        XCTAssertEqual(state.controlRelease(nil), .show)
        state.presentationChanged(isPresented: true, at: 1)
        XCTAssertEqual(state.controlRelease(nil), .close)
        state.presentationChanged(isPresented: false, at: 2)
        XCTAssertEqual(state.controlRelease(nil), .show)
    }

    func testOnlyCurrentPresentationMouseUpCanDismiss() {
        var state = State()
        state.presentationChanged(isPresented: true, at: 10)
        XCTAssertFalse(state.shouldDismiss(for: down(11)))
        XCTAssertFalse(state.shouldDismiss(for: up(9)))
        XCTAssertTrue(state.shouldDismiss(for: up(11)))
    }

    func testUnmatchedReleaseAndInvalidTimestampCannotCreateIntent() {
        var state = State()
        XCTAssertEqual(state.controlRelease(up(1)), .ignore)
        let invalid = State.MouseEvent(button: 0, phase: .down, timestamp: .nan, eventNumber: 1)
        state.beginControlPress(invalid)
        XCTAssertFalse(state.hasControlPress(for: up(2)))
        XCTAssertEqual(state.controlRelease(up(2)), .ignore)
    }
}
