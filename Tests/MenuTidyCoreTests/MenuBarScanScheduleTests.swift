import XCTest
@testable import MenuTidyCore

final class MenuBarScanScheduleTests: XCTestCase {
    func testPrioritiesAndNewOwnersAreScannedBeforeNegativeOwners() {
        var schedule = MenuBarScanSchedule<Int>(batchSize: 2)

        let first = schedule.plan(current: [1, 2, 3, 4, 5], priority: [1, 5], discover: true)
        XCTAssertEqual(first, [1, 5, 2, 3])

        schedule.complete(scanned: first)
        let second = schedule.plan(current: [1, 2, 3, 4, 5], priority: [1, 5], discover: true)
        XCTAssertEqual(second, [1, 5, 4])
    }

    func testNewOwnerIsPromotedAndMissingOwnerIsDropped() {
        var schedule = MenuBarScanSchedule<Int>(batchSize: 2)
        _ = schedule.plan(current: [1, 2, 3], priority: [1], discover: true)
        schedule.complete(scanned: [1, 2, 3])

        let next = schedule.plan(current: [1, 2, 4], priority: [1], discover: true)
        XCTAssertEqual(next, [1, 4])
        XCTAssertFalse(next.contains(3))
    }

    func testPassiveRebindOnlyUsesPriorityOwners() {
        var schedule = MenuBarScanSchedule<Int>(batchSize: 8)
        let selected = schedule.plan(current: [1, 2, 3], priority: [2], discover: false)
        XCTAssertEqual(selected, [2])
    }
}
