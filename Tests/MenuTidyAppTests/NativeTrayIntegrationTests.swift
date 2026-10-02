import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class NativeTrayIntegrationTests: XCTestCase {
    private let bundle = "org.example.MenuTidyFixture"

    @MainActor
    private func environment(_ rules: [ItemRule]) -> MenuTidyTestEnvironment {
        let result = MenuTidyTestEnvironment()
        for (index, rule) in rules.enumerated() {
            let pid = Int32(10000 + index)
            result.snapshots.append(MenuBarItemSnapshot(id: rule.id, processIdentifier: pid,
                name: rule.name, ownerName: rule.name, bundleIdentifier: rule.bundleIdentifier,
                frame: CGRect(x: index * 30, y: 0, width: 22, height: 22), hasReliableGeometry: true,
                canMove: true, detail: "", persistentIdentity: rule.id.hasPrefix("item:"), ownIdentifier: nil))
            result.identities[rule.id] = ObservedItemGroupHistory.Identity(id: rule.id, pid: pid,
                bundleIdentifier: rule.bundleIdentifier, launchTime: 100)
        }
        return result
    }

    private func rule(_ id: String, _ group: ItemVisibility, name: String = "Fixture") -> ItemRule {
        ItemRule(id: id, name: name, bundleIdentifier: bundle, visibility: group)
    }

    private func save(_ rules: [ItemRule], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(ItemRuleBook(rules: Dictionary(uniqueKeysWithValues:
            rules.map { ($0.id, $0) }))), forKey: "itemRules.v1")
        defaults.set(true, forKey: "hasCompletedSetup")
    }

    private func choices(_ defaults: UserDefaults) throws -> NativeTrayChoices {
        try JSONDecoder().decode(NativeTrayChoices.self,
            from: XCTUnwrap(defaults.data(forKey: "nativeTrayChoices.v1")))
    }

    @MainActor
    func testAutomaticReconnectPreservesEveryConflictingLegacyCategoryInEitherOrder() async throws {
        for groups: [ItemVisibility] in [[.visible, .alwaysHidden], [.alwaysHidden, .visible],
                                         [.collapsible, .alwaysHidden], [.alwaysHidden, .collapsible]] {
            let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = [rule("item:a", groups[0], name: "A"), rule("item:b", groups[1], name: "B")]
            try save(original, to: defaults)
            let system = environment(original)
            let model = MenuTidyModel(testing: system, defaults: defaults)
            defer { model.stop() }
            model.refreshMenuItems()
            await model.waitForTestingOperations()
            XCTAssertNil(try choices(defaults).group(bundle: bundle))
            XCTAssertTrue(system.hiddenBundles.isEmpty)
            XCTAssertTrue(system.restoredBundles.isEmpty)
            for originalRule in original {
                XCTAssertEqual(model.trayPlacementGroup(id: originalRule.id), originalRule.visibility)
                XCTAssertTrue(model.trayPlacementFailure(id: originalRule.id)?.contains("不同的旧分类") == true)
            }
            let reloaded = try JSONDecoder().decode(ItemRuleBook.self, from: XCTUnwrap(defaults.data(forKey: "itemRules.v1")))
            XCTAssertEqual(reloaded.rules, Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) }))
        }
    }

    @MainActor
    func testExplicitChoiceResolvesLegacyConflictAndConfirmsEverySibling() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = [rule("item:a", .visible, name: "A"), rule("item:b", .alwaysHidden, name: "B")]
        try save(original, to: defaults)
        let system = environment(original)
        let model = MenuTidyModel(testing: system, defaults: defaults)
        defer { model.stop() }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        model.requestTrayPlacement(id: "item:b", group: .collapsible)
        await model.waitForTestingOperations()
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertEqual(try choices(defaults).group(bundle: bundle), .collapsible)
        XCTAssertTrue(model.items.allSatisfy { $0.group == .collapsible && !$0.isPending })
        XCTAssertTrue(model.itemApplicationIssues.isEmpty)
    }

    @MainActor
    func testNewerStableDraftIsNotMaskedByStartupMigrationAndAppliesThroughReconnect() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = rule("item:stable", .visible)
        try save([original], to: defaults)
        var drafts = PendingDraftStore()
        try drafts.set(rule(original.id, .alwaysHidden), sessionIdentity: nil)
        defaults.set(try JSONEncoder().encode(drafts), forKey: "itemDrafts.v1")
        let system = environment([original])
        let model = MenuTidyModel(testing: system, defaults: defaults)
        defer { model.stop() }
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        XCTAssertEqual(model.trayPlacementGroup(id: original.id), .alwaysHidden)
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertEqual(try choices(defaults).group(bundle: bundle), .alwaysHidden)
        XCTAssertFalse(try XCTUnwrap(model.items.first).isPending)
    }

    @MainActor
    func testUnassociatedConflictingDraftCannotBeMigratedOrConsumedByReconnect() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = rule("item:stable", .visible)
        try save([original], to: defaults)
        let draft = rule("session:old", .alwaysHidden)
        let drafts = try PendingDraftStore(unassociatedRules: [draft])
        defaults.set(try JSONEncoder().encode(drafts), forKey: "itemDrafts.v1")
        let model = MenuTidyModel(testing: environment([original]), defaults: defaults)
        defer { model.stop() }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        XCTAssertEqual(model.offlineDrafts.map(\.rule), [draft])
        XCTAssertEqual(model.trayPlacementGroup(id: original.id), .visible)
        XCTAssertNotNil(model.trayPlacementFailure(id: original.id))
    }

    @MainActor
    func testSessionChoiceSurvivesOfflineRelaunchCanBeForgottenAndDoesNotResurrect() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = rule("session:live", .visible)
        let system = environment([original])
        let model = MenuTidyModel(testing: system, defaults: defaults)
        model.requestTrayPlacement(id: original.id, group: .alwaysHidden)
        await model.waitForTestingOperations()
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertEqual(try choices(defaults).group(bundle: bundle), .alwaysHidden)
        let saved = try JSONDecoder().decode(ItemRuleBook.self, from: XCTUnwrap(defaults.data(forKey: "itemRules.v1")))
        let drafts = try JSONDecoder().decode(PendingDraftStore.self, from: XCTUnwrap(defaults.data(forKey: "itemDrafts.v1")))
        XCTAssertTrue(saved.rules.isEmpty)
        XCTAssertTrue(drafts.records.isEmpty)
        model.stop()

        let offline = MenuTidyModel(testing: MenuTidyTestEnvironment(), defaults: defaults)
        let row = try XCTUnwrap(offline.items.first { $0.bundleIdentifier == bundle })
        XCTAssertFalse(row.isAvailable)
        XCTAssertEqual(row.group, .alwaysHidden)
        XCTAssertTrue(offline.forgetItemAffectsApplication(id: row.id))
        XCTAssertTrue(offline.canForgetItem(id: row.id))
        offline.forgetItem(id: row.id)
        XCTAssertTrue(offline.items.isEmpty)
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        offline.stop()

        let relaunched = MenuTidyModel(testing: environment([original]), defaults: defaults)
        defer { relaunched.stop() }
        relaunched.refreshMenuItems()
        await relaunched.waitForTestingOperations()
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        XCTAssertEqual(relaunched.trayPlacementGroup(id: original.id), .visible)
        XCTAssertFalse(try XCTUnwrap(relaunched.items.first).isPending)
    }

    @MainActor
    func testOfflineApplicationChoiceIsNotDuplicatedAndCannotBeForgottenWhileSiblingIsLive() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try save([rule("item:missing", .alwaysHidden)], to: defaults)
        let live = rule("session:live", .visible)
        let model = MenuTidyModel(testing: environment([live]), defaults: defaults)
        defer { model.stop() }
        XCTAssertEqual(model.items.map(\.id), [live.id])
        XCTAssertFalse(model.canForgetItem(id: live.id))
    }

    @MainActor
    func testMatchingDraftForOneSiblingCannotRemoveAnotherSiblingFromStartupConflict() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = [rule("item:a", .visible, name: "A"), rule("item:b", .alwaysHidden, name: "B")]
        try save(original, to: defaults)
        var drafts = PendingDraftStore()
        try drafts.set(original[0], sessionIdentity: nil)
        defaults.set(try JSONEncoder().encode(drafts), forKey: "itemDrafts.v1")
        let system = environment(original)
        let model = MenuTidyModel(testing: system, defaults: defaults)
        defer { model.stop() }
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        XCTAssertTrue(system.hiddenBundles.isEmpty)
        XCTAssertEqual(model.trayPlacementGroup(id: "item:b"), .alwaysHidden)
        XCTAssertNotNil(model.trayPlacementFailure(id: "item:a"))
        XCTAssertNotNil(model.trayPlacementFailure(id: "item:b"))
    }

    @MainActor
    func testNewerExplicitChoiceSurvivesOlderConfirmationInFlight() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = rule("session:live", .visible)
        let system = environment([original])
        let model = MenuTidyModel(testing: system, defaults: defaults)
        defer { model.stop() }
        system.beforeVisibilityRead = { [weak model, weak system] in
            system?.beforeVisibilityRead = nil
            model?.requestTrayPlacement(id: original.id, group: .visible)
        }
        model.requestTrayPlacement(id: original.id, group: .alwaysHidden)
        await model.waitForTestingOperations()
        XCTAssertEqual(try choices(defaults).group(bundle: bundle), .visible)
        XCTAssertEqual(model.trayPlacementGroup(id: original.id), .visible)
        XCTAssertFalse(try XCTUnwrap(model.items.first).isPending)
        XCTAssertEqual(system.allowed[bundle], true)
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertEqual(system.restoredBundles, [bundle])
    }

    @MainActor
    func testForgettingNativeChoiceAlsoRemovesLegacyRulesThatWouldReviveOnRestart() async throws {
        let suite = "dev.hdh.MenuTidy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try save([rule("item:old", .alwaysHidden)], to: defaults)
        let other = "org.example.Unrelated"
        defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [bundle: .visible, other: .collapsible])),
            forKey: "nativeTrayChoices.v1")
        let model = MenuTidyModel(testing: MenuTidyTestEnvironment(), defaults: defaults)
        let row = try XCTUnwrap(model.items.first { $0.bundleIdentifier == bundle })
        XCTAssertEqual(row.group, .visible, "Offline presentation must show newer native intent.")
        model.forgetItem(id: row.id)
        model.stop()
        let relaunched = MenuTidyModel(testing: MenuTidyTestEnvironment(), defaults: defaults)
        defer { relaunched.stop() }
        XCTAssertFalse(relaunched.items.contains { $0.bundleIdentifier == bundle })
        XCTAssertNil(try choices(defaults).group(bundle: bundle))
        XCTAssertEqual(try choices(defaults).group(bundle: other), .collapsible)
    }

}
