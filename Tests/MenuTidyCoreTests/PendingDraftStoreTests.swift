import Foundation
import XCTest
@testable import MenuTidyCore

final class PendingDraftStoreTests: XCTestCase {
    private func rule(_ id: String, _ visibility: ItemVisibility = .collapsible) -> ItemRule {
        ItemRule(id: id, name: "Same display name", bundleIdentifier: "example.app", visibility: visibility)
    }

    private func identity(_ id: String, pid: Int32 = 42, launchTime: Double = 100) -> ObservedItemGroupHistory.Identity {
        ObservedItemGroupHistory.Identity(id: id, pid: pid, bundleIdentifier: "example.app", launchTime: launchTime)
    }

    private func roundTrip(_ store: PendingDraftStore) throws -> PendingDraftStore {
        try JSONDecoder().decode(PendingDraftStore.self, from: JSONEncoder().encode(store))
    }

    func testStableChoiceSurvivesRestartButNeverMatchesByNameOrBundle() throws {
        var store = PendingDraftStore()
        let original = rule("item:stable-one", .alwaysHidden)
        try store.set(original, sessionIdentity: nil)
        let restored = try roundTrip(store)

        XCTAssertEqual(restored.record(for: original.id, sessionIdentity: nil)?.rule, original)
        XCTAssertNil(restored.record(for: "item:another-same-app", sessionIdentity: nil))
        XCTAssertEqual(restored.records.count, 1, "Absence from a scan must not remove a stored edit.")
    }

    func testSessionChoiceIsUnboundAfterRestartEvenWithTheExactOldIdentity() throws {
        var store = PendingDraftStore()
        let original = rule("session:old")
        let owner = identity(original.id)
        try store.set(original, sessionIdentity: owner)
        XCTAssertNotNil(store.record(for: original.id, sessionIdentity: owner))

        var restored = try roundTrip(store)
        XCTAssertEqual(restored.records, store.records)
        XCTAssertNil(restored.record(for: original.id, sessionIdentity: owner))
        XCTAssertNil(restored.record(for: "session:new", sessionIdentity: identity("session:new")))
        XCTAssertThrowsError(try restored.set(original, sessionIdentity: owner))
        XCTAssertEqual(restored.records.count, 1, "An unbound old ID must not create another draft implicitly.")
    }

    func testProcessReplacementInvalidatesLiveBindingWithoutDeletingChoice() throws {
        var store = PendingDraftStore()
        let original = rule("session:one")
        try store.set(original, sessionIdentity: identity(original.id))
        XCTAssertNil(store.record(for: original.id, sessionIdentity: identity(original.id, launchTime: 200)))
        store.retainSessionBindings { _ in false }
        XCTAssertNil(store.record(for: original.id, sessionIdentity: identity(original.id)))
        XCTAssertEqual(store.records.count, 1)
    }

    func testEditsAndExplicitReassociationKeepOneRecordAndItsDesiredCategory() throws {
        var store = PendingDraftStore()
        let id = try store.set(rule("session:old"), sessionIdentity: identity("session:old"))
        let editedID = try store.set(rule("session:old", .alwaysHidden), sessionIdentity: identity("session:old"))
        XCTAssertEqual(id, editedID)
        store = try roundTrip(store)
        try store.reassociate(id: id, to: rule("session:new", .visible), sessionIdentity: identity("session:new"))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "session:new", sessionIdentity: identity("session:new"))?.id, id)
        XCTAssertEqual(store.records.first?.rule.visibility, .alwaysHidden)
        XCTAssertNil(store.record(for: "session:old", sessionIdentity: identity("session:old")))
    }

    func testReassociationToExistingDraftRejectsWithoutOverwritingEitherChoice() throws {
        var store = try PendingDraftStore(unassociatedRules: [rule("session:offline", .alwaysHidden)])
        let orphanID = try XCTUnwrap(store.records.first?.id)
        try store.set(rule("item:occupied", .visible), sessionIdentity: nil)
        let before = store.records
        XCTAssertThrowsError(try store.reassociate(id: orphanID, to: rule("item:occupied"), sessionIdentity: nil)) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        XCTAssertEqual(store.records, before)
    }

    func testPartialVerificationOnlyClearsMatchingCurrentChoice() throws {
        var store = PendingDraftStore()
        let first = rule("item:first")
        let second = rule("item:second", .alwaysHidden)
        try store.set(first, sessionIdentity: nil)
        try store.set(second, sessionIdentity: nil)
        try store.set(rule("session:offline"), sessionIdentity: identity("session:offline"))
        store = try roundTrip(store)

        store.removeVerified(rule(second.id, .visible), sessionIdentity: nil)
        store.removeVerified(rule("session:offline"), sessionIdentity: identity("session:offline"))
        XCTAssertEqual(store.records.count, 3, "A mismatch or an unbound session cannot count as verified.")
        store.removeVerified(first, sessionIdentity: nil)
        XCTAssertEqual(Set(store.records.map(\.rule.id)), [second.id, "session:offline"])
    }

    func testDiscardUnboundSessionLeavesOtherDraftsAndBindingsIntact() throws {
        var store = try PendingDraftStore(unassociatedRules: [rule("session:offline")])
        let orphanID = try XCTUnwrap(store.records.first?.id)
        let live = rule("session:live", .alwaysHidden)
        try store.set(live, sessionIdentity: identity(live.id))
        try store.set(rule("item:stable"), sessionIdentity: nil)
        store.remove(id: orphanID)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.record(for: live.id, sessionIdentity: identity(live.id))?.rule, live)
        XCTAssertNotNil(store.record(for: "item:stable", sessionIdentity: nil))
    }

    func testExplicitBackupImportNeverRebindsSessionAndRejectsDuplicates() throws {
        let old = rule("session:backed-up")
        let store = try PendingDraftStore(unassociatedRules: [old, rule("item:stable")])
        XCTAssertNil(store.record(for: old.id, sessionIdentity: identity(old.id)))
        XCTAssertEqual(store.record(for: "item:stable", sessionIdentity: nil)?.rule.id, "item:stable")
        XCTAssertThrowsError(try PendingDraftStore(unassociatedRules: [old, old]))
    }

    func testUnknownOwnerLifetimeCannotCreateOrBindSessionChoice() throws {
        var store = PendingDraftStore()
        XCTAssertThrowsError(try store.set(rule("session:new"), sessionIdentity: identity("session:new", launchTime: 0)))
        XCTAssertThrowsError(try store.set(rule("session:new"), sessionIdentity: identity("session:other")))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testArchiveRejectsDuplicateStableTargetsAndUnknownCategories() throws {
        let store = try PendingDraftStore(unassociatedRules: [rule("item:one")])
        let data = try JSONEncoder().encode(store)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(document["records"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(entries.first)
        duplicate["id"] = UUID().uuidString
        entries.append(duplicate)
        document["records"] = entries
        XCTAssertThrowsError(try JSONDecoder().decode(PendingDraftStore.self,
            from: JSONSerialization.data(withJSONObject: document)))

        let invalidCategory = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "collapsible", with: "unknown-category")
        XCTAssertThrowsError(try JSONDecoder().decode(PendingDraftStore.self, from: Data(invalidCategory.utf8)))
    }

    func testVerifiedSessionChoiceStopsBeingPendingButSurvivesRestartUnbound() throws {
        var store = PendingDraftStore()
        let original = rule("session:verified", .alwaysHidden)
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: owner))
        store.retainSessionBindings { $0 == owner }
        XCTAssertTrue(store.records.isEmpty, "A current owner must not make an applied choice pending again.")

        var restored = try roundTrip(store)
        XCTAssertEqual(restored.records.map(\.id), [id])
        XCTAssertEqual(restored.records.first?.rule, original)
        XCTAssertNil(restored.record(for: original.id, sessionIdentity: owner))
        XCTAssertThrowsError(try restored.set(original, sessionIdentity: owner)) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        try restored.reassociate(id: id, to: rule("session:restarted"), sessionIdentity: identity("session:restarted"))
        XCTAssertEqual(restored.record(for: "session:restarted", sessionIdentity: identity("session:restarted"))?.rule.visibility,
                       .alwaysHidden)
    }

    func testStableVerificationStillDeletesChoiceAcrossRestart() throws {
        var store = PendingDraftStore()
        let original = rule("item:verified")
        try store.set(original, sessionIdentity: nil)
        store.removeVerified(original, sessionIdentity: nil)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try roundTrip(store).records.isEmpty)
    }

    func testEditingVerifiedSessionKeepsOneRecordAndPersistsLatestChoice() throws {
        var store = PendingDraftStore()
        let original = rule("session:edited")
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)

        let edited = rule(original.id, .alwaysHidden)
        XCTAssertEqual(try store.set(edited, sessionIdentity: owner), id)
        XCTAssertEqual(store.records.map(\.id), [id])
        XCTAssertEqual(store.record(for: original.id, sessionIdentity: owner)?.rule, edited)
        let whilePending = try roundTrip(store)
        XCTAssertEqual(whilePending.records.map(\.id), [id])
        XCTAssertEqual(whilePending.records.first?.rule, edited, "The pending edit overrides its saved baseline exactly once.")

        store.removeVerified(edited, sessionIdentity: owner)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try roundTrip(store).records.first?.rule, edited)
        XCTAssertEqual(try store.set(original, sessionIdentity: owner), id)
        XCTAssertEqual(store.records.first?.rule, original, "Applying an edit must replace the retained baseline.")
    }

    func testReturningToVerifiedCategoryCancelsEditWithoutLosingSavedChoice() throws {
        var store = PendingDraftStore()
        let original = rule("session:cancel-category")
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        try store.set(rule(original.id, .alwaysHidden), sessionIdentity: owner)

        XCTAssertEqual(try store.set(original, sessionIdentity: owner), id)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: owner))
        XCTAssertEqual(try roundTrip(store).records.first?.rule, original)
    }

    func testDiscardingSessionEditRestoresBaselineAndExplicitRemovalForgetsIt() throws {
        var store = PendingDraftStore()
        let original = rule("session:cancel-edit")
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        let other = rule("item:other", .visible)
        try store.set(other, sessionIdentity: nil)
        try store.set(rule(original.id, .alwaysHidden), sessionIdentity: owner)

        store.remove(id: id)
        XCTAssertEqual(store.records.map(\.rule), [other])
        let restored = try roundTrip(store)
        XCTAssertEqual(restored.records.first(where: { $0.id == id })?.rule, original)
        XCTAssertEqual(restored.records.count, 2)

        store.remove(id: id)
        XCTAssertEqual(try roundTrip(store).records.map(\.rule), [other])
        XCTAssertNotEqual(try store.set(original, sessionIdentity: owner), id)
    }

    func testVerifiedTargetRejectsReassociationAndReplacementOwnerWithoutOverwritingChoices() throws {
        let offline = rule("session:offline", .alwaysHidden)
        var store = try PendingDraftStore(unassociatedRules: [offline])
        let orphanID = try XCTUnwrap(store.records.first?.id)
        let applied = rule("session:occupied")
        let owner = identity(applied.id)
        try store.set(applied, sessionIdentity: owner)
        store.removeVerified(applied, sessionIdentity: owner)
        let before = try roundTrip(store).records

        XCTAssertThrowsError(try store.reassociate(id: orphanID, to: applied, sessionIdentity: owner)) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        XCTAssertThrowsError(try store.set(rule(applied.id, .visible),
                                         sessionIdentity: identity(applied.id, launchTime: 200))) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        XCTAssertEqual(try roundTrip(store).records, before)
        XCTAssertEqual(store.records.map(\.rule), [offline])
    }

    func testOwnerReplacementRestoresVerifiedChoiceAsUnboundDraft() throws {
        var store = PendingDraftStore()
        let original = rule("session:departed", .alwaysHidden)
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        let live = rule("session:staying")
        let liveOwner = identity(live.id, pid: 43)
        try store.set(live, sessionIdentity: liveOwner)
        store.removeVerified(live, sessionIdentity: liveOwner)

        store.retainSessionBindings { $0 == liveOwner }
        XCTAssertEqual(store.records.map(\.id), [id])
        XCTAssertEqual(store.records.first?.rule, original)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: owner))
        let replacement = identity(original.id, launchTime: 200)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: replacement))
        XCTAssertThrowsError(try store.set(original, sessionIdentity: replacement))
        try store.reassociate(id: id, to: original, sessionIdentity: replacement)
        XCTAssertEqual(store.record(for: original.id, sessionIdentity: replacement)?.id, id)
        XCTAssertEqual(try roundTrip(store).records.count, 2)
    }

    func testOwnerInvalidationKeepsLatestPendingEditInsteadOfVerifiedBaseline() throws {
        var store = PendingDraftStore()
        let original = rule("session:pending-owner")
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        let edited = rule(original.id, .alwaysHidden)
        try store.set(edited, sessionIdentity: owner)

        store.retainSessionBindings { _ in false }
        XCTAssertEqual(store.records.map(\.id), [id])
        XCTAssertEqual(store.records.first?.rule, edited)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: owner))
        XCTAssertEqual(try roundTrip(store).records, store.records)
        store.remove(id: id)
        XCTAssertTrue(try roundTrip(store).records.isEmpty, "An offline draft has no live verified baseline to restore.")
    }

    func testExplicitReassociationTransfersChoiceWithoutOldVerificationOrDuplicateTarget() throws {
        var store = PendingDraftStore()
        let original = rule("session:moving")
        let owner = identity(original.id)
        let id = try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        try store.set(rule(original.id, .alwaysHidden), sessionIdentity: owner)

        try store.reassociate(id: id, to: rule("item:new-stable", .visible), sessionIdentity: nil)
        let restored = try roundTrip(store)
        XCTAssertEqual(restored.records.map(\.id), [id])
        XCTAssertEqual(restored.records.first?.rule.id, "item:new-stable")
        XCTAssertEqual(restored.records.first?.rule.visibility, .alwaysHidden)
        XCTAssertNil(store.record(for: original.id, sessionIdentity: owner))
        store.removeVerified(rule("item:new-stable", .alwaysHidden), sessionIdentity: nil)
        XCTAssertTrue(try roundTrip(store).records.isEmpty)
    }

    func testWrongSessionOwnerOrCategoryCannotClearPendingEditOrChangeRetainedBaseline() throws {
        var store = PendingDraftStore()
        let original = rule("session:verify-mismatch")
        let owner = identity(original.id)
        try store.set(original, sessionIdentity: owner)
        store.removeVerified(original, sessionIdentity: owner)
        let edited = rule(original.id, .alwaysHidden)
        try store.set(edited, sessionIdentity: owner)

        store.removeVerified(edited, sessionIdentity: identity(original.id, pid: 99))
        store.removeVerified(original, sessionIdentity: owner)
        XCTAssertEqual(store.record(for: original.id, sessionIdentity: owner)?.rule, edited)
        XCTAssertEqual(try roundTrip(store).records.map(\.rule), [edited])
        let id = try XCTUnwrap(store.records.first?.id)
        store.remove(id: id)
        XCTAssertEqual(try roundTrip(store).records.map(\.rule), [original])
    }
}
