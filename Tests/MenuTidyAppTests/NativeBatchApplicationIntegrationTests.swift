import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class NativeBatchApplicationIntegrationTests: XCTestCase {
    @MainActor
    func testApplyAllSharesScanAndWritesAllTargetsBeforeFirstVisibilityConfirmation() async throws {
        let f = try Fixture(includeVisible: true); defer { f.dispose() }
        var scans = 0, observations = 0
        f.system.beforeScan = { scans += 1 }
        f.system.beforeVisibilityRead = {
            observations += 1
            XCTAssertEqual(f.system.allowed[f.a], false)
            XCTAssertEqual(f.system.allowed[f.b], false)
            XCTAssertEqual(f.system.allowed[f.c], true)
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(scans, 2, "Shared preflight and final verification, independent of app count")
        XCTAssertEqual(f.system.visibilityBatches, [[f.a: true, f.b: true, f.c: false]])
        XCTAssertGreaterThanOrEqual(observations, 6, "Each source still needs independent positive evidence")
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.model.items.first { $0.bundleIdentifier == f.b }?.group, .alwaysHidden)
    }

    @MainActor
    func testOneVisibilityFailureRestoresOnlyThatTargetAndKeepsConfirmedPeer() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeVisibilityReadForItem = { id in
            if id == "session:a" { throw MenuBarAccessError.rejected }
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.system.allowed[f.a], true)
        XCTAssertEqual(f.system.allowed[f.b], false)
        XCTAssertEqual(Set(f.system.restoredBundles), [f.a])
        XCTAssertTrue(try XCTUnwrap(f.model.items.first { $0.id == "session:a" }).isPending)
        XCTAssertFalse(try XCTUnwrap(f.model.items.first { $0.id == "session:b" }).isPending)
        XCTAssertEqual(f.model.trayRetryCount, 1)
    }

    @MainActor
    func testPreferenceWriteWithoutPhysicalHideStaysPendingAndRestoresTarget() async throws {
        let f = try Fixture(); defer { f.dispose() }
        // The preference backend accepts the write, while the AX substitute
        // reports that this source is still physically visible.
        f.system.observedVisibility[f.a] = true
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()

        XCTAssertEqual(f.system.allowed[f.a], true)
        XCTAssertEqual(f.system.allowed[f.b], false)
        XCTAssertTrue(f.model.items.first { $0.id == "session:a" }?.isPending == true)
        XCTAssertTrue(f.model.trayPlacementFailure(id: "session:a")?.sourceText.contains("仍在菜单栏中") == true)
        XCTAssertEqual(Set(f.system.restoredBundles), [f.a])
    }

    @MainActor
    func testCancellationAfterBatchWriteRecoversEveryUnconfirmedApplication() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var cancelled = false
        f.system.beforeVisibilityRead = { [weak model = f.model] in
            if !cancelled { cancelled = true; model?.cancelCurrentOperation(); throw CancellationError() }
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.system.allowed[f.a], true)
        XCTAssertEqual(f.system.allowed[f.b], true)
        XCTAssertTrue(f.system.managedBundles.isEmpty)
        XCTAssertEqual(Set(f.system.restoredBundles), [f.a, f.b])
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 2)
        XCTAssertFalse(f.model.isApplying)
    }

    @MainActor
    func testNewChoiceForBatchMemberSurvivesTheOlderBatchAndAppliesNext() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var changed = false
        f.system.beforeVisibilityRead = { [weak model = f.model] in
            if !changed { changed = true; model?.requestTrayPlacement(id: "session:b", group: .visible) }
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertTrue(changed)
        XCTAssertEqual(f.system.allowed[f.a], false)
        XCTAssertEqual(f.system.allowed[f.b], true)
        XCTAssertEqual(f.model.trayPlacementGroup(id: "session:b"), .visible)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.system.visibilityBatches.count, 2)
        XCTAssertEqual(f.system.visibilityBatches.last, [f.b: false])
    }

    @MainActor
    func testOwnerRestartDuringSharedPreflightStopsBeforeAnyBatchWrite() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeScan = {
            f.system.identities["session:b"] = ObservedItemGroupHistory.Identity(id: "session:b", pid: 302,
                bundleIdentifier: f.b, launchTime: 20)
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertTrue(f.system.hiddenBundles.isEmpty)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 2)
    }

    @MainActor
    func testVanishedSystemSourceDoesNotRejectUnchangedApplicationPeers() async throws {
        let f = try Fixture(includeTransientSystem: true); defer { f.dispose() }
        f.system.beforeScan = {
            f.system.snapshots.removeAll { $0.id == "session:system" }
        }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()

        XCTAssertEqual(f.system.visibilityBatches, [[f.a: true, f.b: true]])
        for bundle in [f.a, f.b] {
            XCTAssertFalse(try XCTUnwrap(f.model.items.first { $0.bundleIdentifier == bundle }).isPending)
        }
        XCTAssertEqual(f.model.trayPlacementGroup(id: "session:system"), .collapsible)
        XCTAssertNotNil(f.model.trayPlacementFailure(id: "session:system"))
    }

    @MainActor
    func testHiddenOwnerRelaunchIsDiscoveredAndReconnected() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(f.system.allowed[f.b], false)
        XCTAssertFalse(try XCTUnwrap(f.model.items.first { $0.bundleIdentifier == f.b }).isPending)

        f.system.snapshots.removeAll { $0.bundleIdentifier == f.b }
        f.system.identities.removeValue(forKey: "session:b")
        f.system.snapshots.append(MenuBarItemSnapshot(id: "session:b2", processIdentifier: 402, name: f.b,
            ownerName: f.b, bundleIdentifier: f.b, frame: CGRect(x: 40, y: 0, width: 22, height: 22),
            hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
        f.system.identities["session:b2"] = ObservedItemGroupHistory.Identity(id: "session:b2", pid: 402,
            bundleIdentifier: f.b, launchTime: 30)

        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        let relaunched = try XCTUnwrap(f.model.items.first { $0.bundleIdentifier == f.b && $0.isAvailable })
        XCTAssertFalse(relaunched.isPending)
        XCTAssertEqual(f.model.trayPlacementGroup(id: relaunched.id), .alwaysHidden)
        XCTAssertEqual(f.system.allowed[f.b], false)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testNativeAssessmentAcceptsAXNodeReplacementWhileOwnerEpochRemainsCurrent() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.nativeAssessmentAuthoritative = true
        var replaced = false
        f.system.beforeVisibilityReadForItem = { id in
            guard id == "session:a", !replaced else { return }
            replaced = true
            f.system.snapshots.removeAll { $0.id == id }
        }

        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()

        XCTAssertTrue(replaced)
        XCTAssertEqual(f.system.allowed[f.a], false)
        XCTAssertNil(f.model.trayPlacementFailure(id: "session:a"))
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testAssessmentInventorySurvivesEverySourceDisappearingBeforeConfirmation() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.nativeAssessmentAuthoritative = true
        var scans = 0
        f.system.beforeScan = {
            scans += 1
            f.system.managedBundles = [f.a, f.b]
            f.system.allowed = [f.a: false, f.b: false]
            if scans > 1 { f.system.snapshots.removeAll() }
        }
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        f.system.beforeScan = nil
        // Reproduce startup intent already hiding an observed application
        // before its first queued request can confirm individual AX sources.
        f.system.managedBundles = [f.a, f.b]
        f.system.allowed = [f.a: false, f.b: false]
        f.system.snapshots.removeAll()
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertEqual(f.model.items.filter(\.isAvailable).count, 2)
        XCTAssertTrue(f.model.items.allSatisfy { !$0.isAwaitingDiscovery && !$0.isPending })

        for _ in 0..<3 {
            f.model.refreshMenuItems()
            await f.model.waitForTestingOperations()
            XCTAssertEqual(f.model.panelItems.count, 1, "Repeated scans must retain the hidden tray entry")
            XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        }
        // A replacement process cannot inherit the retained inventory.
        f.system.identities["session:a"] = ObservedItemGroupHistory.Identity(id: "session:a",
            pid: 301, bundleIdentifier: f.a, launchTime: 20)
        f.system.runningBundles = [f.a, f.b]
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        XCTAssertFalse(f.model.panelItems.contains { $0.bundleIdentifier == f.a })
        let waiting = try XCTUnwrap(f.model.managementItems.first { $0.bundleIdentifier == f.a })
        XCTAssertTrue(waiting.isAwaitingDiscovery)
        XCTAssertFalse(waiting.canMove)
        XCTAssertFalse(waiting.isPending)
        XCTAssertFalse(f.model.trayItemNeedsAttention(waiting))
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testFreshBundleSourcesReplaceAssessmentInventoryWithoutDuplicateTrayEntries() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.nativeAssessmentAuthoritative = true
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        let old = try XCTUnwrap(f.system.snapshots.first { $0.bundleIdentifier == f.a })
        f.system.snapshots.removeAll { $0.bundleIdentifier == f.a }
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        XCTAssertTrue(f.model.items.contains { $0.id == old.id && $0.isAvailable })
        let replacement = MenuBarItemSnapshot(id: "session:new-a", processIdentifier: old.processIdentifier,
            name: old.name, ownerName: old.ownerName, bundleIdentifier: f.a, frame: old.frame,
            hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)
        f.system.snapshots.append(replacement)
        f.system.identities[replacement.id] = ObservedItemGroupHistory.Identity(id: replacement.id,
            pid: old.processIdentifier, bundleIdentifier: f.a, launchTime: 10)
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        XCTAssertFalse(f.model.items.contains { $0.id == old.id && $0.isAvailable })
        XCTAssertEqual(f.model.managementItems.filter { $0.bundleIdentifier == f.a }.count, 1)
        XCTAssertEqual(f.model.panelItems.filter { $0.bundleIdentifier == f.a }.count, 1)
    }

    @MainActor
    private final class Fixture {
        let a = "org.example.BatchA", b = "org.example.BatchB", c = "org.example.BatchC"
        let suite = "dev.hdh.MenuTidy.tests.native-batch.\(UUID().uuidString)"
        let defaults: UserDefaults
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        init(includeVisible: Bool = false, includeTransientSystem: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(false, forKey: "startupApplyPending")
            defaults.set(false, forKey: "periodicApplyPending")
            var choices: [String: ItemVisibility] = [a: .collapsible, b: .alwaysHidden]
            if includeVisible { choices[c] = .visible; system.managedBundles.insert(c); system.allowed[c] = false }
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: choices)), forKey: "nativeTrayChoices.v1")
            for (offset, bundle) in [a, b, c].prefix(includeVisible ? 3 : 2).enumerated() {
                let id = "session:" + ["a", "b", "c"][offset]
                let pid = Int32(301 + offset)
                system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid, name: bundle,
                    ownerName: bundle, bundleIdentifier: bundle, frame: CGRect(x: 20 * offset, y: 0, width: 22, height: 22),
                    hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
                system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: pid, bundleIdentifier: bundle, launchTime: 10)
            }
            if includeTransientSystem {
                let id = "session:system", bundle = "com.apple.fixture"
                system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: 401, name: "System",
                    ownerName: "System", bundleIdentifier: bundle, frame: CGRect(x: 80, y: 0, width: 22, height: 22),
                    hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
                system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: 401,
                    bundleIdentifier: bundle, launchTime: 10)
                var saved = ItemRuleBook()
                saved.set(ItemRule(id: id, name: "System", bundleIdentifier: bundle, visibility: .collapsible))
                defaults.set(try JSONEncoder().encode(saved), forKey: "itemRules.v1")
            }
            model = MenuTidyModel(testing: system, defaults: defaults)
        }
        func dispose() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
