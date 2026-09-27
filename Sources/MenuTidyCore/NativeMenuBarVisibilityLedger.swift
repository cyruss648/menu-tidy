import CoreFoundation
import Foundation

/// Owns exact third-party records, never the surrounding Control Center table.
/// Pending intent is durable before the system write so interrupted writes can
/// be reconciled without treating a pre-existing disabled item as ours.
public enum NativeMenuBarVisibilityLedger {
    public enum Mode: String, Sendable { case original, hidden, revealed }
    public enum Operation: String, Sendable { case hide, reveal, rehide, restore }

    public struct Entry: Equatable, Sendable {
        public let bundleIdentifier: String
        public let originalRecord: Data
        public let mode: Mode
        public let pending: Operation?

        public init(bundleIdentifier: String, originalRecord: Data,
                    mode: Mode, pending: Operation? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.originalRecord = originalRecord
            self.mode = mode
            self.pending = pending
        }

        public func preparing(_ operation: Operation) -> Entry {
            Entry(bundleIdentifier: bundleIdentifier, originalRecord: originalRecord,
                  mode: mode, pending: operation)
        }

        public var isTemporarilyRevealed: Bool { mode == .revealed || pending == .reveal }

        public func hiddenRecord() throws -> Data {
            let snapshot = try NativeMenuBarVisibilityCodec.decode(originalRecord)
            guard let change = try snapshot.settingAllowed(false, bundleIdentifier: bundleIdentifier) else {
                throw Failure.invalidEntry
            }
            return change.data
        }

        public func expectedRecord() throws -> Data { mode == .hidden ? try hiddenRecord() : originalRecord }

        public func writtenRecord() throws -> Data {
            guard let pending else { throw Failure.invalidEntry }
            return pending == .hide || pending == .rehide ? try hiddenRecord() : originalRecord
        }

        public func completingPending() -> Entry? {
            guard let pending else { return self }
            guard pending != .restore else { return nil }
            return Entry(bundleIdentifier: bundleIdentifier, originalRecord: originalRecord,
                         mode: pending == .reveal ? .revealed : .hidden)
        }

        public func discardingUnappliedPending() -> Entry? {
            guard mode != .original else { return nil }
            return Entry(bundleIdentifier: bundleIdentifier, originalRecord: originalRecord, mode: mode)
        }
    }

    public enum Recovery: Equatable {
        case unchanged, completed(Entry?), notApplied(Entry?), conflicted
    }
    public enum Failure: Error { case invalidArchive, invalidEntry, tooLarge, conflictingOriginal }
    public static let maximumDataSize = 1_048_576
    public static let maximumEntries = 256

    public static func recovery(for entry: Entry, current: NativeMenuBarVisibilityCodec.Snapshot) throws -> Recovery {
        try validate(entry)
        if entry.pending != nil {
            if try current.matches(record: entry.writtenRecord(), bundleIdentifier: entry.bundleIdentifier) {
                return .completed(entry.completingPending())
            }
            if try current.matches(record: entry.expectedRecord(), bundleIdentifier: entry.bundleIdentifier) {
                return .notApplied(entry.discardingUnappliedPending())
            }
            return .conflicted
        }
        return try current.matches(record: entry.expectedRecord(), bundleIdentifier: entry.bundleIdentifier)
            ? .unchanged : .conflicted
    }

    /// Re-open a journal after a local I/O failure without discarding receipts
    /// still held by the running process. A completed disk transition wins;
    /// missing entries are re-journalled before any new preference write.
    public static func mergeForRecovery(persisted: [Entry], remembered: [Entry]) throws -> [Entry] {
        _ = try encode(persisted)
        _ = try encode(remembered)
        var merged = Dictionary(uniqueKeysWithValues: persisted.map { ($0.bundleIdentifier, $0) })
        for entry in remembered {
            if let existing = merged[entry.bundleIdentifier] {
                guard try NativeMenuBarVisibilityCodec.decode(existing.originalRecord).matches(
                    record: entry.originalRecord, bundleIdentifier: entry.bundleIdentifier) else {
                    throw Failure.conflictingOriginal
                }
            } else {
                merged[entry.bundleIdentifier] = entry
            }
        }
        let result = merged.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        _ = try encode(result)
        return result
    }

    /// Unlike crash recovery, a running process can know it never issued the
    /// system write. Clear that pending intent instead of adopting an identical
    /// value written by somebody else. Existing prior ownership is retained.
    public static func discardingKnownUnwritten(_ attempted: Entry, from entries: [Entry]) throws -> [Entry] {
        try validate(attempted)
        guard attempted.pending != nil else { throw Failure.invalidEntry }
        _ = try encode(entries)
        let cancelled = attempted.discardingUnappliedPending()
        var next = Dictionary(uniqueKeysWithValues: entries.map { ($0.bundleIdentifier, $0) })
        if let existing = next[attempted.bundleIdentifier] {
            guard existing == attempted || existing == cancelled else { throw Failure.conflictingOriginal }
        }
        next[attempted.bundleIdentifier] = cancelled
        return next.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    public static func encode(_ entries: [Entry]) throws -> Data {
        guard entries.count <= maximumEntries,
              Set(entries.map(\.bundleIdentifier)).count == entries.count else { throw Failure.invalidArchive }
        let records: [[String: Any]] = try entries.sorted { $0.bundleIdentifier < $1.bundleIdentifier }.map { entry in
            try validate(entry)
            var record: [String: Any] = ["bundleIdentifier": entry.bundleIdentifier,
                "originalRecord": entry.originalRecord, "mode": entry.mode.rawValue]
            if let pending = entry.pending { record["pending"] = pending.rawValue }
            return record
        }
        let payload: [String: Any] = ["schemaVersion": 1, "applicationID": "dev.hdh.MenuTidy",
            "relativeDomain": "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter",
            "preferenceKey": "trackedApplications", "entries": records]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        guard data.count <= maximumDataSize else { throw Failure.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumDataSize else { throw Failure.tooLarge }
        guard let payload = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(payload.keys) == ["schemaVersion", "applicationID", "relativeDomain", "preferenceKey", "entries"],
              let version = payload["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) == CFNumberGetTypeID(), !CFNumberIsFloatType(version), version == 1,
              payload["applicationID"] as? String == "dev.hdh.MenuTidy",
              payload["relativeDomain"] as? String == "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter",
              payload["preferenceKey"] as? String == "trackedApplications",
              let records = payload["entries"] as? [[String: Any]], records.count <= maximumEntries else {
            throw Failure.invalidArchive
        }
        let entries = try records.map { record -> Entry in
            guard Set(record.keys).isSubset(of: ["bundleIdentifier", "originalRecord", "mode", "pending"]),
                  let bundle = record["bundleIdentifier"] as? String,
                  let original = record["originalRecord"] as? Data,
                  let rawMode = record["mode"] as? String, let mode = Mode(rawValue: rawMode) else {
                throw Failure.invalidEntry
            }
            var pending: Operation?
            if let raw = record["pending"] {
                guard let string = raw as? String, let operation = Operation(rawValue: string) else { throw Failure.invalidEntry }
                pending = operation
            }
            let entry = Entry(bundleIdentifier: bundle, originalRecord: original, mode: mode, pending: pending)
            try validate(entry)
            return entry
        }
        guard Set(entries.map(\.bundleIdentifier)).count == entries.count else { throw Failure.invalidArchive }
        return entries
    }

    private static func validate(_ entry: Entry) throws {
        let snapshot = try NativeMenuBarVisibilityCodec.decode(entry.originalRecord)
        guard snapshot.count == 1, try snapshot.isAllowed(bundleIdentifier: entry.bundleIdentifier) else {
            throw Failure.invalidEntry
        }
        switch entry.mode {
        case .original: guard entry.pending == .hide else { throw Failure.invalidEntry }
        case .hidden:
            guard entry.pending == nil || entry.pending == .reveal || entry.pending == .restore else { throw Failure.invalidEntry }
        case .revealed:
            guard entry.pending == nil || entry.pending == .rehide else { throw Failure.invalidEntry }
        }
    }
}
