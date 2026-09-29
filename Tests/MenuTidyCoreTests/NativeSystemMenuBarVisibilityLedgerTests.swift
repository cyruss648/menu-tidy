import CoreFoundation
import Foundation
import XCTest
@testable import MenuTidyCore

final class NativeSystemMenuBarVisibilityLedgerTests: XCTestCase {
    private typealias Ledger = NativeSystemMenuBarVisibilityLedger
    private let host = "11D167D7-A397-40DF-850A-784394141613"

    private func entry(_ mode: Ledger.Mode, _ operation: Ledger.Operation? = nil,
                       original: Int64 = 2) -> Ledger.Entry {
        Ledger.Entry(key: "AirDrop", hostIdentifier: host, originalValue: original, mode: mode, pending: operation)
    }

    private func alteredArchive(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var value = try XCTUnwrap(PropertyListSerialization.propertyList(from: Ledger.encode([entry(.hidden)]), format: nil) as? [String: Any])
        mutate(&value)
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    func testInputMenuLifecycleAndIndependentAirDropReceipt() throws {
        let input = Ledger.Entry(key: "TextInputMenu", hostIdentifier: host, originalValue: 2, mode: .original, pending: .hide)
        let hidden = input.completingPending()!
        XCTAssertEqual(try Ledger.recovery(for: input, current: 8), .completed(hidden))
        let revealing = hidden.preparing(.reveal)
        let revealed = revealing.completingPending()!
        XCTAssertEqual(try Ledger.recovery(for: revealing, current: 2), .completed(revealed))
        XCTAssertEqual(try Ledger.recovery(for: revealed.preparing(.rehide), current: 8), .completed(hidden))
        XCTAssertEqual(try Ledger.recovery(for: hidden.preparing(.restore), current: 2), .completed(nil))
        let both = [entry(.hidden, original: 0x42), hidden]
        XCTAssertEqual(try Ledger.decode(Ledger.encode(both)), both)
        XCTAssertEqual(try Ledger.discardingKnownUnwritten(entries: [both[0], input], known: [input]), [both[0]])
    }

    func testInputMenuCannotClaimIntegerBitsOrPreexistingHiddenState() {
        for original: Int64 in [0, 8, 10, 0x42, 0x48] {
            XCTAssertThrowsError(try Ledger.encode([Ledger.Entry(key: "TextInputMenu", hostIdentifier: host,
                originalValue: original, mode: .hidden)]))
        }
    }

    func testLegacyAirDropReceiptRemainsRecoverableButCannotContainInputMenu() throws {
        let data = try alteredArchive {
            $0["schemaVersion"] = 1
            $0["domain"] = "com.apple.controlcenter"
            $0["hostScope"] = "currentHost"
        }
        XCTAssertEqual(try Ledger.decode(data), [entry(.hidden)])
        var archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var records = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        records[0]["key"] = "TextInputMenu"
        archive["entries"] = records
        XCTAssertThrowsError(try Ledger.decode(PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)))
    }

    func testAcceptsOnlyNonnegativeIntegerNumbers() throws {
        for value: Int64 in [0, 2, 8, 0x42, Int64.max] {
            XCTAssertEqual(try Ledger.integerValue(NSNumber(value: value)), value)
        }
        for value: Any in [true, false, -1, 2.0, Float(8), "2", NSNumber(value: UInt64.max)] {
            XCTAssertThrowsError(try Ledger.integerValue(value))
        }
    }

    func testKnownMasksOnly() throws {
        XCTAssertTrue(try Ledger.isAllowed(2))
        XCTAssertFalse(try Ledger.isAllowed(8))
        XCTAssertTrue(try Ledger.isAllowed(0x42))
        XCTAssertFalse(try Ledger.isAllowed(0x48))
        for value: Int64 in [-1, 0, 10, 0x40, 0x4A] { XCTAssertThrowsError(try Ledger.isAllowed(value)) }
    }

    func testReplacementPreservesAllForeignBits() throws {
        let original: Int64 = 0x1555555555555552
        let hidden = try Ledger.replacingMask(in: original, with: 8)
        XCTAssertEqual(hidden & ~0xA, original & ~0xA)
        XCTAssertEqual(hidden & 0xA, 8)
        XCTAssertEqual(try Ledger.replacingMask(in: hidden, with: 2), original)
    }

    func testReplacementRefusesUnknownSourceAndBroadReplacement() {
        for value: Int64 in [0, 10, -1] { XCTAssertThrowsError(try Ledger.replacingMask(in: value, with: 8)) }
        for replacement: Int64 in [0, 10, -1, 0x48] { XCTAssertThrowsError(try Ledger.replacingMask(in: 2, with: replacement)) }
    }

    func testCrashBeforeInitialWriteDoesNotAcquireOwnership() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.original, .hide), current: 0x42), .notApplied(nil))
    }

    func testCrashAfterHideRetainsOwnershipDespiteForeignBits() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.original, .hide), current: 0x48), .completed(entry(.hidden)))
    }

    func testCrashBeforeAndAfterReveal() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .reveal), current: 0x48), .notApplied(entry(.hidden)))
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .reveal), current: 0x42), .completed(entry(.revealed)))
    }

    func testCrashBeforeAndAfterRehide() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.revealed, .rehide), current: 0x42), .notApplied(entry(.revealed)))
        XCTAssertEqual(try Ledger.recovery(for: entry(.revealed, .rehide), current: 0x48), .completed(entry(.hidden)))
    }

    func testCrashBeforeAndAfterRestore() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .restore), current: 0x48), .notApplied(entry(.hidden)))
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .restore), current: 0x42), .completed(nil))
    }

    func testForeignBitsDoNotRevokeOwnershipButUnknownVisibilityDoes() throws {
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden), current: 0x58), .unchanged)
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden), current: 0x52), .conflicted)
        XCTAssertEqual(try Ledger.recovery(for: entry(.hidden, .reveal), current: 0x5A), .conflicted)
    }

    func testOriginalOffCannotBeClaimedAsOwned() {
        XCTAssertThrowsError(try Ledger.encode([entry(.hidden, original: 8)]))
        XCTAssertThrowsError(try Ledger.encode([entry(.original, .hide, original: 0x48)]))
    }

    func testSystemKeyAllowlistIsExact() {
        for key in ["Bluetooth", "airdrop", "AirDrop ", "../AirDrop"] {
            let invalid = Ledger.Entry(key: key, hostIdentifier: host, originalValue: 2, mode: .hidden)
            XCTAssertThrowsError(try Ledger.encode([invalid]))
        }
    }

    func testInvalidHostAndStateAreRejected() {
        let foreign = Ledger.Entry(key: "AirDrop", hostIdentifier: "anyHost", originalValue: 2, mode: .hidden)
        XCTAssertThrowsError(try Ledger.encode([foreign]))
        for (mode, operation) in [(Ledger.Mode.original, Ledger.Operation.restore), (.hidden, .hide),
                                  (.revealed, .reveal), (.revealed, .restore)] {
            XCTAssertThrowsError(try Ledger.encode([entry(mode, operation)]))
        }
        XCTAssertThrowsError(try Ledger.encode([entry(.original)]))
    }

    func testJournalRoundtripPreservesOriginalForeignBitsAndIntent() throws {
        for (mode, operation) in [(Ledger.Mode.original, Ledger.Operation.hide), (.hidden, .reveal),
                                  (.revealed, .rehide), (.hidden, .restore)] {
            let value = entry(mode, operation, original: 0x42)
            XCTAssertEqual(try Ledger.decode(Ledger.encode([value])), [value])
        }
    }

    func testScopeAndUnknownEnvelopeFieldsAreRejected() throws {
        for (key, value) in [("applicationID", "foreign"), ("domain", "group.com.apple.controlcenter"),
                             ("userScope", "anyUser"), ("hostScope", "anyHost"), ("extra", "unexpected")] {
            XCTAssertThrowsError(try Ledger.decode(alteredArchive { $0[key] = value }))
        }
    }

    func testBooleanOrFloatingVersionAndOriginalAreRejected() throws {
        for invalid: Any in [true, 1.0] {
            XCTAssertThrowsError(try Ledger.decode(alteredArchive { $0["schemaVersion"] = invalid }))
        }
        for invalid: Any in [true, 2.0, -1] {
            let data = try alteredArchive { payload in
                var values = payload["entries"] as! [[String: Any]]
                values[0]["originalValue"] = invalid
                payload["entries"] = values
            }
            XCTAssertThrowsError(try Ledger.decode(data))
        }
    }

    func testDuplicateAndOversizedJournalRejected() {
        XCTAssertThrowsError(try Ledger.encode([entry(.hidden), entry(.hidden)]))
        XCTAssertThrowsError(try Ledger.decode(Data(repeating: 0, count: Ledger.maximumDataSize + 1)))
    }

    func testReloadRetainsMemoryReceiptAndCompletedDiskTransition() throws {
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [], remembered: [entry(.hidden)]), [entry(.hidden)])
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [entry(.hidden)], remembered: [entry(.original, .hide)]), [entry(.hidden)])
    }

    func testReloadAllowsForeignOriginalBitsButRejectsOtherHost() throws {
        let persisted = entry(.hidden, original: 0x42)
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [persisted], remembered: [entry(.hidden)]), [persisted])
        let otherHost = Ledger.Entry(key: "AirDrop", hostIdentifier: UUID().uuidString, originalValue: 2, mode: .hidden)
        XCTAssertThrowsError(try Ledger.mergeForRecovery(persisted: [persisted], remembered: [otherHost]))
    }

    func testHostIdentifierCaseDoesNotChangeOwnershipIdentity() throws {
        let lowercase = Ledger.Entry(key: "AirDrop", hostIdentifier: host.lowercased(), originalValue: 2, mode: .hidden)
        XCTAssertEqual(try Ledger.mergeForRecovery(persisted: [entry(.hidden)], remembered: [lowercase]), [entry(.hidden)])
    }

    func testKnownAbortedInitialWriteIsNotRecoveredAsExternalHide() throws {
        let pending = entry(.original, .hide)
        XCTAssertTrue(try Ledger.discardingKnownUnwritten(entries: [pending], known: [pending]).isEmpty)
        XCTAssertThrowsError(try Ledger.discardingKnownUnwritten(entries: [entry(.hidden)], known: [pending]))
    }

    func testKnownAbortedRevealRetainsPriorOwnershipAfterJournalFailure() throws {
        let pending = entry(.hidden, .reveal)
        XCTAssertEqual(try Ledger.discardingKnownUnwritten(entries: [pending], known: [pending]), [entry(.hidden)])
        XCTAssertEqual(try Ledger.discardingKnownUnwritten(entries: [], known: [pending]), [entry(.hidden)])
    }
}
