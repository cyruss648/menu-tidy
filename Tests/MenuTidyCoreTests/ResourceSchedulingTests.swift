import XCTest
@testable import MenuTidyCore

final class ResourceSchedulingTests: XCTestCase {
    func testMissingImagesBackOffAndStopWhenComplete() {
        var schedule = PassiveIconCaptureSchedule()
        schedule.updateMissingIDs(["hidden"], at: 100)
        XCTAssertFalse(schedule.isDue(at: 101.9))
        XCTAssertTrue(schedule.isDue(at: 102))
        var now = 102.0
        for delay in [5.0, 15, 30, 30] {
            schedule.finishAttempt(generation: schedule.generation, madeProgress: false, cancelled: false, at: now)
            XCTAssertEqual(schedule.nextAttemptAt, now + delay)
            now += delay
        }
        schedule.updateMissingIDs([], at: now)
        XCTAssertNil(schedule.nextAttemptAt)
        XCTAssertFalse(schedule.isDue(at: now + 300))
    }

    func testEventCannotBePostponedByOlderAttempt() {
        var schedule = PassiveIconCaptureSchedule()
        schedule.updateMissingIDs(["hidden"], at: 0)
        let attempt = schedule.generation
        schedule.requestAfterEvent(at: 3)
        schedule.finishAttempt(generation: attempt, madeProgress: false, cancelled: false, at: 4)
        XCTAssertEqual(schedule.nextAttemptAt, 3)
        XCTAssertTrue(schedule.isDue(at: 4))
    }

    func testChangedCandidatesAndCancellationResetBackoff() {
        var schedule = PassiveIconCaptureSchedule()
        schedule.updateMissingIDs(["a", "b"], at: 0)
        schedule.finishAttempt(generation: schedule.generation, madeProgress: false, cancelled: false, at: 2)
        let oldAttempt = schedule.generation
        schedule.updateMissingIDs(["b"], at: 3)
        schedule.finishAttempt(generation: oldAttempt, madeProgress: false, cancelled: false, at: 4)
        XCTAssertEqual(schedule.nextAttemptAt, 5)
        schedule.finishAttempt(generation: schedule.generation, madeProgress: false, cancelled: true, at: 5)
        XCTAssertEqual(schedule.nextAttemptAt, 7)
        schedule.finishAttempt(generation: schedule.generation, madeProgress: true, cancelled: false, at: 7)
        XCTAssertEqual(schedule.nextAttemptAt, 9)
    }

    func testUnchangedInventoryDoesNotRestartRetries() {
        var schedule = PassiveIconCaptureSchedule()
        schedule.updateMissingIDs(["a"], at: 0)
        schedule.finishAttempt(generation: schedule.generation, madeProgress: false, cancelled: false, at: 2)
        schedule.updateMissingIDs(["a"], at: 6)
        XCTAssertEqual(schedule.nextAttemptAt, 7)
        XCTAssertFalse(schedule.isDue(at: .infinity))
    }

    func testTimerUsesEarliestRequiredDeadlineAndCanStop() {
        XCTAssertNil(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: nil,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil))
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: nil,
            permissionDue: 13, passiveCaptureDue: 40, recoveryDue: nil), 3)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: 11,
            permissionDue: 13, passiveCaptureDue: 40, recoveryDue: 12), 1)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: nil,
            permissionDue: nil, passiveCaptureDue: 9, recoveryDue: nil), 0.05)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: nil,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil, startupApplicationDue: 40), 30)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 10, autoCollapseDue: 11,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil, startupApplicationDue: 40), 1)
        XCTAssertEqual(BackgroundMaintenanceSchedule.tolerance(for: 30), 1)
        XCTAssertEqual(BackgroundMaintenanceSchedule.tolerance(for: 1), 0.1)
    }
}
