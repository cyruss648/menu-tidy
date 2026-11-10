import AppKit
import MenuTidyCore
import SwiftUI
import XCTest
@testable import MenuTidy

@MainActor
final class LocalizationIntegrationTests: XCTestCase {
    private func fixture() throws -> (MenuTidyModel, MenuTidyTestEnvironment, AppPreferences, () -> Void) {
        let suite = "dev.hdh.MenuTidy.tests.localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(false, forKey: "startupApplyPending")
        defaults.set(false, forKey: "periodicApplyPending")
        defaults.set(false, forKey: "shortcutEnabled")
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let preferences = AppPreferences(defaults: defaults, resourceBundle: try XCTUnwrap(Bundle(path: resources.path)))
        let system = MenuTidyTestEnvironment()
        system.snapshots = [MenuBarItemSnapshot(id: "session:sogou", processIdentifier: 501, name: "搜狗输入法",
            ownerName: "搜狗输入法", bundleIdentifier: "org.example.Sogou", frame: CGRect(x: 20, y: 0, width: 22, height: 22),
            hasReliableGeometry: true, canMove: true, detail: "", persistentIdentity: false, ownIdentifier: nil)]
        let model = MenuTidyModel(testing: system, defaults: defaults)
        return (model, system, preferences, { model.stop(); defaults.removePersistentDomain(forName: suite) })
    }

    func testScreenshotMessagesFollowLanguageWithoutRefreshingOrReplacingModel() async throws {
        let (model, _, preferences, dispose) = try fixture()
        defer { dispose() }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        let result = try XCTUnwrap(model.managementMessage)
        model.updateIconImageWarning(summary: ImageAvailabilitySummary(
            requested: Set((0..<21).map(String.init)), available: Set((0..<18).map(String.init))),
            unobservedConfiguredCount: 2)
        let warning = try XCTUnwrap(model.iconImageWarning)
        let details = try XCTUnwrap(model.iconImageWarningDetails)

        XCTAssertTrue(preferences.localized(result).contains("列表已更新，共 1 个项目"))
        preferences.language = .english
        XCTAssertEqual(preferences.localized(result), "List refreshed: 1 items. Existing groups and pending choices are preserved.")
        XCTAssertEqual(preferences.localized(warning), "Some icon images are not available yet (3/21)")
        XCTAssertFalse(preferences.localized(details).contains("图标"))
        XCTAssertTrue(preferences.localized(details).contains("21"))
        XCTAssertTrue(preferences.localized(details).contains("18"))
        XCTAssertEqual(model.managementItems.first?.name, "搜狗输入法")
        XCTAssertEqual(model.managementMessage, result)
        XCTAssertEqual(model.iconImageWarning, warning)

        preferences.language = .chinese
        XCTAssertTrue(preferences.localized(warning).contains("部分图标图像尚未获取"))
        XCTAssertTrue(preferences.localized(result).contains("现有分组与待应用选择已保留"))
    }

    func testNestedScanErrorsFollowLanguageAndPreserveTheExistingList() async throws {
        let (model, system, preferences, dispose) = try fixture()
        defer { dispose() }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        system.beforeScan = { throw MenuBarAccessError.scanTimedOut(scannedOwners: 3, totalOwners: 27, elapsed: 2.5) }
        model.refreshMenuItems()
        await model.waitForTestingOperations()
        let error = try XCTUnwrap(model.managementError)
        preferences.language = .english
        let english = preferences.localized(error)
        XCTAssertTrue(english.contains("3/27"))
        XCTAssertTrue(english.contains("2.5"))
        XCTAssertTrue(preferences.localized(try XCTUnwrap(model.managementMessage)).contains("previous scan"))
        XCTAssertFalse(english.contains("菜单栏"))
        XCTAssertEqual(model.managementItems.first?.name, "搜狗输入法")
        preferences.language = .chinese
        XCTAssertTrue(preferences.localized(error).contains("菜单栏读取未及时完成"))
    }

    func testLegacyFormatArrayAndNestedModelErrorAreRenderedSafely() throws {
        let (_, _, preferences, dispose) = try fixture()
        defer { dispose() }
        preferences.language = .english
        XCTAssertEqual(preferences.localizedFormat("需要处理 · %lld", arguments: [Int64(27)]), "Needs Attention · 27")
        let message = LocalizedMessage("权限变化后恢复隐藏位置未完成：\(MenuBarAccessError.permission.localizedMessage)")
        XCTAssertEqual(preferences.localized(message),
                       "Hidden positions could not be fully restored after the permission change: Accessibility access is required. Grant Menu Tidy access on the permissions page and retry.")
    }

    func testThemeAndLanguageKeepTheLiveScrollViewAndPresentationState() async throws {
        let (model, _, preferences, dispose) = try fixture()
        defer { dispose() }
        let state = SettingsViewState()
        state.page = .settings
        state.permissionHelpExpanded = true
        state.traySearchText = "搜狗"
        let updates = UpdateController(model: model, enabled: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(model: model, updates: updates, presentation: state, preferences: preferences))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        await settle()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 100)
        for theme in [AppPreferences.Theme.dark, .light, .system] {
            preferences.theme = theme
            await settle()
            XCTAssertTrue(window.contentView === host)
            XCTAssertTrue(descendants(host).contains { $0 === scroll })
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 1)
        }
        preferences.language = .english
        await settle()
        XCTAssertTrue(descendants(host).contains { $0 === scroll })
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100)
        XCTAssertEqual(state.page, .settings)
        XCTAssertEqual(state.traySearchText, "搜狗")
        XCTAssertTrue(state.permissionHelpExpanded)
    }

    func testReturningToSystemUsesCurrentAppearance() throws {
        let (_, _, preferences, dispose) = try fixture()
        defer { dispose() }
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        preferences.refreshSystemAppearance()
        preferences.theme = .light
        XCTAssertEqual(preferences.resolvedColorScheme, .light)
        preferences.theme = .system
        XCTAssertEqual(preferences.resolvedColorScheme, .dark)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        preferences.refreshSystemAppearance()
        XCTAssertEqual(preferences.resolvedColorScheme, .light)
    }

    func testBundledHistoryUsesTheExplicitLanguageAndCoversTheSameVersions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Match the packaged bundle layout, including the root Chinese file.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("CHANGELOG.md"),
                                        to: directory.appendingPathComponent("CHANGELOG.md"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/en.lproj/CHANGELOG.md"),
                                        to: directory.appendingPathComponent("en.lproj/CHANGELOG.md"))
        let bundle = try XCTUnwrap(Bundle(path: directory.path))
        let chinese = HistoryEntry.bundled(language: .chinese, resourceBundle: bundle)
        let english = HistoryEntry.bundled(language: .english, resourceBundle: bundle)
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertEqual(chinese.map(\.title), english.map(\.title).map {
            $0.replacingOccurrences(of: "Unreleased diagnostic version", with: "未发布诊断版本")
        })
        // Verify a known translation without assuming it is still the newest
        // entry when a later release adds its own history.
        let chineseLocalization = try XCTUnwrap(chinese.first { $0.title.hasPrefix("0.7.6 ") })
        let englishLocalization = try XCTUnwrap(english.first { $0.title == chineseLocalization.title })
        XCTAssertTrue(chineseLocalization.lines.joined().contains("动态状态"))
        XCTAssertTrue(englishLocalization.lines.joined().contains("Localized dynamic status"))
    }

    func testOpenTrayUpdatesItsLanguageAndAppearanceWithoutReplacingContent() async throws {
        let (model, _, _, dispose) = try fixture()
        defer { dispose() }
        let preferences = AppPreferences.shared
        let oldTheme = preferences.theme
        let oldLanguage = preferences.language
        defer { preferences.theme = oldTheme; preferences.language = oldLanguage }
        preferences.theme = .light
        preferences.language = .chinese
        let controller = HiddenItemsPanelController()
        controller.show(model: model, anchor: nil)
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Menu Tidy · 托盘" })
        let content = try XCTUnwrap(panel.contentView)
        preferences.theme = .dark
        preferences.language = .english
        await settle()
        // XCTest runs outside the app bundle. Test the exact preference lookup
        // rather than expecting production resources in the XCTest executable.
        XCTAssertEqual(panel.title, preferences.localized("Menu Tidy · 托盘"))
        XCTAssertTrue(panel.contentView === content)
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        preferences.theme = .system
        await settle()
        XCTAssertTrue(panel.contentView === content)
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                       NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle() async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(20))
            await Task.yield()
        }
    }
}
