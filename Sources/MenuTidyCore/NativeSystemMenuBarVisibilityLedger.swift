import CoreFoundation
import Foundation

/// Ownership of the verified AirDrop visibility bits in the current user's
/// current-host Control Center preferences. Other system modules are excluded.
/// Restore changes only our mask in a fresh integer, preserving foreign bits.
public enum NativeSystemMenuBarVisibilityLedger {
    public static let visibilityMask: Int64 = 0xA
    public static let shownMask: Int64 = 0x2
    public static let hiddenMask: Int64 = 0x8
    public static let maximumDataSize = 16_384
    public static let maximumEntries = 1

    public enum Mode: String, Sendable { case original, hidden, revealed }
    public enum Operation: String, Sendable { case hide, reveal, rehide, restore }
    public enum Failure: Error, Equatable {
        case invalidArchive, invalidEntry, invalidInteger, unsupportedMask, unsupportedKey
        case conflictingOriginal, archiveTooLarge
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let hostIdentifier: String
        public let originalValue: Int64
        public let mode: Mode
        public let pending: Operation?

        public init(key: String, hostIdentifier: String, originalValue: Int64,
                    mode: Mode, pending: Operation? = nil) {
            self.key = key
            self.hostIdentifier = hostIdentifier
            self.originalValue = originalValue
            self.mode = mode
            self.pending = pending
        }

        public func preparing(_ operation: Operation) -> Entry {
            Entry(key: key, hostIdentifier: hostIdentifier, originalValue: originalValue,
                  mode: mode, pending: operation)
        }

        public var isTemporarilyRevealed: Bool { mode == .revealed || pending == .reveal }

        public func expectedMask() -> Int64 {
            mode == .hidden ? hiddenMask : originalValue & visibilityMask
        }

        public func writtenMask() -> Int64 {
            guard let pending else { return expectedMask() }
            return pending == .hide || pending == .rehide ? hiddenMask : originalValue & visibilityMask
        }

        public func completingPending() -> Entry? {
            guard let pending else { return self }
            guard pending != .restore else { return nil }
            return Entry(key: key, hostIdentifier: hostIdentifier, originalValue: originalValue,
                         mode: pending == .reveal ? .revealed : .hidden)
        }

        public func discardingUnappliedPending() -> Entry? {
            guard mode != .original else { return nil }
            return Entry(key: key, hostIdentifier: hostIdentifier, originalValue: originalValue, mode: mode)
        }
    }

    public enum Recovery: Equatable {
        case unchanged, completed(Entry?), notApplied(Entry?), conflicted
    }

    public static func integerValue(_ object: Any) throws -> Int64 {
        guard let number = object as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number), number.int64Value >= 0 else { throw Failure.invalidInteger }
        return number.int64Value
    }

    public static func isAllowed(_ value: Int64) throws -> Bool {
        guard value >= 0 else { throw Failure.invalidInteger }
        switch value & visibilityMask {
        case shownMask: return true
        case hiddenMask: return false
        default: throw Failure.unsupportedMask
        }
    }

    public static func replacingMask(in value: Int64, with replacement: Int64) throws -> Int64 {
        _ = try isAllowed(value)
        guard replacement == shownMask || replacement == hiddenMask else { throw Failure.unsupportedMask }
        return (value & ~visibilityMask) | replacement
    }

    public static func recovery(for entry: Entry, current: Int64) throws -> Recovery {
        try validate(entry)
        guard current >= 0 else { throw Failure.invalidInteger }
        let mask = current & visibilityMask
        // Unknown new system states are conflicts, never a cue to clear or
        // rebuild bits that this version has not verified.
        guard mask == shownMask || mask == hiddenMask else { return .conflicted }
        if entry.pending != nil {
            if mask == entry.writtenMask() { return .completed(entry.completingPending()) }
            if mask == entry.expectedMask() { return .notApplied(entry.discardingUnappliedPending()) }
            return .conflicted
        }
        return mask == entry.expectedMask() ? .unchanged : .conflicted
    }

    public static func mergeForRecovery(persisted: [Entry], remembered: [Entry]) throws -> [Entry] {
        _ = try encode(persisted)
        _ = try encode(remembered)
        var merged = Dictionary(uniqueKeysWithValues: persisted.map { ($0.key, $0) })
        for entry in remembered {
            if let existing = merged[entry.key] {
                guard UUID(uuidString: existing.hostIdentifier) == UUID(uuidString: entry.hostIdentifier),
                      existing.originalValue & visibilityMask == entry.originalValue & visibilityMask else {
                    throw Failure.conflictingOriginal
                }
            } else { merged[entry.key] = entry }
        }
        let result = merged.values.sorted { $0.key < $1.key }
        _ = try encode(result)
        return result
    }

    /// Apply same-process knowledge that CFPreferencesSetValue was never
    /// called, even if saving the cancellation previously failed.
    public static func discardingKnownUnwritten(entries: [Entry], known: [Entry]) throws -> [Entry] {
        _ = try encode(entries)
        _ = try encode(known)
        var next = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        for attempted in known {
            guard attempted.pending != nil else { throw Failure.invalidEntry }
            let cancelled = attempted.discardingUnappliedPending()
            if let existing = next[attempted.key] {
                guard existing == attempted || existing == cancelled else { throw Failure.conflictingOriginal }
            }
            next[attempted.key] = cancelled
        }
        return next.values.sorted { $0.key < $1.key }
    }

    public static func encode(_ entries: [Entry]) throws -> Data {
        guard entries.count <= maximumEntries, Set(entries.map(\.key)).count == entries.count else {
            throw Failure.invalidArchive
        }
        let records: [[String: Any]] = try entries.sorted { $0.key < $1.key }.map { entry in
            try validate(entry)
            var value: [String: Any] = ["key": entry.key, "hostIdentifier": entry.hostIdentifier,
                "originalValue": NSNumber(value: entry.originalValue), "mode": entry.mode.rawValue]
            if let pending = entry.pending { value["pending"] = pending.rawValue }
            return value
        }
        let payload: [String: Any] = ["schemaVersion": 1, "applicationID": "dev.hdh.MenuTidy",
            "domain": "com.apple.controlcenter", "userScope": "currentUser", "hostScope": "currentHost",
            "entries": records]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        guard data.count <= maximumDataSize else { throw Failure.archiveTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumDataSize else { throw Failure.archiveTooLarge }
        guard let payload = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(payload.keys) == ["schemaVersion", "applicationID", "domain", "userScope", "hostScope", "entries"],
              let version = payload["schemaVersion"], try integerValue(version) == 1,
              payload["applicationID"] as? String == "dev.hdh.MenuTidy",
              payload["domain"] as? String == "com.apple.controlcenter",
              payload["userScope"] as? String == "currentUser",
              payload["hostScope"] as? String == "currentHost",
              let values = payload["entries"] as? [[String: Any]], values.count <= maximumEntries else {
            throw Failure.invalidArchive
        }
        let entries = try values.map { value -> Entry in
            guard Set(value.keys).isSubset(of: ["key", "hostIdentifier", "originalValue", "mode", "pending"]),
                  let key = value["key"] as? String, let host = value["hostIdentifier"] as? String,
                  let original = value["originalValue"], let rawMode = value["mode"] as? String,
                  let mode = Mode(rawValue: rawMode) else { throw Failure.invalidEntry }
            var pending: Operation?
            if let raw = value["pending"] {
                guard let string = raw as? String, let operation = Operation(rawValue: string) else { throw Failure.invalidEntry }
                pending = operation
            }
            let entry = Entry(key: key, hostIdentifier: host, originalValue: try integerValue(original),
                              mode: mode, pending: pending)
            try validate(entry)
            return entry
        }
        guard Set(entries.map(\.key)).count == entries.count else { throw Failure.invalidArchive }
        return entries
    }

    private static func validate(_ entry: Entry) throws {
        guard entry.key == "AirDrop" else { throw Failure.unsupportedKey }
        guard UUID(uuidString: entry.hostIdentifier) != nil, try isAllowed(entry.originalValue) else { throw Failure.invalidEntry }
        switch entry.mode {
        case .original: guard entry.pending == .hide else { throw Failure.invalidEntry }
        case .hidden:
            guard entry.pending == nil || entry.pending == .reveal || entry.pending == .restore else { throw Failure.invalidEntry }
        case .revealed:
            guard entry.pending == nil || entry.pending == .rehide else { throw Failure.invalidEntry }
        }
    }
}
