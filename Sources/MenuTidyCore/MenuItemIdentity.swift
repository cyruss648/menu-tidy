import Foundation

/// Builds persistent identities only from identifiers that are stable and unique
/// in the current scan. Display names and accessibility labels are deliberately
/// excluded because applications may change them as their state changes.
public enum MenuItemIdentity {
    private static let positionNamespace = "menu-bar-position-v1"

    public static func persistentID(
        bundleIdentifier: String?,
        accessibilityIdentifier: String?,
        occurrenceCount: Int
    ) -> String? {
        guard occurrenceCount == 1,
              let bundleIdentifier, !bundleIdentifier.isEmpty,
              let accessibilityIdentifier, !accessibilityIdentifier.isEmpty,
              let encoded = try? JSONEncoder().encode([bundleIdentifier, accessibilityIdentifier]),
              let identity = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        // A structured pair avoids collisions when either identifier contains
        // punctuation that would otherwise be used to concatenate the values.
        return "item:" + identity
    }

    /// The caller must first prove the live owner, complete originating source
    /// and unique existing preference key. This encodes saved intent, never a
    /// permission to write preferences or reuse an AX object after restarting.
    public static func persistentPositionID(bundleIdentifier: String?, positionKey: String) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let prefix = "status:\(bundleIdentifier)::"
        guard positionKey.hasPrefix(prefix), positionKey.count > prefix.count,
              let encoded = try? JSONEncoder().encode([positionNamespace, bundleIdentifier, positionKey]),
              let identity = String(data: encoded, encoding: .utf8) else { return nil }
        // Three fields and a versioned namespace cannot collide with the
        // existing two-field accessibility identifier representation.
        return "item:" + identity
    }

    /// Recognizes only our canonical encoding and the exact originating bundle.
    /// Used to retain an already-proven identity while its live source is still
    /// independently verifiable and the preference table is temporarily unreadable.
    public static func positionKey(inPersistentID id: String, bundleIdentifier: String?) -> String? {
        guard id.hasPrefix("item:"),
              let parts = try? JSONDecoder().decode([String].self, from: Data(id.dropFirst(5).utf8)),
              parts.count == 3, parts[0] == positionNamespace, parts[1] == bundleIdentifier,
              persistentPositionID(bundleIdentifier: bundleIdentifier, positionKey: parts[2]) == id else { return nil }
        return parts[2]
    }
}
