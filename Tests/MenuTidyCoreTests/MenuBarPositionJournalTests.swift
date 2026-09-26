import CoreFoundation
import Foundation
import XCTest
@testable import MenuTidyCore

final class MenuBarPositionJournalTests: XCTestCase {
    private let source = "status:com.example.source::one"
    private let anchor = "status:dev.hdh.MenuTidy::MenuTidyControl"

    private func entry(id: UUID = UUID(), source: String? = nil,
                       original: NSNumber = 930.5, written: NSNumber = 170.75) -> MenuBarPositionJournal.Entry {
        let source = source ?? self.source
        return .init(id: id, sourceKey: source, anchorKey: anchor,
                     originalValues: [source: original], writtenValues: [source: written])
    }

    private func changingPayload(_ change: (inout [String: Any]) -> Void) throws -> Data {
        let data = try MenuBarPositionJournal.encode([entry()])
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        change(&payload)
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    }

    func testRecoveryRetainsIdentityAndOriginalIntegerBeyondDoublePrecision() throws {
        let original = NSNumber(value: Int64(9_007_199_254_740_993))
        let record = entry(original: original)
        let recovered = try XCTUnwrap(MenuBarPositionJournal.decode(MenuBarPositionJournal.encode([record])).first)
        XCTAssertEqual(recovered.id, record.id)
        XCTAssertEqual(recovered.sourceKey, source)
        XCTAssertEqual(recovered.anchorKey, anchor)
        XCTAssertEqual(recovered.originalValues[source]?.int64Value, original.int64Value)
        XCTAssertEqual(recovered.writtenValues[source]?.doubleValue, 170.75)
    }

    func testFloatAndDoubleRemainRealValuesWithoutIntegerConversion() throws {
        for original in [NSNumber(value: Float(0.1)), NSNumber(value: Double(0.1))] {
            let decoded = try MenuBarPositionJournal.decode(MenuBarPositionJournal.encode([entry(original: original)]))
            let recovered = try XCTUnwrap(decoded.first?.originalValues[source])
            XCTAssertEqual(String(cString: recovered.objCType), String(cString: original.objCType))
            XCTAssertEqual(recovered.doubleValue, original.doubleValue)
            XCTAssertTrue(recovered.isEqual(to: original))
        }
        // A plist can canonicalize an integer's storage width; it must retain
        // the integer kind and exact value instead of passing through Double.
        let decoded = try MenuBarPositionJournal.decode(MenuBarPositionJournal.encode([entry(original: NSNumber(value: Int32(200)))]))
        let integer = try XCTUnwrap(decoded.first?.originalValues[source])
        XCTAssertFalse(CFNumberIsFloatType(integer))
        XCTAssertEqual(integer.int64Value, 200)
    }

    func testMultipleDifferentTargetsRecoverWithoutAddingUntouchedKeys() throws {
        let first = entry()
        let second = entry(source: "status:com.example.second::two", original: -0.125, written: 2.25)
        let recovered = try MenuBarPositionJournal.decode(MenuBarPositionJournal.encode([first, second]))
        XCTAssertEqual(Set(recovered.map(\.id)), [first.id, second.id])
        for record in recovered {
            XCTAssertEqual(Set(record.originalValues.keys), [record.sourceKey])
            XCTAssertEqual(Set(record.writtenValues.keys), [record.sourceKey])
            XCTAssertNil(record.originalValues[anchor])
        }
    }

    func testRejectsForeignScopeAndAdditionalRecoveryPaths() throws {
        for (key, value) in [("applicationID", "com.example.other"),
                             ("relativeDomain", "/tmp/other.plist"),
                             ("preferenceKey", "OtherPreferences"),
                             ("backupPath", "../../other.plist")] {
            let data = try changingPayload { $0[key] = value }
            XCTAssertThrowsError(try MenuBarPositionJournal.decode(data))
        }
    }

    func testRejectsUnsupportedVersionAndBooleanVersion() throws {
        for version in [NSNumber(value: 2), NSNumber(value: true)] {
            let data = try changingPayload { $0["schemaVersion"] = version }
            XCTAssertThrowsError(try MenuBarPositionJournal.decode(data))
        }
    }

    func testRejectsBooleanAndNonFinitePositionValues() {
        for invalid in [NSNumber(value: true), NSNumber(value: Double.infinity), NSNumber(value: Double.nan)] {
            XCTAssertThrowsError(try MenuBarPositionJournal.encode([entry(original: invalid)]))
            XCTAssertThrowsError(try MenuBarPositionJournal.encode([entry(written: invalid)]))
        }
    }

    func testDoesNotAcceptWrongTargetOrMultipleTouchedKeys() throws {
        let wrongKey = MenuBarPositionJournal.Entry(id: UUID(), sourceKey: source, anchorKey: anchor,
            originalValues: [anchor: 1], writtenValues: [source: 2])
        let broadWrite = MenuBarPositionJournal.Entry(id: UUID(), sourceKey: source, anchorKey: anchor,
            originalValues: [source: 1, anchor: 2], writtenValues: [source: 3, anchor: 4])
        XCTAssertThrowsError(try MenuBarPositionJournal.encode([wrongKey]))
        XCTAssertThrowsError(try MenuBarPositionJournal.encode([broadWrite]))
        XCTAssertThrowsError(try MenuBarPositionJournal.encode([entry(source: "../../other.plist")]))
        let data = try changingPayload {
            var entries = $0["transactions"] as? [[String: Any]] ?? []
            entries[0]["writtenValues"] = [self.source: true]
            $0["transactions"] = entries
        }
        XCTAssertThrowsError(try MenuBarPositionJournal.decode(data))
    }

    func testRejectsDuplicateTransactionAndConflictingSameTarget() {
        let first = entry()
        let duplicateID = entry(id: first.id, source: "status:com.example.second::two")
        XCTAssertThrowsError(try MenuBarPositionJournal.encode([first, duplicateID]))
        XCTAssertThrowsError(try MenuBarPositionJournal.encode([first, entry(original: 5, written: 6)]))
    }

    func testMalformedOrOversizedArchiveDoesNotProducePartialRecovery() throws {
        let data = try MenuBarPositionJournal.encode([entry()])
        XCTAssertThrowsError(try MenuBarPositionJournal.decode(Data(data.prefix(data.count / 2))))
        XCTAssertThrowsError(try MenuBarPositionJournal.decode(Data(repeating: 0, count: MenuBarPositionJournal.maximumDataSize + 1)))
        XCTAssertTrue(try MenuBarPositionJournal.decode(MenuBarPositionJournal.encode([])).isEmpty)
        let malformedID = try changingPayload {
            var entries = $0["transactions"] as? [[String: Any]] ?? []
            entries[0]["id"] = "not-a-transaction"
            $0["transactions"] = entries
        }
        XCTAssertThrowsError(try MenuBarPositionJournal.decode(malformedID))
    }
}
