import XCTest
@testable import MenuTidyCore

final class MenuBarOwnBoundaryPlanTests: XCTestCase {
    private let divider = MenuBarOwnBoundaryPlan.dividerKey
    private let control = MenuBarOwnBoundaryPlan.controlKey

    func testOnlyExactDividerMovesBetweenEveryOrdinaryRecordAndReservedHiddenRange() throws {
        let initial: [String: Double] = [divider: 200, control: 170.5,
            "status:old.example::possibly-stale": 9_000, "module:Bluetooth": 1_000,
            "unrecognized-numeric-record": 21_000, "hidden-a": 50_000, "hidden-b": 50_030]
        let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions: initial,
            managedHiddenWeights: ["hidden-a": 50_000, "hidden-b": 50_030]))
        let result = try plan.applying(to: initial)
        XCTAssertEqual(result.filter { $0.key != divider }, initial.filter { $0.key != divider })
        XCTAssertGreaterThan(plan.writtenWeight, 21_000)
        XCTAssertLessThan(plan.writtenWeight, MenuBarHiddenLedger.minimumHiddenWeight)
        XCTAssertEqual(plan.originalValues, [divider: 200])
        XCTAssertEqual(plan.writtenValues, [divider: plan.writtenWeight])
    }

    func testAlreadySeparatedDividerIsNotMovedAgain() throws {
        XCTAssertNil(try MenuBarOwnBoundaryPlan.prepare(positions:
            [divider: 25_000, control: 200, "other": 24_999, "hidden": 50_000],
            managedHiddenWeights: ["hidden": 50_000]))
    }

    func testEqualOrdinaryWeightAndReservedDividerValueBothRequireRepositioning() throws {
        for value in [900.0, 50_000.0, 50_100.0] {
            let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions:
                [divider: value, control: 200, "other": 900, "hidden": 50_000],
                managedHiddenWeights: ["hidden": 50_000]))
            XCTAssertGreaterThan(plan.writtenWeight, 900)
            XCTAssertLessThan(plan.writtenWeight, 50_000)
        }
    }

    func testMissingExactOwnKeysCannotInventRecordsOrMoveLookalikes() {
        let cases: [[String: Double]] = [[divider: 200], [control: 200],
            ["status:another.app::MenuTidyDivider": 200, control: 100],
            [divider: 200, "status:dev.hdh.MenuTidy::MenuTidyControlExtra": 100]]
        for positions in cases {
            XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions: positions)) {
                XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .missingOwnItem)
            }
        }
    }

    func testHiddenControlAndNonfiniteUnrelatedPositionsAreRejected() {
        XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions: [divider: 1, control: 50_000])) {
            XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .invalidControlPosition)
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions:
                [divider: 1, control: 200, "unrelated": invalid])) {
                XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .invalidPositions)
            }
        }
    }

    func testReservedLimitNeverCrossedWhenOnlyOneOrNoRepresentableSlotRemains() throws {
        let interior = Double(50_000).nextDown
        let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions:
            [divider: 100, control: interior.nextDown]))
        XCTAssertEqual(plan.writtenWeight, interior)
        XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions: [divider: 100, control: interior])) {
            XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .noFiniteGap)
        }
    }

    func testFreshMergePreservesUnrelatedChangesButRejectsChangedBoundaryOrOwnIdentityValues() throws {
        let initial: [String: Double] = [divider: 100, control: 200, "upper": 900, "other": 20, "hidden": 50_000]
        let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions: initial,
            managedHiddenWeights: ["hidden": 50_000]))
        var unrelated = initial
        unrelated["other"] = 30
        unrelated["newOrdinary"] = 50
        let result = try plan.applying(to: unrelated)
        XCTAssertEqual(result["other"], 30)
        XCTAssertEqual(result["newOrdinary"], 50)
        for (key, value) in [(divider, 101.0), (control, 201.0), ("upper", 901.0), ("newOrdinary", 4_000.0)] {
            var changed = initial
            changed[key] = value
            XCTAssertThrowsError(try plan.applying(to: changed)) {
                XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .stalePlan)
            }
        }
    }

    func testUnknownLargeRecordIsNotAssumedHiddenAndMissingOrChangedManagedValueIsRejected() throws {
        let initial: [String: Double] = [divider: 100, control: 200, "hidden": 50_000]
        XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions: initial)) {
            XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .noFiniteGap)
        }
        for managed in [["hidden": 50_010.0], ["missing": 50_000.0], ["hidden": 499.0]] {
            XCTAssertThrowsError(try MenuBarOwnBoundaryPlan.prepare(positions: initial, managedHiddenWeights: managed)) {
                XCTAssertEqual($0 as? MenuBarOwnBoundaryPlan.PlanError, .invalidPositions)
            }
        }
        let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions: initial,
            managedHiddenWeights: ["hidden": 50_000]))
        var unexpected = initial
        unexpected["historical-unknown-key"] = 60_000
        XCTAssertThrowsError(try plan.applying(to: unexpected))
    }

    func testNegativeExtremeOrdinaryWeightsStillGiveFiniteSingleKeyPlanAndConditionalRollback() throws {
        let initial = [divider: -Double.greatestFiniteMagnitude, control: -Double.greatestFiniteMagnitude]
        let plan = try XCTUnwrap(MenuBarOwnBoundaryPlan.prepare(positions: initial))
        XCTAssertTrue(plan.writtenWeight.isFinite)
        let restored = try MenuBarPositionPlan.rollback(originalValues: plan.originalValues,
            writtenValues: plan.writtenValues, current: plan.applying(to: initial))
        XCTAssertEqual(restored.restorations, [divider: -Double.greatestFiniteMagnitude])
        let external = try MenuBarPositionPlan.rollback(originalValues: plan.originalValues,
            writtenValues: plan.writtenValues, current: [divider: 123, control: initial[control]!])
        XCTAssertEqual(external.conflictedKeys, [divider])
        XCTAssertTrue(external.restorations.isEmpty)
    }
}
