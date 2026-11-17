import ApplicationServices
import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class MenuBarClientRecoveryIntegrationTests: XCTestCase {
    @MainActor
    func testRepeatedDeniedConnectionRecoversOnlyAfterFreshClientConfirmation() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        var probes = 0
        var relaunches = 0
        f.system.probeFreshMenuBarClient = { owner in
            probes += 1
            XCTAssertEqual(owner.pid, f.owner.pid)
            return true
        }
        f.model.onReconnectMenuBarClient = { showSettings in
            XCTAssertFalse(showSettings)
            XCTAssertEqual(f.defaults.string(forKey: "menuBarClientRecoveryBoot.v1"),
                f.system.clientRecoveryBootIdentifier, "The budget must be persisted before an immediate quit")
            relaunches += 1
            return true
        }
        for attempt in 1...4 {
            await f.refresh()
            XCTAssertEqual(relaunches, attempt < 3 ? 0 : 1)
        }
        XCTAssertEqual(probes, 1)
        let row = try XCTUnwrap(f.model.managementItems.first)
        XCTAssertTrue(row.isAwaitingDiscovery)
        XCTAssertFalse(row.canMove)
        XCTAssertTrue(f.model.trayDiscoveryConnectionFailed(id: row.id))
        XCTAssertTrue(f.model.trayItemNeedsAttention(row))
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 1)
        XCTAssertEqual(f.model.trayPlacementGroup(id: row.id), .collapsible)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertEqual(f.system.panelPressCount, 0)
    }

    @MainActor
    func testSameBootBudgetSurvivesRelaunchButANewBootCanRecover() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.defaults.set(f.system.clientRecoveryBootIdentifier, forKey: "menuBarClientRecoveryBoot.v1")
        var probes = 0
        var relaunches = 0
        f.system.probeFreshMenuBarClient = { _ in probes += 1; return true }
        f.model.onReconnectMenuBarClient = { _ in relaunches += 1; return true }
        for _ in 0..<4 { await f.refresh() }
        XCTAssertEqual(probes, 0)
        f.system.clientRecoveryBootIdentifier = "next-boot"
        await f.refresh()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(relaunches, 1)
    }

    @MainActor
    func testRefusedRelaunchHandoffRestoresTheBootBudget() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.system.probeFreshMenuBarClient = { _ in true }
        f.model.onReconnectMenuBarClient = { _ in false }
        for _ in 0..<3 { await f.refresh() }
        XCTAssertNil(f.defaults.string(forKey: "menuBarClientRecoveryBoot.v1"))
        XCTAssertNotNil(f.model.managementError)
    }

    @MainActor
    func testNoIconOrFailedIndependentCheckNeverRelaunches() async throws {
        for hasFailure in [false, true] {
            let f = try Fixture()
            defer { f.dispose() }
            if !hasFailure { f.system.ownerReadFailures = [] }
            var probes = 0
            f.system.probeFreshMenuBarClient = { _ in probes += 1; return false }
            f.model.onReconnectMenuBarClient = { _ in XCTFail("An absent icon is not a broken client"); return true }
            for _ in 0..<5 { await f.refresh() }
            XCTAssertEqual(probes, hasFailure ? 1 : 0)
        }
    }

    @MainActor
    func testOrdinaryAbsenceAfterAConnectionErrorClearsAttentionWithoutRestarting() async throws {
        let f = try Fixture(); defer { f.dispose() }
        await f.refresh()
        let failed = try XCTUnwrap(f.model.managementItems.first)
        XCTAssertTrue(f.model.trayItemNeedsAttention(failed))
        f.system.ownerReadFailures = [MenuBarOwnerReadFailure(owner: f.owner, error: AXError.noValue.rawValue)]
        f.model.onReconnectMenuBarClient = { _ in
            XCTFail("A cleared connection error must not restart Menu Tidy")
            return true
        }
        for _ in 0..<4 { await f.refresh() }
        XCTAssertTrue(f.model.managementItems.isEmpty)
        let absent = try XCTUnwrap(f.model.items.first)
        XCTAssertFalse(absent.isAvailable)
        XCTAssertTrue(absent.isAwaitingDiscovery)
        XCTAssertFalse(absent.isPending)
        XCTAssertFalse(f.model.trayItemNeedsAttention(absent))
        XCTAssertFalse(f.model.trayDiscoveryConnectionFailed(id: absent.id))
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertNil(f.defaults.string(forKey: "menuBarClientRecoveryBoot.v1"))
    }

    @MainActor
    func testManagementWindowRequiresExplicitReconnectAndReopensAfterRecovery() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.settingsVisible = true
        var relaunches = 0
        f.system.probeFreshMenuBarClient = { _ in true }
        f.model.onReconnectMenuBarClient = { showSettings in
            XCTAssertTrue(showSettings)
            relaunches += 1
            return true
        }
        for _ in 0..<4 { await f.refresh() }
        XCTAssertEqual(relaunches, 0)
        let row = try XCTUnwrap(f.model.managementItems.first)
        f.model.reconnectMenuBarClient(id: row.id)
        await f.model.waitForTestingOperations()
        XCTAssertEqual(relaunches, 1)
    }

    @MainActor
    func testLockOrOwnerReplacementDuringIndependentCheckCannotRelaunch() async throws {
        for locks in [false, true] {
            let f = try Fixture()
            defer { f.dispose() }
            f.system.probeFreshMenuBarClient = { _ in
                if locks { f.model.setDesktopSessionAvailableForTesting(false) }
                else {
                    f.system.identities["owner"] = ObservedItemGroupHistory.Identity(
                        id: "owner", pid: f.owner.pid, bundleIdentifier: f.bundle, launchTime: 200)
                }
                return true
            }
            f.model.onReconnectMenuBarClient = { _ in XCTFail("Stale probe cannot authorize a relaunch"); return true }
            for _ in 0..<3 { await f.refresh() }
        }
    }

    @MainActor
    func testFreshObservationClearsFailureAndRetainsTheSavedChoice() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        await f.refresh()
        XCTAssertTrue(try XCTUnwrap(f.model.managementItems.first).isAwaitingDiscovery)
        f.system.ownerReadFailures = []
        f.system.snapshots = [MenuBarItemSnapshot(id: "session:recovered", processIdentifier: f.owner.pid,
            name: "Fixture", ownerName: "Fixture", bundleIdentifier: f.bundle,
            frame: CGRect(x: 0, y: 0, width: 24, height: 24), hasReliableGeometry: true,
            canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)]
        f.system.identities["session:recovered"] = ObservedItemGroupHistory.Identity(
            id: "session:recovered", pid: f.owner.pid, bundleIdentifier: f.bundle, launchTime: f.owner.launchTime)
        await f.refresh()
        let row = try XCTUnwrap(f.model.managementItems.first)
        XCTAssertFalse(row.isAwaitingDiscovery)
        XCTAssertFalse(f.model.trayDiscoveryConnectionFailed(id: row.id))
        XCTAssertEqual(row.group, .collapsible)
    }

    @MainActor
    func testDiscoveryResumingDuringTheProbePreventsAnUnnecessaryRelaunch() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.system.probeFreshMenuBarClient = { _ in
            f.system.ownerReadFailures = []
            f.system.snapshots = [MenuBarItemSnapshot(id: "session:late", processIdentifier: f.owner.pid,
                name: "Fixture", ownerName: "Fixture", bundleIdentifier: f.bundle,
                frame: CGRect(x: 0, y: 0, width: 24, height: 24), hasReliableGeometry: true,
                canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)]
            f.system.identities["session:late"] = ObservedItemGroupHistory.Identity(id: "session:late",
                pid: f.owner.pid, bundleIdentifier: f.bundle, launchTime: f.owner.launchTime)
            f.model.refreshMenuItems()
            return true
        }
        f.model.onReconnectMenuBarClient = { _ in XCTFail("A new scan already has the icon"); return true }
        for _ in 0..<3 { await f.refresh() }
        XCTAssertFalse(try XCTUnwrap(f.model.managementItems.first).isAwaitingDiscovery)
    }

    @MainActor
    private struct Fixture {
        let bundle = "org.example.DelayedInputMethod"
        let owner: MenuBarOwner
        let system: MenuTidyTestEnvironment
        let model: MenuTidyModel
        let defaults: UserDefaults
        let suite: String

        init() throws {
            suite = "dev.hdh.MenuTidy.tests.client-recovery.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            for key in ["startupApplyPending", "periodicApplyPending", "shortcutEnabled", "autoCollapse"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [bundle: .collapsible])),
                forKey: "nativeTrayChoices.v1")
            owner = MenuBarOwner(pid: 10001, bundleIdentifier: bundle, name: "Fixture", launchTime: 100)
            system = MenuTidyTestEnvironment()
            system.uptime = 100
            system.runningBundles = [bundle]
            system.identities["owner"] = ObservedItemGroupHistory.Identity(
                id: "owner", pid: owner.pid, bundleIdentifier: bundle, launchTime: owner.launchTime)
            system.ownerReadFailures = [MenuBarOwnerReadFailure(owner: owner,
                error: MenuBarClientRecoveryPolicy.apiDisabledError)]
            model = MenuTidyModel(testing: system, defaults: defaults)
        }

        func refresh() async {
            model.refreshMenuItems()
            await model.waitForTestingOperations()
        }

        func dispose() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
