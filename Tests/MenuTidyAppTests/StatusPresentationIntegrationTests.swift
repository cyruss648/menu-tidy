import AppKit
import MenuTidyCore
import SwiftUI
import XCTest
@testable import MenuTidy

@MainActor
final class StatusPresentationIntegrationTests: XCTestCase {
    func testShortActivityNeverAppearsAndCancelledDelayCannotLeakIntoTheNextOperation() async throws {
        let state = ActivityFixture()
        let window = makeWindow(ActivityHarness(state: state))
        defer { window.close() }
        await settle()

        state.active = true
        await settle()
        XCTAssertFalse(state.renderedActive)
        state.active = false
        await settle()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(state.renderedActive, "A completed short operation must never reveal its delayed indicator")

        state.active = true
        await settle()
        XCTAssertFalse(state.renderedActive, "A new operation starts a fresh presentation delay")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(state.renderedActive, "Long-running work must still be visible")
        state.active = false
        await settle()
        XCTAssertFalse(state.renderedActive, "Completed work must not retain a stale loading indicator")
    }

    func testRefreshErrorsAndOptionalImageDiagnosticsPreserveTheListViewportAndScrollOffset() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        let state = SettingsViewState()
        let updates = UpdateController(model: fixture.model, enabled: false)
        let window = makeWindow(SettingsView(model: fixture.model, updates: updates,
                                             presentation: state, preferences: fixture.preferences))
        defer { window.close() }
        await settle()
        let host = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        let original = try Layout(scroll, in: host)
        XCTAssertGreaterThan(original.offset, 100)
        let gate = ScanGate()
        fixture.system.beforeScan = { await gate.wait() }
        defer { gate.resume() }
        fixture.model.refreshMenuItems()
        await settle()
        XCTAssertTrue(fixture.model.isRefreshing)
        XCTAssertTrue(fixture.model.canCancelCurrentOperation, "The presentation delay must not delay cancellation")
        try assertLayout(original, scroll: scroll, host: host)
        try await Task.sleep(for: .milliseconds(400))
        try assertLayout(original, scroll: scroll, host: host)
        gate.resume()
        await fixture.model.waitForTestingOperations()
        await settle()
        try assertLayout(original, scroll: scroll, host: host)

        fixture.system.beforeScan = { throw MenuBarAccessError.rejected }
        fixture.model.refreshMenuItems()
        await fixture.model.waitForTestingOperations()
        await settle()
        XCTAssertNotNil(fixture.model.managementError)
        try assertLayout(original, scroll: scroll, host: host)
        fixture.model.updateIconImageDiagnostics(summary: ImageAvailabilitySummary(
            requested: ["one", "two"], available: ["one"]), unobservedConfiguredCount: 0)
        await settle()
        XCTAssertNotNil(fixture.model.iconImageDiagnostics)
        try assertLayout(original, scroll: scroll, host: host)
    }

    func testOptionalImageGapsNeverBecomeGlobalErrorsOrClearRealOperationFailures() async throws {
        let fixture = try await makeFixture(screenCaptureGranted: true)
        defer { fixture.dispose() }
        let view = SettingsView(model: fixture.model, updates: UpdateController(model: fixture.model, enabled: false),
                                presentation: SettingsViewState(), preferences: fixture.preferences)
        for available in [Set(["one"]), Set<String>()] {
            fixture.model.updateIconImageDiagnostics(summary: ImageAvailabilitySummary(
                requested: ["one", "two"], available: available), unobservedConfiguredCount: 18,
                issues: [MenuBarIconCapture.CaptureError.noIndependentWindows.localizedMessage])
            XCTAssertNotNil(fixture.model.iconImageDiagnostics)
            XCTAssertNil(view.statusAttentionMessage, "Missing optional snapshots must not request user intervention")
        }
        fixture.model.updateIconImageDiagnostics(summary: ImageAvailabilitySummary(requested: [], available: []),
                                                unobservedConfiguredCount: 18)
        XCTAssertNil(view.statusAttentionMessage, "Offline choices are not image errors")
        XCTAssertFalse(try XCTUnwrap(fixture.model.iconImageDiagnostics).sourceText.contains(
            MenuBarIconCapture.CaptureError.noIndependentWindows.localizedMessage.sourceText),
                       "A new recount must not carry a previous attempt's preparation failure")
        fixture.model.recordPanelItemFailure(id: "one", message: MenuBarAccessError.permission.localizedMessage)
        fixture.model.updateIconImageDiagnostics(summary: ImageAvailabilitySummary(
            requested: ["one", "two"], available: ["one", "two"]), unobservedConfiguredCount: 0)
        XCTAssertEqual(fixture.model.panelActivationError, MenuBarAccessError.permission.localizedMessage)
        XCTAssertEqual(view.statusAttentionMessage, fixture.preferences.localized(MenuBarAccessError.permission.localizedMessage))
    }

    func testOptionalScreenshotPermissionIsNotRequiredForTheTray() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        fixture.model.refreshIconImageDiagnostics()
        XCTAssertTrue(try XCTUnwrap(fixture.model.iconImageDiagnostics).sourceText.contains("增强未启用"))
        let view = SettingsView(model: fixture.model, updates: UpdateController(model: fixture.model, enabled: false),
                                presentation: SettingsViewState(), preferences: fixture.preferences)
        XCTAssertNil(view.statusAttentionMessage)
    }

    func testRowFailureAndPendingStateKeepTheSameContentHeight() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        let window = makeWindow(SettingsView(model: fixture.model,
            updates: UpdateController(model: fixture.model, enabled: false),
            presentation: SettingsViewState(), preferences: fixture.preferences))
        defer { window.close() }
        await settle()
        let host = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let original = try Layout(scroll, in: host)
        let item = try XCTUnwrap(fixture.model.managementItems.first)
        fixture.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
        fixture.model.requestTrayPlacement(id: item.id, group: .collapsible)
        await fixture.model.waitForTestingOperations()
        await settle()
        XCTAssertNotNil(fixture.model.trayPlacementFailure(id: item.id))
        try assertLayout(original, scroll: scroll, host: host)

        let gate = ScanGate()
        fixture.system.beforeScan = { await gate.wait() }
        defer { gate.resume() }
        fixture.model.retryTrayPlacement(id: item.id)
        await settle()
        try await Task.sleep(for: .milliseconds(400))
        try assertLayout(original, scroll: scroll, host: host)
        gate.resume()
        await fixture.model.waitForTestingOperations()
    }

    func testManagementRowsRemainCompactWithAndWithoutFailureDetails() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        let item = try XCTUnwrap(fixture.model.managementItems.first)
        let settings = SettingsView(model: fixture.model,
            updates: UpdateController(model: fixture.model, enabled: false),
            presentation: SettingsViewState(), preferences: fixture.preferences)
        for failing in [false, true] {
            if failing {
                fixture.system.beforeVisibilityRead = { throw MenuBarAccessError.rejected }
                fixture.model.requestTrayPlacement(id: item.id, group: .collapsible)
                await fixture.model.waitForTestingOperations()
                XCTAssertNotNil(fixture.model.trayPlacementFailure(id: item.id))
            }
            for width in [CGFloat(720), CGFloat(1000)] {
                let row = settings.trayItemRow(try XCTUnwrap(fixture.model.managementItems.first))
                let window = makeWindow(row.frame(width: width))
                defer { window.close() }
                await settle()
                XCTAssertEqual(try XCTUnwrap(window.contentView).fittingSize.height, 48, accuracy: 1,
                               "Normal and failed rows must share a compact height with readable controls")
            }
        }
    }

    func testBusyUpdatesKeepSettingsHeightAndScrollOffset() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }
        let state = SettingsViewState()
        state.page = .settings
        let window = makeWindow(SettingsView(model: fixture.model,
            updates: UpdateController(model: fixture.model, enabled: false),
            presentation: state, preferences: fixture.preferences))
        defer { window.close() }
        await settle()
        let host = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        let original = try Layout(scroll, in: host)
        let gate = ScanGate()
        fixture.system.beforeScan = { await gate.wait() }
        defer { gate.resume() }
        fixture.model.refreshMenuItems()
        try await Task.sleep(for: .milliseconds(450))
        try assertLayout(original, scroll: scroll, host: host)
        gate.resume()
        await fixture.model.waitForTestingOperations()
        await settle()
        try assertLayout(original, scroll: scroll, host: host)
    }

    func testUpdateFeedbackStaysCompactAcrossIdleWaitingCheckingAndLongErrors() async throws {
        // Check the actual SwiftUI row's intrinsic height at both a narrow and a wide card width.
        // The old implementation reserved seven lines even when there was no activity or error.
        for width in [CGFloat(480), CGFloat(800)] {
            let state = UpdateStatusFixture()
            let host = NSHostingView(rootView: UpdateStatusHarness(state: state).frame(width: width))
            let window = makeWindow(EmptyView())
            window.contentView = host
            defer { window.close() }
            await settle()
            let idleHeight = host.fittingSize.height
            XCTAssertGreaterThan(idleHeight, 40, "Keep readable text and vertical padding")
            XCTAssertLessThanOrEqual(idleHeight, 64, "Do not reserve hidden waiting/error paragraphs")

            state.busy = true
            await settle()
            XCTAssertEqual(host.fittingSize.height, idleHeight, accuracy: 1)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(host.fittingSize.height, idleHeight, accuracy: 1)
            state.checking = true
            state.status = "正在检查新版本…"
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(host.fittingSize.height, idleHeight, accuracy: 1)
            state.issue = String(repeating: "网络连接暂时不可用，请稍后重新检查更新。", count: 12)
            state.status = "本次更新检查未完成"
            state.busy = false
            state.checking = false
            await settle()
            XCTAssertEqual(host.fittingSize.height, idleHeight, accuracy: 1,
                           "A long failure must remain readable in details without expanding the card")
            state.issue = nil
            state.status = "当前没有可安装的新版本"
            await settle()
            XCTAssertEqual(host.fittingSize.height, idleHeight, accuracy: 1)
        }
    }

    @MainActor
    private struct Layout {
        let viewport: CGRect
        let height: CGFloat
        let offset: CGFloat

        init(_ scroll: NSScrollView, in host: NSView) throws {
            viewport = scroll.convert(scroll.bounds, to: host)
            height = try XCTUnwrap(scroll.documentView).frame.height
            offset = scroll.contentView.bounds.origin.y
        }
    }

    private func assertLayout(_ expected: Layout, scroll: NSScrollView, host: NSView,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try Layout(scroll, in: host)
        XCTAssertEqual(actual.viewport, expected.viewport, "Status must not move or resize the viewport", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, "Status must not insert height into the document", file: file, line: line)
        XCTAssertEqual(actual.offset, expected.offset, accuracy: 1, "The user's reading position must be preserved", file: file, line: line)
    }

    private func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 740),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func makeFixture(screenCaptureGranted: Bool = false) async throws -> Fixture {
        let suite = "dev.hdh.MenuTidy.tests.status.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hasCompletedSetup")
        for key in ["startupApplyPending", "periodicApplyPending", "shortcutEnabled", "autoCollapse"] {
            defaults.set(false, forKey: key)
        }
        let system = MenuTidyTestEnvironment()
        system.screenCaptureGranted = screenCaptureGranted
        for index in 0..<24 {
            let id = "item:status.\(index)"
            let bundle = "org.example.MenuTidyStatusFixture\(index)"
            let pid = Int32(22000 + index)
            system.snapshots.append(MenuBarItemSnapshot(id: id, processIdentifier: pid,
                name: "Fixture \(index)", ownerName: "Fixture \(index)", bundleIdentifier: bundle,
                frame: CGRect(x: index * 24, y: 0, width: 22, height: 22),
                hasReliableGeometry: true, canMove: true, detail: "",
                persistentIdentity: true, ownIdentifier: nil))
            system.identities[id] = .init(id: id, pid: pid, bundleIdentifier: bundle, launchTime: 100)
        }
        let model = MenuTidyModel(testing: system, defaults: defaults)
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        return Fixture(model: model, system: system, preferences: AppPreferences(defaults: defaults),
                       defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let model: MenuTidyModel
        let system: MenuTidyTestEnvironment
        let preferences: AppPreferences
        let defaults: UserDefaults
        let suite: String

        func dispose() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class ScanGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func resume() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ActivityFixture: ObservableObject {
        @Published var active = false
        var renderedActive = false
    }

    private struct ActivityHarness: View {
        @ObservedObject var state: ActivityFixture
        var body: some View {
            DeferredActivity(isActive: state.active) { visible in
                ActivityProbe(state: state, visible: visible)
            }
        }
    }

    private struct ActivityProbe: NSViewRepresentable {
        let state: ActivityFixture
        let visible: Bool
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { state.renderedActive = visible }
    }

    private final class UpdateStatusFixture: ObservableObject {
        @Published var status = "当前没有可安装的新版本"
        @Published var issue: String?
        @Published var busy = false
        @Published var checking = false
    }

    private struct UpdateStatusHarness: View {
        @ObservedObject var state: UpdateStatusFixture
        var body: some View {
            UpdateStatusRow(status: state.status, lastCheck: "最近检查：2026年11月16日 16:38",
                            issue: state.issue, operationInProgress: state.busy,
                            sessionInProgress: state.checking, canCheckForUpdates: !state.busy,
                            checkForUpdates: {})
        }
    }
}
