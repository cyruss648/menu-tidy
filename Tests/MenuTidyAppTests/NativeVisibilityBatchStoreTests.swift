import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class NativeVisibilityBatchStoreTests: XCTestCase {
    private let a = "org.example.BatchA", b = "org.example.BatchB", other = "org.example.Other"

    @MainActor
    func testTwoTargetsShareOneWriteAndTwoJournalCommits() throws {
        let io = try fixture()
        let untouched = try NativeMenuBarVisibilityCodec.decode(io.preferenceData).record(bundleIdentifier: other)
        let store = NativeMenuBarVisibilityStore(testing: io)
        let results = store.changeVisibility([a: true, b: true])
        try results[a]?.get(); try results[b]?.get()
        XCTAssertEqual(io.events, ["journal", "preferences", "journal"])
        XCTAssertEqual(store.managedBundles, [a, b])
        XCTAssertFalse(try store.readAllowed(bundle: a)); XCTAssertFalse(try store.readAllowed(bundle: b))
        XCTAssertTrue(try store.readAllowed(bundle: other))
        XCTAssertTrue(try NativeMenuBarVisibilityCodec.decode(io.preferenceData).matches(record: untouched, bundleIdentifier: other))
        XCTAssertTrue(try NativeMenuBarVisibilityLedger.decode(XCTUnwrap(io.journalData)).allSatisfy { $0.pending == nil })
    }

    @MainActor
    func testTwentyFourApplicationsStillUseOnePreferenceWrite() throws {
        let bundles = (0..<24).map { "org.example.Batch\($0)" }
        let io = try fixture(bundles: bundles)
        let store = NativeMenuBarVisibilityStore(testing: io)
        let results = store.changeVisibility(Dictionary(uniqueKeysWithValues: bundles.map { ($0, true) }))
        XCTAssertEqual(results.count, 24)
        for result in results.values { try result.get() }
        XCTAssertEqual(store.managedBundles, Set(bundles))
        XCTAssertEqual(io.events, ["journal", "preferences", "journal"])
    }

    @MainActor
    func testRestoreAndHideCanShareOneWriteWithoutChangingAnotherManagedTarget() throws {
        let io = try fixture(); let store = NativeMenuBarVisibilityStore(testing: io)
        for result in store.changeVisibility([a: true, b: true]).values { try result.get() }
        io.events = []
        for result in store.changeVisibility([a: false, other: true]).values { try result.get() }
        XCTAssertEqual(io.events, ["journal", "preferences", "journal"])
        XCTAssertEqual(store.managedBundles, [b, other])
        XCTAssertTrue(try store.readAllowed(bundle: a)); XCTAssertFalse(try store.readAllowed(bundle: b))
    }

    @MainActor
    func testJournalFailureStopsBeforeAnyPreferenceMutation() throws {
        let io = try fixture(); let original = io.preferenceData
        io.beforeJournalSave = { _ in throw Failure.injected }
        let store = NativeMenuBarVisibilityStore(testing: io)
        assertFailed(store.changeVisibility([a: true, b: true]))
        XCTAssertEqual(io.preferenceData, original)
        XCTAssertFalse(io.events.contains("preferences"))
        XCTAssertNotNil(store.pendingRecoveryIssue)
        io.beforeJournalSave = nil
        try store.reloadForRecovery()
        XCTAssertTrue(store.managedBundles.isEmpty)
    }

    @MainActor
    func testUncertainWriteRetainsEveryIntentAndCanRecoverAfterRestart() throws {
        let io = try fixture(); let store = NativeMenuBarVisibilityStore(testing: io)
        io.afterPreferenceWrite = { throw Failure.injected }
        assertFailed(store.changeVisibility([a: true, b: true]))
        let pending = try NativeMenuBarVisibilityLedger.decode(XCTUnwrap(io.journalData))
        XCTAssertEqual(Set(pending.map(\.bundleIdentifier)), [a, b])
        XCTAssertTrue(pending.allSatisfy { $0.pending == .hide })
        io.afterPreferenceWrite = nil
        let restarted = NativeMenuBarVisibilityStore(testing: io)
        XCTAssertTrue(try restarted.recoverPendingWrites().isEmpty)
        XCTAssertEqual(restarted.managedBundles, [a, b])
        XCTAssertTrue(restarted.restoreAll().isEmpty)
        XCTAssertTrue(try restarted.readAllowed(bundle: a)); XCTAssertTrue(try restarted.readAllowed(bundle: b))
        XCTAssertNil(io.journalData)
    }

    @MainActor
    func testReconciliationJournalFailureBlocksPreviouslyPreparedPeers() throws {
        let io = try fixture()
        let original = io.preferenceData
        let record = try NativeMenuBarVisibilityCodec.decode(original).record(bundleIdentifier: b)
        io.journalData = try NativeMenuBarVisibilityLedger.encode([
            .init(bundleIdentifier: b, originalRecord: record, mode: .original, pending: .hide)
        ])
        var saves = 0
        io.beforeJournalSave = { _ in saves += 1; if saves == 1 { throw Failure.injected } }
        let store = NativeMenuBarVisibilityStore(testing: io)
        assertFailed(store.changeVisibility([a: true, b: true]))
        XCTAssertEqual(io.preferenceData, original)
        XCTAssertFalse(io.events.contains("preferences"))
        XCTAssertNotNil(store.pendingRecoveryIssue)
    }

    @MainActor
    func testCommitFailureKeepsTheFullPreparedJournalRecoverable() throws {
        let io = try fixture(); let store = NativeMenuBarVisibilityStore(testing: io)
        io.beforeJournalSave = { _ in if io.events.contains("preferences") { throw Failure.injected } }
        assertFailed(store.changeVisibility([a: true, b: true]))
        XCTAssertNotNil(store.pendingRecoveryIssue)
        XCTAssertEqual(try NativeMenuBarVisibilityLedger.decode(XCTUnwrap(io.journalData)).count, 2)
        io.beforeJournalSave = nil
        try store.reloadForRecovery()
        XCTAssertTrue(try store.recoverPendingWrites().isEmpty)
        XCTAssertEqual(store.managedBundles, [a, b])
    }

    @MainActor
    func testSameValueWrittenExternallyAfterPreparationIsNotAdopted() throws {
        let io = try fixture(); let store = NativeMenuBarVisibilityStore(testing: io)
        var changed = false
        io.beforeJournalSave = { [a] data in
            if data != nil && !changed {
                changed = true
                io.preferenceData = try XCTUnwrap(NativeMenuBarVisibilityCodec.decode(io.preferenceData)
                    .settingAllowed(false, bundleIdentifier: a)).data
            }
        }
        assertFailed(store.changeVisibility([a: true, b: true]))
        XCTAssertFalse(io.events.contains("preferences"))
        XCTAssertTrue(store.managedBundles.isEmpty)
        XCTAssertNil(io.journalData)
        XCTAssertFalse(try store.readAllowed(bundle: a)); XCTAssertTrue(try store.readAllowed(bundle: b))
    }

    @MainActor
    func testUnrelatedExternalEditIsMergedAndPreserved() throws {
        let io = try fixture(); let store = NativeMenuBarVisibilityStore(testing: io)
        var changed = false
        io.beforeJournalSave = { [other] data in
            if data != nil && !changed {
                changed = true
                io.preferenceData = try XCTUnwrap(NativeMenuBarVisibilityCodec.decode(io.preferenceData)
                    .settingAllowed(false, bundleIdentifier: other)).data
            }
        }
        for result in store.changeVisibility([a: true, b: true]).values { try result.get() }
        XCTAssertFalse(try store.readAllowed(bundle: other))
        XCTAssertEqual(store.managedBundles, [a, b])
        XCTAssertEqual(io.events.filter { $0 == "preferences" }.count, 1)
    }

    @MainActor
    func testExternallyHiddenTargetFailsWithoutBlockingQualifiedPeer() throws {
        let io = try fixture()
        io.preferenceData = try XCTUnwrap(NativeMenuBarVisibilityCodec.decode(io.preferenceData)
            .settingAllowed(false, bundleIdentifier: b)).data
        let store = NativeMenuBarVisibilityStore(testing: io)
        let results = store.changeVisibility([a: true, b: true])
        try XCTUnwrap(results[a]).get()
        XCTAssertThrowsError(try XCTUnwrap(results[b]).get())
        XCTAssertEqual(store.managedBundles, [a])
        XCTAssertFalse(try store.readAllowed(bundle: b))
    }

    @MainActor
    private func fixture(bundles: [String]? = nil) throws -> NativeVisibilityStoreTestIO {
        let values: [Any] = (bundles ?? [a, b, other]).flatMap { bundle -> [Any] in
            let key: [String: Any] = ["bundle": ["_0": bundle]]
            return [key, ["location": key, "menuItemLocations": [key], "isAllowed": true,
                "futureField": ["bytes": Data([1, 2, 3]), "version": 7]] as [String: Any]]
        }
        return NativeVisibilityStoreTestIO(preferences: try PropertyListSerialization.data(
            fromPropertyList: values, format: .binary, options: 0))
    }
    private func assertFailed(_ results: [String: Result<Void, Error>], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(results.count, 2, file: file, line: line)
        for result in results.values { XCTAssertThrowsError(try result.get(), file: file, line: line) }
    }
    private enum Failure: Error { case injected }
}
