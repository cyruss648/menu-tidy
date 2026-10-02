import Foundation
import XCTest
@testable import MenuTidy

/// Exercises the application model's real panel lifecycle and maintenance
/// Timer callback. Only monotonic time and system input are supplied by the
/// isolated environment; no native menu, global input or user preferences run.
final class AutoCollapseIntegrationTests: XCTestCase {
    @MainActor
    func testFailedLongOperationKeepsItsErrorVisibleForAFullIdleInterval() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, environment) = (fixture.model, fixture.environment)

        model.showIconPanelFromControl()
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 101)

        model.beginPanelItemOperation(id: "test-item", progress: "Opening test item")
        XCTAssertTrue(model.isActivatingPanelItem)
        XCTAssertNil(environment.maintenanceTimer, "Paused auto-collapse must not restore idle polling")

        environment.uptime = 120
        model.recordPanelItemFailure(id: "test-item", message: "The test application did not open")
        model.finishPanelItemOperation()
        XCTAssertFalse(model.isActivatingPanelItem)
        XCTAssertEqual(model.trayItemErrors["test-item"], "The test application did not open")
        XCTAssertNotNil(environment.maintenanceTimer)

        // An already overdue callback must not count the 19 busy seconds as
        // idle time or immediately dismiss the newly restored failure result.
        try fireMaintenance(environment, at: 120.05)
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 121)
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 122)
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 123)
        XCTAssertFalse(model.isPanelPresented)
        XCTAssertNil(environment.maintenanceTimer, "A collapsed tray has no auto-collapse work")
        XCTAssertEqual(model.trayItemErrors["test-item"], "The test application did not open")
    }

    @MainActor
    func testPointerInteractionAfterFailureRestartsTheIdleInterval() async throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let (model, environment) = (fixture.model, fixture.environment)

        model.showIconPanelFromControl()
        model.beginPanelItemOperation(id: "test-item", progress: "Opening test item")
        environment.uptime = 120
        model.recordPanelItemFailure(id: "test-item", message: "Try again")
        model.finishPanelItemOperation()

        environment.pointerInPanel = true
        try fireMaintenance(environment, at: 121)
        try fireMaintenance(environment, at: 122)
        XCTAssertTrue(model.isPanelPresented)

        environment.pointerInPanel = false
        try fireMaintenance(environment, at: 123)
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 124)
        XCTAssertTrue(model.isPanelPresented)
        try fireMaintenance(environment, at: 125)
        XCTAssertFalse(model.isPanelPresented)
    }

    @MainActor
    func testDisabledAutoCollapseDoesNotStartATimerWhenAnOperationFinishes() async throws {
        let fixture = try makeFixture(autoCollapse: false)
        defer { fixture.dispose() }
        let (model, environment) = (fixture.model, fixture.environment)

        model.showIconPanelFromControl()
        model.beginPanelItemOperation(id: "test-item", progress: "Opening test item")
        environment.uptime = 1_000
        model.recordPanelItemFailure(id: "test-item", message: "Try again")
        model.finishPanelItemOperation()

        XCTAssertTrue(model.isPanelPresented)
        XCTAssertFalse(model.isActivatingPanelItem)
        XCTAssertNil(environment.maintenanceTimer)
    }

    @MainActor
    private func fireMaintenance(_ environment: MenuTidyTestEnvironment, at uptime: TimeInterval) throws {
        environment.uptime = uptime
        let timer = try XCTUnwrap(environment.maintenanceTimer)
        XCTAssertTrue(timer.isValid)
        timer.fire()
    }

    @MainActor
    private func makeFixture(autoCollapse: Bool = true) throws -> Fixture {
        let suiteName = "dev.hdh.MenuTidy.tests.auto-collapse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(autoCollapse, forKey: "autoCollapse")
        defaults.set(3.0, forKey: "autoCollapseDelay")
        defaults.set(false, forKey: "shortcutEnabled")
        let environment = MenuTidyTestEnvironment()
        environment.uptime = 100
        return Fixture(model: MenuTidyModel(testing: environment, defaults: defaults),
            environment: environment, defaults: defaults, suiteName: suiteName)
    }

    @MainActor
    private struct Fixture {
        let model: MenuTidyModel
        let environment: MenuTidyTestEnvironment
        let defaults: UserDefaults
        let suiteName: String

        func dispose() {
            model.stop()
            environment.maintenanceTimer?.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
