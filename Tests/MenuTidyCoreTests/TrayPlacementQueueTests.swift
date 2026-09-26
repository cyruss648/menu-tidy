import Foundation
import XCTest
@testable import MenuTidyCore

final class TrayPlacementQueueTests: XCTestCase {
    func testRapidChoicesCoalesceToLatestWithoutDuplicateWork() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        queue.enqueue(id: "a", desiredInTray: false)
        queue.enqueue(id: "a", desiredInTray: true)

        XCTAssertEqual(queue.pendingIDs, ["a"])
        XCTAssertEqual(queue.desired(id: "a"), true)
        let request = try XCTUnwrap(queue.claimNext())
        XCTAssertTrue(request.desiredInTray)
        XCTAssertTrue(queue.finish(token: request.token))
        XCTAssertNil(queue.claimNext())
    }

    func testUpdatingPendingChoicePreservesFirstQueuedOrder() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        queue.enqueue(id: "b", desiredInTray: true)
        queue.enqueue(id: "a", desiredInTray: false)

        XCTAssertEqual(queue.pendingIDs, ["a", "b"])
        let first = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(first.id, "a")
        XCTAssertFalse(first.desiredInTray)
        queue.finish(token: first.token)
        XCTAssertEqual(queue.claimNext()?.id, "b")
    }

    func testActiveClaimPreventsSecondNativeOperation() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        queue.enqueue(id: "b", desiredInTray: false)
        let first = try XCTUnwrap(queue.claimNext())

        XCTAssertEqual(queue.active, first)
        XCTAssertNil(queue.claimNext())
        XCTAssertEqual(queue.pendingIDs, ["b"])
        XCTAssertEqual(queue.desired(id: "a"), true)
        XCTAssertEqual(queue.desired(id: "b"), false)
        XCTAssertNil(queue.desired(id: "unrequested"))
    }

    func testCompletionCannotEraseNewerChoiceForSameItem() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let active = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "a", desiredInTray: false)

        XCTAssertTrue(active.desiredInTray)
        XCTAssertEqual(queue.active, active)
        XCTAssertEqual(queue.desired(id: "a"), false)
        XCTAssertTrue(queue.finish(token: active.token))
        XCTAssertEqual(queue.desired(id: "a"), false)
        let next = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(next.id, "a")
        XCTAssertFalse(next.desiredInTray)
        XCTAssertNotEqual(next.token, active.token)
    }

    func testChangesToActiveItemJoinQueueBehindEarlierOtherItems() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let active = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "b", desiredInTray: false)
        queue.enqueue(id: "a", desiredInTray: false)
        queue.enqueue(id: "c", desiredInTray: true)
        queue.enqueue(id: "a", desiredInTray: true)

        XCTAssertEqual(queue.pendingIDs, ["b", "a", "c"])
        XCTAssertEqual(queue.desired(id: "a"), true)
        queue.finish(token: active.token)
        let next = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(next.id, "b")
        queue.finish(token: next.token)
        XCTAssertEqual(queue.claimNext()?.id, "a")
    }

    func testFailedRequestDoesNotAutomaticallyRetryButLaterIntentSurvives() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let failed = try XCTUnwrap(queue.claimNext())
        queue.finish(token: failed.token)
        XCTAssertNil(queue.claimNext())
        XCTAssertNil(queue.desired(id: "a"))

        queue.enqueue(id: "a", desiredInTray: true)
        let secondFailure = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "a", desiredInTray: false)
        queue.enqueue(id: "a", desiredInTray: true)
        queue.finish(token: secondFailure.token)
        let explicitLaterIntent = try XCTUnwrap(queue.claimNext())
        XCTAssertTrue(explicitLaterIntent.desiredInTray)
        XCTAssertNotEqual(explicitLaterIntent.token, secondFailure.token)
        queue.finish(token: explicitLaterIntent.token)
        XCTAssertNil(queue.claimNext())
    }

    func testLateCompletionCannotReleaseNewActiveRequestOrChangeItsPendingIntent() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let old = try XCTUnwrap(queue.claimNext())
        queue.finish(token: old.token)
        queue.enqueue(id: "a", desiredInTray: false)
        let current = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "a", desiredInTray: true)

        XCTAssertFalse(queue.finish(token: old.token))
        XCTAssertFalse(queue.finish(token: UUID()))
        XCTAssertEqual(queue.active, current)
        XCTAssertEqual(queue.desired(id: "a"), true)
        XCTAssertEqual(queue.pendingIDs, ["a"])
        XCTAssertNil(queue.claimNext())
    }

    func testCancelPendingDoesNotUnlockActiveOperationBeforeCleanup() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let active = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "a", desiredInTray: false)
        queue.enqueue(id: "b", desiredInTray: true)
        queue.cancelAllPending()

        XCTAssertTrue(queue.pendingIDs.isEmpty)
        XCTAssertEqual(queue.active, active)
        XCTAssertEqual(queue.desired(id: "a"), true)
        XCTAssertNil(queue.desired(id: "b"))
        XCTAssertNil(queue.claimNext())
        queue.finish(token: active.token)
        XCTAssertNil(queue.claimNext())
        XCTAssertNil(queue.desired(id: "a"))
    }

    func testNewIntentAfterStopWaitsForOldCleanupAndThenRunsOnce() throws {
        var queue = TrayPlacementQueue()
        queue.enqueue(id: "a", desiredInTray: true)
        let stopping = try XCTUnwrap(queue.claimNext())
        queue.enqueue(id: "b", desiredInTray: true)
        queue.cancelAllPending()
        queue.enqueue(id: "a", desiredInTray: false)

        XCTAssertNil(queue.claimNext())
        XCTAssertEqual(queue.desired(id: "a"), false)
        queue.finish(token: stopping.token)
        let next = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(next.id, "a")
        XCTAssertFalse(next.desiredInTray)
        queue.finish(token: next.token)
        XCTAssertNil(queue.claimNext())
    }

    func testEmptyQueueAndRepeatedFinishRemainIdle() throws {
        var queue = TrayPlacementQueue()
        XCTAssertNil(queue.active)
        XCTAssertNil(queue.claimNext())
        XCTAssertNil(queue.desired(id: "a"))
        XCTAssertFalse(queue.finish(token: UUID()))
        queue.cancelAllPending()
        queue.enqueue(id: "a", desiredInTray: false)
        let request = try XCTUnwrap(queue.claimNext())
        XCTAssertTrue(queue.finish(token: request.token))
        XCTAssertFalse(queue.finish(token: request.token))
        XCTAssertTrue(queue.pendingIDs.isEmpty)
        XCTAssertNil(queue.active)
    }
}
