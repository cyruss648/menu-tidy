import XCTest
@testable import MenuTidyCore

final class ManualArrangementRulesTests: XCTestCase {
    private func rule(_ id: String, _ visibility: ItemVisibility, name: String = "菜单项目") -> ItemRule {
        ItemRule(id: id, name: name, bundleIdentifier: "example.application", visibility: visibility)
    }

    private func book(_ rules: ItemRule...) -> ItemRuleBook {
        ItemRuleBook(rules: Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) }))
    }

    func testUneditedMirrorFollowsManualPositionDespiteMetadataChanges() {
        let saved = rule("item.one", .visible, name: "旧名称")
        let mirror = rule("item.one", .visible, name: "显示名称已变化")
        let observed = rule("item.one", .alwaysHidden, name: "最新名称")

        let result = ManualArrangementRules.reconcile(
            saved: book(saved), drafts: book(mirror), observed: [observed])

        XCTAssertEqual(result.saved.rule(for: saved.id), observed)
        XCTAssertEqual(result.drafts.rule(for: saved.id), observed)
    }

    func testExplicitGUIDraftSurvivesWhileSavedRuleReflectsActualPosition() {
        let saved = rule("item.one", .visible)
        let draft = rule("item.one", .collapsible, name: "保留草稿元数据")
        let observed = rule("item.one", .alwaysHidden)

        let result = ManualArrangementRules.reconcile(
            saved: book(saved), drafts: book(draft), observed: [observed])

        XCTAssertEqual(result.saved.rule(for: saved.id), observed)
        XCTAssertEqual(result.drafts.rule(for: saved.id), draft)
    }

    func testNewGUIDraftWithoutSavedRuleIsStillExplicit() {
        let draft = rule("item.new", .alwaysHidden)
        let observed = rule("item.new", .visible)

        let result = ManualArrangementRules.reconcile(
            saved: ItemRuleBook(), drafts: book(draft), observed: [observed])

        XCTAssertEqual(result.saved.rule(for: draft.id), observed)
        XCTAssertEqual(result.drafts.rule(for: draft.id), draft)
    }

    func testNewObservedItemAndSavedItemWithoutDraftGainMirrors() {
        let saved = rule("item.saved", .visible)
        let changed = rule("item.saved", .collapsible)
        let added = rule("item.new", .alwaysHidden)

        let result = ManualArrangementRules.reconcile(
            saved: book(saved), drafts: ItemRuleBook(), observed: [changed, added])

        XCTAssertEqual(result.saved, book(changed, added))
        XCTAssertEqual(result.drafts, book(changed, added))
    }

    func testMissingOrUnverifiedItemsAreNotRemovedOrAssignedDefaultGroups() {
        let unavailable = rule("item.unavailable", .alwaysHidden)
        let unavailableDraft = rule("item.unavailable", .collapsible)
        let draftOnly = rule("item.pending", .alwaysHidden)
        let observed = rule("item.available", .visible)
        let originalSaved = book(unavailable)
        let originalDrafts = book(unavailableDraft, draftOnly)

        let empty = ManualArrangementRules.reconcile(
            saved: originalSaved, drafts: originalDrafts, observed: [])
        XCTAssertEqual(empty.saved, originalSaved)
        XCTAssertEqual(empty.drafts, originalDrafts)

        let partial = ManualArrangementRules.reconcile(
            saved: originalSaved, drafts: originalDrafts, observed: [observed])
        XCTAssertEqual(partial.saved, book(unavailable, observed))
        XCTAssertEqual(partial.drafts, book(unavailableDraft, draftOnly, observed))
        XCTAssertNil(partial.saved.rule(for: draftOnly.id))
    }

    func testSessionItemsFromSameApplicationRemainIndependentInMemory() {
        let first = rule("session:first", .alwaysHidden)
        let second = rule("session:second", .collapsible)

        let result = ManualArrangementRules.reconcile(
            saved: ItemRuleBook(), drafts: ItemRuleBook(), observed: [first, second])

        XCTAssertEqual(result.saved, book(first, second))
        XCTAssertEqual(result.drafts, book(first, second))
    }

    func testConflictingDuplicateIdentityLeavesBothPreviousRulesUntouched() {
        let saved = rule("item.ambiguous", .visible)
        let draft = rule("item.ambiguous", .collapsible)
        let duplicateOne = rule(saved.id, .alwaysHidden)
        let duplicateTwo = rule(saved.id, .collapsible)
        let unambiguous = rule("item.unique", .alwaysHidden)

        let result = ManualArrangementRules.reconcile(
            saved: book(saved), drafts: book(draft),
            observed: [duplicateOne, unambiguous, duplicateTwo])

        XCTAssertEqual(result.saved, book(saved, unambiguous))
        XCTAssertEqual(result.drafts, book(draft, unambiguous))
    }

    func testIdenticalDuplicateObservationsCannotCreateNewRule() {
        let ambiguous = rule("item.duplicate", .alwaysHidden)

        let result = ManualArrangementRules.reconcile(
            saved: ItemRuleBook(), drafts: ItemRuleBook(), observed: [ambiguous, ambiguous])

        XCTAssertTrue(result.saved.rules.isEmpty)
        XCTAssertTrue(result.drafts.rules.isEmpty)
    }

    func testMixedReconciliationIsIdempotentAndObservationOrderIndependent() {
        let first = rule("item.first", .visible)
        let second = rule("item.second", .visible)
        let edited = rule(second.id, .collapsible)
        let observed = [rule(first.id, .collapsible), rule(second.id, .alwaysHidden)]
        let initialSaved = book(first, second)
        let initialDrafts = book(first, edited)

        let once = ManualArrangementRules.reconcile(
            saved: initialSaved, drafts: initialDrafts, observed: observed)
        let twice = ManualArrangementRules.reconcile(
            saved: once.saved, drafts: once.drafts, observed: observed)
        let reordered = ManualArrangementRules.reconcile(
            saved: initialSaved, drafts: initialDrafts, observed: observed.reversed())

        XCTAssertEqual(once.saved, book(observed[0], observed[1]))
        XCTAssertEqual(once.drafts, book(observed[0], edited))
        XCTAssertEqual(twice.saved, once.saved)
        XCTAssertEqual(twice.drafts, once.drafts)
        XCTAssertEqual(reordered.saved, once.saved)
        XCTAssertEqual(reordered.drafts, once.drafts)
    }
}
