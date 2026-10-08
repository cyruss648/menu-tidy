import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

/// Drives the real maintenance Timer and batch queue with an isolated clock,
/// preferences and menu-bar backend. No login, TCC or user menu bar is touched.
final class StartupPendingApplicationIntegrationTests: XCTestCase {
    private let bundle = "org.example.StartupFixture"

    @MainActor
    func testDefaultWaitsThirtySecondsRefreshesLateIconsAndAppliesOnlyOnlineChoices() async throws {
        let lateBundle = "org.example.LateStartupFixture"
        let offlineBundle = "org.example.OfflineStartupFixture"
        let fixture = try makeFixture(choices: [bundle: .collapsible, lateBundle: .alwaysHidden,
            offlineBundle: .alwaysHidden])
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        XCTAssertTrue(model.startupApplyPendingEnabled)
        var scans = 0
        system.beforeScan = { scans += 1 }

        try fireMaintenance(system, at: 129.99)
        await model.waitForTestingOperations()
        XCTAssertEqual(scans, 0)
        XCTAssertTrue(system.hiddenBundles.isEmpty)

        // The late application did not exist in the model's launch snapshot.
        addItem(to: system, id: "session:late", bundle: lateBundle, pid: 10001)
        try await finishStartupAttempt(fixture, at: 130)
        XCTAssertEqual(Set(system.hiddenBundles), [bundle, lateBundle])
        XCTAssertEqual(system.hiddenBundles.count, 2)
        XCTAssertTrue(model.items.filter(\.isAvailable).allSatisfy { !$0.isPending })
        let offline = try XCTUnwrap(model.items.first { $0.bundleIdentifier == offlineBundle })
        XCTAssertFalse(offline.isAvailable)
        XCTAssertEqual(offline.group, .alwaysHidden)
        XCTAssertNil(system.maintenanceTimer, "The one launch attempt must stop its timer")
    }

    @MainActor
    func testDelayedAttemptRetriesAnEarlyConnectionFailureForTheSameIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        XCTAssertNotNil(model.trayPlacementFailure(id: "session:startup"))
        XCTAssertEqual(system.hiddenBundles, [bundle])

        system.beforeVisibilityRead = nil
        try await finishStartupAttempt(fixture, at: 130)
        XCTAssertEqual(system.hiddenBundles, [bundle, bundle])
        XCTAssertNil(model.trayPlacementFailure(id: "session:startup"))
        XCTAssertFalse(try XCTUnwrap(model.items.first).isPending)
        XCTAssertNil(system.maintenanceTimer)
    }

    @MainActor
    func testBusyOperationPostponesTheAttemptUntilItFinishes() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        var scans = 0
        system.beforeScan = { scans += 1 }
        model.beginPanelItemOperation(id: "session:startup", progress: "Opening item")

        try fireMaintenance(system, at: 130)
        await model.waitForTestingOperations()
        XCTAssertEqual(scans, 0)
        XCTAssertTrue(system.hiddenBundles.isEmpty)
        XCTAssertNotNil(system.maintenanceTimer)

        system.uptime = 131
        model.finishPanelItemOperation()
        try await finishStartupAttempt(fixture, at: 131)
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertNil(system.maintenanceTimer)
    }

    @MainActor
    func testOpenTrayPostponesTheAttemptWithoutClosingTheTray() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        model.showIconPanelFromControl()
        XCTAssertTrue(model.isPanelPresented)

        try fireMaintenance(system, at: 130)
        await model.waitForTestingOperations()
        XCTAssertTrue(model.isPanelPresented)
        XCTAssertTrue(system.hiddenBundles.isEmpty)

        model.closeIconPanel()
        try await finishStartupAttempt(fixture, at: 131)
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertNil(system.maintenanceTimer)
    }

    @MainActor
    func testFailedDelayedBatchStopsAndCanStillBeRetriedManually() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }

        try await finishStartupAttempt(fixture, at: 130)
        XCTAssertEqual(system.hiddenBundles, [bundle])
        XCTAssertTrue(try XCTUnwrap(model.items.first).isPending)
        XCTAssertNotNil(model.trayPlacementFailure(id: "session:startup"))
        XCTAssertNil(system.maintenanceTimer, "A failed batch must not loop automatically")

        system.uptime = 1_000
        system.beforeVisibilityRead = nil
        // Even toggling the preference cannot repeat an already consumed launch.
        model.startupApplyPendingEnabled = false
        model.startupApplyPendingEnabled = true
        XCTAssertNil(system.maintenanceTimer)
        model.applyPendingTrayPlacements()
        await model.waitForTestingOperations()
        XCTAssertEqual(system.hiddenBundles, [bundle, bundle])
        XCTAssertFalse(try XCTUnwrap(model.items.first).isPending)
    }

    @MainActor
    func testFailedRefreshPreservesPendingRowsAndDoesNotApplyAStaleInventory() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        system.beforeScan = { throw MenuBarAccessError.rejected }

        try fireMaintenance(system, at: 130)
        await model.waitForTestingOperations()
        XCTAssertNotNil(model.managementError)
        XCTAssertTrue(try XCTUnwrap(model.items.first).isPending)
        XCTAssertTrue(system.hiddenBundles.isEmpty)
        XCTAssertNil(system.maintenanceTimer)
    }

    @MainActor
    func testDisablingDuringRefreshCancelsTheBatchAndPersistsAcrossLaunches() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, system) = (fixture.model, fixture.system)
        system.beforeScan = { [weak model] in model?.startupApplyPendingEnabled = false }

        try fireMaintenance(system, at: 130)
        await model.waitForTestingOperations()
        XCTAssertTrue(system.hiddenBundles.isEmpty)
        XCTAssertNil(system.maintenanceTimer)
        XCTAssertFalse(fixture.defaults.bool(forKey: "startupApplyPending"))

        let nextSystem = MenuTidyTestEnvironment()
        nextSystem.uptime = 1_000
        let relaunched = MenuTidyModel(testing: nextSystem, defaults: fixture.defaults)
        defer { relaunched.stop() }
        XCTAssertFalse(relaunched.startupApplyPendingEnabled)
        XCTAssertNil(nextSystem.maintenanceTimer)
    }

    @MainActor
    func testDisabledOrIncompleteSetupDoesNotScheduleAndStoppingCancelsTheTimer() throws {
        for configuration in [(enabled: false, completedSetup: true), (enabled: true, completedSetup: false)] {
            let fixture = try makeFixture(enabled: configuration.enabled, completedSetup: configuration.completedSetup)
            XCTAssertNil(fixture.system.maintenanceTimer)
            fixture.dispose()
        }
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let timer = try XCTUnwrap(fixture.system.maintenanceTimer)
        fixture.model.stop()
        XCTAssertFalse(timer.isValid)
        XCTAssertNil(fixture.system.maintenanceTimer)
    }

    @MainActor
    private func finishStartupAttempt(_ fixture: Fixture, at uptime: TimeInterval) async throws {
        try fireMaintenance(fixture.system, at: uptime)
        await fixture.model.waitForTestingOperations()
        try fireMaintenance(fixture.system, at: uptime + 0.05)
        await fixture.model.waitForTestingOperations()
    }

    @MainActor
    private func fireMaintenance(_ system: MenuTidyTestEnvironment, at uptime: TimeInterval) throws {
        system.uptime = uptime
        let timer = try XCTUnwrap(system.maintenanceTimer)
        XCTAssertTrue(timer.isValid)
        timer.fire()
    }

    @MainActor
    private func addItem(to system: MenuTidyTestEnvironment, id: String, bundle: String, pid: Int32) {
        system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid,
            name: "Fixture", ownerName: "Fixture", bundleIdentifier: bundle,
            frame: CGRect(x: 0, y: 0, width: 22, height: 22), hasReliableGeometry: true,
            canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
        system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: pid,
            bundleIdentifier: bundle, launchTime: 100)
    }

    @MainActor
    private func makeFixture(enabled: Bool? = nil, completedSetup: Bool = true,
                             choices: [String: ItemVisibility]? = nil) throws -> Fixture {
        let suite = "dev.hdh.MenuTidy.tests.startup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(completedSetup, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "shortcutEnabled")
        defaults.set(false, forKey: "autoCollapse")
        if let enabled { defaults.set(enabled, forKey: "startupApplyPending") }
        var savedChoices = NativeTrayChoices()
        for (bundle, group) in choices ?? [bundle: .collapsible] {
            _ = savedChoices.set(bundle: bundle, group: group)
        }
        defaults.set(try JSONEncoder().encode(savedChoices), forKey: "nativeTrayChoices.v1")
        let system = MenuTidyTestEnvironment()
        system.uptime = 100
        addItem(to: system, id: "session:startup", bundle: bundle, pid: 10000)
        return Fixture(model: MenuTidyModel(testing: system, defaults: defaults), system: system,
            defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let model: MenuTidyModel
        let system: MenuTidyTestEnvironment
        let defaults: UserDefaults
        let suite: String

        func dispose() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
