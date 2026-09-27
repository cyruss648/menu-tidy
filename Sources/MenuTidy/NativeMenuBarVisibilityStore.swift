import Darwin
import Foundation
import MenuTidyCore

/// Serial ownership of exact third-party visibility records. This store does
/// not use assessment mode, change positions, or prove that pixels disappeared.
@MainActor
final class NativeMenuBarVisibilityStore {
    private typealias Codec = NativeMenuBarVisibilityCodec
    private typealias Ledger = NativeMenuBarVisibilityLedger
    private let access: NativeMenuBarVisibilityAccess
    private let journal = NativeVisibilityJournalFile()
    private var entries: [String: Ledger.Entry] = [:]
    // Retain this knowledge if journal cancellation itself hits a transient I/O
    // failure, so same-process reload cannot adopt another writer's value.
    private var knownUnwritten: [String: Ledger.Entry] = [:]
    private var initialJournalWasUnreadable = false
    private(set) var pendingRecoveryIssue: String?

    var managedBundles: Set<String> { Set(entries.keys) }
    var revealedBundles: Set<String> { Set(entries.values.filter(\.isTemporarilyRevealed).map(\.bundleIdentifier)) }
    // Capability and schema support are separate: a readable future schema
    // must not send an already-authorized user back through the file picker.
    var accessAvailable: Bool { access.hasSelection && (try? readPreferenceValue()) != nil }
    func isTemporarilyRevealed(bundle: String) -> Bool { entries[bundle]?.isTemporarilyRevealed == true }

    private var domain: CFString { access.preferenceFile.deletingPathExtension().path as CFString }
    private let preferenceKey = "trackedApplications" as CFString

    init(access: NativeMenuBarVisibilityAccess = NativeMenuBarVisibilityAccess()) {
        self.access = access
        do {
            let data = try journal.load()
            let loaded = try data.map(Ledger.decode) ?? []
            entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.bundleIdentifier, $0) })
        } catch {
            initialJournalWasUnreadable = true
            pendingRecoveryIssue = "菜单栏显示记录无法安全读取。已停止新的隐藏操作，请保留 Transactions/NativeVisibility.plist 以便恢复。"
        }
    }

    func requestAccess() async throws -> Bool {
        guard try await access.requestAccess() else { return false }
        _ = try readPreferenceValue()
        return true
    }

    /// Explicit local recovery after a transient journal error. This never
    /// writes preferences and does not bypass malformed/conflicting receipts.
    /// The caller can then reconcile pending writes and restore owned items.
    func reloadForRecovery() throws {
        do {
            let data = try journal.load()
            guard data != nil || !initialJournalWasUnreadable else {
                throw failure("原来的菜单栏恢复记录无法读取且现在已缺失，不能猜测原始显示设置。请保留或恢复原来的恢复文件。")
            }
            var persisted = try data.map(Ledger.decode) ?? []
            var remembered = Array(entries.values)
            for attempted in knownUnwritten.values {
                persisted = try Ledger.discardingKnownUnwritten(attempted, from: persisted)
                remembered = try Ledger.discardingKnownUnwritten(attempted, from: remembered)
            }
            let recovered = try Ledger.mergeForRecovery(persisted: persisted, remembered: remembered)
            let recoveredData = try recovered.isEmpty ? nil : Ledger.encode(recovered)
            // If a previously failed removal already reached disk, keeping
            // the in-memory receipt once more is safe: reconciliation observes
            // the restored original and subsequently removes it durably.
            try journal.save(recoveredData)
            entries = Dictionary(uniqueKeysWithValues: recovered.map { ($0.bundleIdentifier, $0) })
            knownUnwritten.removeAll()
            initialJournalWasUnreadable = false
            pendingRecoveryIssue = nil
        } catch {
            pendingRecoveryIssue = "菜单栏恢复记录仍无法安全重新载入；已保留当前记录且未改变系统设置。请检查 Transactions/NativeVisibility.plist 后重试。"
            throw failure(pendingRecoveryIssue!)
        }
    }

    func readAllowed(bundle: String) throws -> Bool {
        try Codec.decode(readData()).isAllowed(bundleIdentifier: bundle)
    }

    /// true means we own this item's visibility. false means it was already
    /// disabled externally and must not be temporarily enabled by the tray.
    @discardableResult
    func hide(bundle: String) throws -> Bool {
        try requireReady()
        try reconcile(bundle: bundle)
        let snapshot = try Codec.decode(readData())
        if let entry = entries[bundle] {
            guard try snapshot.matches(record: entry.expectedRecord(), bundleIdentifier: bundle) else { throw conflict() }
            // A live menu owns the temporary reveal until the caller releases
            // it. Background refresh must not close that menu by re-hiding.
            return true
        }
        guard try snapshot.isAllowed(bundleIdentifier: bundle) else { return false }
        let original = try snapshot.record(bundleIdentifier: bundle)
        let entry = Ledger.Entry(bundleIdentifier: bundle, originalRecord: original, mode: .original, pending: .hide)
        try perform(entry)
        return true
    }

    func temporarilyReveal(bundle: String) throws {
        try requireReady()
        try reconcile(bundle: bundle)
        guard let entry = entries[bundle] else {
            throw failure("此应用的隐藏开关不由 Menu Tidy 管理，未改变系统显示设置。")
        }
        if entry.mode == .revealed { try assertCurrent(entry); return }
        guard entry.mode == .hidden else { throw conflict() }
        try perform(entry.preparing(.reveal))
    }

    func rehide(bundle: String) throws {
        try requireReady()
        try reconcile(bundle: bundle)
        guard let entry = entries[bundle] else { return }
        if entry.mode == .hidden { try assertCurrent(entry); return }
        guard entry.mode == .revealed else { throw conflict() }
        try perform(entry.preparing(.rehide))
    }

    func restore(bundle: String) throws {
        try requireReady()
        try reconcile(bundle: bundle)
        guard let entry = entries[bundle] else { return }
        let current = try Codec.decode(readData())
        if try current.matches(record: entry.originalRecord, bundleIdentifier: bundle) {
            var next = entries; next.removeValue(forKey: bundle)
            try save(next)
            return
        }
        guard entry.mode == .hidden else { throw conflict() }
        try perform(entry.preparing(.restore))
    }

    /// Attempts every owned item; failures stay journalled for another run.
    @discardableResult
    func restoreAll() -> Set<String> {
        var failed: Set<String> = []
        for bundle in managedBundles.sorted() {
            do { try restore(bundle: bundle) }
            catch { failed.insert(bundle) }
        }
        return failed
    }

    /// Read-only reconciliation of interrupted writes, followed only by local
    /// journal updates. External target changes are per-item conflicts.
    @discardableResult
    func recoverPendingWrites() throws -> Set<String> {
        try requireReady()
        var conflicts: Set<String> = []
        for bundle in managedBundles.sorted() {
            do { try reconcile(bundle: bundle) }
            catch {
                if pendingRecoveryIssue != nil { throw error }
                conflicts.insert(bundle)
            }
        }
        return conflicts
    }

    /// End ownership only when a fresh complete target record proves that an
    /// external change superseded ours. Never changes system preferences.
    func forgetExternallyChanged(bundle: String) throws {
        try requireReady()
        guard let entry = entries[bundle] else { return }
        let current = try Codec.decode(readData())
        guard try Ledger.recovery(for: entry, current: current) == .conflicted else {
            throw failure("此应用的显示记录仍由 Menu Tidy 管理，请使用恢复显示结束管理。")
        }
        var next = entries; next.removeValue(forKey: bundle)
        try save(next)
    }

    private func requireReady() throws {
        if let issue = pendingRecoveryIssue { throw failure(issue) }
        guard access.hasSelection else { throw failure("请先允许访问菜单栏显示记录，再连接托盘图标。") }
    }

    private func assertCurrent(_ entry: Ledger.Entry) throws {
        guard try Codec.decode(readData()).matches(record: entry.expectedRecord(), bundleIdentifier: entry.bundleIdentifier) else {
            throw conflict()
        }
    }

    private func reconcile(bundle: String) throws {
        guard let entry = entries[bundle], entry.pending != nil else { return }
        let recovery = try Ledger.recovery(for: entry, current: Codec.decode(readData()))
        switch recovery {
        case .unchanged: return
        case .completed(let updated), .notApplied(let updated):
            var next = entries; next[bundle] = updated
            try save(next)
        case .conflicted: throw conflict()
        }
    }

    private func perform(_ entry: Ledger.Entry) throws {
        let expected = try entry.expectedRecord()
        let replacement = try entry.writtenRecord()
        guard try Codec.decode(readData()).matches(record: expected, bundleIdentifier: entry.bundleIdentifier) else { throw conflict() }
        var prepared = entries; prepared[entry.bundleIdentifier] = entry
        knownUnwritten[entry.bundleIdentifier] = entry
        try save(prepared) // durable write-ahead intent before changing preferences

        // Re-read after journal I/O and merge only the target into the latest
        // table. A final byte check catches intervening edits; CFPreferences
        // provides no atomic compare-and-swap, so a later race stays possible.
        let written: Data
        do {
            let fresh = try readData()
            guard let merged = try Codec.decode(fresh).replacingRecord(bundleIdentifier: entry.bundleIdentifier,
                    expected: expected, replacement: replacement), try readData() == fresh else { throw conflict() }
            written = merged
        } catch {
            knownUnwritten[entry.bundleIdentifier] = entry
            let cancelled = try Ledger.discardingKnownUnwritten(entry, from: Array(entries.values))
            try save(Dictionary(uniqueKeysWithValues: cancelled.map { ($0.bundleIdentifier, $0) }))
            knownUnwritten.removeValue(forKey: entry.bundleIdentifier)
            throw error
        }
        knownUnwritten.removeValue(forKey: entry.bundleIdentifier)
        CFPreferencesSetValue(preferenceKey, written as CFData, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw failure("菜单栏显示开关尚未确认，恢复记录已保留。")
        }
        let readback = try Codec.decode(readData())
        guard try readback.matches(record: replacement, bundleIdentifier: entry.bundleIdentifier) else {
            throw failure("菜单栏显示结果尚未确认，恢复记录已保留；没有覆盖新的目标记录。")
        }
        var completed = entries; completed[entry.bundleIdentifier] = entry.completingPending()
        try save(completed)
    }

    private func readPreferenceValue() throws -> CFPropertyList {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let raw = CFPreferencesCopyValue(preferenceKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw failure("无法读取菜单栏显示记录，请重新允许访问指定文件。")
        }
        return raw
    }

    private func readData() throws -> Data {
        let raw = try readPreferenceValue()
        guard CFGetTypeID(raw) == CFDataGetTypeID(), let data = raw as? Data else { throw Codec.Failure.malformed }
        _ = try Codec.decode(data)
        return data
    }

    private func save(_ next: [String: Ledger.Entry]) throws {
        do {
            let data = try next.isEmpty ? nil : Ledger.encode(Array(next.values))
            try journal.save(data)
            entries = next
        } catch {
            pendingRecoveryIssue = "菜单栏恢复记录未能安全保存，已停止后续写入；请保留 Transactions/NativeVisibility.plist 并重新启动恢复。"
            throw failure(pendingRecoveryIssue!)
        }
    }

    private func conflict() -> StoreFailure {
        failure("此应用的显示设置已被其他操作修改，未覆盖新设置。请恢复或重新连接此图标。")
    }
    private func failure(_ message: String) -> StoreFailure { StoreFailure(message: message) }
    private struct StoreFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// A bounded, owner-only local journal with no symlink following. Failure
/// preserves the on-disk receipt and stops further preference mutations.
@MainActor
private final class NativeVisibilityJournalFile {
    private let name = "NativeVisibility.plist"
    private var contents: Data?
    private let maximumSize = NativeMenuBarVisibilityLedger.maximumDataSize

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
        let temporary = ".NativeVisibility-\(UUID().uuidString).tmp"
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

    private func ioFailure() -> NSError { NSError(domain: "MenuTidy.NativeVisibilityJournal", code: 1) }
}
