import CoreFoundation
import Foundation

/// Durable ownership of a hidden position, separate from a one-shot move.
/// Numbers stay NSNumbers throughout storage and recovery: converting an
/// original integer through Double can lose the value needed for restoration.
public enum MenuBarHiddenLedger {
    public enum Mode: String, CaseIterable {
        case original, hidden, temporarilyRevealed
    }

    public enum Operation: String, CaseIterable {
        case hide, temporarilyReveal, restoreTemporaryReveal, restoreOriginal
    }

    public struct PendingWrite: Equatable {
        public let operation: Operation
        public let expectedValue: NSNumber
        public let writtenValue: NSNumber

        public init(operation: Operation, expectedValue: NSNumber, writtenValue: NSNumber) {
            self.operation = operation
            self.expectedValue = expectedValue
            self.writtenValue = writtenValue
        }
    }

    public struct Entry: Equatable {
        public let key: String
        public let originalValue: NSNumber
        public let hiddenValue: NSNumber
        public let lastAppWrite: NSNumber?
        public let mode: Mode
        public let pending: PendingWrite?

        public init(key: String, originalValue: NSNumber, hiddenValue: NSNumber,
                    lastAppWrite: NSNumber?, mode: Mode, pending: PendingWrite? = nil) {
            self.key = key
            self.originalValue = originalValue
            self.hiddenValue = hiddenValue
            self.lastAppWrite = lastAppWrite
            self.mode = mode
            self.pending = pending
        }

        public func preparing(_ operation: Operation, value: NSNumber) -> Entry {
            Entry(key: key, originalValue: originalValue, hiddenValue: hiddenValue,
                  lastAppWrite: lastAppWrite, mode: mode,
                  pending: PendingWrite(operation: operation,
                      expectedValue: lastAppWrite ?? originalValue, writtenValue: value))
        }

        /// Call only after the preference's exact value matches the pending
        /// write. A completed restore no longer owns the system position.
        public func completingPending() -> Entry? {
            guard let pending else { return self }
            if pending.operation == .restoreOriginal { return nil }
            return Entry(key: key, originalValue: originalValue, hiddenValue: hiddenValue,
                lastAppWrite: pending.writtenValue,
                mode: pending.operation == .temporarilyReveal ? .temporarilyRevealed : .hidden)
        }

        public func discardingUnappliedPending() -> Entry? {
            guard mode != .original else { return nil }
            return Entry(key: key, originalValue: originalValue, hiddenValue: hiddenValue,
                         lastAppWrite: lastAppWrite, mode: mode)
        }
    }

    public enum Recovery: Equatable {
        case unchanged
        case completed(Entry?)
        case notApplied(Entry?)
        case conflicted
        case missing
    }

    public enum LedgerError: Error, Equatable {
        case invalidSchema, invalidEntry, duplicateKey, archiveTooLarge, noHiddenSlot
    }

    public static let maximumDataSize = 1_048_576
    public static let minimumHiddenWeight = 50_000.0
    private static let envelopeKeys: Set<String> = ["schemaVersion", "applicationID", "relativeDomain", "preferenceKey", "entries"]
    private static let entryKeys: Set<String> = ["key", "originalValue", "hiddenValue", "mode", "lastAppWrite", "pending"]
    private static let pendingKeys: Set<String> = ["operation", "expectedValue", "writtenValue"]

    /// Existing and reserved hidden slots both count, even while another
    /// managed item is temporarily visible or its owner is not running.
    public static func allocateHiddenWeight(positions: [String: NSNumber], entries: [Entry]) throws -> NSNumber {
        guard positions.values.allSatisfy(validNumber) else { throw LedgerError.invalidEntry }
        try validate(entries)
        let occupied = Set(positions.values.map(\.doubleValue) + entries.map { $0.hiddenValue.doubleValue })
        var value = minimumHiddenWeight
        for _ in 0...occupied.count {
            if !occupied.contains(value) { return NSNumber(value: value) }
            value += 10
            guard value.isFinite else { throw LedgerError.noHiddenSlot }
        }
        throw LedgerError.noHiddenSlot
    }

    /// Reconciliation never writes preferences. The persisted intent makes a
    /// crash before/after the system write distinguishable without guessing.
    public static func recovery(for entry: Entry, current: NSNumber?) -> Recovery {
        guard let current else { return .missing }
        guard validNumber(current) else { return .conflicted }
        guard let pending = entry.pending else {
            return current.isEqual(to: entry.lastAppWrite ?? entry.originalValue) ? .unchanged : .conflicted
        }
        if current.isEqual(to: pending.writtenValue) { return .completed(entry.completingPending()) }
        if current.isEqual(to: pending.expectedValue) { return .notApplied(entry.discardingUnappliedPending()) }
        return .conflicted
    }

    public static func encode(_ entries: [Entry]) throws -> Data {
        try validate(entries)
        let values: [[String: Any]] = entries.sorted { $0.key < $1.key }.map { entry in
            var value: [String: Any] = ["key": entry.key, "originalValue": entry.originalValue,
                "hiddenValue": entry.hiddenValue, "mode": entry.mode.rawValue]
            if let last = entry.lastAppWrite { value["lastAppWrite"] = last }
            if let pending = entry.pending {
                value["pending"] = ["operation": pending.operation.rawValue,
                    "expectedValue": pending.expectedValue, "writtenValue": pending.writtenValue]
            }
            return value
        }
        let payload: [String: Any] = ["schemaVersion": 1, "applicationID": "dev.hdh.MenuTidy",
            "relativeDomain": "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar",
            "preferenceKey": "TrailingItemPreferredPositions", "entries": values]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        guard data.count <= maximumDataSize else { throw LedgerError.archiveTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumDataSize else { throw LedgerError.archiveTooLarge }
        guard let payload = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(payload.keys) == envelopeKeys,
              let version = payload["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) == CFNumberGetTypeID(), !CFNumberIsFloatType(version), version == 1,
              payload["applicationID"] as? String == "dev.hdh.MenuTidy",
              payload["relativeDomain"] as? String == "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar",
              payload["preferenceKey"] as? String == "TrailingItemPreferredPositions",
              let values = payload["entries"] as? [[String: Any]] else { throw LedgerError.invalidSchema }
        let entries = try values.map { value -> Entry in
            guard Set(value.keys).isSubset(of: entryKeys),
                  let key = value["key"] as? String,
                  let original = value["originalValue"] as? NSNumber,
                  let hidden = value["hiddenValue"] as? NSNumber,
                  let rawMode = value["mode"] as? String, let mode = Mode(rawValue: rawMode),
                  value["lastAppWrite"] == nil || value["lastAppWrite"] is NSNumber else { throw LedgerError.invalidEntry }
            var pending: PendingWrite?
            if let raw = value["pending"] {
                guard let raw = raw as? [String: Any], Set(raw.keys) == pendingKeys,
                      let name = raw["operation"] as? String, let operation = Operation(rawValue: name),
                      let expected = raw["expectedValue"] as? NSNumber,
                      let written = raw["writtenValue"] as? NSNumber else { throw LedgerError.invalidEntry }
                pending = PendingWrite(operation: operation, expectedValue: expected, writtenValue: written)
            }
            return Entry(key: key, originalValue: original, hiddenValue: hidden,
                         lastAppWrite: value["lastAppWrite"] as? NSNumber, mode: mode, pending: pending)
        }
        try validate(entries)
        return entries
    }

    private static func validate(_ entries: [Entry]) throws {
        guard entries.count <= 256 else { throw LedgerError.archiveTooLarge }
        var keys: Set<String> = []
        var hiddenSlots: Set<Double> = []
        for entry in entries {
            guard keys.insert(entry.key).inserted else { throw LedgerError.duplicateKey }
            guard validStatusKey(entry.key), validNumber(entry.originalValue), validNumber(entry.hiddenValue),
                  entry.hiddenValue.doubleValue >= minimumHiddenWeight,
                  hiddenSlots.insert(entry.hiddenValue.doubleValue).inserted,
                  entry.lastAppWrite.map(validNumber) ?? true else { throw LedgerError.invalidEntry }
            switch entry.mode {
            case .original:
                guard entry.lastAppWrite == nil, entry.pending?.operation == .hide else { throw LedgerError.invalidEntry }
            case .hidden:
                guard entry.lastAppWrite?.isEqual(to: entry.hiddenValue) == true else { throw LedgerError.invalidEntry }
            case .temporarilyRevealed:
                guard let last = entry.lastAppWrite, last.doubleValue < minimumHiddenWeight else { throw LedgerError.invalidEntry }
            }
            if let pending = entry.pending {
                guard validNumber(pending.expectedValue), validNumber(pending.writtenValue),
                      pending.expectedValue.isEqual(to: entry.lastAppWrite ?? entry.originalValue) else { throw LedgerError.invalidEntry }
                switch pending.operation {
                case .hide, .restoreTemporaryReveal:
                    guard pending.writtenValue.isEqual(to: entry.hiddenValue),
                          pending.operation != .restoreTemporaryReveal || entry.mode == .temporarilyRevealed else { throw LedgerError.invalidEntry }
                case .temporarilyReveal:
                    guard entry.mode == .hidden, pending.writtenValue.doubleValue < minimumHiddenWeight else { throw LedgerError.invalidEntry }
                case .restoreOriginal:
                    guard entry.mode != .original, pending.writtenValue.isEqual(to: entry.originalValue) else { throw LedgerError.invalidEntry }
                }
            }
        }
    }

    private static func validStatusKey(_ key: String) -> Bool {
        if SystemModuleIdentity.isSupportedPositionKey(key) { return true }
        guard key.hasPrefix("status:"), key.utf8.count <= 4_096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let separator = key.range(of: "::"), separator.lowerBound > key.index(key.startIndex, offsetBy: 7),
              separator.upperBound < key.endIndex else { return false }
        return true
    }

    private static func validNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFNumberGetTypeID() && number.doubleValue.isFinite
    }
}
