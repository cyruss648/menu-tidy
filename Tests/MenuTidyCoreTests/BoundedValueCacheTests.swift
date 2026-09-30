import XCTest
@testable import MenuTidyCore

final class BoundedValueCacheTests: XCTestCase {
    func testLeastRecentlyUsedEvictionAndCostLimit() {
        var cache = BoundedValueCache<String, Int>(countLimit: 2, costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.totalCost, 8)
        cache.insert(4, for: "large", cost: 9)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 9)
    }

    func testReplacementOversizeAndPressureClear() {
        var cache = BoundedValueCache<String, Int>(countLimit: 3, costLimit: 10)
        cache.insert(1, for: "a", cost: 5)
        cache.insert(2, for: "a", cost: 2)
        XCTAssertEqual(cache.totalCost, 2)
        cache.insert(3, for: "a", cost: 11)
        XCTAssertEqual(cache.value(for: "a"), 2)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testDisabledCacheAndOverflowSafeAccounting() {
        var disabled = BoundedValueCache<String, Int>(countLimit: 0, costLimit: 0)
        disabled.insert(1, for: "a", cost: 0)
        XCTAssertEqual(disabled.count, 0)
        var huge = BoundedValueCache<String, Int>(countLimit: 2, costLimit: .max)
        huge.insert(1, for: "a", cost: .max)
        huge.insert(2, for: "b", cost: 1)
        XCTAssertNil(huge.value(for: "a"))
        XCTAssertEqual(huge.totalCost, 1)
    }
}
