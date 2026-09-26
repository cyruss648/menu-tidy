import AppKit

/// Keeps the user's narrowly selected preferences directory accessible across
/// launches. Selection is performed by the system's open panel, never by
/// changing privacy databases or copying another process's privileges.
@MainActor
final class MenuBarPositionAccess {
    private let bookmarkKey = "menuBarPositionDirectoryBookmark.v1"
    private var scopedURL: URL?
    private var panel: NSOpenPanel?
    private let defaults: UserDefaults

    var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/com.apple.MenuBar/Library/Preferences", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSelection()
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func request() async throws -> Bool {
        guard panel == nil else { return false }
        let panel = NSOpenPanel()
        self.panel = panel
        defer { self.panel = nil }
        panel.title = "允许访问菜单栏排序记录"
        panel.message = "请选择已定位的 Preferences 文件夹。Menu Tidy 只使用其中的菜单栏排序记录来后台分组，不移动鼠标。"
        panel.prompt = "允许访问"
        panel.directoryURL = directory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
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
        guard selected.standardizedFileURL == directory.standardizedFileURL else {
            throw AccessError.wrongDirectory
        }
        let started = selected.startAccessingSecurityScopedResource()
        do {
            let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = started ? selected : nil
            defaults.set(bookmark, forKey: bookmarkKey)
        } catch {
            if started { selected.stopAccessingSecurityScopedResource() }
            throw AccessError.cannotRemember
        }
        return true
    }

    private func restoreSelection() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let selected = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard selected.standardizedFileURL == directory.standardizedFileURL else { return }
            let started = selected.startAccessingSecurityScopedResource()
            scopedURL = started ? selected : nil
            if stale, let renewed = try? selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(renewed, forKey: bookmarkKey)
            }
        } catch {
            // Preserve the old bookmark for recovery; availability is established
            // by the actual preferences read, not by bookmark resolution alone.
        }
    }

    private enum AccessError: LocalizedError {
        case wrongDirectory, cannotRemember
        var errorDescription: String? {
            switch self {
            case .wrongDirectory: "请选择自动定位的菜单栏 Preferences 文件夹，其他文件夹无法提供排序访问。"
            case .cannotRemember: "未能保存这次目录授权，请重试。分类草稿已保留。"
            }
        }
    }
}
