import AppKit
import MenuTidyCore
import XCTest
@testable import MenuTidy

/// Uses the real AppKit window and SwiftUI hosting view. Model dependencies
/// remain isolated, and no pointer event is needed to complete the layout.
final class HiddenItemsPanelLayoutIntegrationTests: XCTestCase {
    private let panelTitle = "Menu Tidy · 托盘"
    private let standardPanelWidth: CGFloat = 318
    private let fourRowPanelHeight: CGFloat = 255

    @MainActor
    func testClickOnEachDisplayOverridesAnAnchorOnTheOtherDisplay() async throws {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { throw XCTSkip("Display selection requires two connected screens") }
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }

        for (index, screen) in screens.enumerated() {
            let otherScreen = screens[(index + 1) % screens.count]
            let wrongAnchor = CGRect(x: otherScreen.frame.maxX - 44, y: otherScreen.frame.maxY - 22,
                width: 22, height: 22)
            let click = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)
            fixture.controller.show(model: fixture.model, anchor: wrongAnchor, clickPoint: click)
            let panel = try presentedPanel()
            let firstFrame = panel.frame
            XCTAssertTrue(screen.frame.contains(firstFrame), "The tray must open entirely on the clicked display")
            XCTAssertEqual(panel.screen, screen)
            XCTAssertEqual(firstFrame.midX, click.x, accuracy: 0.5)
            XCTAssertEqual(firstFrame.maxY,
                screen.frame.maxY - max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 8,
                accuracy: 0.5)
            try assertContentFits(panel, frame: firstFrame)

            try await allowLayoutToSettle()
            XCTAssertEqual(panel.frame, firstFrame)
            fixture.controller.close()
        }
    }

    @MainActor
    func testSecondaryDisplayPresentationStaysOnThatDisplayWhenContentResizes() async throws {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { throw XCTSkip("Display selection requires two connected screens") }
        let screen = screens[1]
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }
        let click = NSPoint(x: screen.frame.maxX - 12, y: screen.frame.maxY - 12)
        fixture.controller.show(model: fixture.model, anchor: fixture.anchor, clickPoint: click)
        let panel = try presentedPanel()
        let firstFrame = panel.frame
        XCTAssertTrue(screen.frame.contains(firstFrame), "A click near the edge must keep the whole tray on screen")
        XCTAssertLessThanOrEqual(firstFrame.maxX, screen.visibleFrame.maxX - 8)
        let itemID = try XCTUnwrap(fixture.model.panelItems.first?.id)
        fixture.model.recordPanelItemFailure(id: itemID, message: "The fixture application did not open. Please retry.")

        try await waitForLayout { panel.frame.height > self.fourRowPanelHeight + 12 }
        XCTAssertTrue(screen.frame.contains(panel.frame))
        XCTAssertEqual(panel.screen, screen)
        XCTAssertEqual(panel.frame.minX, firstFrame.minX, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, firstFrame.maxY, accuracy: 0.5)
        try assertContentFits(panel)
    }

    @MainActor
    func testNineteenItemsAreFullySizedBeforeShowReturns() async throws {
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }

        fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
        let panel = try presentedPanel()
        // Capture the frame before fittingSize can itself trigger a layout.
        let firstFrame = panel.frame
        XCTAssertEqual(firstFrame.width, standardPanelWidth, accuracy: 0.5)
        XCTAssertEqual(firstFrame.height, fourRowPanelHeight, accuracy: 0.5,
            "The first visible frame must fit all four rows and the footer")
        try assertContentFits(panel, frame: firstFrame)

        try await allowLayoutToSettle()
        XCTAssertEqual(panel.frame, firstFrame,
            "An idle run loop must not be required to repair the initial size")
        try assertContentFits(panel)
    }

    @MainActor
    func testEmptyTrayFitsItsMessageAndFooterOnFirstPresentation() async throws {
        let fixture = try await makeFixture(itemCount: 0)
        defer { fixture.dispose() }

        fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
        let panel = try presentedPanel()
        let firstFrame = panel.frame
        XCTAssertGreaterThan(firstFrame.height, 105,
            "The empty message needs more height than one icon row")
        try assertContentFits(panel, frame: firstFrame)

        try await allowLayoutToSettle()
        XCTAssertEqual(panel.frame, firstFrame)
        try assertContentFits(panel)
    }

    @MainActor
    func testMoreThanTwentyFourItemsKeepAFourRowViewport() async throws {
        let fixture = try await makeFixture(itemCount: 31)
        defer { fixture.dispose() }

        fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
        let panel = try presentedPanel()
        let firstFrame = panel.frame
        XCTAssertEqual(firstFrame.height, fourRowPanelHeight, accuracy: 0.5,
            "Additional rows must scroll rather than enlarge the panel")
        try assertContentFits(panel, frame: firstFrame)

        try await allowLayoutToSettle()
        XCTAssertEqual(panel.frame.height, fourRowPanelHeight, accuracy: 0.5)
        try assertContentFits(panel)
    }

    @MainActor
    func testRepeatedPresentationIsFullySizedEveryTime() async throws {
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }

        for _ in 0..<3 {
            fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
            let panel = try presentedPanel()
            let firstFrame = panel.frame
            XCTAssertEqual(firstFrame.height, fourRowPanelHeight, accuracy: 0.5)
            try assertContentFits(panel, frame: firstFrame)

            try await allowLayoutToSettle()
            XCTAssertEqual(panel.frame, firstFrame)
            fixture.controller.close()
            XCTAssertFalse(panel.isVisible)
        }
    }

    @MainActor
    func testOperationFailureResizesAndClearingItRestoresTheOriginalHeight() async throws {
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }

        fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
        let panel = try presentedPanel()
        let firstFrame = panel.frame
        XCTAssertEqual(firstFrame.height, fourRowPanelHeight, accuracy: 0.5)

        let itemID = try XCTUnwrap(fixture.model.panelItems.first?.id)
        fixture.model.beginPanelItemOperation(id: itemID, progress: "Opening fixture item")
        fixture.model.recordPanelItemFailure(id: itemID, message: "The fixture application did not open. Please retry.")
        fixture.model.finishPanelItemOperation()

        try await waitForLayout { panel.frame.height > self.fourRowPanelHeight + 12 }
        XCTAssertGreaterThan(panel.frame.height, fourRowPanelHeight + 12)
        XCTAssertEqual(panel.frame.maxY, firstFrame.maxY, accuracy: 0.5,
            "An error must expand the panel downward from its menu bar anchor")
        try assertContentFits(panel)

        fixture.model.beginPanelItemOperation(id: itemID, progress: "Retrying fixture item")
        fixture.model.finishPanelItemOperation()
        try await waitForLayout { abs(panel.frame.height - self.fourRowPanelHeight) < 0.5 }
        XCTAssertEqual(panel.frame.height, fourRowPanelHeight, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, firstFrame.maxY, accuracy: 0.5)
        try assertContentFits(panel)
    }

    @MainActor
    func testChangingItemCountResizesBothDirectionsWithoutMovingTheTopAnchor() async throws {
        let fixture = try await makeFixture(itemCount: 19)
        defer { fixture.dispose() }

        fixture.controller.show(model: fixture.model, anchor: fixture.anchor)
        let panel = try presentedPanel()
        let firstFrame = panel.frame
        XCTAssertEqual(firstFrame.height, fourRowPanelHeight, accuracy: 0.5)
        let allSnapshots = fixture.environment.snapshots

        fixture.environment.snapshots = Array(allSnapshots.prefix(1))
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.count, 1)
        try await waitForLayout { abs(panel.frame.height - 105) < 0.5 }
        XCTAssertEqual(panel.frame.height, 105, accuracy: 0.5,
            "One icon row and the footer should replace the four-row layout")
        XCTAssertEqual(panel.frame.maxY, firstFrame.maxY, accuracy: 0.5)
        try assertContentFits(panel)

        fixture.environment.snapshots = allSnapshots
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        // Removing an observed item revokes its native visibility evidence.
        // Reintroducing the same identity requires an explicit retry because
        // discovery only reconnects once per process lifetime. Confirm the
        // isolated fixture again before expecting a layout without a notice.
        fixture.model.applyPendingTrayPlacements()
        await fixture.model.waitForTestingOperations()
        XCTAssertEqual(fixture.model.panelItems.count, 19)
        XCTAssertTrue(fixture.model.panelItems.allSatisfy { !fixture.model.trayPlacementIsPending(id: $0.id)
            && !$0.isPending && fixture.model.trayPlacementMessage(id: $0.id) == nil },
            "The restored sizing fixture must have no pending or error notice")
        try await waitForLayout { abs(panel.frame.height - self.fourRowPanelHeight) < 0.5 }
        XCTAssertEqual(panel.frame.height, fourRowPanelHeight, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, firstFrame.maxY, accuracy: 0.5)
        XCTAssertTrue(panel.isVisible)
        try assertContentFits(panel)
    }

    @MainActor
    func testQueuedResizeFromClosedPresentationCannotChangeTheReplacementPanel() async throws {
        let oldFixture = try await makeFixture(itemCount: 19)
        defer { oldFixture.dispose() }
        let newFixture = try await makeFixture(itemCount: 1)
        defer { newFixture.dispose() }

        oldFixture.controller.show(model: oldFixture.model, anchor: oldFixture.anchor)
        let oldPanel = try presentedPanel()
        let oldItemID = try XCTUnwrap(oldFixture.model.panelItems.first?.id)

        // Do not yield between publishing the old error and replacing its
        // window: the old presentation's resize task is still queued.
        oldFixture.model.beginPanelItemOperation(id: oldItemID, progress: "Opening old fixture item")
        oldFixture.model.recordPanelItemFailure(id: oldItemID, message: "An error belongs to the closed presentation.")
        oldFixture.model.finishPanelItemOperation()
        oldFixture.controller.close()
        oldFixture.controller.show(model: newFixture.model, anchor: newFixture.anchor)

        let newPanel = try presentedPanel()
        let replacementFrame = newPanel.frame
        XCTAssertFalse(oldPanel === newPanel)
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertEqual(replacementFrame.height, 105, accuracy: 0.5)
        try assertContentFits(newPanel, frame: replacementFrame)

        try await allowLayoutToSettle()
        XCTAssertEqual(newPanel.frame, replacementFrame,
            "A queued update from the old presentation must not resize the new window")
        try assertContentFits(newPanel)

        oldFixture.model.recordPanelItemFailure(id: oldItemID, message: "A later update still belongs to the old model.")
        try await allowLayoutToSettle()
        XCTAssertEqual(newPanel.frame, replacementFrame,
            "The replacement panel must no longer observe the previous model")
        XCTAssertTrue(newPanel.isVisible)
        try assertContentFits(newPanel)
    }

    @MainActor
    private func presentedPanel() throws -> NSPanel {
        try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? NSPanel }
            .first { $0.title == panelTitle && $0.isVisible })
    }

    @MainActor
    private func assertContentFits(_ panel: NSPanel, frame: NSRect? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(panel.contentView, file: file, line: line)
        let observedFrame = frame ?? panel.frame
        let fittingHeight = content.fittingSize.height.rounded(.up)
        XCTAssertGreaterThan(fittingHeight, 0, file: file, line: line)
        XCTAssertEqual(observedFrame.height, fittingHeight, accuracy: 0.5,
            "The first frame must fit the actual SwiftUI content", file: file, line: line)
        XCTAssertEqual(content.bounds.width, observedFrame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(content.bounds.height, observedFrame.height, accuracy: 0.5, file: file, line: line)
    }

    @MainActor
    private func allowLayoutToSettle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor
    private func waitForLayout(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The native window did not reflect the SwiftUI layout within one second")
    }

    @MainActor
    private func makeFixture(itemCount: Int) async throws -> Fixture {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        guard screen.visibleFrame.width >= 334, screen.visibleFrame.height >= 450 else {
            throw XCTSkip("Native panel layout requires a screen large enough for four rows and an error notice")
        }
        let suiteName = "dev.hdh.MenuTidy.tests.panel-layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "autoCollapse")
        defaults.set(false, forKey: "shortcutEnabled")
        defaults.set(false, forKey: "startupApplyPending")

        let environment = MenuTidyTestEnvironment()
        let bundle = "org.example.MenuTidyPanelLayoutFixture"
        let rules = (0..<itemCount).map { index in
            ItemRule(id: "item:panel-layout.\(index)", name: "Fixture \(index)",
                bundleIdentifier: bundle, visibility: .collapsible)
        }
        defaults.set(try JSONEncoder().encode(ItemRuleBook(rules: Dictionary(uniqueKeysWithValues:
            rules.map { ($0.id, $0) }))), forKey: "itemRules.v1")
        for (index, rule) in rules.enumerated() {
            let pid = Int32(20000 + index)
            environment.snapshots.append(MenuBarItemSnapshot(id: rule.id, processIdentifier: pid,
                name: rule.name, ownerName: rule.name, bundleIdentifier: bundle,
                frame: CGRect(x: index * 30, y: 0, width: 22, height: 22), hasReliableGeometry: true,
                canMove: true, detail: "", persistentIdentity: true, ownIdentifier: nil))
            environment.identities[rule.id] = ObservedItemGroupHistory.Identity(id: rule.id,
                pid: pid, bundleIdentifier: bundle, launchTime: 100)
        }
        let model = MenuTidyModel(testing: environment, defaults: defaults)
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        XCTAssertEqual(model.panelItems.count, itemCount)
        XCTAssertTrue(model.panelItems.allSatisfy { !model.trayPlacementIsPending(id: $0.id)
            && model.trayPlacementMessage(id: $0.id) == nil },
            "The sizing fixture must start without a pending or error notice")

        return Fixture(model: model, environment: environment, defaults: defaults, suiteName: suiteName,
            controller: HiddenItemsPanelController(), anchor: CGRect(x: screen.frame.maxX - 44,
                y: screen.frame.maxY - 22, width: 22, height: 22))
    }

    @MainActor
    private struct Fixture {
        let model: MenuTidyModel
        let environment: MenuTidyTestEnvironment
        let defaults: UserDefaults
        let suiteName: String
        let controller: HiddenItemsPanelController
        let anchor: CGRect

        func dispose() {
            controller.close()
            model.stop()
            environment.maintenanceTimer?.invalidate()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
