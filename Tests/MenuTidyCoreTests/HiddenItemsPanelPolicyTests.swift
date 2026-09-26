import XCTest
@testable import MenuTidyCore

final class HiddenItemsPanelPolicyTests: XCTestCase {
    func testUnappliedDraftCannotRevealSavedAlwaysHiddenItem() {
        let saved = ItemRule(id: "item.private", name: "图标", bundleIdentifier: nil, visibility: .alwaysHidden)
        var drafts = ItemRuleBook(rules: [saved.id: saved])
        var edited = saved
        edited.visibility = .collapsible
        drafts.set(edited)
        let reconciled = ManualArrangementRules.reconcile(
            saved: ItemRuleBook(rules: [saved.id: saved]), drafts: drafts, observed: [saved])

        XCTAssertEqual(reconciled.drafts.rule(for: saved.id)?.visibility, .collapsible)
        XCTAssertFalse(HiddenItemsPanelPolicy.includes(
            savedVisibility: reconciled.saved.rule(for: saved.id)?.visibility,
            observedVisibility: .alwaysHidden, includeAlwaysHidden: false))
        XCTAssertTrue(HiddenItemsPanelPolicy.includes(
            savedVisibility: reconciled.saved.rule(for: saved.id)?.visibility,
            observedVisibility: .alwaysHidden, includeAlwaysHidden: true))
    }

    func testSavedPrivacyChoiceWinsOverConflictingObservation() {
        XCTAssertFalse(HiddenItemsPanelPolicy.includes(
            savedVisibility: .alwaysHidden, observedVisibility: .collapsible, includeAlwaysHidden: false))
        XCTAssertTrue(HiddenItemsPanelPolicy.includes(
            savedVisibility: .collapsible, observedVisibility: nil, includeAlwaysHidden: false))
    }

    func testVerifiedUnsavedAndSessionItemsCanAppearWithoutDrafts() {
        XCTAssertTrue(HiddenItemsPanelPolicy.includes(
            savedVisibility: nil, observedVisibility: .collapsible, includeAlwaysHidden: false))
        XCTAssertFalse(HiddenItemsPanelPolicy.includes(
            savedVisibility: nil, observedVisibility: .alwaysHidden, includeAlwaysHidden: false))
        XCTAssertTrue(HiddenItemsPanelPolicy.includes(
            savedVisibility: nil, observedVisibility: .alwaysHidden, includeAlwaysHidden: true))
    }

    func testUnknownAndVisibleItemsDoNotEnterEitherHiddenPanel() {
        for includeAlwaysHidden in [false, true] {
            XCTAssertFalse(HiddenItemsPanelPolicy.includes(
                savedVisibility: nil, observedVisibility: nil, includeAlwaysHidden: includeAlwaysHidden))
            XCTAssertFalse(HiddenItemsPanelPolicy.includes(
                savedVisibility: .visible, observedVisibility: .collapsible, includeAlwaysHidden: includeAlwaysHidden))
            XCTAssertFalse(HiddenItemsPanelPolicy.includes(
                savedVisibility: nil, observedVisibility: .visible, includeAlwaysHidden: includeAlwaysHidden))
        }
    }
}
