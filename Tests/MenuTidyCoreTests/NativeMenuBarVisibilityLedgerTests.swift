import Foundation
import XCTest
@testable import MenuTidyCore

final class NativeMenuBarVisibilityLedgerTests: XCTestCase {
    private typealias Ledger = NativeMenuBarVisibilityLedger
    private typealias Codec = NativeMenuBarVisibilityCodec
    private let bundle = "dev.fixture.Target"

    private func record(_ allowed: Bool = true, extra: String = "original") throws -> Data {
        let location: [String: Any] = ["bundle": ["_0": bundle]]
        let value: [String: Any] = ["location": location, "menuItemLocations": [location],
                                    "isAllowed": allowed, "unknownField": extra]
        return try PropertyListSerialization.data(fromPropertyList: [location, value], format: .binary, options: 0)
    }

    private func entry(_ mode: Ledger.Mode, _ operation: Ledger.Operation? = nil) throws -> Ledger.Entry {
        Ledger.Entry(bundleIdentifier: bundle, originalRecord: try record(), mode: mode, pending: operation)
    }

    func testCrashBeforeFirstWriteOwnsNothing() throws {
        let pending = try entry(.original, .hide)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record())), .notApplied(nil))
    }

    func testCrashAfterFirstWriteRecoversHiddenOwnership() throws {
        let pending = try entry(.original, .hide)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record(false))), .completed(try entry(.hidden)))
    }

    func testCrashBeforeRevealKeepsHiddenMode() throws {
        let pending = try entry(.hidden, .reveal)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record(false))), .notApplied(try entry(.hidden)))
    }

    func testCrashAfterRevealRetainsOriginalAndRevealedMode() throws {
        let pending = try entry(.hidden, .reveal)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record())), .completed(try entry(.revealed)))
        XCTAssertTrue(pending.isTemporarilyRevealed)
    }

    func testCrashBeforeRehideKeepsRevealReceipt() throws {
        let pending = try entry(.revealed, .rehide)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record())), .notApplied(try entry(.revealed)))
    }

    func testCrashAfterRehideReturnsToHiddenOwnership() throws {
        let pending = try entry(.revealed, .rehide)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record(false))), .completed(try entry(.hidden)))
    }

    func testCrashBeforeRestoreRetainsRecoveryReceipt() throws {
        let pending = try entry(.hidden, .restore)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record(false))), .notApplied(try entry(.hidden)))
    }

    func testCrashAfterRestoreEndsOwnership() throws {
        let pending = try entry(.hidden, .restore)
        XCTAssertEqual(try Ledger.recovery(for: pending, current: Codec.decode(record())), .completed(nil))
    }

    func testTargetUnknownFieldEditedDuringPendingWriteConflicts() throws {
        for allowed in [false, true] {
            XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .reveal),
                current: Codec.decode(record(allowed, extra: "external"))), .conflicted)
        }
    }

    func testTargetDisappearingNeverCreatesAReplacement() throws {
        let empty = try PropertyListSerialization.data(fromPropertyList: [], format: .binary, options: 0)
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden), current: Codec.decode(empty)), .conflicted)
    }

    func testCommittedHiddenEntryDistinguishesExternalEnable() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden), current: Codec.decode(record(false))), .unchanged)
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden), current: Codec.decode(record())), .conflicted)
    }

    func testPreexistingFalseCannotBecomeOwnedThroughJournal() throws {
        let invalid = Ledger.Entry(bundleIdentifier: bundle, originalRecord: try record(false), mode: .hidden)
        XCTAssertThrowsError(try Ledger.encode([invalid]))
    }

    func testJournalRoundtripPreservesPendingModeAndCompleteOriginal() throws {
        for (mode, operation) in [(Ledger.Mode.original, Ledger.Operation.hide), (.hidden, .reveal),
                                  (.revealed, .rehide), (.hidden, .restore)] {
            let value = try entry(mode, operation)
            XCTAssertEqual(try Ledger.decode(Ledger.encode([value])), [value])
        }
    }

    func testInvalidModeOperationPairsFailClosed() throws {
        for (mode, operation) in [(Ledger.Mode.original, Ledger.Operation.restore), (.hidden, .hide),
                                  (.revealed, .reveal), (.revealed, .restore)] {
            XCTAssertThrowsError(try Ledger.encode([entry(mode, operation)]))
        }
        XCTAssertThrowsError(try Ledger.encode([entry(.original)]))
    }

    func testJournalRejectsDuplicateOwnershipAndForeignScope() throws {
        let value = try entry(.hidden)
        XCTAssertThrowsError(try Ledger.encode([value, value]))
        let valid = try Ledger.encode([value])
        for (key, replacement) in [("applicationID", "foreign"), ("relativeDomain", "/tmp/other"),
                                   ("preferenceKey", "OtherPreferences"), ("extraField", "unexpected")] {
            var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: valid, format: nil) as? [String: Any])
            payload[key] = replacement
            let changed = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            XCTAssertThrowsError(try Ledger.decode(changed))
        }
    }

    func testJournalBooleanVersionAndOversizedInputRejected() throws {
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: Ledger.encode([entry(.hidden)]), format: nil) as? [String: Any])
        payload["schemaVersion"] = true
        XCTAssertThrowsError(try Ledger.decode(PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)))
        XCTAssertThrowsError(try Ledger.decode(Data(repeating: 0, count: Ledger.maximumDataSize + 1)))
    }

    func testSingleRecordReplacementMergesIntoFreshUnrelatedEdits() throws {
        let original = try record()
        let hidden = try entry(.hidden).hiddenRecord()
        var fresh = try XCTUnwrap(PropertyListSerialization.propertyList(from: hidden, format: nil) as? [Any])
        let newLocation: [String: Any] = ["bundle": ["_0": "dev.fixture.New"]]
        let newRecord: [String: Any] = ["location": newLocation, "menuItemLocations": [newLocation],
                                       "isAllowed": false, "externalRevision": 17]
        fresh += [newLocation, newRecord]
        let freshData = try PropertyListSerialization.data(fromPropertyList: fresh, format: .binary, options: 0)
        let merged = try XCTUnwrap(Codec.decode(freshData).replacingRecord(bundleIdentifier: bundle, expected: hidden, replacement: original))
        let mergedValues = try XCTUnwrap(PropertyListSerialization.propertyList(from: merged, format: nil) as? [Any])
        XCTAssertEqual(mergedValues.count, 4)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(mergedValues[3] as? [String: Any])).isEqual(to: newRecord))
        XCTAssertTrue(try Codec.decode(merged).isAllowed(bundleIdentifier: bundle))
    }

    func testSingleRecordReplacementRefusesRacingTargetEdit() throws {
        let hidden = try entry(.hidden).hiddenRecord()
        let fresh = try Codec.decode(record(false, extra: "external"))
        XCTAssertNil(try fresh.replacingRecord(bundleIdentifier: bundle, expected: hidden, replacement: record()))
    }

    func testReloadRetainsMemoryReceiptWhenJournalDisappearedAfterIOFailure() throws {
        let remembered = try entry(.hidden)
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [], remembered: [remembered]), [remembered])
    }

    func testReloadUsesDurablyCompletedTransitionAfterFailedSaveAcknowledgement() throws {
        let pending = try entry(.original, .hide)
        let completed = try entry(.hidden)
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [completed], remembered: [pending]), [completed])
    }

    func testReloadAfterFailedJournalRemovalDoesNotLoseOriginalRecoveryReceipt() throws {
        let pendingRestore = try entry(.hidden, .restore)
        let merged = try Ledger.mergeForRecovery(persisted: [], remembered: [pendingRestore])
        XCTAssertEqual(merged, [pendingRestore])
        XCTAssertEqual(try Ledger.recovery(for: XCTUnwrap(merged.first), current: Codec.decode(record())), .completed(nil))
    }

    func testReloadRefusesDifferentOriginalRatherThanReplacingOwnership() throws {
        let memory = try entry(.hidden)
        let conflictingDisk = Ledger.Entry(bundleIdentifier: bundle,
            originalRecord: try record(true, extra: "different original"), mode: .hidden)
        XCTAssertThrowsError(try Ledger.mergeForRecovery(persisted: [conflictingDisk], remembered: [memory]))
    }

    func testReloadDoesNotAdoptAnInvalidPreexistingDisabledOriginal() throws {
        let invalid = Ledger.Entry(bundleIdentifier: bundle, originalRecord: try record(false), mode: .hidden)
        XCTAssertThrowsError(try Ledger.mergeForRecovery(persisted: [invalid], remembered: []))
    }

    func testKnownPrewriteAbortCannotAdoptAnExternalHide() throws {
        let attempted = try entry(.original, .hide)
        let cancelled = try Ledger.discardingKnownUnwritten(attempted, from: [attempted])
        XCTAssertTrue(cancelled.isEmpty)
        // A transient failure to save cancellation leaves the attempted disk
        // receipt; retry must apply the same known-abort decision, not recover
        // an external false value as this process's completed write.
        let reloaded = try Ledger.discardingKnownUnwritten(attempted, from: [attempted])
        XCTAssertTrue(try Ledger.mergeForRecovery(persisted: reloaded, remembered: cancelled).isEmpty)
    }

    func testKnownPrewriteRevealAbortRetainsPriorHiddenOwnership() throws {
        let attempted = try entry(.hidden, .reveal)
        XCTAssertEqual(try Ledger.discardingKnownUnwritten(attempted, from: [attempted]), [try entry(.hidden)])
        XCTAssertEqual(try Ledger.discardingKnownUnwritten(attempted, from: []), [try entry(.hidden)])
    }

    func testKnownAbortDoesNotOverwriteAConflictingCompletedReceipt() throws {
        let attempted = try entry(.original, .hide)
        XCTAssertThrowsError(try Ledger.discardingKnownUnwritten(attempted, from: [entry(.hidden)]))
    }
}
