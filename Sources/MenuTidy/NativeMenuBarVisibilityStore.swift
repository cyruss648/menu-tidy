import Darwin
import Foundation
import MenuTidyCore
import OSLog

/// Serial ownership of exact third-party visibility records. This store does
/// not use assessment mode, change positions, or prove that pixels disappeared.
@MainActor
final class NativeMenuBarVisibilityStore {
    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "NativeVisibility")
    private typealias Codec = NativeMenuBarVisibilityCodec
    private typealias Ledger = NativeMenuBarVisibilityLedger
    private let access: NativeMenuBarVisibilityAccess
    private let journal = NativeVisibilityJournalFile()
    private let testingIO: NativeVisibilityStoreTestIO?
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
    var accessAvailable: Bool { (testingIO != nil || access.hasSelection) && (try? readPreferenceValue()) != nil }
    func isTemporarilyRevealed(bundle: String) -> Bool { entries[bundle]?.isTemporarilyRevealed == true }

    private var domain: CFString { access.preferenceFile.deletingPathExtension().path as CFString }
    private let preferenceKey = "trackedApplications" as CFString

    convenience init(access: NativeMenuBarVisibilityAccess = NativeMenuBarVisibilityAccess()) {
        self.init(access: access, testingIO: nil)
    }

    #if DEBUG
    convenience init(testing io: NativeVisibilityStoreTestIO) {
        let defaults = UserDefaults(suiteName: "dev.hdh.MenuTidy.tests.store.\(UUID().uuidString)")!
        self.init(access: NativeMenuBarVisibilityAccess(defaults: defaults), testingIO: io)
    }
    #endif

    private init(access: NativeMenuBarVisibilityAccess, testingIO: NativeVisibilityStoreTestIO?) {
        self.access = access
        self.testingIO = testingIO
        do {
            let data = try loadJournalData()
            let loaded = try data.map(Ledger.decode) ?? []
            entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.bundleIdentifier, $0) })
        } catch {
            initialJournalWasUnreadable = true
            pendingRecoveryIssue = "菜单栏显示记录无法安全读取。已停止新的隐藏操作，请保留 Transactions/NativeVisibility.plist 以便恢复。"
        }
    }

    func requestAccess() async throws -> Bool {
        if testingIO != nil { _ = try readData(); return true }
        guard try await access.requestAccess() else { return false }
        _ = try readPreferenceValue()
        return true
    }

    /// Explicit local recovery after a transient journal error. This never
    /// writes preferences and does not bypass malformed/conflicting receipts.
    /// The caller can then reconcile pending writes and restore owned items.
    func reloadForRecovery() throws {
        do {
            let data = try loadJournalData()
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
            try saveJournalData(recoveredData)
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
        guard testingIO != nil || access.hasSelection else { throw failure("请先允许访问菜单栏显示记录，再连接托盘图标。") }
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

    private func perform(_ entry: Ledger.Entry) throws { try perform([entry]) }

    /// Every target has durable intent before one merged preference write.
    /// Recovery remains per complete target record, including uncertain writes.
    private func perform(_ changes: [Ledger.Entry]) throws {
        guard !changes.isEmpty else { return }
        let initial = try Codec.decode(readData())
        for entry in changes {
            guard try initial.matches(record: entry.expectedRecord(), bundleIdentifier: entry.bundleIdentifier) else { throw conflict() }
        }
        var prepared = entries
        for entry in changes {
            prepared[entry.bundleIdentifier] = entry
            knownUnwritten[entry.bundleIdentifier] = entry
        }
        try save(prepared)
        let written: Data
        do {
            let fresh = try readData()
            var merged = fresh
            for entry in changes {
                guard let next = try Codec.decode(merged).replacingRecord(bundleIdentifier: entry.bundleIdentifier,
                    expected: entry.expectedRecord(), replacement: entry.writtenRecord()) else { throw conflict() }
                merged = next
            }
            // CFPreferences has no compare-and-swap. Preserve the final
            // race check; a later competing write still requires recovery.
            guard try readData() == fresh else { throw conflict() }
            written = merged
        } catch {
            var cancelled = Array(entries.values)
            for entry in changes { cancelled = try Ledger.discardingKnownUnwritten(entry, from: cancelled) }
            try save(Dictionary(uniqueKeysWithValues: cancelled.map { ($0.bundleIdentifier, $0) }))
            for entry in changes { knownUnwritten.removeValue(forKey: entry.bundleIdentifier) }
            throw error
        }
        for entry in changes { knownUnwritten.removeValue(forKey: entry.bundleIdentifier) }
        try writePreferenceData(written)
        let readback = try Codec.decode(readData())
        for entry in changes {
            guard try readback.matches(record: entry.writtenRecord(), bundleIdentifier: entry.bundleIdentifier) else {
                throw failure("菜单栏显示结果尚未确认，恢复记录已保留；没有覆盖新的目标记录。")
            }
        }
        var completed = entries
        for entry in changes { completed[entry.bundleIdentifier] = entry.completingPending() }
        try save(completed)
        Self.logger.notice("nativeVisibility batchWriteConfirmed=true targetCount=\(changes.count) preferenceWrites=1")
    }

    /// Ordinary applications share one preference table. Unsupported or
    /// externally changed targets keep their own errors; qualified peers can
    /// still share a single write and durable journal commit.
    func changeVisibility(_ hiddenByBundle: [String: Bool]) -> [String: Result<Void, Error>] {
        var results: [String: Result<Void, Error>] = [:]
        var changes: [Ledger.Entry] = []
        for bundle in hiddenByBundle.keys.sorted() {
            do {
                try requireReady()
                try reconcile(bundle: bundle)
                let snapshot = try Codec.decode(readData())
                if hiddenByBundle[bundle] == true {
                    if let entry = entries[bundle] {
                        try assertCurrent(entry)
                    } else {
                        guard try snapshot.isAllowed(bundleIdentifier: bundle) else {
                            throw failure("此图标原本已被系统设置隐藏。请先允许它显示，再连接托盘。")
                        }
                        changes.append(Ledger.Entry(bundleIdentifier: bundle,
                            originalRecord: try snapshot.record(bundleIdentifier: bundle), mode: .original, pending: .hide))
                    }
                } else if let entry = entries[bundle] {
                    if try snapshot.matches(record: entry.originalRecord, bundleIdentifier: bundle) {
                        var next = entries; next.removeValue(forKey: bundle); try save(next)
                    } else {
                        guard entry.mode == .hidden else { throw conflict() }
                        changes.append(entry.preparing(.restore))
                    }
                } else {
                    guard try snapshot.isAllowed(bundleIdentifier: bundle) else { throw conflict() }
                }
                results[bundle] = .success(())
            } catch { results[bundle] = .failure(error) }
        }
        do { try requireReady(); try perform(changes) }
        catch { for entry in changes { results[entry.bundleIdentifier] = .failure(error) } }
        return results
    }

    private func loadJournalData() throws -> Data? {
        if let testingIO { return testingIO.journalData }
        return try journal.load()
    }

    private func saveJournalData(_ data: Data?) throws {
        if let testingIO { try testingIO.saveJournal(data); return }
        try journal.save(data)
    }

    private func writePreferenceData(_ written: Data) throws {
        if let testingIO { try testingIO.writePreferences(written); return }
        CFPreferencesSetValue(preferenceKey, written as CFData, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw failure("菜单栏显示开关尚未确认，恢复记录已保留。")
        }
    }

    private func readPreferenceValue() throws -> CFPropertyList {
        if let testingIO { return try testingIO.readPreferences() as CFData }
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
            try saveJournalData(data)
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
