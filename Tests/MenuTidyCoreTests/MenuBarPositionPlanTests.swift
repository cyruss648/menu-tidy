import XCTest
@testable import MenuTidyCore

final class MenuBarPositionPlanTests: XCTestCase {
    func testAfterPlacesSourceRightOfEntireEqualWeightGroupWithoutChangingPeers() throws {
        let positions: [String: Double] = ["source": 900, "anchor": 170.5, "anchorPeer": 170.5,
            "lower": 100.25, "lowerPeer": 100.25, "external": 30]
        let plan = try MenuBarPositionPlan.moving("source", after: "anchor", positions: positions)
        XCTAssertEqual(plan.placement, .after)
        XCTAssertEqual(plan.lowerWeight, 100.25)
        XCTAssertEqual(plan.writtenWeight, 135.375)
        let result = try plan.applying(to: positions)
        XCTAssertEqual(result.filter { $0.key != "source" }, positions.filter { $0.key != "source" })
        XCTAssertLessThan(result["source"]!, result["anchor"]!)
        XCTAssertGreaterThan(result["source"]!, result["lower"]!)
    }

    func testAfterExcludesSourceAndUsesFinitePredecessorAtRightmostEnd() throws {
        let plan = try MenuBarPositionPlan.moving("source", after: "anchor", positions: ["source": 50, "anchor": 100])
        XCTAssertNil(plan.lowerWeight)
        XCTAssertEqual(plan.writtenWeight, Double(100).nextDown)
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", after: "anchor",
            positions: ["source": 0, "anchor": -Double.greatestFiniteMagnitude])) {
            XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .noFiniteGap)
        }
    }

    func testAfterExtremeBoundsAndRepresentableGap() throws {
        let extreme = try MenuBarPositionPlan.moving("source", after: "anchor",
            positions: ["source": 1, "lower": -Double.greatestFiniteMagnitude, "anchor": Double.greatestFiniteMagnitude])
        XCTAssertEqual(extreme.writtenWeight, 0)
        let interior = Double(1).nextDown
        let narrow = try MenuBarPositionPlan.moving("source", after: "anchor",
            positions: ["source": 2, "lower": interior.nextDown, "anchor": 1])
        XCTAssertEqual(narrow.writtenWeight, interior)
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", after: "anchor",
            positions: ["source": 2, "lower": interior, "anchor": 1])) {
            XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .noFiniteGap)
        }
    }

    func testAfterFreshValidationChecksLowerBoundaryAndPreservesUnrelatedChanges() throws {
        let original: [String: Double] = ["source": 300, "anchor": 100, "lower": 50, "far": 500]
        let plan = try MenuBarPositionPlan.moving("source", after: "anchor", positions: original)
        var unrelated = original
        unrelated["far"] = 600
        XCTAssertEqual(try plan.applying(to: unrelated)["far"], 600)
        for (key, value) in [("source", 301.0), ("anchor", 101.0), ("lower", 49.0), ("newLower", 80.0)] {
            var fresh = original
            fresh[key] = value
            XCTAssertThrowsError(try plan.applying(to: fresh)) {
                XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .stalePlan)
            }
        }
    }

    func testAfterRejectsMissingKeysAndNonfiniteUnrelatedValue() {
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", after: "anchor", positions: [:]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("missing", after: "anchor", positions: ["anchor": 1]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", after: "missing", positions: ["source": 1]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("same", after: "same", positions: ["same": 1]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", after: "anchor",
            positions: ["source": 1, "anchor": 2, "other": .nan]))
    }

    func testFractionalWeightsPlaceSourceVisuallyLeftWithoutChangingPeers() throws {
        let positions = ["source": 541.0, "anchor": 170.5, "upper": 200.25, "other": 856.0]
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor", positions: positions)
        let result = try plan.applying(to: positions)
        XCTAssertEqual(plan.writtenWeight, 185.375)
        XCTAssertGreaterThan(result["source"]!, result["anchor"]!)
        XCTAssertLessThan(result["source"]!, result["upper"]!)
        XCTAssertEqual(result.filter { $0.key != "source" }, positions.filter { $0.key != "source" })
        XCTAssertEqual(plan.originalValues, ["source": 541.0])
        XCTAssertEqual(plan.writtenValues, ["source": 185.375])
    }

    func testOriginalSourceSlotDoesNotActAsItsOwnUpperBoundary() throws {
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": 120, "anchor": 100, "upper": 300])
        XCTAssertEqual(plan.upperWeight, 300)
        XCTAssertEqual(plan.writtenWeight, 200)
    }

    func testDuplicateBoundaryWeightsAreOneGroupAndAllDuplicatesStayUntouched() throws {
        let positions: [String: Double] = ["source": 50, "anchor": 100, "anchorPeer": 100,
            "upper": 200, "upperPeer": 200, "far": 900, "farPeer": 900]
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor", positions: positions)
        XCTAssertEqual(plan.writtenWeight, 150)
        let result = try plan.applying(to: positions)
        XCTAssertEqual(result.filter { $0.key != "source" }, positions.filter { $0.key != "source" })
    }

    func testOppositeExtremeBoundsUseFiniteMidpointWithoutOverflow() throws {
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": -1, "anchor": -Double.greatestFiniteMagnitude, "upper": Double.greatestFiniteMagnitude])
        XCTAssertEqual(plan.writtenWeight, 0)
        XCTAssertTrue(plan.writtenWeight.isFinite)
    }

    func testAdjacentRepresentableBoundsHaveNoInteriorAndAreRejected() {
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": 0, "anchor": 1, "upper": Double(1).nextUp])) {
            XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .noFiniteGap)
        }
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": -1, "anchor": 0, "upper": Double.leastNonzeroMagnitude]))
    }

    func testOneRepresentableInteriorValueIsUsedExactly() throws {
        let interior = Double(1).nextUp
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": 0, "anchor": 1, "upper": interior.nextUp])
        XCTAssertEqual(plan.writtenWeight, interior)
    }

    func testLeftmostAnchorRequiresFiniteSuccessor() throws {
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor", positions: ["source": 1, "anchor": 100])
        XCTAssertNil(plan.upperWeight)
        XCTAssertEqual(plan.writtenWeight, Double(100).nextUp)
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "anchor",
            positions: ["source": 0, "anchor": Double.greatestFiniteMagnitude])) {
            XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .noFiniteGap)
        }
    }

    func testMissingOrIdenticalKeysCannotInventNewPositionRecords() {
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "anchor", positions: [:]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("missing", before: "anchor", positions: ["anchor": 100]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "missing", positions: ["source": 100]))
        XCTAssertThrowsError(try MenuBarPositionPlan.moving("same", before: "same", positions: ["same": 100]))
    }

    func testNonfiniteValueAnywhereRejectsPlanning() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try MenuBarPositionPlan.moving("source", before: "anchor",
                positions: ["source": 1, "anchor": 100, "unrelated": value]))
        }
    }

    func testFreshMergeKeepsUnrelatedExternalChanges() throws {
        let initial: [String: Double] = ["source": 1, "anchor": 100, "upper": 200, "external": 500]
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor", positions: initial)
        var fresh = initial
        fresh["external"] = 600.75
        fresh["newExternal"] = 800.25
        let merged = try plan.applying(to: fresh)
        XCTAssertEqual(merged["external"], 600.75)
        XCTAssertEqual(merged["newExternal"], 800.25)
        XCTAssertEqual(merged["source"], 150)
    }

    func testChangedSourceAnchorOrGapInvalidatesPreparedPlan() throws {
        let initial: [String: Double] = ["source": 1, "anchor": 100, "upper": 200]
        let plan = try MenuBarPositionPlan.moving("source", before: "anchor", positions: initial)
        for (key, value) in [("source", 2.0), ("anchor", 101.0), ("upper", 201.0), ("newNeighbor", 150.0)] {
            var fresh = initial
            fresh[key] = value
            XCTAssertThrowsError(try plan.applying(to: fresh)) {
                XCTAssertEqual($0 as? MenuBarPositionPlan.PlanError, .stalePlan)
            }
        }
    }

    func testConditionalRollbackRestoresOnlyStillOwnedValues() throws {
        let rollback = try MenuBarPositionPlan.rollback(
            originalValues: ["owned": 10.5, "conflict": 20.25, "missing": 30.75, "already": 40.5],
            writtenValues: ["owned": 100.5, "conflict": 200.25, "missing": 300.75, "already": 400.5],
            current: ["owned": 100.5, "conflict": 999, "already": 40.5, "unrelated": 7.25])
        XCTAssertEqual(rollback.restorations, ["owned": 10.5])
        XCTAssertEqual(rollback.conflictedKeys, ["conflict"])
        XCTAssertEqual(rollback.missingKeys, ["missing"])
        XCTAssertEqual(rollback.alreadyRestoredKeys, ["already"])
    }

    func testRepeatedRollbackAndNoopWritesRequireNoAdditionalMutation() throws {
        let rollback = try MenuBarPositionPlan.rollback(originalValues: ["source": 170.5],
            writtenValues: ["source": 170.5], current: ["source": 170.5, "untouched": 930])
        XCTAssertTrue(rollback.restorations.isEmpty)
        XCTAssertEqual(rollback.alreadyRestoredKeys, ["source"])
        XCTAssertTrue(rollback.conflictedKeys.isEmpty)
    }

    func testMalformedRollbackCannotTouchUnlistedOrNonfiniteValues() {
        XCTAssertThrowsError(try MenuBarPositionPlan.rollback(originalValues: ["a": 1], writtenValues: ["b": 2], current: ["b": 2]))
        XCTAssertThrowsError(try MenuBarPositionPlan.rollback(originalValues: [:], writtenValues: [:], current: ["a": 1]))
        XCTAssertThrowsError(try MenuBarPositionPlan.rollback(originalValues: ["a": 1], writtenValues: ["a": 2], current: ["a": .nan]))
    }
}
