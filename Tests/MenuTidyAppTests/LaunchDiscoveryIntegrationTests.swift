import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class LaunchDiscoveryIntegrationTests: XCTestCase {
    @MainActor
    func testMembershipChangeDiscoversWithoutLaunchNotification() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.noteRunningApplications([])
        f.model.noteRunningApplications([f.owner])
        f.system.snapshots = [f.snapshot]
        try await f.fire(101)
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertNil(f.system.maintenanceTimer)
        XCTAssertEqual(f.system.panelPressCount, 0)
    }

    @MainActor
    func testUnchangedMembershipDoesNotRearmExhaustedRetries() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.noteRunningApplications([])
        f.model.noteRunningApplications([f.owner])
        for time in [101.0, 103, 107, 115] { try await f.fire(time) }
        XCTAssertNil(f.system.maintenanceTimer)
        f.model.noteRunningApplications([f.owner])
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testMembershipRelaunchGetsFreshRetriesAfterExhaustion() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.noteRunningApplications([])
        f.model.noteRunningApplications([f.owner])
        for time in [101.0, 103, 107, 115] { try await f.fire(time) }
        let replacement = MenuBarOwner(pid: 10002, bundleIdentifier: f.bundle, name: "Fixture", launchTime: 200)
        f.system.identities["session:new-status"] = ObservedItemGroupHistory.Identity(id: "session:new-status",
            pid: replacement.pid, bundleIdentifier: f.bundle, launchTime: replacement.launchTime)
        f.system.uptime = 200
        f.model.noteRunningApplications([replacement])
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        try await f.fire(201)
        XCTAssertEqual(scans, 1)
        XCTAssertNotNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testInitialMembershipDoesNotStartLaunchRetries() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.noteRunningApplications([f.owner])
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testDelayedHiddenStatusItemReconnectsWithoutManualRefreshOrRestart() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let originalChoice = f.defaults.data(forKey: "nativeTrayChoices.v1")
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.noteApplicationLaunch(f.owner)
        try await f.fire(101)
        XCTAssertEqual(scans, 1)
        XCTAssertFalse(f.model.items.contains { $0.isAvailable })
        XCTAssertNotNil(f.system.maintenanceTimer)

        f.system.snapshots = [f.snapshot]
        try await f.fire(103)
        XCTAssertTrue(f.model.items.contains { $0.isAvailable && $0.group == .collapsible && !$0.isPending })
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertEqual(f.model.managedHiddenApplicationBundles, [f.bundle])
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), originalChoice)
        XCTAssertEqual(f.system.panelPressCount, 0)
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.system.maintenanceTimer, "Successful discovery must stop the launch retry timer")
    }

    @MainActor
    func testApplicationWithoutAStatusItemStopsRetrying() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.noteApplicationLaunch(f.owner)
        for time in [101.0, 103, 107, 115] { try await f.fire(time) }
        XCTAssertEqual(scans, 4)
        XCTAssertNil(f.system.maintenanceTimer)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertTrue(f.system.hiddenBundles.isEmpty)
    }

    @MainActor
    func testLaunchDiscoveryWaitsForAnActiveNativeOperation() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.beginPanelItemOperation(id: "other", progress: "Opening")
        f.model.noteApplicationLaunch(f.owner)
        XCTAssertNil(f.system.maintenanceTimer)
        f.system.uptime = 104
        f.model.finishPanelItemOperation()
        f.system.snapshots = [f.snapshot]
        try await f.fire(105)
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testTemporarilyRevealedAndUnmanagedApplicationsDoNotReceiveHiddenDiscoveryPermission() throws {
        let f = try Fixture(); defer { f.dispose() }
        XCTAssertEqual(f.model.managedHiddenApplicationBundles, [f.bundle])
        f.system.allowed[f.bundle] = true
        XCTAssertTrue(f.model.managedHiddenApplicationBundles.isEmpty)
        f.system.allowed[f.bundle] = false
        f.system.managedBundles = []
        XCTAssertTrue(f.model.managedHiddenApplicationBundles.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let bundle = "org.example.DelayedStatus"
        let system: MenuTidyTestEnvironment
        let model: MenuTidyModel
        let defaults: UserDefaults
        let suite: String

        var owner: MenuBarOwner { MenuBarOwner(pid: 10001, bundleIdentifier: bundle, name: "Fixture", launchTime: 100) }
        var snapshot: MenuBarItemSnapshot {
            MenuBarItemSnapshot(id: "session:new-status", processIdentifier: owner.pid,
                name: "Fixture", ownerName: "Fixture", bundleIdentifier: bundle,
                frame: CGRect(x: -1, y: 1068, width: 34, height: 24), hasReliableGeometry: false,
                canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil,
                presentationIdentity: .application(bundle: bundle))
        }

        init() throws {
            suite = "dev.hdh.MenuTidy.tests.launch-discovery.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            for key in ["startupApplyPending", "periodicApplyPending", "autoCollapse", "shortcutEnabled"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [bundle: .collapsible])),
                forKey: "nativeTrayChoices.v1")
            system = MenuTidyTestEnvironment()
            system.uptime = 100
            system.managedBundles = [bundle]
            system.allowed[bundle] = false
            system.identities["session:new-status"] = ObservedItemGroupHistory.Identity(id: "session:new-status",
                pid: 10001, bundleIdentifier: bundle, launchTime: 100)
            model = MenuTidyModel(testing: system, defaults: defaults)
        }

        func fire(_ time: TimeInterval) async throws {
            system.uptime = time
            try XCTUnwrap(system.maintenanceTimer).fire()
            await model.waitForTestingOperations()
        }

        func dispose() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
