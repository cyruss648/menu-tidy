import XCTest
@testable import MenuTidyCore

final class AccessibilityScanBudgetTests: XCTestCase {
    func testDescendantReadsShareOneDeadline() {
        let budget = AccessibilityScanBudget(startedAt: 100)
        XCTAssertEqual(budget.timeout(at: 100), 0.12)
        XCTAssertEqual(budget.timeout(at: 102), 0.12)
        XCTAssertEqual(budget.timeout(at: 102.95) ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertNil(budget.timeout(at: 103))
        XCTAssertFalse(budget.canPublish(at: 103))
    }

    func testCancellationCannotPublishAnIncompleteInventory() {
        let budget = AccessibilityScanBudget(startedAt: 1)
        XCTAssertNil(budget.timeout(at: 1.1, cancelled: true))
        XCTAssertFalse(budget.canPublish(at: 1.1, cancelled: true))
        XCTAssertTrue(budget.canPublish(at: 1.1))
    }

    func testExpiredAndInvalidBudgetsFailClosed() {
        XCTAssertNil(AccessibilityScanBudget(startedAt: 1, duration: -1).timeout(at: 1))
        XCTAssertNil(AccessibilityScanBudget(startedAt: .infinity).timeout(at: 1))
        XCTAssertFalse(AccessibilityScanBudget(startedAt: 1).canPublish(at: .nan))
    }
}
