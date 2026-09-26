/// Adopts verified native menu-bar positions without discarding GUI choices.
/// Geometry verification and persistent/session storage remain the caller's job.
public enum ManualArrangementRules {
    public static func reconcile(
        saved: ItemRuleBook,
        drafts: ItemRuleBook,
        observed: [ItemRule]
    ) -> (saved: ItemRuleBook, drafts: ItemRuleBook) {
        var occurrences: [String: Int] = [:]
        for rule in observed {
            occurrences[rule.id, default: 0] += 1
        }

        var updatedSaved = saved
        var updatedDrafts = drafts
        for rule in observed where occurrences[rule.id] == 1 {
            let previousSaved = saved.rule(for: rule.id)
            let previousDraft = drafts.rule(for: rule.id)
            // Name/metadata updates do not constitute an edited classification.
            // A draft with no previous saved rule is an explicit new GUI choice.
            let hasExplicitDraft = previousDraft.map {
                $0.visibility != previousSaved?.visibility
            } ?? false
            updatedSaved.set(rule)
            if !hasExplicitDraft {
                updatedDrafts.set(rule)
            }
        }
        return (updatedSaved, updatedDrafts)
    }

    /// A native arrangement has already established its own intent. GUI drafts
    /// may still be displayed, but cannot replace those observed categories.
    /// Require complete, unique current rows before sending either intent to
    /// the background backend; missing or changed ownership remains unknown.
    public static func applicationRules(
        requestedIDs: [String], displayed: [ItemRule], confirmed: [ItemRule]? = nil
    ) -> [ItemRule]? {
        let requested = Set(requestedIDs)
        guard !requested.isEmpty, requested.count == requestedIDs.count,
              displayed.count == requested.count,
              Set(displayed.map(\.id)) == requested else { return nil }
        let available = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
        let intended = confirmed ?? displayed
        guard intended.count == requested.count,
              Set(intended.map(\.id)) == requested,
              intended.allSatisfy({ rule in
                  available[rule.id]?.bundleIdentifier == rule.bundleIdentifier
              }) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: intended.map { ($0.id, $0) })
        return requestedIDs.compactMap { byID[$0] }
    }

}
