import AppKit
import MenuTidyCore
import OSLog
import SwiftUI

@main
@MainActor
enum MenuTidyApp {
    static func main() {
        // Validate the entire command line before any application or probe UI.
        switch MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) {
        case .rejected:
            print("Menu Tidy: rejected incompatible or unknown arguments; no application UI or input started.")
            return
        case .disabledCommand:
            print("Menu Tidy: disabled-known-global-modifier-side-effect; no application UI or input started.")
            return
        case .ownerObserver(let bundleIdentifier):
            runMenuBarVisibilityObserver(bundleIdentifier: bundleIdentifier)
            return
        case .statusItems:
            runTargetedStatusItemProbe()
            return
        case .targetedEvents:
            runTargetedEventProbe()
            return
        case .legacyNoCursor, .privateRecord:
            runLegacyNoCursorEventProbe()
            return
        case .normal:
            break
        }
        // A UI fixture can run only from its separately identified app bundle.
        // Production launches cannot accidentally opt into mocked permissions.
        if CommandLine.arguments.contains("--preview-ui") != (Bundle.main.bundleIdentifier == "dev.hdh.MenuTidy.preview") {
            print("Menu Tidy: UI preview requires the isolated preview bundle.")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let lifecycleLogger = Logger(subsystem: "dev.hdh.MenuTidy", category: "Lifecycle")
    private var model: MenuTidyModel!
    private(set) var updates: UpdateController?
    private var settingsWindow: NSWindow?
    // A minimized or hidden window is still open and must keep its Dock entry.
    private var settingsWindowIsOpen = false
    private let settingsPresentation = SettingsViewState()
    private var settingsReleaseTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLifecycle("didFinishLaunching")
        // Reopening an existing instance shows its management window.
        if !CommandLine.arguments.contains("--demo-items"),
           let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            logLifecycle("activateExistingInstance")
            NSApp.terminate(nil)
            return
        }
        model = MenuTidyModel()
        updates = UpdateController(model: model, enabled: !CommandLine.arguments.contains("--demo-items") && !model.isUIPreview)
        configureMainMenu()
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onMemoryPressure = { [weak self] in self?.releaseClosedSettingsContent() }
        model.start()
        if !model.hasCompletedSetup || !model.accessibilityGranted || CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--demo-items") || model.isUIPreview {
            showSettings()
        }
    }

    func showSettings(refreshItems: Bool = true) {
        guard model != nil, let updates else { return }
        settingsReleaseTask?.cancel()
        settingsReleaseTask = nil
        logLifecycle("showSettingsRequested")
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 820, height: 660)
            window.title = model.isUIPreview ? "Menu Tidy · 独立交互预览（模拟数据）" : "Menu Tidy · 菜单栏整理"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, updates: updates, presentation: settingsPresentation))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MenuTidySettingsV2")
            settingsWindow = window
        }
        settingsWindowIsOpen = true
        model.settingsVisible = true
        if NSApp.activationPolicy() != .regular {
            let accepted = NSApp.setActivationPolicy(.regular)
            lifecycleLogger.info("action=setRegularPolicy accepted=\(accepted, privacy: .public)")
        }
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.refreshPermissions()
        if refreshItems && model.accessibilityGranted { model.refreshMenuItems() }
        logLifecycle("showSettingsCompleted")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindowIsOpen = false
        model.settingsVisible = false
        let accepted = NSApp.setActivationPolicy(.accessory)
        lifecycleLogger.info("action=setAccessoryPolicy accepted=\(accepted, privacy: .public)")
        logLifecycle("windowWillClose")
        settingsReleaseTask?.cancel()
        settingsReleaseTask = Task { [weak self, weak window] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, let window, self.settingsWindow === window else { return }
            self.releaseClosedSettingsContent()
        }
    }

    private func releaseClosedSettingsContent() {
        guard !settingsWindowIsOpen, let window = settingsWindow,
              !window.isVisible, !window.isMiniaturized else { return }
        settingsReleaseTask?.cancel()
        settingsReleaseTask = nil
        window.contentView = nil
        window.delegate = nil
        settingsWindow = nil
        logLifecycle("releasedClosedSettingsContent")
    }
    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        logLifecycle("windowDidMiniaturize")
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        logLifecycle("windowDidDeminiaturize")
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        logLifecycle("applicationDidBecomeActive")
        model?.refreshLoginStatus()
        model?.refreshPermissions()
    }
    func applicationDidResignActive(_ notification: Notification) { logLifecycle("applicationDidResignActive") }
    func applicationDidHide(_ notification: Notification) { logLifecycle("applicationDidHide") }
    func applicationDidUnhide(_ notification: Notification) { logLifecycle("applicationDidUnhide") }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A nonactivating icon panel is not counted as a visible document by
        // LaunchServices. Accessibility activation can therefore send reopen
        // immediately before an icon action. Preserve that interaction instead
        // of showing settings beneath the target menu. Explicit Settings menu
        // actions still call showSettings directly; an existing settings window
        // keeps its normal Dock reopen behavior.
        if !settingsWindowIsOpen, let model, model.isPanelPresented || model.isPanelItemOperationRunning {
            lifecycleLogger.info("action=handleReopen preservedPanelInteraction=true")
            return false
        }
        // Opening settings is not a visibility recovery command. Preserve the
        // current physical groups whether this window was closed or still open.
        let wasOpen = settingsWindowIsOpen
        lifecycleLogger.info("action=handleReopen windowWasOpen=\(wasOpen, privacy: .public) hasVisibleWindows=\(flag, privacy: .public)")
        showSettings(refreshItems: !wasOpen)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logLifecycle("applicationShouldTerminate")
        if model?.requiresTerminationCleanup == true {
            if terminationTask == nil {
                terminationTask = Task { [weak self] in
                    guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
                    let canTerminate = await self.model.prepareForTermination()
                    self.terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: canTerminate)
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        logLifecycle("applicationWillTerminate")
        settingsReleaseTask?.cancel()
        settingsReleaseTask = nil
        model?.stop()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Menu Tidy")
        let settingsItem = NSMenuItem(title: "管理窗口…", action: #selector(showManagementWindow(_:)), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        applicationMenu.addItem(updateItem)
        applicationMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 Menu Tidy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Menu Tidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showManagementWindow(_ sender: Any?) {
        showSettings(refreshItems: !settingsWindowIsOpen)
    }

    @objc func checkForUpdates(_ sender: Any?) { updates?.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return updates?.canCheckForUpdates == true }
        return true
    }

    private func logLifecycle(_ action: String) {
        // Only our lifecycle event and state flags are logged, never window or item content.
        lifecycleLogger.info("action=\(action, privacy: .public) regular=\(NSApp.activationPolicy() == .regular, privacy: .public) accessory=\(NSApp.activationPolicy() == .accessory, privacy: .public) windowOpen=\(self.settingsWindowIsOpen, privacy: .public) windowVisible=\(self.settingsWindow?.isVisible == true, privacy: .public) miniaturized=\(self.settingsWindow?.isMiniaturized == true, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) appHidden=\(NSApp.isHidden, privacy: .public)")
    }
}
