import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class ItemPresentationIntegrationTests: XCTestCase {
    private let application = "io.github.clash-verge-rev.clash-verge-rev"
    private let host = SystemModuleIdentity.ownerBundleIdentifier
    private let live = "live-activity-pill-com.apple.chrono.WidgetRenderer-Activities"

    @MainActor
    func testClashAndSystemProjectionsBecomeSeparateSingleRowsWithoutDiscardingSources() async throws {
        let sources = [snapshot("session:a", bundle: application), snapshot("session:b", bundle: application),
            snapshot("session:l1", bundle: host, identifier: live), snapshot("session:l2", bundle: host, identifier: live),
            snapshot("session:w1", bundle: host, identifier: "com.apple.menuextra.wifi"),
            snapshot("session:w2", bundle: host, identifier: "com.apple.menuextra.wifi")]
        let fixture = try makeFixture(sources)
        defer { fixture.dispose() }
        try await refresh(fixture)
        XCTAssertEqual(fixture.model.items.count, 6, "All original nodes remain independently addressable")
        XCTAssertEqual(fixture.model.managementItems.count, 3)
        XCTAssertEqual(Set(fixture.model.managementItems.map(\.presentationID)).count, 3)
        XCTAssertEqual(Set(fixture.model.managementItems.flatMap(\.underlyingIDs)), Set(sources.map(\.id)))
        let liveRow = try XCTUnwrap(fixture.model.managementItems.first { $0.presentationIdentity == .systemModule(identifier: live) })
        XCTAssertEqual(liveRow.underlyingIDs, ["session:l1", "session:l2"])
    }

    @MainActor
    func testSourceReplacementAndRepeatedRefreshKeepTheApplicationPresentationIdentity() async throws {
        let fixture = try makeFixture([snapshot("session:old-a", bundle: application), snapshot("session:old-b", bundle: application)])
        defer { fixture.dispose() }
        let rowID = try XCTUnwrap(fixture.model.managementItems.first?.presentationID)
        for round in 1...5 {
            let sources = [snapshot("session:new-a-\(round)", bundle: application), snapshot("session:new-b-\(round)", bundle: application)]
            fixture.setSources(sources)
            try await refresh(fixture)
            XCTAssertEqual(fixture.model.managementItems.count, 1)
            XCTAssertEqual(fixture.model.managementItems.first?.presentationID, rowID)
            XCTAssertEqual(Set(try XCTUnwrap(fixture.model.managementItems.first).underlyingIDs), Set(sources.map(\.id)))
        }
    }

    @MainActor
    func testSameNamesInDifferentApplicationsAndUnidentifiedSystemNodesRemainSeparate() throws {
        let fixture = try makeFixture([snapshot("session:a", bundle: application), snapshot("session:b", bundle: application + ".helper"),
            snapshot("session:s1", bundle: host), snapshot("session:s2", bundle: host)])
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.model.managementItems.count, 4)
        XCTAssertEqual(Set(fixture.model.managementItems.map(\.presentationID)).count, 4)
    }

    @MainActor
    func testApplicationChoiceAndTrayRemainSingleWhileEverySourceIsConfirmed() async throws {
        let fixture = try makeFixture([snapshot("item:a", bundle: application), snapshot("item:b", bundle: application)])
        defer { fixture.dispose() }
        let row = try XCTUnwrap(fixture.model.managementItems.first)
        fixture.model.requestTrayPlacement(id: row.id, group: .collapsible)
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.items.count, 2)
        XCTAssertTrue(fixture.model.items.allSatisfy { !$0.isPending && fixture.model.trayPlacementGroup(id: $0.id) == .collapsible })
        XCTAssertEqual(fixture.model.managementItems.count, 1)
        XCTAssertEqual(fixture.model.panelItems.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(fixture.model.panelItems.first).underlyingIDs), ["item:a", "item:b"])
        let saved = try JSONDecoder().decode(ItemRuleBook.self, from: XCTUnwrap(fixture.defaults.data(forKey: "itemRules.v1")))
        XCTAssertEqual(Set(saved.rules.keys), ["item:a", "item:b"], "Display IDs never enter saved source rules")
    }

    @MainActor
    func testSiblingFailureIsSurfacedInTheSingleManagementRow() async throws {
        let fixture = try makeFixture([snapshot("session:a", bundle: application), snapshot("session:b", bundle: application)])
        defer { fixture.dispose() }
        fixture.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
        fixture.model.requestTrayPlacement(id: "session:b", group: .collapsible)
        await fixture.model.waitForTestingOperations()
        let row = try XCTUnwrap(fixture.model.managementItems.first)
        XCTAssertEqual(fixture.model.managementItems.count, 1)
        XCTAssertTrue(row.isPending)
        XCTAssertNotNil(fixture.model.trayPlacementFailure(id: row.id))
        XCTAssertEqual(Set(row.underlyingIDs), ["session:a", "session:b"])
        XCTAssertEqual(fixture.model.trayPlacementOutstandingCount, 1)
        XCTAssertEqual(fixture.model.trayPendingApplicationCount, 1)
        XCTAssertEqual(fixture.model.trayRetryCount, 1)
        XCTAssertEqual(fixture.model.actionablePendingCount, 1)
    }

    @MainActor
    func testSharedChoiceSurvivesHostProjectionDisappearingDuringPreflightAndConsumesOwnedDrafts() async throws {
        let fixture = try makeFixture([snapshot("session:a", bundle: application), snapshot("session:b", bundle: application)])
        defer { fixture.dispose() }
        let canonical = snapshot("session:a", bundle: application)
        fixture.system.beforeScan = { fixture.setSources([canonical]) }
        fixture.model.requestTrayPlacement(id: "session:b", group: .collapsible)
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.system.hiddenBundles, [application])
        XCTAssertNil(fixture.model.managementError)
        XCTAssertEqual(fixture.model.managementItems.count, 1)
        XCTAssertFalse(try XCTUnwrap(fixture.model.managementItems.first).isPending)
        XCTAssertEqual(fixture.model.panelItems.count, 1)
        let drafts = try JSONDecoder().decode(PendingDraftStore.self,
            from: XCTUnwrap(fixture.defaults.data(forKey: "itemDrafts.v1")))
        XCTAssertTrue(drafts.records.isEmpty, "Only the confirmed request's obsolete projections are consumed")
    }

    @MainActor
    func testSharedChoiceSurvivesCompleteNodeReplacementWithinTheSameOwnerEpoch() async throws {
        let fixture = try makeFixture([snapshot("session:old-a", bundle: application), snapshot("session:old-b", bundle: application)])
        defer { fixture.dispose() }
        let replacements = [snapshot("session:new-a", bundle: application), snapshot("session:new-b", bundle: application)]
        fixture.system.beforeScan = { fixture.setSources(replacements) }
        fixture.model.requestTrayPlacement(id: "session:old-a", group: .collapsible)
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.system.hiddenBundles, [application])
        XCTAssertNil(fixture.model.managementError)
        XCTAssertTrue(fixture.model.items.allSatisfy { !$0.isPending && $0.group == .collapsible })
        XCTAssertEqual(Set(try XCTUnwrap(fixture.model.panelItems.first).underlyingIDs), Set(replacements.map(\.id)))
        let drafts = try JSONDecoder().decode(PendingDraftStore.self,
            from: XCTUnwrap(fixture.defaults.data(forKey: "itemDrafts.v1")))
        XCTAssertTrue(drafts.records.isEmpty)
    }

    @MainActor
    func testSharedChoiceCannotCrossAProcessRestartDuringPreflight() async throws {
        let fixture = try makeFixture([snapshot("session:old", bundle: application)])
        defer { fixture.dispose() }
        let replacement = snapshot("session:new", bundle: application)
        fixture.system.beforeScan = {
            fixture.setSources([replacement])
            fixture.system.identities[replacement.id] = ObservedItemGroupHistory.Identity(id: replacement.id,
                pid: replacement.processIdentifier, bundleIdentifier: replacement.bundleIdentifier, launchTime: 200)
        }
        fixture.model.requestTrayPlacement(id: "session:old", group: .collapsible)
        await fixture.model.waitForTestingOperations()
        XCTAssertTrue(fixture.system.hiddenBundles.isEmpty, "A fresh owner cannot inherit an in-flight operation")
        XCTAssertNotNil(fixture.model.managementError)
        XCTAssertTrue(try XCTUnwrap(fixture.model.managementItems.first).isPending)
        let drafts = try JSONDecoder().decode(PendingDraftStore.self,
            from: XCTUnwrap(fixture.defaults.data(forKey: "itemDrafts.v1")))
        XCTAssertEqual(drafts.records.count, 1, "Unconfirmed intent remains available for recovery")
    }

    @MainActor
    func testLegacyMixedChoicesArePreservedAndMarkedUntilAnExplicitApplicationChoice() throws {
        let sources = [snapshot("session:a", bundle: application), snapshot("session:b", bundle: application)]
        let rules = [ItemRule(id: "session:a", name: "Fixture", bundleIdentifier: application, visibility: .visible),
            ItemRule(id: "session:b", name: "Fixture", bundleIdentifier: application, visibility: .alwaysHidden)]
        let fixture = try makeFixture(sources, rules: rules)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.model.managementItems.count, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.model.managementItems.first).hasMixedGroups)
        XCTAssertEqual(Set(fixture.model.items.map { fixture.model.trayPlacementGroup(id: $0.id) }), [.visible, .alwaysHidden])
    }

    private func snapshot(_ id: String, bundle: String, identifier: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(id: id, processIdentifier: bundle == host ? 10002 : (bundle == application ? 10001 : 10003),
            name: "Fixture", ownerName: "Fixture", bundleIdentifier: bundle,
            frame: CGRect(x: 0, y: 0, width: 22, height: 22), hasReliableGeometry: true,
            canMove: true, detail: "", persistentIdentity: id.hasPrefix("item:"), ownIdentifier: nil,
            presentationIdentity: MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle, accessibilityIdentifier: identifier))
    }

    @MainActor
    private func makeFixture(_ sources: [MenuBarItemSnapshot], rules: [ItemRule] = []) throws -> Fixture {
        let suite = "dev.hdh.MenuTidy.tests.presentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "shortcutEnabled")
        defaults.set(false, forKey: "autoCollapse")
        defaults.set(false, forKey: "startupApplyPending")
        defaults.set(try JSONEncoder().encode(ItemRuleBook(rules: Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) }))),
            forKey: "itemRules.v1")
        let system = MenuTidyTestEnvironment()
        system.snapshots = sources
        system.identities = Dictionary(uniqueKeysWithValues: sources.map { item in
            (item.id, ObservedItemGroupHistory.Identity(id: item.id, pid: item.processIdentifier,
                bundleIdentifier: item.bundleIdentifier, launchTime: 100))
        })
        return Fixture(model: MenuTidyModel(testing: system, defaults: defaults), system: system, defaults: defaults, suite: suite)
    }

    @MainActor
    private func refresh(_ fixture: Fixture) async throws {
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertNil(fixture.model.managementError)
    }

    @MainActor
    private struct Fixture {
        let model: MenuTidyModel
        let system: MenuTidyTestEnvironment
        let defaults: UserDefaults
        let suite: String

        func setSources(_ sources: [MenuBarItemSnapshot]) {
            system.snapshots = sources
            system.identities = Dictionary(uniqueKeysWithValues: sources.map { item in
                (item.id, ObservedItemGroupHistory.Identity(id: item.id, pid: item.processIdentifier,
                    bundleIdentifier: item.bundleIdentifier, launchTime: 100))
            })
        }

        func dispose() { system.beforeScan = nil; model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
