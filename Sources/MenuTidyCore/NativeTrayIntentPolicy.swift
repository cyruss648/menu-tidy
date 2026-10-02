/// Reconciles legacy item intent with an application-wide native switch.
/// Explicit native choices always win; automatic confirmation must not choose
/// one of several conflicting old categories on the user's behalf.
public enum NativeTrayIntentPolicy {
    /// Loading an old applied rule must not mask a newer pending edit. Do not
    /// promote unassociated drafts to application intent during startup either.
    public static func migratingSaved(saved: ItemRuleBook, drafts: [ItemRule],
                                      choices: NativeTrayChoices, excluding: Set<String> = []) -> NativeTrayChoices {
        let byBundle = Dictionary(grouping: Array(saved.rules.values) + drafts, by: \.bundleIdentifier)
        let conflicts = Set(byBundle.compactMap { bundle, rules in
            Set(rules.map(\.visibility)).count > 1 ? bundle : nil
        })
        let compatible = saved.rules.filter { _, rule in
            rule.bundleIdentifier.map { !conflicts.contains($0) } ?? false
        }
        var result = choices
        result.migrate(saved: ItemRuleBook(rules: compatible), excluding: excluding)
        return result
    }

    public static func hasLegacyConflict(bundle: String, saved: ItemRuleBook,
                                         drafts: [ItemRule], choices: NativeTrayChoices) -> Bool {
        guard choices.group(bundle: bundle) == nil else { return false }
        let groups = Set(effectiveRules(saved: saved, drafts: drafts).rules.values
            .filter { $0.bundleIdentifier == bundle }.map(\.visibility))
        return groups.count > 1
    }

    public static func migratingConfirmed(_ confirmed: ItemRule, saved: ItemRuleBook,
                                           drafts: [ItemRule], choices: NativeTrayChoices,
                                           excluding: Set<String> = []) -> NativeTrayChoices {
        guard let bundle = confirmed.bundleIdentifier, choices.group(bundle: bundle) == nil else { return choices }
        let related = effectiveRules(saved: saved, drafts: drafts).rules.values
            .filter { $0.bundleIdentifier == bundle }
        guard related.allSatisfy({ $0.visibility == confirmed.visibility }) else { return choices }
        var result = choices
        var candidates = ItemRuleBook(rules: Dictionary(uniqueKeysWithValues: related.map { ($0.id, $0) }))
        candidates.set(confirmed)
        result.migrate(saved: candidates, excluding: excluding)
        return result
    }

    /// Application intent outlives session item IDs and their verified drafts.
    /// These rows represent saved choices only and never claim a live identity.
    public static func offlineRules(choices: NativeTrayChoices, representedBundles: Set<String>) -> [ItemRule] {
        choices.choices.keys.sorted().compactMap { bundle in
            guard !representedBundles.contains(bundle), let group = choices.group(bundle: bundle) else { return nil }
            return ItemRule(id: "native-app:" + bundle, name: bundle,
                bundleIdentifier: bundle, visibility: group)
        }
    }

    private static func effectiveRules(saved: ItemRuleBook, drafts: [ItemRule]) -> ItemRuleBook {
        var result = saved
        for draft in drafts { result.set(draft) }
        return result
    }
}
