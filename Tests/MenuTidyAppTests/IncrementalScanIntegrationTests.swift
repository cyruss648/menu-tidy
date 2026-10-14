import Foundation
import MenuTidyCore
import XCTest
@testable import MenuTidy

/// Exercise the real scan/row publication path with host roots distinct from
/// the originating processes. No AX reads, preferences or input reach the desktop.
final class IncrementalScanIntegrationTests: XCTestCase {
    private let application = MenuBarOwner(pid: 10001, bundleIdentifier: "org.example.Remote",
        name: "Fixture", launchTime: 100)
    private let host = MenuBarOwner(pid: 10002, bundleIdentifier: "com.apple.MenuBarAgent",
        name: "Fixture host", launchTime: 100)

    @MainActor
    func testHostObservationsReplaceUnscannedOwnerRowsAcrossRepeatedRefreshes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [host]
        for round in 1...7 {
            fixture.system.snapshots = [snapshot("session:a", name: "Latest \(round)"), snapshot("session:b")]
            try await refresh(fixture)
            XCTAssertEqual(fixture.model.items.count, 2)
            XCTAssertEqual(Set(fixture.model.items.map(\.id)).count, 2)
            XCTAssertEqual(fixture.model.items.first { $0.id == "session:a" }?.name, "Latest \(round)")
        }
    }

    @MainActor
    func testUnobservedItemOfSameUnscannedApplicationIsRetained() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [host]
        fixture.system.snapshots = [snapshot("session:a", name: "Fresh")]
        try await refresh(fixture)
        XCTAssertEqual(Set(fixture.model.items.map(\.id)), ["session:a", "session:b"])
        XCTAssertEqual(fixture.model.items.count, 2)
        XCTAssertEqual(fixture.model.items.first { $0.id == "session:a" }?.name, "Fresh")
    }

    @MainActor
    func testScannedApplicationDropsItemsMissingFromItsCurrentInventory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [application]
        fixture.system.snapshots = [snapshot("session:a")]
        try await refresh(fixture)
        XCTAssertEqual(fixture.model.items.map(\.id), ["session:a"])
    }

    @MainActor
    func testDepartedApplicationDoesNotRetainRowsThroughTheHost() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [host]
        fixture.system.snapshots = []
        fixture.system.identities = fixture.system.identities.filter { $0.value.pid == host.pid }
        try await refresh(fixture)
        XCTAssertTrue(fixture.model.items.isEmpty)
    }

    @MainActor
    func testPIDReuseOrBundleChangeCannotInheritThePreviousInventory() async throws {
        for (bundle, launchTime) in [(application.bundleIdentifier, 200.0), ("org.example.Replacement", 100.0)] {
            let fixture = try await makeFixture()
            defer { fixture.dispose() }
            fixture.system.enumerationOwners = [host]
            fixture.system.snapshots = []
            for id in ["session:a", "session:b"] {
                fixture.system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: application.pid,
                    bundleIdentifier: bundle, launchTime: launchTime)
            }
            try await refresh(fixture)
            XCTAssertTrue(fixture.model.items.isEmpty)
        }
    }

    @MainActor
    func testFailedHostScanPreservesTheLastSuccessfulRowsThenRecoversWithoutDuplicates() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [host]
        fixture.system.snapshots = [snapshot("session:a", name: "Fresh"), snapshot("session:b")]
        fixture.system.beforeScan = { throw MenuBarAccessError.rejected }
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertNotNil(fixture.model.managementError)
        XCTAssertEqual(fixture.model.items.count, 2)
        XCTAssertEqual(fixture.model.items.first { $0.id == "session:a" }?.name, "Fixture")

        fixture.system.beforeScan = nil
        try await refresh(fixture)
        XCTAssertEqual(fixture.model.items.count, 2)
        XCTAssertEqual(fixture.model.items.first { $0.id == "session:a" }?.name, "Fresh")
    }

    @MainActor
    func testLegacyDuplicatesAreRemovedForBothObservedAndRetainedIDs() async throws {
        // Seed the previous inventory as an old affected build could leave it.
        let oldRows = (0..<7).flatMap { _ in [snapshot("session:a"), snapshot("session:b")] }
        let fixture = try await makeFixture(initialSnapshots: oldRows)
        defer { fixture.dispose() }
        fixture.system.enumerationOwners = [host]
        fixture.system.snapshots = [snapshot("session:a", name: "Fresh")]
        try await refresh(fixture)
        XCTAssertEqual(fixture.model.items.count, 2)
        XCTAssertEqual(Set(fixture.model.items.map(\.id)), ["session:a", "session:b"])
        XCTAssertEqual(fixture.model.items.first { $0.id == "session:a" }?.name, "Fresh")
    }

    @MainActor
    private func refresh(_ fixture: Fixture) async throws {
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertNil(fixture.model.managementError)
    }

    private func snapshot(_ id: String, name: String = "Fixture") -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(id: id, processIdentifier: application.pid, name: name,
            ownerName: application.name, bundleIdentifier: application.bundleIdentifier,
            frame: CGRect(x: id == "session:a" ? 0 : 30, y: 0, width: 22, height: 22),
            hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)
    }

    @MainActor
    private func makeFixture(initialSnapshots: [MenuBarItemSnapshot]? = nil) async throws -> Fixture {
        let suite = "dev.hdh.MenuTidy.tests.incremental.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "shortcutEnabled")
        defaults.set(false, forKey: "autoCollapse")
        defaults.set(false, forKey: "startupApplyPending")
        let system = MenuTidyTestEnvironment()
        system.snapshots = initialSnapshots ?? [snapshot("session:a"), snapshot("session:b")]
        for id in ["session:a", "session:b"] {
            system.identities[id] = ObservedItemGroupHistory.Identity(id: id, pid: application.pid,
                bundleIdentifier: application.bundleIdentifier, launchTime: application.launchTime)
        }
        system.identities["host"] = ObservedItemGroupHistory.Identity(id: "host", pid: host.pid,
            bundleIdentifier: host.bundleIdentifier, launchTime: host.launchTime)
        let fixture = Fixture(model: MenuTidyModel(testing: system, defaults: defaults), system: system,
            defaults: defaults, suite: suite)
        // The first full scan establishes the previous inventory's owner epochs.
        try await refresh(fixture)
        return fixture
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
