import Foundation
import XCTest
@testable import MenuTidyCore

final class DragArrivalPolicyTests: XCTestCase {
    private let previous = CGPoint(x: 100, y: 15)

    private func decide(_ current: CGPoint?, target: CGPoint = CGPoint(x: 120.666687, y: 15),
                        previous: CGPoint? = nil, now: Double = 0.014,
                        arrivalDeadline: Double = 0.15, operationDeadline: Double = 2,
                        unexpectedInput: Bool = false) -> DragArrivalPolicy.Decision {
        DragArrivalPolicy.evaluate(previous: previous ?? self.previous, target: target, current: current,
            now: now, arrivalDeadline: arrivalDeadline, operationDeadline: operationDeadline,
            hasUnexpectedInput: unexpectedInput)
    }

    func testDelayedSystemEventWaitsAtPreviousPointThenAcceptsTarget() {
        // Regression: event 27 was posted, but the 14 ms sample still showed 26.
        let target = CGPoint(x: 120.666687, y: 15)
        XCTAssertEqual(decide(previous), .waiting)
        XCTAssertEqual(decide(previous, now: 0.08), .waiting)
        XCTAssertEqual(decide(target, now: 0.09), .arrived)
    }

    func testSmallStepCannotConfirmAnUnmovedPointer() {
        let target = CGPoint(x: 106, y: 15)
        XCTAssertEqual(decide(previous, target: target), .waiting)
        XCTAssertEqual(decide(previous, target: target, now: 0.149), .waiting)
        XCTAssertEqual(decide(previous, target: target, now: 0.15), .timedOut)
    }

    func testOverlappingNeighborhoodRequiresProgressTowardTarget() {
        let target = CGPoint(x: 106, y: 15)
        XCTAssertEqual(decide(CGPoint(x: 102, y: 15), target: target), .waiting)
        XCTAssertEqual(decide(CGPoint(x: 103, y: 15), target: target), .waiting)
        XCTAssertEqual(decide(CGPoint(x: 104, y: 15), target: target), .arrived)
    }

    func testLastActualObservationIsUsedAsPreviousPoint() {
        let lastActual = CGPoint(x: 118, y: 15)
        let target = CGPoint(x: 124, y: 15)
        XCTAssertEqual(decide(lastActual, target: target, previous: lastActual), .waiting)
        XCTAssertEqual(decide(target, target: target, previous: lastActual), .arrived)
    }

    func testNoMovementTargetDoesNotRequireAVisibleDisplacement() {
        XCTAssertEqual(decide(previous, target: previous), .arrived)
    }

    func testBothDragDirectionsUseTheSameProgressRule() {
        let target = CGPoint(x: 79.333313, y: 15)
        XCTAssertEqual(decide(previous, target: target), .waiting)
        XCTAssertEqual(decide(target, target: target), .arrived)
    }

    func testPointerOutsideBothNeighborhoodsRejectsEvenAlongDragPath() {
        let distantTarget = CGPoint(x: 150, y: 15)
        XCTAssertEqual(decide(CGPoint(x: 125, y: 15), target: distantTarget), .unexpectedInput)
        XCTAssertEqual(decide(CGPoint(x: 100, y: 27.001)), .unexpectedInput)
    }

    func testTwelvePointLimitIsNotExpanded() {
        let target = CGPoint(x: 130, y: 15)
        XCTAssertEqual(decide(CGPoint(x: 142, y: 15), target: target), .arrived)
        XCTAssertEqual(decide(CGPoint(x: 142.001, y: 15), target: target), .unexpectedInput)
        XCTAssertEqual(decide(CGPoint(x: 88, y: 15), target: target), .waiting)
        XCTAssertEqual(decide(CGPoint(x: 87.999, y: 15), target: target), .unexpectedInput)
    }

    func testLateArrivalCannotExtendEitherDeadline() {
        let target = CGPoint(x: 120.666687, y: 15)
        XCTAssertEqual(decide(target, now: 0.15), .timedOut)
        XCTAssertEqual(decide(target, now: 0.12, operationDeadline: 0.12), .timedOut)
        XCTAssertEqual(decide(previous, now: 0.12, operationDeadline: 0.12), .timedOut)
    }

    func testModifierOrButtonInterferenceRejectsEvenAtTarget() {
        XCTAssertEqual(decide(CGPoint(x: 120.666687, y: 15), unexpectedInput: true), .unexpectedInput)
        XCTAssertEqual(decide(previous, unexpectedInput: true), .unexpectedInput)
    }

    func testMissingOrNonfiniteGeometryCannotConfirmArrival() {
        XCTAssertEqual(decide(nil), .unavailablePosition)
        XCTAssertEqual(decide(CGPoint(x: Double.nan, y: 15)), .unavailablePosition)
        XCTAssertEqual(decide(previous, target: CGPoint(x: Double.infinity, y: 15)), .unavailablePosition)
        XCTAssertEqual(decide(previous, now: .nan), .unavailablePosition)
        XCTAssertEqual(decide(previous, arrivalDeadline: .infinity), .unavailablePosition)
    }
}
