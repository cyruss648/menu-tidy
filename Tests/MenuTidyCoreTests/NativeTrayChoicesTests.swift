import Foundation
import XCTest
@testable import MenuTidyCore

final class NativeTrayChoicesTests: XCTestCase {
    func testForgetOfflineExactBundlePreservesOtherApplicationAndCase() throws {
        var choices = NativeTrayChoices(existing: ["org.example.App": .alwaysHidden,
                                                   "org.example.AppHelper": .collapsible,
                                                   "org.example.app": .visible])
        XCTAssertTrue(choices.remove(bundle: "org.example.App", liveBundles: ["org.example.AppHelper"]))
        XCTAssertNil(choices.group(bundle: "org.example.App"))
        XCTAssertEqual(choices.group(bundle: "org.example.AppHelper"), .collapsible)
        XCTAssertEqual(choices.group(bundle: "org.example.app"), .visible)
        let reloaded = try JSONDecoder().decode(NativeTrayChoices.self, from: JSONEncoder().encode(choices))
        XCTAssertNil(reloaded.group(bundle: "org.example.App"))
    }

    func testForgetCannotChangeChoiceWhileAnySiblingIsLive() {
        var choices = NativeTrayChoices(existing: ["org.example.App": .alwaysHidden])
        XCTAssertFalse(NativeTrayChoices.canForget(bundle: "org.example.App", liveBundles: ["org.example.App"]))
        XCTAssertFalse(choices.remove(bundle: "org.example.App", liveBundles: ["org.example.App"]))
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .alwaysHidden)
    }

    func testForgetRejectsUnknownSystemOwnAndGuessedBundleIdentifiers() {
        for bundle in ["", "App", "org.example.App ", "com.apple.App", "COM.APPLE.App", "dev.hdh.MenuTidy"] {
            XCTAssertFalse(NativeTrayChoices.canForget(bundle: bundle, liveBundles: [], excluding: ["dev.hdh.MenuTidy"]), bundle)
        }
        var choices = NativeTrayChoices(existing: ["org.example.App": .alwaysHidden])
        XCTAssertFalse(choices.remove(bundle: "org.example.app", liveBundles: []))
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .alwaysHidden)
    }

    private func book(_ entries: [(String, String?, ItemVisibility)]) -> ItemRuleBook {
        ItemRuleBook(rules: Dictionary(uniqueKeysWithValues: entries.map { id, bundle, group in
            (id, ItemRule(id: id, name: "Fixture", bundleIdentifier: bundle, visibility: group))
        }))
    }

    func testConsistentOldIDsMigrateOnceWithoutDependingOnIDGrammar() {
        var choices = NativeTrayChoices()
        let imported = choices.migrate(saved: book([
            ("position:old", "org.example.App", .collapsible),
            ("session:old", "org.example.App", .collapsible),
            ("ax:old", "org.example.App", .collapsible)
        ]))
        XCTAssertEqual(imported, ["org.example.App"])
        XCTAssertEqual(choices.choices.count, 1)
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .collapsible)
    }

    func testVisibleHiddenConflictDoesNotPickOneAndDoesNotBlockOtherBundles() {
        var choices = NativeTrayChoices()
        let imported = choices.migrate(saved: book([
            ("a", "org.example.Mixed", .visible),
            ("b", "org.example.Mixed", .collapsible),
            ("c", "org.example.Other", .alwaysHidden)
        ]))
        XCTAssertEqual(imported, ["org.example.Other"])
        XCTAssertNil(choices.group(bundle: "org.example.Mixed"))
        XCTAssertEqual(choices.group(bundle: "org.example.Other"), .alwaysHidden)
    }

    func testDifferentHiddenCategoriesRemainAConflict() {
        var choices = NativeTrayChoices()
        XCTAssertTrue(choices.migrate(saved: book([
            ("a", "org.example.Mixed", .collapsible),
            ("b", "org.example.Mixed", .alwaysHidden)
        ])).isEmpty)
        XCTAssertNil(choices.group(bundle: "org.example.Mixed"))
    }

    func testExistingNativeIntentWinsIncludingExplicitVisibleChoice() {
        var choices = NativeTrayChoices(existing: ["org.example.App": .visible])
        XCTAssertTrue(choices.migrate(saved: book([
            ("old", "org.example.App", .alwaysHidden)
        ])).isEmpty)
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .visible)
        XCTAssertTrue(choices.set(bundle: "org.example.App", group: .collapsible))
        choices.migrate(saved: book([("older", "org.example.App", .visible)]))
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .collapsible)
    }

    func testAppleAndExplicitOwnBundlesAreNotMigrated() {
        var choices = NativeTrayChoices()
        let imported = choices.migrate(saved: book([
            ("system", "com.apple.controlcenter", .collapsible),
            ("system-case", "COM.APPLE.MenuBarAgent", .alwaysHidden),
            ("own", "dev.hdh.MenuTidy", .alwaysHidden),
            ("other", "org.example.App", .visible),
            ("similar", "dev.hdh.MenuTidyHelper", .collapsible)
        ]), excluding: ["dev.hdh.MenuTidy"])
        XCTAssertEqual(imported, ["org.example.App", "dev.hdh.MenuTidyHelper"])
        XCTAssertNil(choices.group(bundle: "com.apple.controlcenter"))
        XCTAssertNil(choices.group(bundle: "dev.hdh.MenuTidy"))
    }

    func testIncompleteIdentifiersAreNotTrimmedOrGuessed() {
        let invalid: [String?] = [nil, "", "App", ".org.example", "org.example.",
                                  "org..example", " org.example", "org.example ",
                                  "org.example/Other", "org.example_*", "组织.example"]
        var choices = NativeTrayChoices()
        let rules = invalid.enumerated().map { ("item.\($0.offset)", $0.element, ItemVisibility.alwaysHidden) }
        XCTAssertTrue(choices.migrate(saved: book(rules)).isEmpty)
        for bundle in invalid.compactMap({ $0 }) {
            XCTAssertFalse(choices.set(bundle: bundle, group: .collapsible), bundle)
        }
        XCTAssertTrue(choices.choices.isEmpty)
    }

    func testSetRejectsSystemAndOwnBundleWithoutChangingExistingIntent() {
        var choices = NativeTrayChoices(existing: ["org.example.App": .visible])
        XCTAssertFalse(choices.set(bundle: "com.apple", group: .alwaysHidden))
        XCTAssertFalse(choices.set(bundle: "com.apple.App", group: .alwaysHidden))
        XCTAssertFalse(choices.set(bundle: "dev.hdh.MenuTidy", group: .alwaysHidden,
                                   excluding: ["dev.hdh.MenuTidy"]))
        XCTAssertEqual(choices.choices, ["org.example.App": .visible])
    }

    func testRoundTripRetainsEveryVisibilityCategoryAndExactCase() throws {
        var choices = NativeTrayChoices()
        for group in ItemVisibility.allCases {
            XCTAssertTrue(choices.set(bundle: "org.example.\(group.rawValue)", group: group))
        }
        XCTAssertTrue(choices.set(bundle: "org.example.MixedCase", group: .visible))
        let decoded = try JSONDecoder().decode(NativeTrayChoices.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(decoded, choices)
        XCTAssertNil(decoded.group(bundle: "org.example.mixedcase"))
    }

    func testUnknownCategoryAndUnsafePersistedBundleRejectDecode() {
        for json in [
            #"{"choices":{"org.example.App":"futureCategory"}}"#,
            #"{"choices":{"com.apple.App":"alwaysHidden"}}"#,
            #"{"choices":{" org.example.App":"collapsible"}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(NativeTrayChoices.self, from: Data(json.utf8)))
        }
    }

    func testObservedSnowShotIdentifierWithUnderscorePersistsWithoutNormalization() throws {
        let bundle = "com.snowshot.snow_shot"
        var choices = NativeTrayChoices()
        XCTAssertTrue(choices.set(bundle: bundle, group: .collapsible))
        let reloaded = try JSONDecoder().decode(NativeTrayChoices.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(reloaded.group(bundle: bundle), .collapsible)
        XCTAssertNil(reloaded.group(bundle: "com.snowshot.snow-shot"))
        var migrated = NativeTrayChoices()
        XCTAssertEqual(migrated.migrate(saved: book([("session:snow-shot", bundle, .collapsible)])), [bundle])
        let identity = ObservedItemGroupHistory.Identity(id: "session:snow-shot", pid: 42,
            bundleIdentifier: bundle, launchTime: 100)
        let rule = ItemRule(id: identity.id, name: "Snow Shot", bundleIdentifier: bundle, visibility: .collapsible)
        var drafts = PendingDraftStore()
        try drafts.set(rule, sessionIdentity: identity)
        drafts.removeVerified(rule, sessionIdentity: identity, nativeChoices: reloaded)
        let restored = try JSONDecoder().decode(PendingDraftStore.self, from: JSONEncoder().encode(drafts))
        XCTAssertTrue(restored.records.isEmpty)
    }

    func testMigrationIsIdempotentAndPreservesUnmentionedChoices() {
        var choices = NativeTrayChoices(existing: ["org.example.Offline": .alwaysHidden])
        let saved = book([("one", "org.example.App", .visible)])
        XCTAssertEqual(choices.migrate(saved: saved), ["org.example.App"])
        XCTAssertTrue(choices.migrate(saved: saved).isEmpty)
        XCTAssertEqual(choices.group(bundle: "org.example.Offline"), .alwaysHidden)
        XCTAssertEqual(choices.group(bundle: "org.example.App"), .visible)
    }
}
