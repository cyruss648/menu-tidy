import Foundation

/// A user's saved choice. Session choices need reassociation after restarting,
/// including choices that were verified during the previous run.
public struct PendingDraftRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var rule: ItemRule

    public var requiresReassociationAfterRestart: Bool { rule.id.hasPrefix("session:") }
}

/// Stores explicit user choices, never choices inferred from observations.
/// Session bindings deliberately never cross the Codable boundary. A saved
/// session choice needs an explicit association after this application restarts.
public struct PendingDraftStore: Codable, Sendable {
    public enum StoreError: Error, Equatable {
        case invalidIdentity
        case recordNotFound
        case targetHasDraft
    }

    /// Pending or unassociated choices; excludes verified choices with a live owner.
    public private(set) var records: [PendingDraftRecord] = []
    private var sessionBindings: [UUID: ObservedItemGroupHistory.Identity] = [:]
    // Applied session rules are not persisted by the stable rule store. Keep
    // their choices here without presenting them as pending during this run.
    // A later edit can temporarily overlay the same record ID in `records`.
    private var verifiedSessionChoices: [UUID: PendingDraftRecord] = [:]
    private enum CodingKeys: String, CodingKey { case records }

    public init() {}

    /// Explicit import of backed-up choices. Session records start unbound;
    /// even their original session IDs are not treated as live identities.
    public init(unassociatedRules: [ItemRule]) throws {
        guard Set(unassociatedRules.map(\.id)).count == unassociatedRules.count,
              unassociatedRules.allSatisfy({ Self.isSupportedID($0.id) }) else { throw StoreError.invalidIdentity }
        records = unassociatedRules.map { PendingDraftRecord(id: UUID(), rule: $0) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([PendingDraftRecord].self, forKey: .records)
        guard Set(decoded.map(\.id)).count == decoded.count,
              Set(decoded.map(\.rule.id)).count == decoded.count,
              decoded.allSatisfy({ Self.isSupportedID($0.rule.id) }) else {
            throw DecodingError.dataCorruptedError(forKey: .records, in: container,
                debugDescription: "Draft records require unique record IDs and unique target IDs.")
        }
        records = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(savedRecords, forKey: .records)
    }

    public func record(for itemID: String, sessionIdentity: ObservedItemGroupHistory.Identity?) -> PendingDraftRecord? {
        if itemID.hasPrefix("item:") {
            return records.first { $0.rule.id == itemID && !$0.requiresReassociationAfterRestart }
        }
        guard let sessionIdentity, sessionIdentity.id == itemID, Self.isValidSession(sessionIdentity) else { return nil }
        return records.first { $0.requiresReassociationAfterRestart && sessionBindings[$0.id] == sessionIdentity }
    }

    @discardableResult
    public mutating func set(_ rule: ItemRule, sessionIdentity: ObservedItemGroupHistory.Identity?) throws -> UUID {
        try validate(rule, sessionIdentity: sessionIdentity)
        if let verified = verifiedSessionChoices.values.first(where: {
            $0.rule.id == rule.id && sessionBindings[$0.id] == sessionIdentity
        }) {
            let choice = PendingDraftRecord(id: verified.id, rule: rule)
            records.removeAll { $0.id == verified.id }
            if rule.visibility == verified.rule.visibility {
                // Returning to the applied category cancels only the edit;
                // the previously verified choice must still survive restart.
                verifiedSessionChoices[verified.id] = choice
            } else {
                records.append(choice)
            }
            return verified.id
        }
        if let existing = record(for: rule.id, sessionIdentity: sessionIdentity),
           let index = records.firstIndex(where: { $0.id == existing.id }) {
            records[index].rule = rule
            return existing.id
        }
        // An old unbound session ID is not permission to reattach it or create
        // another copy. Explicit reassociation is the only way to reuse it.
        guard !savedRecords.contains(where: { $0.rule.id == rule.id }) else { throw StoreError.targetHasDraft }
        let id = UUID()
        records.append(PendingDraftRecord(id: id, rule: rule))
        if rule.id.hasPrefix("session:") { sessionBindings[id] = sessionIdentity }
        return id
    }

    /// Called only after a user explicitly selects a current target. It keeps
    /// the record identity and desired category; an existing target edit wins.
    public mutating func reassociate(id: UUID, to target: ItemRule,
                                     sessionIdentity: ObservedItemGroupHistory.Identity?) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw StoreError.recordNotFound }
        try validate(target, sessionIdentity: sessionIdentity)
        if savedRecords.contains(where: { $0.rule.id == target.id && $0.id != id }) {
            throw StoreError.targetHasDraft
        }
        let choice = records[index].rule.visibility
        records[index].rule = ItemRule(id: target.id, name: target.name,
            bundleIdentifier: target.bundleIdentifier, visibility: choice)
        // Explicitly moving a choice to another target or owner transfers the
        // record, not the old target's verification. Same-owner edits retain
        // their applied baseline so cancelling them remains reversible.
        if verifiedSessionChoices[id]?.rule.id != target.id || sessionBindings[id] != sessionIdentity {
            verifiedSessionChoices.removeValue(forKey: id)
        }
        sessionBindings.removeValue(forKey: id)
        if target.id.hasPrefix("session:") { sessionBindings[id] = sessionIdentity }
    }

    /// Discards an edit, retaining its applied session baseline when present.
    /// A retained choice with no pending edit can also be explicitly forgotten.
    public mutating func remove(id: UUID) {
        let removesEdit = records.contains { $0.id == id }
        records.removeAll { $0.id == id }
        if removesEdit && verifiedSessionChoices[id] != nil { return }
        verifiedSessionChoices.removeValue(forKey: id)
        sessionBindings.removeValue(forKey: id)
    }

    /// Explicitly forget all saved choices of one exact application, including
    /// unassociated drafts and verified session baselines. Callers must first
    /// exclude every live sibling and explain this application-wide scope.
    public mutating func removeAll(bundleIdentifier: String) {
        let ids = Set(savedRecords.filter { $0.rule.bundleIdentifier == bundleIdentifier }.map(\.id))
        records.removeAll { ids.contains($0.id) }
        for id in ids {
            verifiedSessionChoices.removeValue(forKey: id)
            sessionBindings.removeValue(forKey: id)
        }
    }

    /// A successful subset must not discard the remaining choices. Unknown or
    /// mismatching results never satisfy an edit.
    public mutating func removeVerified(_ rule: ItemRule,
                                       sessionIdentity: ObservedItemGroupHistory.Identity?) {
        guard let record = record(for: rule.id, sessionIdentity: sessionIdentity),
              record.rule.visibility == rule.visibility else { return }
        if record.requiresReassociationAfterRestart {
            verifiedSessionChoices[record.id] = record
            records.removeAll { $0.id == record.id }
        } else {
            remove(id: record.id)
        }
    }

    public mutating func retainSessionBindings(where isCurrent: (ObservedItemGroupHistory.Identity) -> Bool) {
        sessionBindings = sessionBindings.filter { isCurrent($0.value) }
        for record in verifiedSessionChoices.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
            where sessionBindings[record.id] == nil {
            if !records.contains(where: { $0.id == record.id }) { records.append(record) }
            verifiedSessionChoices.removeValue(forKey: record.id)
        }
    }

    private var savedRecords: [PendingDraftRecord] {
        let pendingIDs = Set(records.map(\.id))
        return records + verifiedSessionChoices.values
            .filter { !pendingIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func validate(_ rule: ItemRule, sessionIdentity: ObservedItemGroupHistory.Identity?) throws {
        guard Self.isSupportedID(rule.id) else { throw StoreError.invalidIdentity }
        if rule.id.hasPrefix("session:") {
            guard let sessionIdentity, Self.isValidSession(sessionIdentity),
                  sessionIdentity.id == rule.id,
                  sessionIdentity.bundleIdentifier == rule.bundleIdentifier else { throw StoreError.invalidIdentity }
        }
    }

    private static func isSupportedID(_ id: String) -> Bool {
        (id.hasPrefix("item:") && id.count > 5) || (id.hasPrefix("session:") && id.count > 8)
    }

    private static func isValidSession(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        identity.id.hasPrefix("session:") && identity.pid > 0 && identity.launchTime.isFinite && identity.launchTime > 0
    }
}
