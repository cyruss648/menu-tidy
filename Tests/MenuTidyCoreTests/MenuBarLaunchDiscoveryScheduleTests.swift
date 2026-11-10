import XCTest
@testable import MenuTidyCore

final class MenuBarLaunchDiscoveryScheduleTests: XCTestCase {
    func testDelayedStatusCreationHasABoundedReadWindow() {
        var schedule = MenuBarLaunchDiscoverySchedule<String>()
        schedule.register("epoch-a", at: 100)
        XCTAssertEqual(schedule.nextAttemptAt, 101)
        XCTAssertFalse(schedule.consumeDue(at: 100.9))
        for (now, next) in [(101.0, 103.0), (103, 107), (107, 115)] {
            XCTAssertTrue(schedule.consumeDue(at: now))
            XCTAssertEqual(schedule.nextAttemptAt, next)
        }
        XCTAssertTrue(schedule.consumeDue(at: 115))
        XCTAssertNil(schedule.nextAttemptAt)
        XCTAssertTrue(schedule.targets.isEmpty)
        XCTAssertFalse(schedule.consumeDue(at: 1000))
    }

    func testSuccessOrTerminationRetiresOnlyThatProcessLifetime() {
        var schedule = MenuBarLaunchDiscoverySchedule<String>()
        for owner in ["old", "new", "other"] { schedule.register(owner, at: 100) }
        schedule.reconcile(current: ["new", "other"], observed: ["other"])
        XCTAssertEqual(schedule.targets, ["new"])
    }

    func testRepeatedNotificationDoesNotExtendTheRetryWindow() {
        var schedule = MenuBarLaunchDiscoverySchedule<String>()
        schedule.register("owner", at: 100)
        schedule.register("owner", at: 114)
        XCTAssertTrue(schedule.consumeDue(at: 115))
        XCTAssertNil(schedule.nextAttemptAt)
    }

    func testLongPauseCoalescesOverdueReadsInsteadOfReplayingThem() {
        var schedule = MenuBarLaunchDiscoverySchedule<String>()
        schedule.register("owner", at: 100)
        XCTAssertTrue(schedule.consumeDue(at: 114))
        XCTAssertEqual(schedule.nextAttemptAt, 115)
        XCTAssertFalse(schedule.consumeDue(at: 114))
    }

    func testNonFiniteClockCannotCreateUnboundedWork() {
        var schedule = MenuBarLaunchDiscoverySchedule<String>()
        schedule.register("owner", at: .nan)
        XCTAssertNil(schedule.nextAttemptAt)
        schedule.register("owner", at: 100)
        XCTAssertFalse(schedule.consumeDue(at: .infinity))
        XCTAssertEqual(schedule.nextAttemptAt, 101)
    }
}
