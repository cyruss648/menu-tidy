import Foundation
import XCTest
@testable import MenuTidyCore

final class TrayPlacementPolicyTests: XCTestCase {
    typealias Candidate = TrayPlacementPolicy.Candidate

    func testApplyIncludesPendingAndFailureButExcludesCompletedOfflineProtectedAndQueued() {
        let candidates = [
            Candidate(id: "pending", group: .alwaysHidden, isPending: true),
            Candidate(id: "failed", group: .collapsible, isPending: true, hasFailure: true),
            Candidate(id: "completed", group: .visible, isPending: false),
            Candidate(id: "offline", group: .alwaysHidden, isAvailable: false, isPending: true, hasFailure: true),
            Candidate(id: "protected", group: .visible, canMove: false, isPending: true, hasFailure: true),
            Candidate(id: "ambiguous", group: .collapsible, hasUniqueIdentity: false, isPending: true),
            Candidate(id: "queued", group: .visible, isPending: true, hasFailure: true, isQueued: true),
            Candidate(id: "identify", group: .alwaysHidden, isPending: true, hasFailure: true, needsIdentification: true)
        ]
        XCTAssertEqual(TrayPlacementPolicy.candidates(candidates, for: .applyPending).map(\.id), ["pending", "failed"])
        XCTAssertEqual(TrayPlacementPolicy.candidates(candidates, for: .retryFailed).map(\.id), ["failed"])
        XCTAssertEqual(candidates.filter(\.isOutstanding).map(\.id), ["pending", "failed", "queued", "identify"])
    }

    func testOwnershipConflictRemainsOutstandingButIsExcludedFromBothBatchActions() {
        let conflict = Candidate(id: "conflict", group: .alwaysHidden, isPending: true,
                                 hasFailure: true, needsOwnershipRepair: true)
        let transient = Candidate(id: "transient", group: .collapsible, isPending: true, hasFailure: true)
        XCTAssertTrue(conflict.isOutstanding)
        for action in [TrayPlacementPolicy.Action.applyPending, .retryFailed] {
            XCTAssertEqual(TrayPlacementPolicy.candidates([conflict, transient], for: action).map(\.id), ["transient"])
        }
        let repaired = Candidate(id: "conflict", group: .alwaysHidden, isPending: true, hasFailure: true)
        XCTAssertEqual(TrayPlacementPolicy.candidates([repaired], for: .retryFailed).map(\.group), [.alwaysHidden])
    }

    func testDuplicateIdentityIsExcludedInsteadOfChoosingOneRow() {
        let candidates = [Candidate(id: "same", group: .alwaysHidden, isPending: true),
                          Candidate(id: "same", group: .visible, isPending: true, hasFailure: true)]
        XCTAssertTrue(TrayPlacementPolicy.candidates(candidates, for: .applyPending).isEmpty)
        XCTAssertTrue(TrayPlacementPolicy.candidates(candidates, for: .retryFailed).isEmpty)
    }

    func testBatchRetriesOncePreservesGroupsAndExplicitLatestSelectionWins() throws {
        let candidates = [Candidate(id: "a", group: .alwaysHidden, isPending: true, hasFailure: true),
                          Candidate(id: "b", group: .collapsible, isPending: true, hasFailure: true)]
        var queue = TrayPlacementQueue()
        for candidate in TrayPlacementPolicy.candidates(candidates, for: .retryFailed) {
            queue.enqueue(id: candidate.id, group: candidate.group)
        }
        let first = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(first.group, .alwaysHidden)
        queue.enqueue(id: "b", group: .visible)
        queue.finish(token: first.token) // Failure itself never reinserts a request.
        let second = try XCTUnwrap(queue.claimNext())
        XCTAssertEqual(second.id, "b")
        XCTAssertEqual(second.group, .visible)
        XCTAssertFalse(second.resolveAmbiguousKey, "Bulk retry must not start an identity experiment.")
        queue.finish(token: second.token)
        XCTAssertNil(queue.claimNext())
    }

    func testCancelBatchKeepsActiveTokenUntilCleanupAndDropsEveryWaitingChoice() throws {
        var queue = TrayPlacementQueue()
        for group in ItemVisibility.allCases { queue.enqueue(id: group.rawValue, group: group) }
        let active = try XCTUnwrap(queue.claimNext())
        queue.cancelAllPending()
        XCTAssertEqual(queue.active, active)
        XCTAssertNil(queue.claimNext())
        queue.finish(token: active.token)
        XCTAssertNil(queue.claimNext())
    }

    private func target(_ id: String) -> TrayPlacementPolicy.DraftTarget {
        .init(rule: ItemRule(id: id, name: id, bundleIdentifier: "example.app", visibility: .visible),
              identity: id.hasPrefix("session:") ? .init(id: id, pid: 42, bundleIdentifier: "example.app", launchTime: 100) : nil)
    }

    func testExplicitAssociationPreservesOfflineGroupAndSupersedesNativeSiblingChoice() throws {
        let offline = ItemRule(id: "session:old", name: "Offline", bundleIdentifier: "example.app", visibility: .alwaysHidden)
        var store = try PendingDraftStore(unassociatedRules: [offline])
        let recordID = try XCTUnwrap(store.records.first?.id)
        let source = target("session:live")
        let sibling = target("session:sibling")
        try store.set(sibling.rule, sessionIdentity: sibling.identity)
        let choices = NativeTrayChoices(existing: ["example.app": .visible, "example.other": .collapsible])
        let prepared = try TrayPlacementPolicy.reassociatingDraft(in: store, id: recordID, to: source,
            currentTargets: [source, sibling], nativeChoices: choices)

        XCTAssertEqual(prepared.nativeChoices?.group(bundle: "example.app"), .alwaysHidden)
        XCTAssertEqual(prepared.nativeChoices?.group(bundle: "example.other"), .collapsible)
        XCTAssertEqual(prepared.affectedIDs, [source.rule.id, sibling.rule.id])
        XCTAssertEqual(prepared.drafts.record(for: source.rule.id, sessionIdentity: source.identity)?.id, recordID)
        XCTAssertTrue(prepared.drafts.records.allSatisfy { $0.rule.visibility == .alwaysHidden })
        XCTAssertNil(store.record(for: source.rule.id, sessionIdentity: source.identity), "Preparation must not mutate the input store.")
        XCTAssertEqual(choices.group(bundle: "example.app"), .visible)
    }

    func testAssociationConflictRollsBackOfflineRecordAndEverySiblingChange() throws {
        let old = ItemRule(id: "session:old", name: "Offline", bundleIdentifier: "example.app", visibility: .alwaysHidden)
        let conflict = target("session:unbound")
        let store = try PendingDraftStore(unassociatedRules: [old, conflict.rule])
        let recordID = try XCTUnwrap(store.records.first(where: { $0.rule.id == old.id })?.id)
        let before = store.records
        let choices = NativeTrayChoices(existing: ["example.app": .visible])
        XCTAssertThrowsError(try TrayPlacementPolicy.reassociatingDraft(in: store, id: recordID,
            to: target("session:live"), currentTargets: [target("session:live"), target("session:earlier"), conflict],
            nativeChoices: choices)) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        XCTAssertEqual(store.records, before)
        XCTAssertEqual(choices.group(bundle: "example.app"), .visible)
        XCTAssertNil(store.record(for: "session:live", sessionIdentity: target("session:live").identity))
    }

    func testLegacyAssociationDoesNotRewriteUnrelatedSiblingOrInventNativeIntent() throws {
        let offline = ItemRule(id: "session:old", name: "Offline", bundleIdentifier: "example.app", visibility: .alwaysHidden)
        var store = try PendingDraftStore(unassociatedRules: [offline])
        let id = try XCTUnwrap(store.records.first?.id)
        let sibling = target("session:sibling")
        try store.set(sibling.rule, sessionIdentity: sibling.identity)
        let prepared = try TrayPlacementPolicy.reassociatingDraft(in: store, id: id,
            to: target("session:live"), currentTargets: [sibling], nativeChoices: nil)
        XCTAssertNil(prepared.nativeChoices)
        XCTAssertEqual(prepared.affectedIDs, ["session:live"])
        XCTAssertEqual(prepared.drafts.record(for: sibling.rule.id, sessionIdentity: sibling.identity)?.rule.visibility, .visible)
    }

    func testSharedNativeChoiceReplacesEveryCurrentSiblingDraftAndCanBeVerified() throws {
        let siblings = [target("session:a"), target("session:b")]
        var store = try TrayPlacementPolicy.replacingDrafts(in: PendingDraftStore(), targets: siblings, group: .alwaysHidden)
        store = try TrayPlacementPolicy.replacingDrafts(in: store, targets: siblings, group: .visible)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertTrue(store.records.allSatisfy { $0.rule.visibility == .visible })
        for sibling in siblings {
            store.removeVerified(sibling.rule, sessionIdentity: sibling.identity)
        }
        XCTAssertTrue(store.records.isEmpty, "A superseded hidden sibling draft must not remain pending forever.")
    }

    func testOfflineSessionIsNeverReassociatedAndPartialSiblingEditIsNotCommitted() throws {
        let offline = target("session:offline")
        let store = try PendingDraftStore(unassociatedRules: [offline.rule])
        let before = store.records
        XCTAssertThrowsError(try TrayPlacementPolicy.replacingDrafts(in: store,
            targets: [target("session:live"), offline], group: .alwaysHidden)) {
            XCTAssertEqual($0 as? PendingDraftStore.StoreError, .targetHasDraft)
        }
        XCTAssertEqual(store.records, before)
        XCTAssertNil(store.record(for: offline.rule.id, sessionIdentity: offline.identity))
        let updated = try TrayPlacementPolicy.replacingDrafts(in: store,
            targets: [target("session:live")], group: .alwaysHidden)
        XCTAssertEqual(updated.records.first(where: { $0.id == before.first?.id })?.rule.visibility, .visible)
        XCTAssertNil(updated.record(for: offline.rule.id, sessionIdentity: offline.identity))
    }

    func testPanelRespectsAllThreeChoicesAndKeepsUnrestoredIconsReachable() {
        for includeAlwaysHidden in [false, true] {
            XCTAssertFalse(TrayPlacementPolicy.includesInPanel(group: .visible,
                verifiedGroup: nil, includeAlwaysHidden: includeAlwaysHidden))
            XCTAssertTrue(TrayPlacementPolicy.includesInPanel(group: .collapsible,
                verifiedGroup: nil, includeAlwaysHidden: includeAlwaysHidden))
            XCTAssertEqual(TrayPlacementPolicy.includesInPanel(group: .alwaysHidden,
                verifiedGroup: .collapsible, includeAlwaysHidden: includeAlwaysHidden), includeAlwaysHidden)
            XCTAssertTrue(TrayPlacementPolicy.includesInPanel(group: .visible,
                verifiedGroup: .collapsible, includeAlwaysHidden: includeAlwaysHidden))
            XCTAssertEqual(TrayPlacementPolicy.includesInPanel(group: .visible,
                verifiedGroup: .alwaysHidden, includeAlwaysHidden: includeAlwaysHidden), includeAlwaysHidden)
        }
    }
}
