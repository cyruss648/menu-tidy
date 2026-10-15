import CoreGraphics
import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class DesktopSessionIntegrationTests: XCTestCase {
    @MainActor
    func testSessionReadRequiresAnActiveLoggedInUnlockedConsole() {
        let active: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
        XCTAssertTrue(DesktopSessionMonitor.sessionIsAvailable(active))
        XCTAssertTrue(DesktopSessionMonitor.sessionIsAvailable(active.merging(["CGSSessionScreenIsLocked": false]) { _, new in new }))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable(active.merging(["CGSSessionScreenIsLocked": true]) { _, new in new }))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable(active.merging(["CGSSessionScreenIsLocked": "unknown"]) { _, new in new }))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable(active.merging([kCGSessionOnConsoleKey as String: false]) { _, new in new }))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable(active.merging([kCGSessionLoginDoneKey as String: false]) { _, new in new }))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable(nil))
        XCTAssertFalse(DesktopSessionMonitor.sessionIsAvailable([:]))
    }

    @MainActor
    func testLaunchingLockedDoesNoWorkAndUnlockCoalescesStartupAndPeriodicApplication() async throws {
        let f = try Fixture(available: false); defer { f.dispose() }
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        XCTAssertNil(f.system.maintenanceTimer)
        f.model.refreshMenuItems()
        f.model.applyPendingTrayPlacements()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(scans, 0)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNil(f.defaults.data(forKey: "itemDrafts.v1"))
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(101.99)
        XCTAssertEqual(scans, 0)
        try await f.fire(102)
        XCTAssertEqual(scans, 3)
        XCTAssertEqual(f.system.visibilityBatches, [[f.a: true, f.b: true]])
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(try f.draftCount(), 0)
        try await f.fire(400)
        XCTAssertEqual(scans, 3, "The startup deadline must not introduce an adjacent batch")
        try await f.fire(402)
        XCTAssertEqual(scans, 4)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
    }

    @MainActor
    func testLockInvalidatesTimerAndKeepsIntentUnchangedBeyondItsOldDeadline() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        let timer = try XCTUnwrap(f.system.maintenanceTimer)
        let intent = f.defaults.data(forKey: "nativeTrayChoices.v1")
        f.model.setDesktopSessionAvailableForTesting(false)
        XCTAssertFalse(timer.isValid)
        XCTAssertNil(f.system.maintenanceTimer)
        f.system.uptime = 1200
        timer.fire()
        await f.model.waitForTestingOperations()
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), intent)
        XCTAssertNil(f.defaults.data(forKey: "itemDrafts.v1"))
        XCTAssertEqual(f.model.trayRetryCount, 0)
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(1202)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testLockDuringPeriodicScanDiscardsItsCompletionWithoutNewDraftsOrFailures() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.system.beforeScan = { f.model.setDesktopSessionAvailableForTesting(false) }
        try await f.fire(400)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertEqual(f.model.trayRetryCount, 0)
        XCTAssertNil(f.model.managementError)
        XCTAssertNil(f.defaults.data(forKey: "itemDrafts.v1"))
        XCTAssertNil(f.system.maintenanceTimer)
        f.system.beforeScan = nil
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(402)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testLockAfterBatchWriteAwaitsEveryUnconfirmedRecoveryWithoutFailureDrafts() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        var interrupted = false
        f.system.beforeVisibilityRead = {
            if !interrupted { interrupted = true; f.model.setDesktopSessionAvailableForTesting(false) }
        }
        try await f.fire(400)
        XCTAssertTrue(interrupted)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(Set(f.system.restoredBundles), [f.a, f.b])
        XCTAssertTrue(f.system.managedBundles.isEmpty)
        XCTAssertEqual(f.model.trayRetryCount, 0)
        XCTAssertNil(f.model.managementError)
        XCTAssertEqual(try f.draftCount(), 0)
        XCTAssertFalse(f.model.isApplying)
        f.system.beforeVisibilityRead = nil
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(402)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.system.visibilityBatches.count, 2)
    }

    @MainActor
    func testLockPreservesConfirmedPeerAndOnlyRestoresTheUnconfirmedTarget() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        var firstID: String?
        f.system.beforeVisibilityReadForItem = { id in
            if firstID == nil { firstID = id }
            if id != firstID { f.model.setDesktopSessionAvailableForTesting(false) }
        }
        try await f.fire(400)
        let confirmed = try XCTUnwrap(firstID) == "session:a" ? f.a : f.b
        let interrupted = confirmed == f.a ? f.b : f.a
        XCTAssertEqual(f.system.allowed[confirmed], false)
        XCTAssertEqual(f.system.allowed[interrupted], true)
        XCTAssertEqual(Set(f.system.restoredBundles), [interrupted])
        XCTAssertEqual(f.model.trayRetryCount, 0)
        XCTAssertEqual(try f.draftCount(), 0)
    }

    @MainActor
    func testUnlockWaitsForAnOpenTrayAndThenUsesOneFreshBatch() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        try await f.fire(102)
        XCTAssertTrue(f.model.isPanelPresented)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        f.model.closeIconPanel()
        try await f.fire(103)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
    }

    @MainActor
    func testDisabledApplicationSettingsStillRefreshOnceButDoNotApplyOnUnlock() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.periodicApplyPendingEnabled = false
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(102)
        XCTAssertEqual(scans, 1)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNil(f.system.maintenanceTimer)
        XCTAssertNil(f.defaults.data(forKey: "itemDrafts.v1"))
    }

    @MainActor
    func testRelockDuringResumeRefreshFencesItsLateCompletion() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.setDesktopSessionAvailableForTesting(true)
        f.system.beforeScan = {
            f.model.setDesktopSessionAvailableForTesting(false)
            f.model.setDesktopSessionAvailableForTesting(true)
        }
        try await f.fire(102)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNil(f.model.managementError)
        f.system.beforeScan = nil
        try await f.fire(104)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testInterruptedStartupRefreshCannotConsumeTheOnlyEnabledUnlockCompensation() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.periodicApplyPendingEnabled = false
        f.system.beforeScan = {
            f.model.setDesktopSessionAvailableForTesting(false)
            f.model.setDesktopSessionAvailableForTesting(true)
        }
        try await f.fire(130)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        f.system.beforeScan = nil
        try await f.fire(132)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testDisableDuringUnlockScanPreventsItsAutomaticApply() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.setDesktopSessionAvailableForTesting(true)
        f.system.beforeScan = { f.model.periodicApplyPendingEnabled = false }
        try await f.fire(102)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testFailedAutomaticApplicationDoesNotSynthesizePersistentUserDrafts() async throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
        try await f.fire(400)
        XCTAssertEqual(f.model.trayRetryCount, 2)
        XCTAssertEqual(try f.draftCount(), 0)
        f.model.setDesktopSessionAvailableForTesting(false)
        f.system.beforeVisibilityRead = nil
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(402)
        XCTAssertEqual(f.model.trayRetryCount, 0)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testUserChoiceAndUnrelatedOfflineDraftSurviveLockAndOnlyConfirmedDraftIsConsumed() async throws {
        let f = try Fixture(startup: false, retainedDraft: true); defer { f.dispose() }
        f.model.requestTrayPlacement(id: "session:a", group: .visible)
        f.model.setDesktopSessionAvailableForTesting(false)
        await f.model.waitForTestingOperations()
        XCTAssertEqual(try f.draftCount(), 2)
        XCTAssertEqual(f.model.trayPlacementGroup(id: "session:a"), .visible)
        f.model.setDesktopSessionAvailableForTesting(true)
        try await f.fire(102)
        XCTAssertEqual(f.model.trayPlacementGroup(id: "session:a"), .visible)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(try f.draftCount(), 1)
        let store = try JSONDecoder().decode(PendingDraftStore.self,
            from: XCTUnwrap(f.defaults.data(forKey: "itemDrafts.v1")))
        XCTAssertEqual(store.records.first?.rule.bundleIdentifier, "org.example.UnrelatedOffline")
    }

    @MainActor
    func testStopInvalidatesResumeAndLateAvailabilityEvents() throws {
        let f = try Fixture(startup: false); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.setDesktopSessionAvailableForTesting(true)
        let timer = try XCTUnwrap(f.system.maintenanceTimer)
        f.model.stop()
        XCTAssertFalse(timer.isValid)
        f.model.setDesktopSessionAvailableForTesting(false)
        f.model.setDesktopSessionAvailableForTesting(true)
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    private final class Fixture {
        let suite = "dev.hdh.MenuTidy.tests.session.\(UUID().uuidString)"
        let a = "org.example.SessionA", b = "org.example.SessionB"
        let defaults: UserDefaults
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        init(available: Bool = true, startup: Bool = true, retainedDraft: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(startup, forKey: "startupApplyPending")
            defaults.set(false, forKey: "shortcutEnabled")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [a: .collapsible, b: .collapsible])), forKey: "nativeTrayChoices.v1")
            if retainedDraft {
                let store = try PendingDraftStore(unassociatedRules: [ItemRule(id: "item:unrelated-offline",
                    name: "Offline", bundleIdentifier: "org.example.UnrelatedOffline", visibility: .alwaysHidden)])
                defaults.set(try JSONEncoder().encode(store), forKey: "itemDrafts.v1")
            }
            system.uptime = 100
            system.desktopSessionAvailable = available
            for (id, bundle, pid) in [("session:a", a, Int32(501)), ("session:b", b, Int32(502))] {
                system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid, name: bundle,
                    ownerName: bundle, bundleIdentifier: bundle, frame: CGRect(x: 20, y: 0, width: 22, height: 22),
                    hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
                system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: pid, bundleIdentifier: bundle, launchTime: 10)
            }
            model = MenuTidyModel(testing: system, defaults: defaults)
        }
        func fire(_ uptime: TimeInterval) async throws {
            system.uptime = uptime
            try XCTUnwrap(system.maintenanceTimer).fire()
            await model.waitForTestingOperations()
        }
        func draftCount() throws -> Int {
            guard let data = defaults.data(forKey: "itemDrafts.v1") else { return 0 }
            return try JSONDecoder().decode(PendingDraftStore.self, from: data).records.count
        }
        func dispose() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
