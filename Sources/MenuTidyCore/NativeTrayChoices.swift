/// Persistent user intent for native visibility, whose ownership unit is the
/// exact application bundle. This does not prove a live item or preference
/// record belongs to that application; the native backend must verify both.
public struct NativeTrayChoices: Codable, Equatable, Sendable {
    public private(set) var choices: [String: ItemVisibility]

    private enum CodingKeys: String, CodingKey { case choices }

    public init(existing: [String: ItemVisibility] = [:]) {
        choices = existing.filter { Self.accepts(bundle: $0.key, excluding: []) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([String: ItemVisibility].self, forKey: .choices)
        guard decoded.keys.allSatisfy({ Self.accepts(bundle: $0, excluding: []) }) else {
            throw DecodingError.dataCorruptedError(forKey: .choices, in: container,
                debugDescription: "Native tray choices require complete non-system bundle identifiers.")
        }
        choices = decoded
    }

    public func group(bundle: String) -> ItemVisibility? { choices[bundle] }

    /// Forgetting is application-wide, so any current sibling blocks it. Use
    /// only the exact stored bundle; never infer a parent or normalize case.
    public static func canForget(bundle: String, liveBundles: Set<String>,
                                 excluding: Set<String> = []) -> Bool {
        accepts(bundle: bundle, excluding: excluding) && !liveBundles.contains(bundle)
    }

    @discardableResult
    public mutating func remove(bundle: String, liveBundles: Set<String>,
                                excluding: Set<String> = []) -> Bool {
        guard Self.canForget(bundle: bundle, liveBundles: liveBundles, excluding: excluding) else { return false }
        return choices.removeValue(forKey: bundle) != nil
    }

    /// Explicit visible choices are retained so a later legacy migration cannot
    /// revive an old hidden choice. Identifiers are never trimmed or rewritten.
    @discardableResult
    public mutating func set(bundle: String, group: ItemVisibility,
                             excluding: Set<String> = []) -> Bool {
        guard Self.accepts(bundle: bundle, excluding: excluding) else { return false }
        choices[bundle] = group
        return true
    }

    /// Import only unanimous old item choices for an exact bundle. Different
    /// hidden categories remain different intent; neither is guessed to win.
    /// A newer native choice always takes precedence, including `.visible`.
    @discardableResult
    public mutating func migrate(saved: ItemRuleBook,
                                 excluding: Set<String> = []) -> Set<String> {
        let eligible = saved.rules.values.filter {
            guard let bundle = $0.bundleIdentifier else { return false }
            return Self.accepts(bundle: bundle, excluding: excluding)
        }
        let byBundle = Dictionary(grouping: eligible, by: { $0.bundleIdentifier! })
        var imported: Set<String> = []
        for (bundle, rules) in byBundle where choices[bundle] == nil {
            guard let first = rules.first?.visibility,
                  rules.allSatisfy({ $0.visibility == first }) else { continue }
            choices[bundle] = first
            imported.insert(bundle)
        }
        return imported
    }

    private static func accepts(bundle: String, excluding: Set<String>) -> Bool {
        guard !excluding.contains(bundle), bundle.utf8.count <= 255 else { return false }
        let lower = bundle.lowercased()
        guard lower != "com.apple", !lower.hasPrefix("com.apple.") else { return false }
        let components = bundle.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return false }
        return bundle.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
