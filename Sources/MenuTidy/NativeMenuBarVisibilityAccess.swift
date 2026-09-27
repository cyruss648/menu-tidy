import AppKit

/// Persists only a user-selected Control Center preference-file grant.
@MainActor
final class NativeMenuBarVisibilityAccess {
    private let bookmarkKey = "nativeMenuBarVisibilityFileBookmark.v1"
    private let defaults: UserDefaults
    private var scopedURL: URL?
    private var panel: NSOpenPanel?
    private(set) var hasSelection = false

    var preferenceFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSelection()
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func requestAccess() async throws -> Bool {
        guard panel == nil else { return false }
        let panel = NSOpenPanel()
        self.panel = panel
        defer { self.panel = nil }
        panel.title = "允许管理菜单栏图标"
        panel.message = "请选择已定位的 group.com.apple.controlcenter.plist 文件。Menu Tidy 使用其中的应用显示开关，将图标收进独立托盘。"
        panel.prompt = "允许访问"
        panel.directoryURL = preferenceFile.deletingLastPathComponent()
        panel.nameFieldStringValue = preferenceFile.lastPathComponent
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let selected = panel.url else { return false }
        guard matches(selected) else { throw AccessFailure.wrongFile }
        let started = selected.startAccessingSecurityScopedResource()
        do {
            let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = started ? selected : nil
            hasSelection = true
            defaults.set(bookmark, forKey: bookmarkKey)
        } catch {
            if started { selected.stopAccessingSecurityScopedResource() }
            throw AccessFailure.cannotRemember
        }
        return true
    }

    private func matches(_ url: URL) -> Bool {
        url.standardizedFileURL == preferenceFile.standardizedFileURL &&
            url.resolvingSymlinksInPath() == preferenceFile.standardizedFileURL
    }

    private func restoreSelection() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let selected = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard matches(selected) else { return }
            let started = selected.startAccessingSecurityScopedResource()
            scopedURL = started ? selected : nil
            hasSelection = true
            if stale, let renewed = try? selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(renewed, forKey: bookmarkKey)
            }
        } catch {
            // Keep the old bookmark; an actual preference read determines
            // whether the selected file remains accessible.
        }
    }

    private enum AccessFailure: LocalizedError {
        case wrongFile, cannotRemember
        var errorDescription: String? {
            switch self {
            case .wrongFile: "请选择自动定位的 group.com.apple.controlcenter.plist 文件，其他文件不能提供菜单栏图标访问。"
            case .cannotRemember: "未能保存这次菜单栏文件授权，请重试。图标设置已保留。"
            }
        }
    }
}
