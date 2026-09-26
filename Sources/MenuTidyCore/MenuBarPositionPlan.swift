/// A single-key menu-bar preference change. Larger weights are visually left
/// of smaller weights. Equal weights form one group; this plan places the
/// source strictly to one side of the entire anchor group without relabeling peers.
public struct MenuBarPositionPlan: Equatable, Sendable {
    public enum Placement: Equatable, Sendable { case before, after }
    public enum PlanError: Error, Equatable, Sendable {
        case emptyPositions
        case missingKey(String)
        case sameSourceAndAnchor
        case nonFiniteValue(String)
        case noFiniteGap
        case stalePlan
        case invalidTransaction
    }

    public let sourceKey: String
    public let anchorKey: String
    public let originalWeight: Double
    public let writtenWeight: Double
    public let anchorWeight: Double
    public let upperWeight: Double?
    public let lowerWeight: Double?
    public let placement: Placement

    public var originalValues: [String: Double] { [sourceKey: originalWeight] }
    public var writtenValues: [String: Double] { [sourceKey: writtenWeight] }

    public static func moving(_ key: String, before anchor: String,
                              positions: [String: Double]) throws -> MenuBarPositionPlan {
        guard !positions.isEmpty else { throw PlanError.emptyPositions }
        try validateNumbers(positions)
        guard key != anchor else { throw PlanError.sameSourceAndAnchor }
        guard let original = positions[key] else { throw PlanError.missingKey(key) }
        guard let lower = positions[anchor] else { throw PlanError.missingKey(anchor) }
        // Exclude the source's old slot. Duplicate upper weights still describe
        // one scalar boundary, not multiple ordinal destinations.
        let upper = positions.filter { $0.key != key && $0.value > lower }.values.min()
        let candidate: Double
        if let upper {
            let span = upper - lower
            let midpoint = span.isFinite ? lower + span / 2 : lower / 2 + upper / 2
            candidate = midpoint > lower && midpoint < upper ? midpoint : lower.nextUp
            guard candidate.isFinite, candidate > lower, candidate < upper else { throw PlanError.noFiniteGap }
        } else {
            candidate = lower.nextUp
            guard candidate.isFinite, candidate > lower else { throw PlanError.noFiniteGap }
        }
        return MenuBarPositionPlan(sourceKey: key, anchorKey: anchor, originalWeight: original,
            writtenWeight: candidate, anchorWeight: lower, upperWeight: upper,
            lowerWeight: nil, placement: .before)
    }

    /// Place the source visually right of the anchor's entire equal-weight
    /// group. The source's previous position never supplies its own boundary.
    public static func moving(_ key: String, after anchor: String,
                              positions: [String: Double]) throws -> MenuBarPositionPlan {
        guard !positions.isEmpty else { throw PlanError.emptyPositions }
        try validateNumbers(positions)
        guard key != anchor else { throw PlanError.sameSourceAndAnchor }
        guard let original = positions[key] else { throw PlanError.missingKey(key) }
        guard let upper = positions[anchor] else { throw PlanError.missingKey(anchor) }
        let lower = positions.filter { $0.key != key && $0.value < upper }.values.max()
        let candidate: Double
        if let lower {
            let span = upper - lower
            let midpoint = span.isFinite ? lower + span / 2 : lower / 2 + upper / 2
            candidate = midpoint > lower && midpoint < upper ? midpoint : upper.nextDown
            guard candidate.isFinite, candidate > lower, candidate < upper else { throw PlanError.noFiniteGap }
        } else {
            candidate = upper.nextDown
            guard candidate.isFinite, candidate < upper else { throw PlanError.noFiniteGap }
        }
        return MenuBarPositionPlan(sourceKey: key, anchorKey: anchor, originalWeight: original,
            writtenWeight: candidate, anchorWeight: upper, upperWeight: nil,
            lowerWeight: lower, placement: .after)
    }

    /// Recheck the relevant interval against a fresh table. Unrelated changes
    /// are retained; changed source/anchor/gap evidence invalidates this plan.
    public func applying(to current: [String: Double]) throws -> [String: Double] {
        let fresh = try placement == .before
            ? Self.moving(sourceKey, before: anchorKey, positions: current)
            : Self.moving(sourceKey, after: anchorKey, positions: current)
        guard fresh == self else { throw PlanError.stalePlan }
        var result = current
        result[sourceKey] = writtenWeight
        return result
    }

    public struct RollbackPlan: Equatable, Sendable {
        public let restorations: [String: Double]
        public let alreadyRestoredKeys: Set<String>
        public let conflictedKeys: Set<String>
        public let missingKeys: Set<String>
    }

    /// Missing or externally changed keys are never recreated or overwritten.
    /// Callers must also preserve the original numeric representations on disk.
    public static func rollback(originalValues: [String: Double], writtenValues: [String: Double],
                                current: [String: Double]) throws -> RollbackPlan {
        guard !originalValues.isEmpty, Set(originalValues.keys) == Set(writtenValues.keys) else { throw PlanError.invalidTransaction }
        try validateNumbers(originalValues)
        try validateNumbers(writtenValues)
        try validateNumbers(current)
        var restorations: [String: Double] = [:]
        var already: Set<String> = []
        var conflicts: Set<String> = []
        var missing: Set<String> = []
        for (key, original) in originalValues {
            guard let actual = current[key] else { missing.insert(key); continue }
            if actual == original { already.insert(key) }
            else if actual == writtenValues[key] { restorations[key] = original }
            else { conflicts.insert(key) }
        }
        return RollbackPlan(restorations: restorations, alreadyRestoredKeys: already,
            conflictedKeys: conflicts, missingKeys: missing)
    }

    private static func validateNumbers(_ values: [String: Double]) throws {
        if let invalid = values.first(where: { !$0.value.isFinite }) { throw PlanError.nonFiniteValue(invalid.key) }
    }
}
