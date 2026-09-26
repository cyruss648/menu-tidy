import Foundation
import XCTest
@testable import MenuTidyCore

final class ManagementOperationStateTests: XCTestCase {
    func testCancellingKeepsOperationAndDeadlineUntilCleanupFinishes() {
        var state = ManagementOperationState()
        let token = state.begin(kind: .apply, itemCount: 2, at: Date(timeIntervalSince1970: 0), uptime: 100)
        XCTAssertTrue(state.requestCancellation())
        XCTAssertFalse(state.requestCancellation())
        XCTAssertEqual(state.active?.id, token)
        XCTAssertEqual(state.active?.cancellationRequested, true)
        XCTAssertEqual(state.active?.deadline, 112)
        XCTAssertTrue(state.finish(token: token))
        XCTAssertNil(state.active)
    }

    func testLateCompletionCannotUnlockNewRequest() {
        var state = ManagementOperationState()
        let old = state.begin(kind: .refresh, at: .distantPast, uptime: 100)
        let current = state.begin(kind: .apply, at: .distantFuture, uptime: 101)
        XCTAssertFalse(state.finish(token: old))
        XCTAssertEqual(state.active?.id, current)
        XCTAssertTrue(state.finish(token: current))
        XCTAssertFalse(state.finish(token: current))
    }

    func testDeadlineDoesNotResetAcrossChecksOrClockChanges() {
        var state = ManagementOperationState()
        state.begin(kind: .refresh, at: .distantFuture, uptime: 100)
        XCTAssertFalse(state.hasExpired(uptime: 105.99))
        XCTAssertTrue(state.hasExpired(uptime: 106))
        XCTAssertTrue(state.hasExpired(uptime: 500))
        XCTAssertEqual(state.active?.deadline, 106)
        XCTAssertEqual(state.elapsed(uptime: 105), 5)
        XCTAssertEqual(state.elapsed(uptime: 99), 0)
    }

    func testForegroundBudgetsRemainBoundedForLargeOrInvalidItemCounts() {
        XCTAssertEqual(ManagementOperationKind.refresh.timeLimit(itemCount: 1_000), 6)
        XCTAssertEqual(ManagementOperationKind.refreshImages.timeLimit(itemCount: 1_000), 30)
        XCTAssertEqual(ManagementOperationKind.apply.timeLimit(itemCount: -1), 12)
        XCTAssertEqual(ManagementOperationKind.apply.timeLimit(itemCount: 4), 14)
        XCTAssertEqual(ManagementOperationKind.apply.timeLimit(itemCount: 1_000), 20)
    }

    func testIdleStateDoesNotExposeCancellationOrExpiry() {
        var state = ManagementOperationState()
        XCTAssertFalse(state.requestCancellation())
        XCTAssertFalse(state.hasExpired(uptime: .greatestFiniteMagnitude))
        XCTAssertEqual(state.elapsed(uptime: 100), 0)
    }

    func testCleanupRetainsLocalVerificationTimeAfterForegroundExpires() {
        XCTAssertEqual(ManagementOperationBudget.foreground.deadline(startedUptime: 100,
            timeLimit: 3, operationDeadline: 99), 99)
        XCTAssertEqual(ManagementOperationBudget.cleanup.deadline(startedUptime: 100,
            timeLimit: 3, operationDeadline: 99), 103)
    }

    func testCleanupDoesNotExtendItsExplicitLocalOrOuterLimit() {
        XCTAssertEqual(ManagementOperationBudget.cleanup.deadline(startedUptime: 100,
            timeLimit: 3, operationDeadline: 500), 103)
        XCTAssertEqual(ManagementOperationBudget.cleanup.deadline(startedUptime: 100,
            timeLimit: 3, operationDeadline: 99, outerDeadline: 102), 102)
        XCTAssertEqual(ManagementOperationBudget.foreground.deadline(startedUptime: 100,
            timeLimit: 3, operationDeadline: 101, outerDeadline: 102), 101)
    }
}
