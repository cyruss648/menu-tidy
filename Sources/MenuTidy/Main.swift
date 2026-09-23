import AppKit
import SwiftUI

@main
@MainActor
enum MenuTidyApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: MenuTidyModel!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reopening the app is also the recovery path if the control was moved.
        if !CommandLine.arguments.contains("--demo-items"),
           let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        model = MenuTidyModel()
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.start()
        if !model.hasCompletedSetup || !model.accessibilityGranted || CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--demo-items") {
            showSettings()
        }
    }

    func showSettings() {
        guard model != nil else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 820, height: 660)
            window.title = "Menu Tidy · 菜单栏整理"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MenuTidySettingsV2")
            settingsWindow = window
        }
        model.settingsVisible = true
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.refreshPermissions()
        if model.accessibilityGranted { model.refreshMenuItems() }
    }

    func windowWillClose(_ notification: Notification) { model.settingsVisible = false }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshLoginStatus(); model?.refreshPermissions() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.recoverVisibility()
        showSettings()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isApplying == true { model?.quit(); return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}
