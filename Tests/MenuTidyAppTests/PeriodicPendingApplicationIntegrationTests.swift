import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class PeriodicPendingApplicationIntegrationTests: XCTestCase {
    @MainActor
    func testDefaultFiveMinuteCycleFindsLateAppsAndSkipsConfirmedAndOfflineChoices() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        XCTAssertTrue(model.periodicApplyPendingEnabled)
        XCTAssertEqual(model.periodicApplyPendingInterval, 300)
        var scans = 0
        system.beforeScan = { scans += 1 }
        try await fixture.fire(at: 399.99)
        XCTAssertEqual(scans, 0)
        fixture.add(id: "session:late", bundle: "org.example.PeriodicLate", pid: 202)
        try await fixture.fire(at: 400)
        XCTAssertEqual(scans, 3, "Discovery, shared preflight and final inventory verification")
        XCTAssertEqual(system.visibilityBatches.count, 1)
        XCTAssertEqual(Set(system.hiddenBundles), ["org.example.Periodic", "org.example.PeriodicLate"])
        XCTAssertEqual(model.trayPlacementOutstandingCount, 0)
        let offline = try XCTUnwrap(model.items.first { $0.bundleIdentifier == "org.example.PeriodicOffline" })
        XCTAssertFalse(offline.isAvailable)
        try await fixture.fire(at: 699.99)
        XCTAssertEqual(scans, 3)
        try await fixture.fire(at: 700)
        XCTAssertEqual(scans, 4)
        XCTAssertEqual(system.visibilityBatches.count, 1, "Confirmed targets must not be written every cycle")
    }

    @MainActor
    func testFailureWaitsForNextWholeIntervalAndThenRetries() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
        try await f.fire(at: 400)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayRetryCount, 1)
        try await f.fire(at: 401)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        f.system.beforeVisibilityRead = nil
        try await f.fire(at: 700)
        XCTAssertEqual(f.system.visibilityBatches.count, 2)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testFailedScanDoesNotApplyStaleInventoryAndNextCycleCanRecover() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeScan = { throw MenuBarAccessError.rejected }
        try await f.fire(at: 400)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNotNil(f.model.managementError)
        f.system.beforeScan = nil
        try await f.fire(at: 700)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
    }

    @MainActor
    func testOpenTrayDefersWithoutClosingItOrScanning() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.showIconPanelFromControl()
        try await f.fire(at: 400)
        XCTAssertTrue(f.model.isPanelPresented)
        XCTAssertEqual(scans, 0)
        f.model.closeIconPanel()
        try await f.fire(at: 401)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
    }

    @MainActor
    func testDisableDuringScanCancelsApplicationAndPersists() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeScan = { [weak model = f.model] in model?.periodicApplyPendingEnabled = false }
        try await f.fire(at: 400)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertNil(f.system.maintenanceTimer)
        let next = MenuTidyTestEnvironment()
        let relaunched = MenuTidyModel(testing: next, defaults: f.defaults)
        defer { relaunched.stop() }
        XCTAssertFalse(relaunched.periodicApplyPendingEnabled)
        XCTAssertNil(next.maintenanceTimer)
    }

    @MainActor
    func testIntervalChangeDuringScanInvalidatesTheOldCompletion() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.beforeScan = { [weak model = f.model] in model?.periodicApplyPendingInterval = 60 }
        try await f.fire(at: 400)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertEqual(f.defaults.double(forKey: "periodicApplyPendingInterval"), 60)
        f.system.beforeScan = nil
        try await f.fire(at: 459.99)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        try await f.fire(at: 460)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
    }

    @MainActor
    func testBusyOperationAndStopDoNotLeaveARepeatingTask() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.beginPanelItemOperation(id: "session:first", progress: "Fixture")
        try await f.fire(at: 400)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        f.model.finishPanelItemOperation()
        let timer = try XCTUnwrap(f.system.maintenanceTimer)
        f.model.stop()
        XCTAssertFalse(timer.isValid)
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testStartupAttemptPushesThePeriodicDeadlineToAvoidTwoAdjacentBatches() async throws {
        let f = try Fixture(startup: true); defer { f.dispose() }
        try await f.fire(at: 130)
        try await f.fire(at: 130.05)
        XCTAssertEqual(f.system.visibilityBatches.count, 1)
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        try await f.fire(at: 400)
        XCTAssertEqual(scans, 0)
        try await f.fire(at: 430.05)
        XCTAssertEqual(scans, 1)
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let suite = "dev.hdh.MenuTidy.tests.periodic.\(UUID().uuidString)"
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        init(startup: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(startup, forKey: "startupApplyPending")
            defaults.set(false, forKey: "shortcutEnabled")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: ["org.example.Periodic": .collapsible,
                "org.example.PeriodicLate": .alwaysHidden, "org.example.PeriodicOffline": .collapsible])), forKey: "nativeTrayChoices.v1")
            system.uptime = 100
            Self.add(system, id: "session:first", bundle: "org.example.Periodic", pid: 201)
            model = MenuTidyModel(testing: system, defaults: defaults)
        }

        func add(id: String, bundle: String, pid: Int32) { Self.add(system, id: id, bundle: bundle, pid: pid) }
        private static func add(_ system: MenuTidyTestEnvironment, id: String, bundle: String, pid: Int32) {
            system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid, name: bundle,
                ownerName: bundle, bundleIdentifier: bundle, frame: CGRect(x: 20, y: 0, width: 22, height: 22),
                hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
            system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: pid, bundleIdentifier: bundle, launchTime: 10)
        }
        func fire(at uptime: TimeInterval) async throws {
            system.uptime = uptime
            try XCTUnwrap(system.maintenanceTimer).fire()
            await model.waitForTestingOperations()
        }
        func dispose() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
