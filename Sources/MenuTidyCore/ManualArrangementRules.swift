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
}
