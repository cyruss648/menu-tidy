import CoreFoundation
import Foundation
import XCTest
@testable import MenuTidyCore

final class NativeMenuBarVisibilityCodecTests: XCTestCase {
    private typealias Codec = NativeMenuBarVisibilityCodec
    private let target = "dev.fixture.Target"
    private let other = "dev.fixture.Other"
    private var baseline: [Any] { [key(target), record(target), key(other), record(other)] }

    private func expect(_ condition: @autoclosure () throws -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try condition(), file: file, line: line)
    }
    private func rejected(_ values: Any, as error: Codec.Failure) throws {
        do { _ = try Codec.decode(bytes(values)); XCTFail("Malformed input accepted") }
        catch let actual as Codec.Failure { XCTAssertEqual(actual, error) }
    }
    private func bytes(_ values: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }
    private func values(_ data: Data) throws -> [Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any])
    }
    private func key(_ bundle: String) -> [String: Any] { ["bundle": ["_0": bundle]] }
    private func record(_ bundle: String, _ allowed: Any = true) -> [String: Any] {
        ["location": key(bundle), "menuItemLocations": [key(bundle)], "isAllowed": allowed,
         "futureField": ["bytes": Data([1, 2, 3]), "version": 7, "date": Date(timeIntervalSince1970: 1_000)]]
    }

    func testDecodeAndExactTarget() throws {
        let snapshot = try Codec.decode(bytes(baseline))
        try expect(snapshot.count == 2)
        try expect(snapshot.isAllowed(bundleIdentifier: target))
    }

    func testMutateOneBooleanAndPreserveCompleteOtherRecord() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        let result = try values(change.data)
        let changed = result[1] as! [String: Any]
        var expected = record(target); expected["isAllowed"] = false
        try expect(NSDictionary(dictionary: changed).isEqual(to: expected))
        try expect(NSDictionary(dictionary: result[3] as! [String: Any]).isEqual(to: record(other)))
        try expect(CFGetTypeID(changed["isAllowed"] as! NSNumber) == CFBooleanGetTypeID())
    }

    func testFullSemanticRoundtrip() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        guard case .restored(let restored) = try Codec.decode(change.data).restoring(change.undo) else { throw Codec.Failure.malformed }
        try expect(NSArray(array: try values(restored)).isEqual(to: baseline))
    }

    func testOriginalFalseIsNoWriteAndNoOwnedUndo() throws {
        let initial: [Any] = [key(target), record(target, false)]
        try expect(Codec.decode(bytes(initial)).settingAllowed(false, bundleIdentifier: target) == nil)
    }

    func testAlreadyTrueIsNoWrite() throws {
        try expect(Codec.decode(bytes(baseline)).settingAllowed(true, bundleIdentifier: target) == nil)
    }

    func testRestorePreservesUnrelatedExternalEditAndAppendedItem() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        var fresh = try values(change.data)
        var unrelated = fresh[3] as! [String: Any]; unrelated["external"] = "preserve"; fresh[3] = unrelated
        fresh += [key("dev.fixture.New"), record("dev.fixture.New", false)]
        guard case .restored(let data) = try Codec.decode(bytes(fresh)).restoring(change.undo) else { throw Codec.Failure.malformed }
        let result = try values(data)
        try expect(result.count == 6)
        try expect(NSDictionary(dictionary: result[3] as! [String: Any]).isEqual(to: unrelated))
        try expect(Codec.decode(data).isAllowed(bundleIdentifier: "dev.fixture.New") == false)
    }

    func testRestoreToleratesRecordReordering() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        let changed = try values(change.data)
        let fresh = [changed[2], changed[3], changed[0], changed[1]]
        guard case .restored(let data) = try Codec.decode(bytes(fresh)).restoring(change.undo) else { throw Codec.Failure.malformed }
        try expect(Codec.decode(data).isAllowed(bundleIdentifier: target))
        try expect(NSDictionary(dictionary: try values(data)[0] as! [String: Any]).isEqual(to: key(other)))
    }

    func testTargetExternallyToggledCausesConflict() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        guard case .conflict = try Codec.decode(bytes(baseline)).restoring(change.undo) else { throw Codec.Failure.malformed }
    }

    func testTargetUnknownFieldExternallyEditedCausesConflict() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        var fresh = try values(change.data)
        var item = fresh[1] as! [String: Any]; item["external"] = 1; fresh[1] = item
        guard case .conflict = try Codec.decode(bytes(fresh)).restoring(change.undo) else { throw Codec.Failure.malformed }
    }

    func testUnknownBoolVersusIntegerDistinctionIsAConflict() throws {
        var item = record(target); item["typeSensitive"] = true
        let change = try Codec.decode(bytes([key(target), item])).settingAllowed(false, bundleIdentifier: target)!
        var fresh = try values(change.data)
        var changed = fresh[1] as! [String: Any]; changed["typeSensitive"] = 1; fresh[1] = changed
        guard case .conflict = try Codec.decode(bytes(fresh)).restoring(change.undo) else { throw Codec.Failure.malformed }
    }

    func testTargetRemovedCausesConflict() throws {
        let change = try Codec.decode(bytes(baseline)).settingAllowed(false, bundleIdentifier: target)!
        guard case .conflict = try Codec.decode(bytes([key(other), record(other)])).restoring(change.undo) else { throw Codec.Failure.malformed }
    }

    func testDuplicateLocationRejectsAmbiguity() throws {
        try rejected(baseline + [key(target), record(target, false)], as: .duplicateLocation)
    }

    func testAlternateEnumLocationWithSameTextDoesNotCollideWithBundle() throws {
        let location: [String: Any] = ["path": ["_0": target]]
        let alternate: [String: Any] = ["location": location, "menuItemLocations": [location], "isAllowed": false]
        let snapshot = try Codec.decode(bytes(baseline + [location, alternate]))
        try expect(snapshot.count == 3)
        try expect(snapshot.isAllowed(bundleIdentifier: target))
    }

    func testDifferentPrefixAndCaseDoNotMatch() throws {
        let snapshot = try Codec.decode(bytes(baseline))
        for value in ["dev.fixture", target.lowercased(), target + ".Other"] {
            do { _ = try snapshot.settingAllowed(false, bundleIdentifier: value); throw Codec.Failure.malformed }
            catch Codec.Failure.missingTarget { }
        }
    }

    func testTargetSharedWithAnotherBundleRefused() throws {
        var item = record(target); item["menuItemLocations"] = [key(target), key(other)]
        do { _ = try Codec.decode(bytes([key(target), item])).settingAllowed(false, bundleIdentifier: target); throw Codec.Failure.malformed }
        catch Codec.Failure.unsafeTarget { }
    }

    func testTargetWithUnknownAdditionalOwnerRefused() throws {
        var item = record(target); item["menuItemLocations"] = [key(target), ["path": ["_0": "/fixture/App"]]]
        do { _ = try Codec.decode(bytes([key(target), item])).settingAllowed(false, bundleIdentifier: target); throw Codec.Failure.malformed }
        catch Codec.Failure.unsafeTarget { }
    }

    func testEmptyTargetMenuItemLocationsRefused() throws {
        var item = record(target); item["menuItemLocations"] = []
        do { _ = try Codec.decode(bytes([key(target), item])).settingAllowed(false, bundleIdentifier: target); throw Codec.Failure.malformed }
        catch Codec.Failure.unsafeTarget { }
    }

    private func helperRecord(owner: String, helper: String) -> [String: Any] {
        var item = record(owner)
        item["menuItemLocations"] = [key(helper)]
        return item
    }

    func testWPSHelperUsesExplicitContainingApplicationRecord() throws {
        let owner = "com.kingsoft.wpsoffice.mac"
        let helper = "cn.wps.wpscloudsvr"
        let input: [Any] = [key(owner), helperRecord(owner: owner, helper: helper), key(other), record(other)]
        let snapshot = try Codec.decode(bytes(input))
        XCTAssertTrue(try snapshot.isAllowed(bundleIdentifier: helper))
        let change = try XCTUnwrap(snapshot.settingAllowed(false, bundleIdentifier: helper))
        let output = try values(change.data)
        var expected = helperRecord(owner: owner, helper: helper)
        expected["isAllowed"] = false
        XCTAssertTrue(NSDictionary(dictionary: output[1] as! [String: Any]).isEqual(to: expected))
        XCTAssertTrue(NSDictionary(dictionary: output[3] as! [String: Any]).isEqual(to: record(other)))
        guard case .restored(let restored) = try Codec.decode(change.data).restoring(change.undo) else {
            return XCTFail("Helper restore failed")
        }
        XCTAssertTrue(NSArray(array: try values(restored)).isEqual(to: input))
    }

    func testHelperJournalSurvivesHideRevealRehideAndRestore() throws {
        typealias Ledger = NativeMenuBarVisibilityLedger
        let input: [Any] = [key(other), helperRecord(owner: other, helper: target)]
        let snapshot = try Codec.decode(bytes(input))
        let entry = Ledger.Entry(bundleIdentifier: target, originalRecord: try snapshot.record(bundleIdentifier: target),
                                 mode: .original, pending: .hide)
        let loaded = try XCTUnwrap(Ledger.decode(Ledger.encode([entry])).first)
        let hidden = try Codec.decode(loaded.hiddenRecord())
        let completed = try XCTUnwrap(loaded.completingPending())
        XCTAssertEqual(try Ledger.recovery(for: loaded, current: hidden), .completed(completed))
        let revealed = try XCTUnwrap(completed.preparing(.reveal).completingPending())
        XCTAssertEqual(try Ledger.recovery(for: completed.preparing(.reveal), current: snapshot), .completed(revealed))
        XCTAssertEqual(try Ledger.recovery(for: revealed.preparing(.rehide), current: hidden), .completed(completed))
        let restored = try XCTUnwrap(hidden.replacingRecord(bundleIdentifier: target,
            expected: completed.expectedRecord(), replacement: completed.originalRecord))
        XCTAssertEqual(try Ledger.recovery(for: completed.preparing(.restore), current: Codec.decode(restored)), .completed(nil))
    }

    func testHelperWithAnotherMenuItemOwnerRefused() throws {
        var item = helperRecord(owner: other, helper: target)
        item["menuItemLocations"] = [key(target), key(other)]
        XCTAssertThrowsError(try Codec.decode(bytes([key(other), item])).isAllowed(bundleIdentifier: target)) {
            XCTAssertEqual($0 as? Codec.Failure, .unsafeTarget)
        }
    }

    func testHelperInTwoApplicationRecordsRefused() throws {
        let input: [Any] = [key(other), helperRecord(owner: other, helper: target),
                            key("dev.fixture.Second"), helperRecord(owner: "dev.fixture.Second", helper: target)]
        XCTAssertThrowsError(try Codec.decode(bytes(input)).settingAllowed(false, bundleIdentifier: target)) {
            XCTAssertEqual($0 as? Codec.Failure, .unsafeTarget)
        }
    }

    func testExactRecordCannotMaskAnotherHelperReference() throws {
        let input = baseline + [key("dev.fixture.Parent"), helperRecord(owner: "dev.fixture.Parent", helper: target)]
        XCTAssertThrowsError(try Codec.decode(bytes(input)).isAllowed(bundleIdentifier: target)) {
            XCTAssertEqual($0 as? Codec.Failure, .unsafeTarget)
        }
    }

    func testHelperUnderNonBundleRecordRefused() throws {
        let location: [String: Any] = ["path": ["_0": "/fixture/Parent"]]
        var item = helperRecord(owner: other, helper: target)
        item["location"] = location
        XCTAssertThrowsError(try Codec.decode(bytes([location, item])).isAllowed(bundleIdentifier: target)) {
            XCTAssertEqual($0 as? Codec.Failure, .unsafeTarget)
        }
    }

    func testHelperReparentingDoesNotTransferReceiptOwnership() throws {
        let snapshot = try Codec.decode(bytes([key(other), helperRecord(owner: other, helper: target)]))
        let original = try snapshot.record(bundleIdentifier: target)
        let hidden = try XCTUnwrap(snapshot.settingAllowed(false, bundleIdentifier: target))
        var moved = helperRecord(owner: "dev.fixture.NewParent", helper: target)
        moved["isAllowed"] = false
        let fresh = try Codec.decode(bytes([key("dev.fixture.NewParent"), moved]))
        XCTAssertFalse(try fresh.matches(record: hidden.data, bundleIdentifier: target))
        XCTAssertNil(try fresh.replacingRecord(bundleIdentifier: target, expected: hidden.data, replacement: original))
    }

    func testInteger1IsNotACFBoolean() throws { try rejected([key(target), record(target, 1)], as: .malformed)
    }

    func testInteger0IsNotACFBoolean() throws { try rejected([key(target), record(target, 0)], as: .malformed)
    }

    func testStringBooleanRejected() throws { try rejected([key(target), record(target, "true")], as: .malformed)
    }

    func testOddLengthAlternatingListRejected() throws { try rejected([key(target)], as: .malformed)
    }

    func testDictionaryRootRejected() throws { try rejected(["items": baseline], as: .malformed)
    }

    func testKeyRecordLocationMismatchRejected() throws { try rejected([key(target), record(other)], as: .malformed)
    }

    func testLocationExtraFieldsRejected() throws {
        var malformed = key(target); malformed["url"] = ["_0": target]
        try rejected([malformed, record(target)], as: .malformed)
    }

    func testLocationPayloadExtraFieldsRejected() throws {
        let malformed: [String: Any] = ["bundle": ["_0": target, "unexpected": 1]]
        var item = record(target); item["location"] = malformed
        try rejected([malformed, item], as: .malformed)
    }

    func testByteBound() throws {
        do { _ = try Codec.decode(Data(repeating: 0, count: 1_048_577)); throw Codec.Failure.malformed }
        catch Codec.Failure.oversized { }
    }

    func testRecordCountBound() throws {
        var limits = Codec.Limits(); limits.maximumRecords = 1
        do { _ = try Codec.decode(bytes(baseline), limits: limits); throw Codec.Failure.oversized }
        catch Codec.Failure.malformed { }
    }

    func testNestingDepthBound() throws {
        var nested: Any = "leaf"
        for _ in 0..<20 { nested = ["nested": nested] }
        var item = record(target); item["futureField"] = nested
        try rejected([key(target), item], as: .oversized)
    }

    func testNonfiniteUnknownNumberRejected() throws {
        var item = record(target); item["futureField"] = Double.infinity
        try rejected([key(target), item], as: .malformed)
    }

    func testTruncatedPlistRejected() throws {
        do { _ = try Codec.decode(Data("bplist00broken".utf8)); throw Codec.Failure.oversized }
        catch Codec.Failure.malformed { }
    }

    func testUnrelatedAdhocBinaryURLRecordIsPreservedWhenHidingBundleTarget() throws {
        let adhoc: [String: Any] = ["adhocBinary": ["_0": ["relative": "file:///fixture/standalone-tool"]]]
        var unrelated = record(other)
        unrelated["menuItemLocations"] = [adhoc]
        let input: [Any] = [key(target), record(target), key(other), unrelated]
        let change = try XCTUnwrap(Codec.decode(bytes(input)).settingAllowed(false, bundleIdentifier: target))
        let output = try values(change.data)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(output[3] as? [String: Any])).isEqual(to: unrelated))
        XCTAssertFalse(try Codec.decode(change.data).isAllowed(bundleIdentifier: target))
    }

    func testOpaqueNonBundleLocationsAreNotMistakenForBundleTargets() throws {
        let opaque: [String: Any] = ["adhocBinary": ["_0": ["relative": target]]]
        let unrelated: [String: Any] = ["location": opaque, "menuItemLocations": [opaque], "isAllowed": true]
        let input: [Any] = [opaque, unrelated, key(target), record(target)]
        let change = try XCTUnwrap(Codec.decode(bytes(input)).settingAllowed(false, bundleIdentifier: target))
        let output = try values(change.data)
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(output[1] as? [String: Any])).isEqual(to: unrelated))
    }

    func testTargetWithOnlyAdhocLocationStillRequiresConfirmedBundleOwnership() throws {
        var item = record(target)
        item["menuItemLocations"] = [["adhocBinary": ["_0": ["relative": "file:///fixture/tool"]]]]
        XCTAssertThrowsError(try Codec.decode(bytes([key(target), item])).settingAllowed(false, bundleIdentifier: target)) { error in
            XCTAssertEqual(error as? Codec.Failure, .unsafeTarget)
        }
    }
}
