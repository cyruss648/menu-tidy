import Foundation

/// Shared selection rules for counters and bulk actions. Discovery provides
/// current identities; this policy never associates an offline draft by name.
public enum TrayPlacementPolicy {
    /// Current choices control panel membership immediately. A visible choice
    /// that is still physically hidden remains reachable until restoration;
    /// always-hidden items require the explicit reveal-all panel in either case.
    public static func includesInPanel(group: ItemVisibility, verifiedGroup: ItemVisibility?,
                                       includeAlwaysHidden: Bool) -> Bool {
        let membership = group == .visible ? (verifiedGroup ?? group) : group
        return membership == .collapsible || (membership == .alwaysHidden && includeAlwaysHidden)
    }

    public struct Candidate: Sendable {
        public let id: String
        public let group: ItemVisibility
        public let isAvailable: Bool
        public let canMove: Bool
        public let hasUniqueIdentity: Bool
        public let isPending: Bool
        public let hasFailure: Bool
        public let needsIdentification: Bool
        public let isQueued: Bool

        public init(id: String, group: ItemVisibility, isAvailable: Bool = true, canMove: Bool = true,
                    hasUniqueIdentity: Bool = true, isPending: Bool, hasFailure: Bool = false,
                    needsIdentification: Bool = false, isQueued: Bool = false) {
            self.id = id
            self.group = group
            self.isAvailable = isAvailable
            self.canMove = canMove
            self.hasUniqueIdentity = hasUniqueIdentity
            self.isPending = isPending
            self.hasFailure = hasFailure
            self.needsIdentification = needsIdentification
            self.isQueued = isQueued
        }

        public var isOutstanding: Bool {
            isAvailable && canMove && hasUniqueIdentity && (isPending || hasFailure || isQueued)
        }
    }

    public enum Action: Sendable { case applyPending, retryFailed }

    public static func candidates(_ candidates: [Candidate], for action: Action) -> [Candidate] {
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            counts[$0.id] == 1 && $0.isOutstanding && !$0.isQueued && !$0.needsIdentification &&
                (action == .applyPending || $0.hasFailure)
        }
    }

    public struct DraftTarget: Sendable {
        public let rule: ItemRule
        public let identity: ObservedItemGroupHistory.Identity?

        public init(rule: ItemRule, identity: ObservedItemGroupHistory.Identity?) {
            self.rule = rule
            self.identity = identity
        }
    }

    /// Prepare the complete set before committing it. In particular, changing
    /// one native app icon must replace live sibling drafts together while an
    /// unassociated session draft remains untouched and cannot be guessed.
    public static func replacingDrafts(in store: PendingDraftStore, targets: [DraftTarget],
                                      group: ItemVisibility) throws -> PendingDraftStore {
        var updated = store
        for target in targets {
            try updated.set(ItemRule(id: target.rule.id, name: target.rule.name,
                bundleIdentifier: target.rule.bundleIdentifier, visibility: group),
                sessionIdentity: target.identity)
        }
        return updated
    }

    public struct DraftAssociation: Sendable {
        public let drafts: PendingDraftStore
        public let nativeChoices: NativeTrayChoices?
        public let affectedIDs: Set<String>
    }

    /// Explicit association preserves the offline record's category. On native
    /// app switches it must also supersede the application choice and every
    /// currently verified sibling draft. Everything is prepared on copies, so
    /// a conflicting sibling cannot consume or overwrite the original record.
    public static func reassociatingDraft(in store: PendingDraftStore, id: UUID, to target: DraftTarget,
                                         currentTargets: [DraftTarget], nativeChoices: NativeTrayChoices?,
                                         excluding: Set<String> = []) throws -> DraftAssociation {
        var updated = store
        try updated.reassociate(id: id, to: target.rule, sessionIdentity: target.identity)
        guard let associated = updated.record(for: target.rule.id, sessionIdentity: target.identity) else {
            throw PendingDraftStore.StoreError.invalidIdentity
        }
        var choices = nativeChoices
        let shared = target.rule.bundleIdentifier.map {
            choices?.set(bundle: $0, group: associated.rule.visibility, excluding: excluding) == true
        } == true
        let affected = shared ? currentTargets.filter {
            $0.rule.bundleIdentifier == target.rule.bundleIdentifier && $0.rule.id != target.rule.id
        } + [target] : [target]
        updated = try replacingDrafts(in: updated, targets: affected, group: associated.rule.visibility)
        return DraftAssociation(drafts: updated, nativeChoices: shared ? choices : nil,
            affectedIDs: Set(affected.map { $0.rule.id }))
    }
}
