import XCTest
@testable import MenuTidyCore

final class BatchApplicationPlanTests: XCTestCase {
    func testOneUnsupportedItemDoesNotPreventOtherSeventeenFromApplying() throws {
        let requested = (1...18).map { "item-\($0)" }
        let blocked = "item-4"
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: requested,
            supportedIDs: Set(requested).subtracting([blocked]),
            issues: [blocked: "Multiple position keys cannot be safely matched."]))

        XCTAssertEqual(plan.actionableIDs, requested.filter { $0 != blocked })
        XCTAssertEqual(plan.blockedIDs, [blocked])
        XCTAssertEqual(plan.issues.count, 1)
        XCTAssertTrue(plan.isPreflightComplete)
        XCTAssertTrue(plan.uninspectedIDs.isEmpty)
    }

    func testTimeoutPreservesOnlyObservedIssuesAndNeverAppliesTheInspectedSubset() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: ["supported", "blocked", "unread"],
            supportedIDs: ["supported"], issues: ["blocked": "Ambiguous key"], stopReason: .timedOut))

        XCTAssertTrue(plan.actionableIDs.isEmpty)
        XCTAssertEqual(plan.supportedIDs, ["supported"])
        XCTAssertEqual(plan.blockedIDs, ["blocked"])
        XCTAssertEqual(plan.uninspectedIDs, ["unread"])
        XCTAssertNil(plan.issues["unread"])
        XCTAssertEqual(plan.stopReason, .timedOut)
        XCTAssertFalse(plan.isPreflightComplete)
    }

    func testCancellationWinsEvenAfterEveryCapabilityCheckFinished() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: ["a", "b"],
            supportedIDs: ["a", "b"], issues: [:], stopReason: .cancelled))

        XCTAssertTrue(plan.isPreflightComplete)
        XCTAssertEqual(plan.supportedIDs, ["a", "b"])
        XCTAssertTrue(plan.actionableIDs.isEmpty)
        XCTAssertTrue(plan.blockedIDs.isEmpty)
    }

    func testIncompleteChecksCannotAccidentallyAuthorizeWrites() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: ["a", "b"],
            supportedIDs: ["a"], issues: [:]))

        XCTAssertFalse(plan.isPreflightComplete)
        XCTAssertEqual(plan.uninspectedIDs, ["b"])
        XCTAssertTrue(plan.actionableIDs.isEmpty)
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testBlockedItemsKeepSeparateReasonsAndRequestOrder() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: ["z", "a", "m"],
            supportedIDs: ["a"], issues: ["m": "Source disappeared", "z": "Ambiguous key"]))

        XCTAssertEqual(plan.actionableIDs, ["a"])
        XCTAssertEqual(plan.blockedIDs, ["z", "m"])
        XCTAssertEqual(plan.issues["z"], "Ambiguous key")
        XCTAssertEqual(plan.issues["m"], "Source disappeared")
    }

    func testEveryItemBlockedIsCompleteButAuthorizesNoWrites() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: ["a", "b"],
            supportedIDs: [], issues: ["a": "Unsupported", "b": "Ambiguous key"]))

        XCTAssertTrue(plan.isPreflightComplete)
        XCTAssertTrue(plan.actionableIDs.isEmpty)
        XCTAssertEqual(plan.blockedIDs, ["a", "b"])
    }

    func testStaleConflictingAndDuplicateInputsAreRejected() {
        XCTAssertNil(BatchApplicationPlan(requestedIDs: ["a"], supportedIDs: ["other"], issues: [:]))
        XCTAssertNil(BatchApplicationPlan(requestedIDs: ["a"], supportedIDs: [], issues: ["other": "Stale issue"]))
        XCTAssertNil(BatchApplicationPlan(requestedIDs: ["a"], supportedIDs: ["a"], issues: ["a": "Conflicting verdict"]))
        XCTAssertNil(BatchApplicationPlan(requestedIDs: ["a", "a"], supportedIDs: ["a"], issues: [:]))
        XCTAssertNil(BatchApplicationPlan(requestedIDs: [""], supportedIDs: [""], issues: [:]))
    }

    func testEmptyRequestDoesNotInventWorkOrUnsupportedItems() throws {
        let plan = try XCTUnwrap(BatchApplicationPlan(requestedIDs: [], supportedIDs: [], issues: [:]))
        XCTAssertTrue(plan.actionableIDs.isEmpty)
        XCTAssertTrue(plan.blockedIDs.isEmpty)
        XCTAssertTrue(plan.uninspectedIDs.isEmpty)
    }
}
