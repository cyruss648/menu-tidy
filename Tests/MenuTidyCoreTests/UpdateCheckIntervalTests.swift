import XCTest
@testable import MenuTidyCore

final class UpdateCheckIntervalTests: XCTestCase {
    func testUnsupportedValuesUseThirtyMinutes() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 60, 120, 7200] {
            XCTAssertEqual(UpdateCheckInterval.validated(value), 1800)
        }
        for value in UpdateCheckInterval.choices {
            XCTAssertEqual(UpdateCheckInterval.validated(value), value)
        }
    }

    func testDelayWaitsTheRemainderAndRetriesOverdueChecksPromptly() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(UpdateCheckInterval.delay(since: nil, interval: 300, now: now), 1)
        XCTAssertEqual(UpdateCheckInterval.delay(since: now.addingTimeInterval(-600), interval: 1800, now: now), 1200)
        XCTAssertEqual(UpdateCheckInterval.delay(since: now.addingTimeInterval(-1801), interval: 1800, now: now), 1)
        XCTAssertEqual(UpdateCheckInterval.delay(since: now.addingTimeInterval(10), interval: 300, now: now), 300)
        XCTAssertEqual(UpdateCheckInterval.delay(since: Date(timeIntervalSince1970: .nan), interval: 300, now: now), 300)
    }
}
