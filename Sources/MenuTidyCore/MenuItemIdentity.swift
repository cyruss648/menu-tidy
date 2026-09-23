import Foundation

/// Builds persistent identities only from identifiers that are stable and unique
/// in the current scan. Display names and accessibility labels are deliberately
/// excluded because applications may change them as their state changes.
public enum MenuItemIdentity {
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
}
