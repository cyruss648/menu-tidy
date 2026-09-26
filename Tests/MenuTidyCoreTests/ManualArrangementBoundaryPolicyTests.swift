import CoreGraphics
import XCTest
@testable import MenuTidyCore

final class ManualArrangementBoundaryPolicyTests: XCTestCase {
    private let control = ManualArrangementBoundaryPolicy.controlKey
    private let regular = ManualArrangementBoundaryPolicy.regularKey
    private let always = ManualArrangementBoundaryPolicy.alwaysKey

    func testRepairAfterPhysicalBlockerMovesOnlyOwnedMarkersNearControl() throws {
        let initial: [String: Double] = [control: 100, regular: 25_000, always: 300,
            "status:third.party::one": 200, "status:other.app::two": 800]
        let moves = try XCTUnwrap(ManualArrangementBoundaryPolicy.moves(positions: initial))
        XCTAssertEqual(moves.map(\.key), [regular, always])
        XCTAssertEqual(moves.map(\.beforeKey), [control, regular])
        var result = initial
        for move in moves {
            result = try MenuBarPositionPlan.moving(move.key, before: move.beforeKey,
                positions: result).applying(to: result)
        }
        XCTAssertEqual(result.filter { $0.key != regular && $0.key != always },
            initial.filter { $0.key != regular && $0.key != always })
        XCTAssertGreaterThan(try XCTUnwrap(result[always]), try XCTUnwrap(result[regular]))
        XCTAssertGreaterThan(try XCTUnwrap(result[regular]), try XCTUnwrap(result[control]))
        XCTAssertLessThan(try XCTUnwrap(result[always]), 200,
            "Repairing beside the old blocker would leave markers far inside overflow")
        XCTAssertEqual(ManualArrangementBoundaryPolicy.moves(positions: result), [])
    }

    func testAlreadyOrderedRecordsRequireNoPreferenceChange() {
        XCTAssertEqual(ManualArrangementBoundaryPolicy.moves(positions:
            [control: 100, regular: 200, always: 300, "other": 500]), [])
    }

    func testEqualAndInvertedOwnWeightsRequireBothOrderedRepairSteps() throws {
        for values in [[100.0, 100, 100], [300, 200, 100], [100, 500, 200]] {
            let moves = try XCTUnwrap(ManualArrangementBoundaryPolicy.moves(positions:
                [control: values[0], regular: values[1], always: values[2]]))
            XCTAssertEqual(moves.map(\.key), [regular, always])
            XCTAssertEqual(moves.map(\.beforeKey), [control, regular])
        }
    }

    func testMissingLookalikeAndNonfiniteValuesCannotAuthorizeRepair() {
        XCTAssertNil(ManualArrangementBoundaryPolicy.moves(positions: [:]))
        XCTAssertNil(ManualArrangementBoundaryPolicy.moves(positions:
            [control: 100, regular: 200, "status:another.app::MenuTidyAlwaysDivider": 300]))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ManualArrangementBoundaryPolicy.moves(positions:
                [control: 100, regular: 200, always: 300, "other": invalid]))
        }
    }

    func testRepairRollbackDoesNotOverwriteExternalMarkerOrThirdPartyChanges() throws {
        let initial = [control: 100.0, regular: 25_000, always: 300, "other": 200]
        let plan = try MenuBarPositionPlan.moving(regular, before: control, positions: initial)
        var current = try plan.applying(to: initial)
        current[regular] = 180
        current["other"] = 210
        let rollback = try MenuBarPositionPlan.rollback(originalValues: plan.originalValues,
            writtenValues: plan.writtenValues, current: current)
        XCTAssertEqual(rollback.conflictedKeys, [regular])
        XCTAssertTrue(rollback.restorations.isEmpty)
        XCTAssertEqual(current["other"], 210)
    }

    func testOrderedGeometryRejectsSharedPlaceholderInversionOverlapAndSpacer() {
        let left = CGRect(x: 1_200, y: 0, width: 60, height: 33)
        let middle = CGRect(x: 1_260, y: 0, width: 60, height: 33)
        let right = CGRect(x: 1_320, y: 0, width: 44, height: 33)
        XCTAssertTrue(ManualArrangementBoundaryPolicy.orderedFrames([left, middle, right]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([left, left, right]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([middle, left, right]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([left, middle.offsetBy(dx: -1, dy: 0), right]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([
            CGRect(x: 800, y: 0, width: 400, height: 33), left]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([left, middle.offsetBy(dx: 0, dy: 50)]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([left]))
        XCTAssertFalse(ManualArrangementBoundaryPolicy.orderedFrames([.zero, right]))
    }
}
