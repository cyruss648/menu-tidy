import AppKit
import Darwin
import MenuTidyCore

/// Owns only the verified AirDrop bits and the input-menu visibility Boolean.
/// It never toggles the whole Control Center host or rewrites a preference table.
@MainActor
final class NativeSystemMenuBarVisibilityStore {
    private typealias Ledger = NativeSystemMenuBarVisibilityLedger
    private let journal = NativeSystemVisibilityJournalFile()
    private let hostIdentifier: String?
    private let access: NativeSystemVisibilityAccess?
    private let inputAccess: NativeSystemVisibilityAccess?
    private var entries: [String: Ledger.Entry] = [:]
    private var knownUnwritten: [String: Ledger.Entry] = [:]
    private var initialJournalWasUnreadable = false
    private var needsWriteAccess: Set<String> = []
    private(set) var pendingRecoveryIssue: String?
    private let domain = "com.apple.controlcenter" as CFString

    var managedKeys: Set<String> { Set(entries.keys) }
    var revealedKeys: Set<String> { Set(entries.values.filter(\.isTemporarilyRevealed).map(\.key)) }

    init() {
        let host = Self.currentHostIdentifier()
        hostIdentifier = host
        access = host.map { NativeSystemVisibilityAccess(hostIdentifier: $0) }
        inputAccess = host.map { NativeSystemVisibilityAccess(hostIdentifier: $0, textInput: true) }
        do {
            guard host != nil else { throw failure("无法确认当前主机，未改变系统图标设置。") }
            let loaded = try journal.load().map(Ledger.decode) ?? []
            try validateHosts(loaded)
            entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.key, $0) })
        } catch {
            initialJournalWasUnreadable = true
            pendingRecoveryIssue = "系统图标恢复记录无法安全读取。已停止新的隐藏操作，请保留 Transactions/NativeSystemVisibility.plist 以便恢复。"
        }
    }

    func accessAvailable(key: String) -> Bool { !needsWriteAccess.contains(key) && (try? readValue(key: key)) != nil }
    func isTemporarilyRevealed(key: String) -> Bool { entries[key]?.isTemporarilyRevealed == true }

    /// Ordinary preferences may already be accessible. Ask for one precise file
    /// only when the actual CFPreferences read fails; selection is not required.
    func requestAccess(key: String) async throws -> Bool {
        try validateKey(key)
        if accessAvailable(key: key) { return true }
        guard let access = key == "TextInputMenu" ? inputAccess : access else { throw failure("无法定位系统图标偏好文件。") }
        guard try await access.requestAccess() else { return false }
        _ = try readValue(key: key)
        needsWriteAccess.remove(key)
        return true
    }

    func reloadForRecovery() throws {
        do {
            let data = try journal.load()
            guard data != nil || !initialJournalWasUnreadable else {
                throw failure("原来的系统图标恢复记录无法读取且现在已缺失，不能猜测原始设置。")
            }
            let persisted = try Ledger.discardingKnownUnwritten(entries: data.map(Ledger.decode) ?? [],
                                                               known: Array(knownUnwritten.values))
            try validateHosts(persisted)
            let remembered = try Ledger.discardingKnownUnwritten(entries: Array(entries.values),
                                                                known: Array(knownUnwritten.values))
            let recovered = try Ledger.mergeForRecovery(persisted: persisted, remembered: remembered)
            try validateHosts(recovered)
            try journal.save(recovered.isEmpty ? nil : Ledger.encode(recovered))
            entries = Dictionary(uniqueKeysWithValues: recovered.map { ($0.key, $0) })
            knownUnwritten.removeAll()
            initialJournalWasUnreadable = false
            pendingRecoveryIssue = nil
        } catch {
            pendingRecoveryIssue = "系统图标恢复记录仍无法安全重新载入；未改变系统设置，请保留 Transactions/NativeSystemVisibility.plist 后重试。"
            throw failure(pendingRecoveryIssue!)
        }
    }

    func readAllowed(key: String) throws -> Bool { try Ledger.isAllowed(readValue(key: key)) }

    /// Pre-existing hidden items are never adopted or temporarily enabled.
    @discardableResult
    func hide(key: String) throws -> Bool {
        try requireReady(key)
        try reconcile(key: key)
        let current = try readValue(key: key)
        if let entry = entries[key] {
            guard current & 0xA == entry.expectedMask() else { throw conflict() }
            return true // An open native menu retains its temporary reveal.
        }
        guard try Ledger.isAllowed(current) else { return false }
        guard let hostIdentifier else { throw failure("无法确认当前主机。") }
        try perform(Ledger.Entry(key: key, hostIdentifier: hostIdentifier, originalValue: current,
                                 mode: .original, pending: .hide))
        return true
    }

    func temporarilyReveal(key: String) throws {
        try requireReady(key)
        try reconcile(key: key)
        guard let entry = entries[key] else { throw failure("此系统图标不由 Menu Tidy 管理，未改变显示设置。") }
        if entry.mode == .revealed { try assertCurrent(entry); return }
        guard entry.mode == .hidden else { throw conflict() }
        try perform(entry.preparing(.reveal))
    }

    func rehide(key: String) throws {
        try requireReady(key)
        try reconcile(key: key)
        guard let entry = entries[key] else { return }
        if entry.mode == .hidden { try assertCurrent(entry); return }
        guard entry.mode == .revealed else { throw conflict() }
        try perform(entry.preparing(.rehide))
    }

    func restore(key: String) throws {
        try requireReady(key)
        try reconcile(key: key)
        guard let entry = entries[key] else { return }
        let current = try readValue(key: key)
        if current & 0xA == entry.originalValue & 0xA {
            var next = entries; next.removeValue(forKey: key)
            try save(next)
            return
        }
        guard entry.mode == .hidden else { throw conflict() }
        try perform(entry.preparing(.restore))
    }

    @discardableResult
    func restoreAll() -> Set<String> {
        var failed: Set<String> = []
        for key in managedKeys.sorted() {
            do { try restore(key: key) } catch { failed.insert(key) }
        }
        return failed
    }

    @discardableResult
    func recoverPendingWrites() throws -> Set<String> {
        if let issue = pendingRecoveryIssue { throw failure(issue) }
        var conflicts: Set<String> = []
        for key in managedKeys.sorted() {
            do { try reconcile(key: key) }
            catch {
                if pendingRecoveryIssue != nil { throw error }
                conflicts.insert(key)
            }
        }
        return conflicts
    }

    private func requireReady(_ key: String) throws {
        try validateKey(key)
        if let issue = pendingRecoveryIssue { throw failure(issue) }
    }

    private func validateKey(_ key: String) throws {
        guard ["AirDrop", "TextInputMenu"].contains(key), hostIdentifier != nil else {
            throw failure("此系统图标尚无经过验证的独立显示开关，未改变设置。")
        }
    }

    private func validateHosts(_ loaded: [Ledger.Entry]) throws {
        guard let hostIdentifier,
              loaded.allSatisfy({ ["AirDrop", "TextInputMenu"].contains($0.key) && $0.hostIdentifier.uppercased() == hostIdentifier }) else {
            throw failure("系统图标恢复记录与当前主机不匹配，未修改设置。")
        }
    }

    private func assertCurrent(_ entry: Ledger.Entry) throws {
        guard try readValue(key: entry.key) & 0xA == entry.expectedMask() else { throw conflict() }
    }

    private func reconcile(key: String) throws {
        guard let entry = entries[key], entry.pending != nil else { return }
        switch try Ledger.recovery(for: entry, current: readValue(key: key)) {
        case .unchanged: return
        case .completed(let updated), .notApplied(let updated):
            var next = entries; next[key] = updated
            try save(next)
        case .conflicted: throw conflict()
        }
    }

    private func perform(_ entry: Ledger.Entry) throws {
        let expectedMask = entry.expectedMask()
        let replacementMask = entry.writtenMask()
        guard try readValue(key: entry.key) & 0xA == expectedMask else { throw conflict() }
        var prepared = entries; prepared[entry.key] = entry
        // Even a failed journal save may have completed its atomic rename.
        // Until the CF write is issued, remember that this intent was not applied.
        knownUnwritten[entry.key] = entry
        try save(prepared) // Durable intent before any CFPreferences mutation.

        let fresh: Int64
        let replacement: Int64
        do {
            fresh = try readValue(key: entry.key)
            guard fresh & 0xA == expectedMask else { throw conflict() }
            replacement = try Ledger.replacingMask(in: fresh, with: replacementMask)
            guard try readValue(key: entry.key) == fresh else { throw conflict() }
        } catch {
            // We know this process never issued the write. Do not later mistake
            // another writer's hidden value for our completed transaction.
            knownUnwritten[entry.key] = entry
            var cancelled = entries; cancelled[entry.key] = entry.discardingUnappliedPending()
            try save(cancelled)
            knownUnwritten.removeValue(forKey: entry.key)
            throw error
        }
        knownUnwritten.removeValue(forKey: entry.key)
        let input = entry.key == "TextInputMenu"
        let targetDomain = input ? inputDomain : domain
        let targetHost = input ? kCFPreferencesAnyHost : kCFPreferencesCurrentHost
        let value = input ? NSNumber(value: replacement == Ledger.shownMask) : NSNumber(value: replacement)
        CFPreferencesSetValue(input ? "visible" as CFString : entry.key as CFString, value, targetDomain,
                              kCFPreferencesCurrentUser, targetHost)
        guard CFPreferencesSynchronize(targetDomain, kCFPreferencesCurrentUser, targetHost) else {
            needsWriteAccess.insert(entry.key)
            throw failure("系统图标显示开关尚未确认，恢复记录已保留。")
        }
        let readback: Int64
        do { readback = try readValue(key: entry.key) }
        catch { needsWriteAccess.insert(entry.key); throw error }
        guard readback & 0xA == replacementMask else {
            needsWriteAccess.insert(entry.key)
            throw failure("系统图标显示结果尚未确认，恢复记录已保留；未覆盖新的设置。")
        }
        var completed = entries; completed[entry.key] = entry.completingPending()
        try save(completed)
    }

    private var inputDomain: CFString {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Preferences/com.apple.TextInputMenu").path as CFString
    }

    private func readValue(key: String) throws -> Int64 {
        try validateKey(key)
        if key == "TextInputMenu" {
            guard CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                  let raw = CFPreferencesCopyValue("visible" as CFString, inputDomain,
                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                  CFGetTypeID(raw) == CFBooleanGetTypeID(), let value = raw as? Bool else {
                throw failure("无法确认输入菜单显示开关，请允许访问 TextInputMenu 的精确偏好文件。")
            }
            return value ? Ledger.shownMask : Ledger.hiddenMask
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
              let raw = CFPreferencesCopyValue(key as CFString, domain,
                                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else {
            throw failure("无法读取 AirDrop 显示开关，请允许访问已定位的当前主机偏好文件。")
        }
        do { return try Ledger.integerValue(raw) }
        catch { throw failure("AirDrop 显示开关不是已验证的整数类型，未修改系统设置。") }
    }

    private func save(_ next: [String: Ledger.Entry]) throws {
        do {
            try journal.save(next.isEmpty ? nil : Ledger.encode(Array(next.values)))
            entries = next
        } catch {
            pendingRecoveryIssue = "系统图标恢复记录未能安全保存，已停止后续写入；请保留 Transactions/NativeSystemVisibility.plist 后重试恢复。"
            throw failure(pendingRecoveryIssue!)
        }
    }

    private static func currentHostIdentifier() -> String? {
        var value = UUID().uuid
        var timeout = timespec(tv_sec: 2, tv_nsec: 0)
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) { gethostuuid($0, &timeout) }
        }
        return result == 0 ? UUID(uuid: value).uuidString : nil
    }

    private func conflict() -> StoreFailure {
        failure("系统图标的显示设置已被其他操作修改，未覆盖新设置；恢复记录已保留。")
    }
    private func failure(_ message: String) -> StoreFailure { StoreFailure(message: message) }
    private struct StoreFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Optional access to the one current-host file. Direct reads remain valid
/// without a stored bookmark when the ordinary preferences are accessible.
@MainActor
private final class NativeSystemVisibilityAccess {
    private let preferenceFile: URL
    private let bookmarkKey: String
    private var scopedURL: URL?
    private var panel: NSOpenPanel?

    private let textInput: Bool

    init(hostIdentifier: String, textInput: Bool = false) {
        self.textInput = textInput
        preferenceFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            textInput ? "Library/Preferences/com.apple.TextInputMenu.plist" :
                "Library/Preferences/ByHost/com.apple.controlcenter.\(hostIdentifier).plist")
        bookmarkKey = textInput ? "nativeTextInputVisibilityBookmark.v1" : "nativeSystemVisibilityFileBookmark.v1.\(hostIdentifier)"
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale), matches(url) {
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(renewed, forKey: bookmarkKey)
                }
            }
        }
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    func requestAccess() async throws -> Bool {
        guard panel == nil else { return false }
        let picker = NSOpenPanel()
        panel = picker
        defer { panel = nil }
        picker.title = textInput ? "允许管理输入法切换图标" : "允许管理 AirDrop 菜单栏图标"
        picker.message = textInput ? "请选择已定位的 com.apple.TextInputMenu.plist；仅使用 visible 显示开关，不修改输入法和快捷键。" : "请选择已定位的当前主机 com.apple.controlcenter 偏好文件。Menu Tidy 只使用其中 AirDrop 的菜单栏显示开关。"
        picker.prompt = "允许访问"
        picker.directoryURL = preferenceFile.deletingLastPathComponent()
        picker.nameFieldStringValue = preferenceFile.lastPathComponent
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                picker.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else { picker.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, let selected = picker.url else { return false }
        guard matches(selected) else { throw NSError(domain: "MenuTidy.SystemVisibilityAccess", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "请选择自动定位的当前主机偏好文件，未读取或修改所选的其他文件。"]) }
        let started = selected.startAccessingSecurityScopedResource()
        do {
            let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = started ? selected : nil
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            if started { selected.stopAccessingSecurityScopedResource() }
            throw error
        }
        return true
    }

    private func matches(_ url: URL) -> Bool {
        url.standardizedFileURL == preferenceFile.standardizedFileURL &&
            url.resolvingSymlinksInPath() == preferenceFile.standardizedFileURL
    }
}

/// A bounded, owner-only local journal with no symlink following. Failure
/// preserves the on-disk receipt and stops further preference mutations.
@MainActor
private final class NativeSystemVisibilityJournalFile {
    private let name = "NativeSystemVisibility.plist"
    private var contents: Data?
    private let maximumSize = NativeSystemMenuBarVisibilityLedger.maximumDataSize

    func load() throws -> Data? {
        let data = try read()
        contents = data
        return data
    }

    func save(_ data: Data?) throws {
        guard let directory = try directory(create: true), try read() == contents else { throw ioFailure() }
        let directoryFD = try openDirectory(directory)
        defer { close(directoryFD) }
        guard let data else {
            if contents != nil { guard unlinkat(directoryFD, name, 0) == 0 else { throw ioFailure() } }
            contents = nil
            guard fsync(directoryFD) == 0, try read() == nil else { throw ioFailure() }
            return
        }
        guard data.count <= maximumSize else { throw ioFailure() }
        let temporary = ".NativeSystemVisibility-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ioFailure() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(directoryFD, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw ioFailure() }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard try read() == contents, renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw ioFailure() }
        contents = data
        guard fsync(directoryFD) == 0, try read() == data else { throw ioFailure() }
    }

    private func read() throws -> Data? {
        guard let directory = try directory(create: false) else { return nil }
        let directoryFD = try openDirectory(directory)
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ioFailure()
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumSize,
              let data = try file.read(upToCount: maximumSize + 1), data.count == info.st_size else { throw ioFailure() }
        return data
    }

    private func directory(create: Bool) throws -> URL? {
        var directory = FileManager.default.homeDirectoryForCurrentUser
        for component in ["", "Library", "Application Support", "Menu Tidy", "Transactions"] {
            if !component.isEmpty { directory.appendPathComponent(component, isDirectory: true) }
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw ioFailure() }
                guard create else { return nil }
                guard mkdir(directory.path, 0o700) == 0, lstat(directory.path, &info) == 0 else { throw ioFailure() }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else { throw ioFailure() }
        }
        return directory
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioFailure() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else { close(descriptor); throw ioFailure() }
        return descriptor
    }

    private func ioFailure() -> NSError { NSError(domain: "MenuTidy.NativeSystemVisibilityJournal", code: 1) }
}
