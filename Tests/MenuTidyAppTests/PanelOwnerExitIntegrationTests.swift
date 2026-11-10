import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

final class PanelOwnerExitIntegrationTests: XCTestCase {
    @MainActor
    func testQuitFromMenuReleasesTemporaryRevealAndOtherIconsRemainUsable() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        let choices = f.defaults.data(forKey: "nativeTrayChoices.v1")
        f.system.panelPresentationStatus = {
            f.exit()
            return .unavailable
        }
        await f.activate(f.id)
        XCTAssertEqual(f.system.panelStatusReadCount, 1)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertFalse(f.system.managedBundles.contains(f.bundle))
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertNil(f.model.trayItemErrors[f.id])
        XCTAssertFalse(f.model.isActivatingPanelItem)
        XCTAssertFalse(f.model.isPanelItemOperationRunning)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choices)
        XCTAssertTrue(f.model.items.contains { $0.bundleIdentifier == f.bundle && !$0.isAvailable })

        f.system.panelPresentationStatus = nil
        await f.activate(f.otherID)
        XCTAssertEqual(f.system.panelPressCount, 2)
        XCTAssertEqual(f.system.allowed[f.otherBundle], false)
        XCTAssertEqual(f.system.rehiddenBundles, [f.otherBundle])
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
    }

    @MainActor
    func testAlreadyClosedMenuDoesNotVerifyHiddenVisibilityOfAnExitedOwner() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.exit()
            return .closed
        }
        await f.activate(f.id)
        XCTAssertTrue(f.system.rehiddenBundles.isEmpty)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testExitBeforePresentationObservationDoesNotReadTheDeadMenu() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.beforePanelPress = { f.exit() }
        await f.activate(f.id)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.panelStatusReadCount, 0)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertNil(f.model.panelActivationError)
    }

    @MainActor
    func testExitWhilePressIsReturningDoesNotPublishDisappearedAsAnError() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.beforePanelPress = {
            f.exit()
            throw MenuBarAccessError.disappeared
        }
        await f.activate(f.id)
        XCTAssertEqual(f.system.panelPressCount, 1)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertNil(f.model.panelActivationError)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testExitDuringRehideVerificationRestoresOwnershipWithoutBlockingOtherIcons() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.beforeVisibilityReadForItem = { id in
            if id == f.id, f.system.allowed[f.bundle] == false { f.exit() }
        }
        await f.activate(f.id)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertTrue(f.system.revealedBundles.isEmpty)
        XCTAssertNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.model.trayPlacementSelectionAllowed)
        f.system.beforeVisibilityReadForItem = nil
        await f.activate(f.otherID)
        XCTAssertEqual(f.system.panelPressCount, 2)
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testRelaunchedApplicationCannotInheritTheOldPresentationOrHiddenProof() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.exit()
            f.system.snapshots.append(f.snapshot(id: f.id, bundle: f.bundle, pid: 10501))
            f.system.identities[f.id] = ObservedItemGroupHistory.Identity(id: f.id, pid: 10501,
                bundleIdentifier: f.bundle, launchTime: 20)
            return .unavailable
        }
        await f.activate(f.id)
        XCTAssertEqual(f.system.restoredBundles, [f.bundle])
        XCTAssertEqual(f.system.allowed[f.bundle], true)
        XCTAssertFalse(f.system.managedBundles.contains(f.bundle))
        XCTAssertEqual(f.system.panelPressCount, 1, "A replacement epoch never replays the old click")
        XCTAssertFalse(f.model.items.contains { $0.isAvailable && $0.bundleIdentifier == f.bundle },
            "The replacement must be discovered again before it can inherit an available tile")
        XCTAssertNil(f.model.positionRecoveryMessage)
    }

    @MainActor
    func testMissingAXSourceWithoutPositiveExitEvidenceKeepsRecoveryProtection() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = {
            f.system.snapshots.removeAll { $0.id == f.id }
            f.system.identities.removeValue(forKey: f.id)
            return .unavailable
        }
        await f.activate(f.id)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.system.revealedBundles.contains(f.bundle))
        XCTAssertTrue(f.system.restoredBundles.isEmpty)
        XCTAssertFalse(f.model.isActivatingPanelItem)
    }

    @MainActor
    func testLiveOwnerWithUnreadableMenuKeepsRecoveryProtection() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        f.system.panelPresentationStatus = { .unavailable }
        await f.activate(f.id)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.system.revealedBundles.contains(f.bundle))
        XCTAssertTrue(f.system.restoredBundles.isEmpty)
        XCTAssertTrue(f.system.rehiddenBundles.isEmpty)
    }

    @MainActor
    func testRealRestoreFailureAfterExitStillRetainsRecoveryErrorAndSavedChoices() async throws {
        let f = try await Fixture.make(); defer { f.dispose() }
        let choices = f.defaults.data(forKey: "nativeTrayChoices.v1")
        f.system.panelPresentationStatus = {
            f.exit()
            return .unavailable
        }
        f.system.beforeRestore = { throw MenuBarAccessError.rejected }
        await f.activate(f.id)
        XCTAssertNotNil(f.model.positionRecoveryMessage)
        XCTAssertTrue(f.system.managedBundles.contains(f.bundle))
        XCTAssertTrue(f.system.revealedBundles.contains(f.bundle))
        XCTAssertEqual(f.defaults.data(forKey: "nativeTrayChoices.v1"), choices)
        XCTAssertFalse(f.model.isActivatingPanelItem)
    }

    @MainActor
    private final class Fixture {
        let suite = "dev.hdh.MenuTidy.tests.panel-exit.\(UUID().uuidString)"
        let id = "session:quitting"
        let otherID = "session:remaining"
        let bundle = "org.example.Quitting"
        let otherBundle = "org.example.Remaining"
        let defaults: UserDefaults
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        private init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(false, forKey: "shortcutEnabled")
            defaults.set(false, forKey: "startupApplyPending")
            defaults.set(false, forKey: "periodicApplyPending")
            defaults.set(try JSONEncoder().encode(NativeTrayChoices(existing:
                [bundle: .collapsible, otherBundle: .collapsible])), forKey: "nativeTrayChoices.v1")
            system.uptime = 100
            for (id, bundle, pid) in [(id, bundle, Int32(10501)), (otherID, otherBundle, Int32(10502))] {
                system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid,
                    name: "Fixture", ownerName: "Fixture", bundleIdentifier: bundle,
                    frame: CGRect(x: pid == 10501 ? 20 : 50, y: 0, width: 22, height: 22),
                    hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil))
                system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: pid,
                    bundleIdentifier: bundle, launchTime: 10)
            }
            model = MenuTidyModel(testing: system, defaults: defaults)
        }

        static func make() async throws -> Fixture {
            let f = try Fixture()
            f.model.applyPendingTrayPlacements()
            await f.model.waitForTestingOperations()
            XCTAssertEqual(f.system.allowed[f.bundle], false)
            XCTAssertEqual(f.system.allowed[f.otherBundle], false)
            return f
        }

        func snapshot(id: String, bundle: String, pid: Int32) -> MenuBarItemSnapshot {
            MenuBarItemSnapshot(id: id, processIdentifier: pid, name: "Fixture", ownerName: "Fixture",
                bundleIdentifier: bundle, frame: CGRect(x: 20, y: 0, width: 22, height: 22),
                hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)
        }

        func exit() {
            if let identity = system.identities.removeValue(forKey: id) { system.endedOwners.append(identity) }
            system.snapshots.removeAll { $0.id == id }
        }

        func activate(_ id: String) async {
            model.showIconPanelFromControl()
            model.activatePanelItem(id: id, useNativeAction: true)
            await model.waitForTestingOperations()
        }

        func dispose() {
            system.panelPresentationStatus = nil
            system.beforePanelPress = nil
            system.beforeVisibilityReadForItem = nil
            system.beforeRestore = nil
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
