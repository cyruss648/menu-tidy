import XCTest
@testable import MenuTidyCore

final class PendingApplicationIntervalTests: XCTestCase {
    func testCorruptAndUnsupportedValuesUseFiveMinutes() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 59, 120, 3601] {
            XCTAssertEqual(PendingApplicationInterval.validated(value), 300)
        }
        for value in PendingApplicationInterval.choices { XCTAssertEqual(PendingApplicationInterval.validated(value), value) }
    }

    func testPeriodicDeadlineSharesTheExistingMaintenanceTimer() {
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 100, autoCollapseDue: nil,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil, periodicApplicationDue: 400), 300)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 100, autoCollapseDue: 101,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil, periodicApplicationDue: 400), 1)
        XCTAssertEqual(BackgroundMaintenanceSchedule.nextDelay(at: 500, autoCollapseDue: nil,
            permissionDue: nil, passiveCaptureDue: nil, recoveryDue: nil, periodicApplicationDue: 400), 0.05)
    }
}
