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
    private final class Fixture {
        let a = "org.example.BatchA", b = "org.example.BatchB", c = "org.example.BatchC"
        let suite = "dev.hdh.MenuTidy.tests.native-batch.\(UUID().uuidString)"
        let defaults: UserDefaults
        let system = MenuTidyTestEnvironment()
        let model: MenuTidyModel

        init(includeVisible: Bool = false) throws {
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
            model = MenuTidyModel(testing: system, defaults: defaults)
        }
        func dispose() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}
