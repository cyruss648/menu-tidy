/// Persistent user intent for native visibility, whose ownership unit is the
/// exact application bundle. This does not prove a live item or preference
/// record belongs to that application; the native backend must verify both.
public struct NativeTrayChoices: Codable, Equatable, Sendable {
    public private(set) var choices: [String: ItemVisibility]
    /// Some real macOS applications use a single-component bundle identifier.
    /// Keep the live-observation proof beside the choice so decoding an
    /// arbitrary user-entered name such as "App" remains rejected.
    private var observedSingleComponentBundles: Set<String>

    private enum CodingKeys: String, CodingKey {
        case choices
        case observedSingleComponentBundles
    }

    public init(existing: [String: ItemVisibility] = [:], observedBundles: Set<String> = []) {
        let observed = Set(observedBundles.filter(Self.isSingleComponentBundleSyntax))
        observedSingleComponentBundles = observed
        choices = existing.filter {
            Self.accepts(bundle: $0.key, excluding: [], observedBundles: observed)
        }
        observedSingleComponentBundles = observed.intersection(choices.keys)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([String: ItemVisibility].self, forKey: .choices)
        let observed = try container.decodeIfPresent(Set<String>.self,
            forKey: .observedSingleComponentBundles) ?? []
        guard observed.allSatisfy(Self.isSingleComponentBundleSyntax),
              observed.isSubset(of: decoded.keys),
              decoded.keys.allSatisfy({
                  Self.accepts(bundle: $0, excluding: [], observedBundles: observed)
              }) else {
            throw DecodingError.dataCorruptedError(forKey: .choices, in: container,
                debugDescription: "Native tray choices require complete non-system bundle identifiers.")
        }
        choices = decoded
        observedSingleComponentBundles = observed
    }

    public func group(bundle: String) -> ItemVisibility? { choices[bundle] }

    /// Instance-scoped eligibility includes only single-component identifiers
    /// previously accepted from a live application observation.
    public func accepts(bundle: String, excluding: Set<String> = []) -> Bool {
        Self.accepts(bundle: bundle, excluding: excluding,
            observedBundles: observedSingleComponentBundles)
    }

    /// Forgetting is application-wide, so any current sibling blocks it. Use
    /// only the exact stored bundle; never infer a parent or normalize case.
    public static func canForget(bundle: String, liveBundles: Set<String>,
                                 excluding: Set<String> = []) -> Bool {
        accepts(bundle: bundle, excluding: excluding) && !liveBundles.contains(bundle)
    }

    public func canForget(bundle: String, liveBundles: Set<String>,
                          excluding: Set<String> = []) -> Bool {
        accepts(bundle: bundle, excluding: excluding) && !liveBundles.contains(bundle)
    }

    @discardableResult
    public mutating func remove(bundle: String, liveBundles: Set<String>,
                                excluding: Set<String> = []) -> Bool {
        guard canForget(bundle: bundle, liveBundles: liveBundles, excluding: excluding) else { return false }
        let removed = choices.removeValue(forKey: bundle) != nil
        observedSingleComponentBundles.remove(bundle)
        return removed
    }

    /// Explicit visible choices are retained so a later legacy migration cannot
    /// revive an old hidden choice. Identifiers are never trimmed or rewritten.
    @discardableResult
    public mutating func set(bundle: String, group: ItemVisibility,
                             excluding: Set<String> = [], observedBundles: Set<String> = []) -> Bool {
        let observed = observedSingleComponentBundles.union(
            observedBundles.filter(Self.isSingleComponentBundleSyntax))
        guard Self.accepts(bundle: bundle, excluding: excluding, observedBundles: observed) else { return false }
        choices[bundle] = group
        if Self.isSingleComponentBundleSyntax(bundle), observed.contains(bundle) {
            observedSingleComponentBundles.insert(bundle)
        }
        return true
    }

    /// Import only unanimous old item choices for an exact bundle. Different
    /// hidden categories remain different intent; neither is guessed to win.
    /// A newer native choice always takes precedence, including `.visible`.
    @discardableResult
    public mutating func migrate(saved: ItemRuleBook,
                                 excluding: Set<String> = [], observedBundles: Set<String> = []) -> Set<String> {
        let observed = observedSingleComponentBundles.union(
            observedBundles.filter(Self.isSingleComponentBundleSyntax))
        let eligible = saved.rules.values.filter {
            guard let bundle = $0.bundleIdentifier else { return false }
            return Self.accepts(bundle: bundle, excluding: excluding, observedBundles: observed)
        }
        let byBundle = Dictionary(grouping: eligible, by: { $0.bundleIdentifier! })
        var imported: Set<String> = []
        for (bundle, rules) in byBundle where choices[bundle] == nil {
            guard let first = rules.first?.visibility,
                  rules.allSatisfy({ $0.visibility == first }) else { continue }
            choices[bundle] = first
            if Self.isSingleComponentBundleSyntax(bundle), observed.contains(bundle) {
                observedSingleComponentBundles.insert(bundle)
            }
            imported.insert(bundle)
        }
        return imported
    }

    /// Intent eligibility only; the native backend must separately verify ownership.
    public static func accepts(bundle: String, excluding: Set<String>) -> Bool {
        accepts(bundle: bundle, excluding: excluding, observedBundles: [])
    }

    /// Eligibility for a bundle identifier read from a live application
    /// owner. The caller supplies the observation; persistence still records
    /// the single-component proof beside the selected group.
    public static func acceptsObserved(bundle: String, excluding: Set<String> = []) -> Bool {
        accepts(bundle: bundle, excluding: excluding, observedBundles: [bundle])
    }

    private static func accepts(bundle: String, excluding: Set<String>,
                                observedBundles: Set<String>) -> Bool {
        guard !excluding.contains(bundle), bundle.utf8.count <= 255 else { return false }
        let lower = bundle.lowercased()
        guard lower != "com.apple", !lower.hasPrefix("com.apple.") else { return false }
        let components = bundle.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }),
              components.count >= 2 || observedBundles.contains(bundle),
              isBundleIdentifierCharacters(bundle) else { return false }
        return true
    }

    private static func isSingleComponentBundleSyntax(_ bundle: String) -> Bool {
        guard !bundle.isEmpty, !bundle.contains("."), bundle.utf8.count <= 255 else { return false }
        return isBundleIdentifierCharacters(bundle)
    }

    private static func isBundleIdentifierCharacters(_ bundle: String) -> Bool {
        bundle.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
