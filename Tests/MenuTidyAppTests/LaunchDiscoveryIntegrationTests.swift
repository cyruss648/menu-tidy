import ApplicationServices
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
        XCTAssertNotNil(f.system.maintenanceTimer)
        f.model.noteRunningApplications([f.owner])
        XCTAssertNotNil(f.system.maintenanceTimer)
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
        XCTAssertEqual(f.model.hiddenApplicationDiscoveryBundles, [f.bundle])
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), originalChoice)
        XCTAssertEqual(f.system.panelPressCount, 0)
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.system.maintenanceTimer, "Successful discovery must stop the launch retry timer")
    }

    @MainActor
    func testApplicationWithoutAStatusItemStopsRetryingAfterExit() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.noteApplicationLaunch(f.owner)
        f.model.noteRunningApplications([f.owner])
        for time in [101.0, 103, 107, 115] { try await f.fire(time) }
        XCTAssertEqual(scans, 4)
        XCTAssertNotNil(f.system.maintenanceTimer)
        XCTAssertTrue(f.system.visibilityBatches.isEmpty)
        XCTAssertTrue(f.system.hiddenBundles.isEmpty)

        try await f.fire(130)
        XCTAssertEqual(scans, 5)
        XCTAssertNotNil(f.system.maintenanceTimer)

        f.system.identities.removeAll()
        f.system.runningBundles = []
        f.model.noteRunningApplications([])
        XCTAssertNotNil(f.system.maintenanceTimer, "Application exit also schedules one membership refresh")
        try await f.fire(135)
        XCTAssertEqual(scans, 6, "Application exit may perform one membership refresh, then must stop retrying")
        XCTAssertNil(f.system.maintenanceTimer)
    }

    @MainActor
    func testRunningApplicationWithoutAnIconKeepsOnlyAnOfflineRecordAndItsChoice() async throws {
        for group in ItemVisibility.allCases {
            let f = try Fixture(group: group); defer { f.dispose() }
            f.system.runningBundles = [f.bundle]
            f.system.ownerReadFailures = [MenuBarOwnerReadFailure(owner: f.owner, error: AXError.noValue.rawValue)]
            let choice = f.defaults.data(forKey: "nativeTrayChoices.v1")
            f.model.onReconnectMenuBarClient = { _ in
                XCTFail("Ordinary icon absence must not restart Menu Tidy")
                return true
            }
            f.model.refreshMenuItems()
            await f.model.waitForTestingOperations()

            XCTAssertTrue(f.model.managementItems.isEmpty, "A running process alone is not a current menu bar icon")
            let row = try XCTUnwrap(f.model.items.first)
            XCTAssertFalse(row.isAvailable)
            XCTAssertTrue(row.isAwaitingDiscovery)
            XCTAssertFalse(row.isPending)
            XCTAssertFalse(row.canMove)
            XCTAssertEqual(row.group, group)
            XCTAssertFalse(f.model.trayDiscoveryConnectionFailed(id: row.id))
            XCTAssertFalse(f.model.trayItemNeedsAttention(row))
            XCTAssertNil(f.model.trayPlacementMessage(id: row.id))
            XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
            XCTAssertEqual(f.model.trayPendingApplicationCount, 0)
            XCTAssertEqual(f.model.trayRetryCount, 0)
            XCTAssertTrue(f.model.panelItems.isEmpty)

            f.model.applyPendingTrayPlacements()
            f.model.retryFailedTrayPlacements()
            await f.model.waitForTestingOperations()
            XCTAssertTrue(f.system.visibilityBatches.isEmpty)
            XCTAssertTrue(f.system.hiddenBundles.isEmpty)
            XCTAssertTrue(f.system.revealedBundles.isEmpty)
            XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choice)
        }
    }

    @MainActor
    func testDisablingAnObservedIconRemovesItUntilTheSameProcessCreatesItAgain() async throws {
        for group in ItemVisibility.allCases {
            let f = try Fixture(group: group); defer { f.dispose() }
            f.system.runningBundles = [f.bundle]
            f.system.snapshots = [f.snapshot]
            f.model.refreshMenuItems()
            await f.model.waitForTestingOperations()
            XCTAssertEqual(f.model.managementItems.count, 1)
            let choice = f.defaults.data(forKey: "nativeTrayChoices.v1")
            let writes = f.system.hiddenBundles.count

            f.system.snapshots = []
            f.model.refreshMenuItems()
            await f.model.waitForTestingOperations()

            XCTAssertTrue(f.model.managementItems.isEmpty)
            XCTAssertTrue(f.model.panelItems.isEmpty)
            XCTAssertEqual(f.model.items.count, 1)
            let saved = try XCTUnwrap(f.model.items.first)
            XCTAssertFalse(saved.isAvailable)
            XCTAssertTrue(saved.isAwaitingDiscovery)
            XCTAssertEqual(saved.group, group)
            XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
            XCTAssertEqual(f.model.trayPendingApplicationCount, 0)
            XCTAssertEqual(f.model.trayRetryCount, 0)
            XCTAssertEqual(f.system.hiddenBundles.count, writes)
            XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choice)

            f.system.snapshots = [f.snapshot]
            try await f.fire(160)
            let returned = try XCTUnwrap(f.model.managementItems.first)
            XCTAssertEqual(f.model.items.count, 1)
            XCTAssertFalse(returned.isAwaitingDiscovery)
            XCTAssertEqual(returned.group, group)
            XCTAssertFalse(returned.isPending)
            XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choice)
            XCTAssertNil(f.system.maintenanceTimer)
        }
    }

    @MainActor
    func testFailedConnectionDoesNotRetryWhenTheSameIconDisappearsAndReturns() async throws {
        for initiallyConfirmed in [false, true] {
            let f = try Fixture(); defer { f.dispose() }
            f.system.runningBundles = [f.bundle]
            f.system.snapshots = [f.snapshot]
            if initiallyConfirmed {
                f.model.refreshMenuItems()
                await f.model.waitForTestingOperations()
                XCTAssertFalse(try XCTUnwrap(f.model.managementItems.first).isPending)
            }
            f.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
            if initiallyConfirmed {
                // Lose the earlier hidden state so applying the same choice
                // performs verification instead of accepting existing proof.
                f.system.allowed[f.bundle] = true
                f.model.refreshMenuItems()
                await f.model.waitForTestingOperations()
                f.model.requestTrayPlacement(id: f.snapshot.id, group: .collapsible)
            } else {
                f.model.refreshMenuItems()
            }
            await f.model.waitForTestingOperations()
            XCTAssertNotNil(f.model.trayPlacementFailure(id: f.snapshot.id))
            let writes = f.system.hiddenBundles.count
            f.system.beforeVisibilityRead = nil
            f.system.snapshots = []
            f.model.refreshMenuItems()
            await f.model.waitForTestingOperations()
            XCTAssertTrue(f.model.managementItems.isEmpty)

            f.system.snapshots = [f.snapshot]
            try await f.fire(160)
            XCTAssertEqual(f.system.hiddenBundles.count, writes, "Disappearance must not reset a failed connection's retry policy")
            XCTAssertNotNil(f.model.trayPlacementFailure(id: f.snapshot.id))
            XCTAssertTrue(try XCTUnwrap(f.model.managementItems.first).isPending)
        }
    }

    @MainActor
    func testAbsentRunningApplicationDoesNotDuplicateOldRulesAndCanBeForgotten() async throws {
        let rules = ["item:old-a", "item:old-b"].map {
            ItemRule(id: $0, name: "Fixture", bundleIdentifier: "org.example.DelayedStatus", visibility: .collapsible)
        }
        let f = try Fixture(group: .alwaysHidden, rules: rules); defer { f.dispose() }
        f.system.runningBundles = [f.bundle]
        let savedRules = f.defaults.data(forKey: "itemRules.v1")
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()

        XCTAssertTrue(f.model.managementItems.isEmpty)
        XCTAssertEqual(f.model.items.count, 1, "One application choice must not appear again for each old source rule")
        let saved = try XCTUnwrap(f.model.items.first)
        XCTAssertFalse(saved.isAvailable)
        XCTAssertEqual(saved.group, .alwaysHidden)
        XCTAssertEqual(f.defaults.data(forKey: "itemRules.v1"), savedRules, "Moving the row must not delete saved rules")
        XCTAssertTrue(f.model.forgetItemAffectsApplication(id: saved.id))
        XCTAssertTrue(f.model.canForgetItem(id: saved.id))

        f.model.forgetItem(id: saved.id)
        XCTAssertTrue(f.model.items.isEmpty)
        XCTAssertNil(try JSONDecoder().decode(NativeTrayChoices.self,
            from: XCTUnwrap(f.defaults.data(forKey: "nativeTrayChoices.v1"))).group(bundle: f.bundle))
        XCTAssertTrue(try JSONDecoder().decode(ItemRuleBook.self,
            from: XCTUnwrap(f.defaults.data(forKey: "itemRules.v1"))).rules.isEmpty)
    }

    @MainActor
    func testIconEnabledInTheSameProcessReconnectsAfterTheLaunchWindow() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.runningBundles = [f.bundle]
        f.system.allowed[f.bundle] = true
        let choice = f.defaults.data(forKey: "nativeTrayChoices.v1")
        var scans = 0
        f.system.beforeScan = { scans += 1 }
        f.model.noteApplicationLaunch(f.owner)
        for time in [101.0, 103, 107, 115, 130] { try await f.fire(time) }
        XCTAssertTrue(f.model.managementItems.isEmpty)
        XCTAssertFalse(try XCTUnwrap(f.model.items.first).isAvailable)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(scans, 5)
        try await f.fire(189)
        XCTAssertEqual(scans, 5, "An absent icon must not create frequent discovery scans")

        f.system.snapshots = [f.snapshot]
        try await f.fire(190)
        let row = try XCTUnwrap(f.model.managementItems.first)
        XCTAssertFalse(row.isAwaitingDiscovery)
        XCTAssertFalse(row.isPending)
        XCTAssertEqual(row.group, .collapsible)
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertEqual(f.system.hiddenBundles, [f.bundle], "The re-enabled icon must receive its saved category")
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertNil(f.system.maintenanceTimer)
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choice)
        XCTAssertEqual(f.system.panelPressCount, 0)
    }

    @MainActor
    func testSavedAbsentIconGetsPassiveDiscoveryWithoutALaunchNotification() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.system.runningBundles = [f.bundle]
        f.model.noteRunningApplications([f.owner])
        f.model.refreshMenuItems()
        await f.model.waitForTestingOperations()
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertNotNil(f.system.maintenanceTimer)
        f.system.snapshots = [f.snapshot]
        try await f.fire(160)
        XCTAssertEqual(f.model.panelItems.count, 1)
        XCTAssertNil(f.system.maintenanceTimer)
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
    func testPreferenceBackendOnlyIncludesCurrentlyManagedHiddenApplicationsOutsideStartup() throws {
        let f = try Fixture(); defer { f.dispose() }
        XCTAssertEqual(f.model.hiddenApplicationDiscoveryBundles, [f.bundle])
        f.system.allowed[f.bundle] = true
        XCTAssertTrue(f.model.hiddenApplicationDiscoveryBundles.isEmpty)
        f.system.allowed[f.bundle] = false
        f.system.managedBundles = []
        XCTAssertTrue(f.model.hiddenApplicationDiscoveryBundles.isEmpty)
    }

    @MainActor
    func testNativeAssessmentDiscoveryExcludesVisibleAndTemporarilyRevealedApplications() throws {
        let visible = try Fixture(group: .visible)
        defer { visible.dispose() }
        visible.system.nativeAssessmentAuthoritative = true
        visible.system.managedBundles = []
        XCTAssertTrue(visible.model.hiddenApplicationDiscoveryBundles.isEmpty)

        let revealed = try Fixture()
        defer { revealed.dispose() }
        revealed.system.nativeAssessmentAuthoritative = true
        revealed.system.allowed[revealed.bundle] = true
        revealed.system.revealedBundles = [revealed.bundle]
        XCTAssertTrue(revealed.model.hiddenApplicationDiscoveryBundles.isEmpty)
    }

    @MainActor
    func testNativeAssessmentRecoveryRetryRediscoversAnOffBandIcon() async throws {
        let fixture = try Fixture()
        defer {
            fixture.system.beforeScan = nil
            fixture.dispose()
        }
        fixture.system.nativeAssessmentAuthoritative = true
        fixture.system.runningBundles = [fixture.bundle]
        fixture.system.snapshots = [fixture.snapshot]
        let savedChoice = fixture.defaults.data(forKey: "nativeTrayChoices.v1")
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])

        fixture.system.beforeScan = {
            let admitsOffBandIcon = HiddenApplicationInventoryPolicy.accepts(isApplicationExtras: true,
                depth: 1, role: "AXMenuBarItem", ownerPID: fixture.owner.pid, rootPID: fixture.owner.pid,
                launchTime: fixture.owner.launchTime, bundleIdentifier: fixture.bundle,
                hiddenApplicationBundles: fixture.model.hiddenApplicationDiscoveryBundles)
            fixture.system.snapshots = admitsOffBandIcon ? [fixture.snapshot] : []
        }
        fixture.model.retryPositionRecovery()
        await fixture.model.waitForTestingOperations()

        XCTAssertTrue(fixture.system.managedBundles.isEmpty)
        XCTAssertEqual(fixture.system.restoredBundles, [fixture.bundle])
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertEqual(fixture.model.panelItems.first?.group, .collapsible)
        XCTAssertEqual(fixture.defaults.data(forKey: "nativeTrayChoices.v1"), savedChoice)
        XCTAssertEqual(fixture.system.panelPressCount, 0)
        XCTAssertNil(fixture.model.positionRecoveryMessage)
    }

    @MainActor
    func testDisplayChangesDiscardTheInFlightScanAndCoalesceDiscovery() async throws {
        let fixture = try Fixture()
        defer {
            fixture.system.beforeScan = nil
            fixture.dispose()
        }
        fixture.system.snapshots = [fixture.snapshot]
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])

        var scans = 0
        fixture.system.snapshots = []
        fixture.system.beforeScan = {
            scans += 1
            guard scans == 1 else { return }
            fixture.system.uptime = 101
            fixture.model.screenLayoutDidChange()
            fixture.system.uptime = 101.5
            fixture.model.screenLayoutDidChange()
        }
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertEqual(scans, 1)

        fixture.system.snapshots = [fixture.snapshot]
        try await fixture.fire(102)
        XCTAssertEqual(scans, 1)
        try await fixture.fire(102.5)
        XCTAssertEqual(scans, 2)
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertNil(fixture.system.maintenanceTimer)
    }

    @MainActor
    func testDisplayChangeReleasesNativeAssessmentAndReconnectsRediscoveredIcons() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.system.nativeAssessmentAuthoritative = true
        fixture.system.runningBundles = [fixture.bundle]
        fixture.system.snapshots = [fixture.snapshot]
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])

        fixture.model.screenLayoutDidChange()
        try await fixture.fire(102)
        XCTAssertEqual(fixture.system.displayAssessmentReleases, 1)
        XCTAssertEqual(fixture.system.displayAssessmentRefreshes, 1)
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertFalse(try XCTUnwrap(fixture.model.managementItems.first).isPending)
        XCTAssertNil(fixture.system.maintenanceTimer)
    }

    @MainActor
    func testDisplayChangeRetriesWhenMenuBarInventoryArrivesLate() async throws {
        let fixture = try Fixture()
        defer {
            fixture.system.beforeScan = nil
            fixture.dispose()
        }
        fixture.system.nativeAssessmentAuthoritative = true
        fixture.system.runningBundles = [fixture.bundle]
        fixture.model.screenLayoutDidChange()
        try await fixture.fire(102)
        XCTAssertNil(fixture.model.panelItems.first)
        XCTAssertTrue(fixture.system.managedBundles.isEmpty)

        fixture.system.snapshots = [fixture.snapshot]
        try await fixture.fire(104)
        XCTAssertEqual(fixture.system.displayAssessmentReleases, 1)
        XCTAssertEqual(fixture.system.displayAssessmentRefreshes, 1)
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertFalse(try XCTUnwrap(fixture.model.managementItems.first).isPending)
        XCTAssertNil(fixture.system.maintenanceTimer)
    }

    @MainActor
    func testDisplayChangeRetriesAFailedRediscoveryWithoutPublishingStaleRows() async throws {
        let fixture = try Fixture()
        defer {
            fixture.system.beforeScan = nil
            fixture.dispose()
        }
        fixture.system.nativeAssessmentAuthoritative = true
        fixture.system.runningBundles = [fixture.bundle]
        fixture.model.screenLayoutDidChange()
        var scans = 0
        fixture.system.beforeScan = {
            scans += 1
            if scans == 1 { throw MenuBarAccessError.scanTimedOut(scannedOwners: 0, totalOwners: 0, elapsed: 0) }
        }
        try await fixture.fire(102)
        XCTAssertTrue(fixture.model.managementItems.isEmpty)
        try await fixture.fire(104)
        fixture.system.snapshots = [fixture.snapshot]
        try await fixture.fire(109)
        XCTAssertEqual(fixture.system.displayAssessmentReleases, 1)
        XCTAssertEqual(fixture.model.panelItems.map(\.id), [fixture.snapshot.id])
        XCTAssertFalse(try XCTUnwrap(fixture.model.managementItems.first).isPending)
        XCTAssertNil(fixture.system.maintenanceTimer)
    }

    @MainActor
    func testRepeatedDisplayChangesReleaseAndRebuildOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.system.nativeAssessmentAuthoritative = true
        fixture.system.runningBundles = [fixture.bundle]
        fixture.system.snapshots = [fixture.snapshot]
        fixture.model.screenLayoutDidChange()
        fixture.system.uptime = 101
        fixture.model.screenLayoutDidChange()
        try await fixture.fire(102)
        XCTAssertEqual(fixture.system.displayAssessmentReleases, 1)
        XCTAssertEqual(fixture.system.displayAssessmentRefreshes, 1)
        XCTAssertNil(fixture.system.maintenanceTimer)
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

        init(group: ItemVisibility = .collapsible, rules: [ItemRule] = []) throws {
            suite = "dev.hdh.MenuTidy.tests.launch-discovery.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            for key in ["startupApplyPending", "periodicApplyPending", "autoCollapse", "shortcutEnabled"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [bundle: group])),
                forKey: "nativeTrayChoices.v1")
            if !rules.isEmpty {
                defaults.set(try JSONEncoder().encode(ItemRuleBook(rules: Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) }))),
                    forKey: "itemRules.v1")
            }
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
