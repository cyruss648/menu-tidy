import CoreFoundation
import Foundation
import XCTest
@testable import MenuTidyCore

final class MenuBarHiddenLedgerTests: XCTestCase {
    private let key = "status:com.example.item::statusItem"

    private func hidden(original: NSNumber = 930.5, weight: NSNumber = 50_000,
                        key: String? = nil) -> MenuBarHiddenLedger.Entry {
        .init(key: key ?? self.key, originalValue: original, hiddenValue: weight,
              lastAppWrite: weight, mode: .hidden)
    }

    private func firstHide(original: NSNumber = 930.5) -> MenuBarHiddenLedger.Entry {
        MenuBarHiddenLedger.Entry(key: key, originalValue: original, hiddenValue: 50_000,
            lastAppWrite: nil, mode: .original).preparing(.hide, value: 50_000)
    }

    private func roundTrip(_ record: MenuBarHiddenLedger.Entry) throws -> MenuBarHiddenLedger.Entry {
        try XCTUnwrap(MenuBarHiddenLedger.decode(MenuBarHiddenLedger.encode([record])).first)
    }

    func testAllocatesWithoutCollidingWithLiveOrReservedTemporarySlots() throws {
        let revealed = MenuBarHiddenLedger.Entry(key: key, originalValue: 50,
            hiddenValue: 50_010, lastAppWrite: 100, mode: .temporarilyRevealed)
        let value = try MenuBarHiddenLedger.allocateHiddenWeight(
            positions: ["live": 50_000, "temporary": 100, "fraction": 50_015], entries: [revealed])
        XCTAssertEqual(value.doubleValue, 50_020)
    }

    func testAllocationDoesNotRelabelExistingValuesAndHandlesDenseRange() throws {
        let positions = Dictionary(uniqueKeysWithValues: (0..<512).map { ("item\($0)", NSNumber(value: 50_000 + $0 * 10)) })
        XCTAssertEqual(try MenuBarHiddenLedger.allocateHiddenWeight(positions: positions, entries: []).doubleValue, 55_120)
        XCTAssertEqual(positions["item0"], 50_000)
        XCTAssertEqual(positions.count, 512)
    }

    func testOriginalIntegerBeyondDoublePrecisionSurvivesAllTransitions() throws {
        let original = NSNumber(value: Int64(9_007_199_254_740_993))
        let pending = try roundTrip(firstHide(original: original))
        let completed = try XCTUnwrap(pending.completingPending())
        let revealed = try XCTUnwrap(try roundTrip(completed.preparing(.temporarilyReveal, value: 123.25)).completingPending())
        let back = try XCTUnwrap(try roundTrip(revealed.preparing(.restoreTemporaryReveal, value: 50_000)).completingPending())
        XCTAssertEqual(back.originalValue.int64Value, original.int64Value)
        XCTAssertFalse(CFNumberIsFloatType(back.originalValue))
        let restoring = try roundTrip(back.preparing(.restoreOriginal, value: back.originalValue))
        XCTAssertEqual(restoring.pending?.writtenValue.int64Value, original.int64Value)
        XCTAssertNil(restoring.completingPending())
    }

    func testFractionalOriginalIsNotRoundedOrRetyped() throws {
        for original in [NSNumber(value: Float(170.5)), NSNumber(value: Double(170.125))] {
            let recovered = try roundTrip(hidden(original: original))
            XCTAssertTrue(recovered.originalValue.isEqual(to: original))
            XCTAssertEqual(String(cString: recovered.originalValue.objCType), String(cString: original.objCType))
        }
    }

    func testCrashBeforeFirstSystemWriteDoesNotClaimOwnership() {
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: firstHide(), current: 930.5), .notApplied(nil))
    }

    func testCrashAfterFirstSystemWriteRetainsOriginalAndCompletesHiddenState() throws {
        let pending = try roundTrip(firstHide())
        guard case .completed(let recovered) = MenuBarHiddenLedger.recovery(for: pending, current: 50_000) else {
            return XCTFail("The hidden write must be recognized without replaying it")
        }
        let entry = try XCTUnwrap(recovered)
        XCTAssertEqual(entry.originalValue, 930.5)
        XCTAssertEqual(entry.lastAppWrite, 50_000)
        XCTAssertEqual(entry.mode, .hidden)
        XCTAssertNil(entry.pending)
    }

    func testCrashBeforeTemporaryRevealKeepsOriginalHiddenOwnership() {
        let entry = hidden()
        let pending = entry.preparing(.temporarilyReveal, value: 123.5)
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 50_000), .notApplied(entry))
    }

    func testCrashAfterTemporaryRevealPreservesBothReturnDestinations() throws {
        let pending = try roundTrip(hidden().preparing(.temporarilyReveal, value: 123.5))
        guard case .completed(let record) = MenuBarHiddenLedger.recovery(for: pending, current: 123.5) else {
            return XCTFail("Expected a visible temporary placement")
        }
        let entry = try XCTUnwrap(record)
        XCTAssertEqual(entry.mode, .temporarilyRevealed)
        XCTAssertEqual(entry.originalValue, 930.5)
        XCTAssertEqual(entry.hiddenValue, 50_000)
        XCTAssertEqual(entry.lastAppWrite, 123.5)
    }

    func testCrashBeforeAndAfterRehideAreDistinguished() throws {
        let revealed = try XCTUnwrap(hidden().preparing(.temporarilyReveal, value: 123.5).completingPending())
        let pending = try roundTrip(revealed.preparing(.restoreTemporaryReveal, value: 50_000))
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 123.5), .notApplied(revealed))
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 50_000), .completed(hidden()))
    }

    func testCrashDuringFinalRestoreEndsOwnershipOnlyAtOriginalValue() {
        let pending = hidden().preparing(.restoreOriginal, value: 930.5)
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 50_000), .notApplied(hidden()))
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 930.5), .completed(nil))
    }

    func testExternalEditsAreNeverTreatedAsBeforeOrAfterWrite() {
        for pending in [firstHide(), hidden().preparing(.temporarilyReveal, value: 123.5), hidden().preparing(.restoreOriginal, value: 930.5)] {
            XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: 777), .conflicted)
            XCTAssertEqual(MenuBarHiddenLedger.recovery(for: pending, current: nil), .missing)
        }
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: hidden(), current: 777), .conflicted)
    }

    func testSteadyHiddenAndVisibleRecordsRemainOwnedWithoutPendingWork() throws {
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: hidden(), current: 50_000), .unchanged)
        let visible = try XCTUnwrap(hidden().preparing(.temporarilyReveal, value: 123.5).completingPending())
        XCTAssertEqual(MenuBarHiddenLedger.recovery(for: visible, current: 123.5), .unchanged)
        XCTAssertEqual(try roundTrip(visible), visible)
    }

    func testRejectsBooleanAndNonFiniteNumbersEverywhere() {
        for invalid in [NSNumber(value: true), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
            XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(original: invalid)]))
            XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(weight: invalid)]))
            XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden().preparing(.temporarilyReveal, value: invalid)]))
            XCTAssertThrowsError(try MenuBarHiddenLedger.allocateHiddenWeight(positions: [key: invalid], entries: []))
            XCTAssertEqual(MenuBarHiddenLedger.recovery(for: hidden(), current: invalid), .conflicted)
        }
    }

    func testRejectsUnscopedKeysAndDuplicateOwnershipOrReservedSlots() {
        for bad in ["../../file", "status:::x", "status:com.example::", "status:com.example::x\n"] {
            XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(key: bad)]))
        }
        XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(), hidden(weight: 50_010)]))
        XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(), hidden(key: "status:com.other::x")]))
    }

    func testRejectsImpossibleLifecycleStates() {
        let invalid = [
            MenuBarHiddenLedger.Entry(key: key, originalValue: 1, hiddenValue: 50_000, lastAppWrite: nil, mode: .hidden),
            MenuBarHiddenLedger.Entry(key: key, originalValue: 1, hiddenValue: 50_000, lastAppWrite: nil, mode: .original),
            MenuBarHiddenLedger.Entry(key: key, originalValue: 1, hiddenValue: 50_000, lastAppWrite: 50_000, mode: .temporarilyRevealed),
            hidden().preparing(.temporarilyReveal, value: 60_000),
            hidden().preparing(.restoreOriginal, value: 800),
            hidden().preparing(.restoreTemporaryReveal, value: 50_000)
        ]
        for record in invalid { XCTAssertThrowsError(try MenuBarHiddenLedger.encode([record])) }
    }

    func testSchemaCannotRedirectRecoveryOrSmuggleAdditionalFields() throws {
        let data = try MenuBarHiddenLedger.encode([hidden()])
        let original = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for (key, value): (String, Any) in [("relativeDomain", "/tmp/another"), ("applicationID", "other"),
                                           ("preferenceKey", "other"), ("schemaVersion", true), ("backupPath", "/tmp/x")] {
            var modified = original
            modified[key] = value
            let encoded = try PropertyListSerialization.data(fromPropertyList: modified, format: .binary, options: 0)
            XCTAssertThrowsError(try MenuBarHiddenLedger.decode(encoded))
        }
    }

    func testMalformedAndOversizedFilesFailWithoutPartialEntries() throws {
        let data = try MenuBarHiddenLedger.encode([hidden()])
        XCTAssertThrowsError(try MenuBarHiddenLedger.decode(Data(data.prefix(data.count / 2))))
        XCTAssertThrowsError(try MenuBarHiddenLedger.decode(Data(repeating: 0, count: MenuBarHiddenLedger.maximumDataSize + 1)))
        XCTAssertTrue(try MenuBarHiddenLedger.decode(MenuBarHiddenLedger.encode([])).isEmpty)
    }
}
