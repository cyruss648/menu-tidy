import CoreFoundation
import Foundation

/// A strictly scoped pending-transaction archive. It contains no recovery path
/// supplied by the file and never interprets arbitrary historical backups.
public enum MenuBarPositionJournal {
    public struct Entry {
        public let id: UUID
        public let sourceKey: String
        public let anchorKey: String
        public let originalValues: [String: NSNumber]
        public let writtenValues: [String: NSNumber]

        public init(id: UUID, sourceKey: String, anchorKey: String,
                    originalValues: [String: NSNumber], writtenValues: [String: NSNumber]) {
            self.id = id
            self.sourceKey = sourceKey
            self.anchorKey = anchorKey
            self.originalValues = originalValues
            self.writtenValues = writtenValues
        }
    }

    public enum JournalError: Error, Equatable {
        case invalidSchema
        case invalidTransaction
        case duplicateTransaction
        case archiveTooLarge
    }

    public static let maximumDataSize = 1_048_576
    private static let applicationID = "dev.hdh.MenuTidy"
    private static let relativeDomain = "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"
    private static let preferenceKey = "TrailingItemPreferredPositions"
    private static let envelopeKeys: Set<String> = ["schemaVersion", "applicationID", "relativeDomain", "preferenceKey", "transactions"]
    private static let entryKeys: Set<String> = ["id", "sourceKey", "anchorKey", "originalValues", "writtenValues"]

    public static func encode(_ entries: [Entry]) throws -> Data {
        try validate(entries)
        let transactions: [[String: Any]] = entries.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            ["id": $0.id.uuidString, "sourceKey": $0.sourceKey, "anchorKey": $0.anchorKey,
             "originalValues": $0.originalValues, "writtenValues": $0.writtenValues]
        }
        let payload: [String: Any] = ["schemaVersion": 1, "applicationID": applicationID,
            "relativeDomain": relativeDomain, "preferenceKey": preferenceKey, "transactions": transactions]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        guard data.count <= maximumDataSize else { throw JournalError.archiveTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumDataSize else { throw JournalError.archiveTooLarge }
        guard let payload = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(payload.keys) == envelopeKeys,
              let version = payload["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) == CFNumberGetTypeID(), !CFNumberIsFloatType(version), version == 1,
              payload["applicationID"] as? String == applicationID,
              payload["relativeDomain"] as? String == relativeDomain,
              payload["preferenceKey"] as? String == preferenceKey,
              let rawEntries = payload["transactions"] as? [[String: Any]] else { throw JournalError.invalidSchema }
        let entries = try rawEntries.map { raw -> Entry in
            guard Set(raw.keys) == entryKeys,
                  let idString = raw["id"] as? String, let id = UUID(uuidString: idString),
                  id.uuidString == idString,
                  let source = raw["sourceKey"] as? String, let anchor = raw["anchorKey"] as? String,
                  let original = raw["originalValues"] as? [String: NSNumber],
                  let written = raw["writtenValues"] as? [String: NSNumber] else { throw JournalError.invalidTransaction }
            return Entry(id: id, sourceKey: source, anchorKey: anchor,
                         originalValues: original, writtenValues: written)
        }
        try validate(entries)
        return entries
    }

    private static func validate(_ entries: [Entry]) throws {
        guard entries.count <= 256 else { throw JournalError.archiveTooLarge }
        var ids: Set<UUID> = []
        var sources: Set<String> = []
        for entry in entries {
            guard ids.insert(entry.id).inserted, sources.insert(entry.sourceKey).inserted else {
                throw JournalError.duplicateTransaction
            }
            guard validStatusKey(entry.sourceKey), validStatusKey(entry.anchorKey), entry.sourceKey != entry.anchorKey,
                  Set(entry.originalValues.keys) == [entry.sourceKey], Set(entry.writtenValues.keys) == [entry.sourceKey],
                  entry.originalValues.values.allSatisfy(validNumber), entry.writtenValues.values.allSatisfy(validNumber) else {
                throw JournalError.invalidTransaction
            }
        }
    }

    private static func validStatusKey(_ key: String) -> Bool {
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
