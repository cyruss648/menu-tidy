import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class PanelSessionIntegrationTests: XCTestCase {
    @MainActor
    func testLockedDesktopCannotOpenTheTrayOrSendANativeAction() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.model.setDesktopSessionAvailableForTesting(false)
        await f.activate()
        XCTAssertFalse(f.model.isPanelPresented)
        XCTAssertEqual(f.system.panelPressCount, 0)
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testLockFromNativeMenuDefersCleanupUntilUnlockWithoutBlockingClassification() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        let intent = f.defaults.data(forKey: "nativeTrayChoices.v1")
        f.system.panelPresentationStatus = {
            f.model.setDesktopSessionAvailableForTesting(false)
            return .unavailable
        }
        await f.activate()
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.panelStatusReadCount, 1, "No AX closure checks after the desktop becomes unavailable")
        XCTAssertTrue(f.system.rehiddenBundles.isEmpty, "Defer preference changes while locked")
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertFalse(f.model.isActivatingPanelItem)
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), intent)
        f.system.panelPresentationStatus = nil
        try await f.unlock(at: 102)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertEqual(f.system.rehiddenBundles, [f.bundle])
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.system.panelPressCount, 1, "Resume never replays the lock-screen command")
    }

    @MainActor
    func testOrdinaryMenuCloseRestoresHiddenState() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.activate()
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.rehiddenBundles, [f.bundle])
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertFalse(f.model.isActivatingPanelItem)
    }

    @MainActor
    func testLockAndUnlockDuringPressCannotPublishAnOldPresentationOrReplayTheAction() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.beforePanelPress = {
            f.model.setDesktopSessionAvailableForTesting(false)
            f.model.setDesktopSessionAvailableForTesting(true)
        }
        await f.activate()
        XCTAssertEqual(f.system.panelStatusReadCount, 0)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testRealCleanupFailureRemainsVisibleAndRetainsSavedChoice() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.beforeRehide = { throw MenuBarAccessError.rejected }
        await f.activate()
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        XCTAssertEqual(f.system.allowed[f.bundle], true)
        XCTAssertEqual(f.model.trayPlacementGroup(id: f.id), .collapsible)
        XCTAssertFalse(f.model.isActivatingPanelItem)
    }

    @MainActor
    func testLockDuringHiddenVerificationDefersWithoutLosingTheRecovery() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        var interrupted = false
        f.system.beforeVisibilityRead = {
            if f.system.allowed[f.bundle] == false, !interrupted {
                interrupted = true
                f.model.setDesktopSessionAvailableForTesting(false)
            }
        }
        await f.activate()
        XCTAssertTrue(interrupted)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertFalse(f.model.isActivatingPanelItem)
        f.system.beforeVisibilityRead = nil
        try await f.unlock(at: 102)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertEqual(f.system.panelPressCount, 1)
    }

    @MainActor
    func testRelockDuringResumeVerificationKeepsRecoveryForTheNextUnlock() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.model.setDesktopSessionAvailableForTesting(false)
            return .unavailable
        }
        await f.activate()
        f.system.panelPresentationStatus = nil
        f.system.beforeVisibilityRead = { f.model.setDesktopSessionAvailableForTesting(false) }
        try await f.unlock(at: 102)
        XCTAssertFalse(f.model.desktopSessionAvailable)
        XCTAssertNil(f.model.positionRecoveryMessage)
        f.system.beforeVisibilityRead = nil
        try await f.unlock(at: 104)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertEqual(f.model.trayPlacementOutstandingCount, 0)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.managementError)
        XCTAssertEqual(f.system.panelPressCount, 1)
    }

    @MainActor
    func testRecoveryFailureCanBeExplicitlyRestoredWithoutLeavingAHiddenBusyGate() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.model.setDesktopSessionAvailableForTesting(false)
            return .unavailable
        }
        await f.activate()
        f.system.panelPresentationStatus = nil
        f.system.beforeRehide = { throw MenuBarAccessError.rejected }
        try await f.unlock(at: 102)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        f.system.beforeRehide = nil
        f.model.retryPositionRecovery()
        await f.model.waitForTestingOperations()
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
        XCTAssertEqual(f.system.allowed[f.bundle], true)
    }

    @MainActor
    func testDepartedOwnerCannotTransferTheOldMenuProofToANewProcess() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.model.setDesktopSessionAvailableForTesting(false)
            return .unavailable
        }
        await f.activate()
        f.system.panelPresentationStatus = nil
        f.system.identities[f.id] = ObservedItemGroupHistory.Identity(id: f.id, pid: 501,
            bundleIdentifier: f.bundle, launchTime: 20)
        try await f.unlock(at: 102)
        XCTAssertEqual(f.system.allowed[f.bundle], true)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertTrue(f.model.items.first(where: { $0.id == f.id })?.isPending == true)
    }

    @MainActor
    func testFirstClickImmediatelyAfterUnlockRunsOnceWithoutClosingTheTrayFirst() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        for _ in 0..<3 { f.model.activatePanelItem(id: f.id, useNativeAction: true) }
        XCTAssertEqual(f.model.pendingPanelItemID, f.id)
        XCTAssertNotNil(f.model.panelRecoveryProgress)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertTrue(f.model.isPanelPresented)
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 2, "Only the new explicit click runs after recovery")
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNil(f.model.panelRecoveryProgress)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
    }

    @MainActor
    func testOpenTrayDoesNotBlockInterruptedMenuRecoveryEvenWithoutANewClick() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        try await f.fire(at: 102)
        XCTAssertTrue(f.model.isPanelPresented)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testClickWhileResumeRefreshIsRunningIsAcceptedAndDispatchedAfterItsCompletion() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        var clicked = false
        f.system.beforeScan = {
            if !clicked {
                clicked = true
                XCTAssertTrue(f.model.isRefreshing)
                XCTAssertFalse(f.model.panelItemActionsDisabled)
                f.model.activatePanelItem(id: f.id, useNativeAction: true)
                XCTAssertEqual(f.model.pendingPanelItemID, f.id)
            }
        }
        try await f.fire(at: 102)
        XCTAssertTrue(clicked)
        XCTAssertEqual(f.system.panelPressCount, 2)
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testClosingTheTrayCancelsTheWaitingClickButStillRestoresTheIcon() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        f.model.activatePanelItem(id: f.id, useNativeAction: true)
        XCTAssertEqual(f.model.pendingPanelItemID, f.id)
        f.model.closeIconPanel()
        XCTAssertNil(f.model.pendingPanelItemID)
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.allowed[f.bundle], false)
    }

    @MainActor
    func testFailedRecoveryDoesNotDispatchTheWaitingClick() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        f.model.activatePanelItem(id: f.id, useNativeAction: true)
        f.system.beforeRehide = { throw MenuBarAccessError.rejected }
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testRestartDuringResumeCannotInheritTheWaitingClick() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        f.model.activatePanelItem(id: f.id, useNativeAction: true)
        f.system.identities[f.id] = ObservedItemGroupHistory.Identity(id: f.id, pid: 501,
            bundleIdentifier: f.bundle, launchTime: 20)
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNotNil(f.model.panelActivationError)
    }

    @MainActor
    func testOpenTrayDefersAutomaticApplicationWithoutRepeatingTheSuccessfulResumeScan() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.model.periodicApplyPendingEnabled = true
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        var refreshes = 0
        f.system.beforeScan = { if f.model.isRefreshing { refreshes += 1 } }
        try await f.fire(at: 102)
        XCTAssertTrue(f.model.isPanelPresented)
        XCTAssertEqual(refreshes, 1)
        f.model.closeIconPanel()
        try await f.fire(at: 103)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(f.system.panelPressCount, 1)
    }

    @MainActor
    func testOldResumeCannotConsumeANewClickAfterAnotherLockAndUnlock() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        var relocked = false
        f.system.beforeScan = {
            if !relocked {
                relocked = true
                f.model.setDesktopSessionAvailableForTesting(false)
                f.model.setDesktopSessionAvailableForTesting(true)
                f.model.showIconPanelFromControl()
                f.model.activatePanelItem(id: f.id, useNativeAction: true)
            }
        }
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.model.pendingPanelItemID, f.id)
        try await f.fire(at: 104)
        XCTAssertEqual(f.system.panelPressCount, 2)
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
    }

    @MainActor
    func testFailedResumeScanShowsRecoveryActionInsteadOfWaitingForever() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        await f.lockFromMenu()
        f.model.setDesktopSessionAvailableForTesting(true)
        f.model.showIconPanelFromControl()
        f.model.activatePanelItem(id: f.id, useNativeAction: true)
        f.system.beforeScan = { throw MenuBarAccessError.scanTimedOut(scannedOwners: 0, totalOwners: 1, elapsed: 1) }
        try await f.fire(at: 102)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertNil(f.model.pendingPanelItemID)
        XCTAssertNil(f.model.panelRecoveryProgress)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        XCTAssertNotNil(f.model.panelError)
        f.system.beforeScan = nil
        f.model.retryPositionRecovery()
        await f.model.waitForTestingOperations()
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelError)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
    }

    @MainActor
    private final class Fixture {
        let suite = "dev.hdh.MenuTidy.tests.panel-session.\(UUID().uuidString)"
        let bundle = "org.example.LockFromMenu"
        let id = "session:lock-menu"
        let defaults: UserDefaults
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        private init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(false, forKey: "shortcutEnabled")
            defaults.set(false, forKey: "startupApplyPending")
            defaults.set(false, forKey: "periodicApplyPending")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing: [bundle: .collapsible])), forKey: "nativeTrayChoices.v1")
            system.uptime = 100
            system.snapshots = [MenuBarItemSnapshot(id: id, processIdentifier: 501, name: "Lock menu", ownerName: "Lock menu",
                bundleIdentifier: bundle, frame: CGRect(x: 20, y: 0, width: 22, height: 22), hasReliableGeometry: true,
                canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)]
            system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: 501, bundleIdentifier: bundle, launchTime: 10)
            model = MenuTidyModel(testing: system, defaults: defaults)
        }

        static func make() async throws -> Fixture {
            let f = try Fixture()
            f.model.applyPendingTrayPlacements()
            await f.model.waitForTestingOperations()
            XCTAssertEqual(f.system.allowed[f.bundle], false)
            return f
        }

        func activate() async {
            model.showIconPanelFromControl()
            model.activatePanelItem(id: id, useNativeAction: true)
            await model.waitForTestingOperations()
        }

        func lockFromMenu() async {
            system.panelPresentationStatus = {
                self.model.setDesktopSessionAvailableForTesting(false)
                return .unavailable
            }
            await activate()
            system.panelPresentationStatus = nil
        }

        func unlock(at uptime: TimeInterval) async throws {
            model.setDesktopSessionAvailableForTesting(true)
            try await fire(at: uptime)
        }

        func fire(at uptime: TimeInterval) async throws {
            system.uptime = uptime
            try XCTUnwrap(system.maintenanceTimer).fire()
            await model.waitForTestingOperations()
        }

        func dispose() {
            system.panelPresentationStatus = nil
            system.beforePanelPress = nil
            system.beforeRehide = nil
            system.beforeScan = nil
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
