/// Separates a finished per-item capability check from interruption of the
/// check itself. A known unsupported item may be excluded; an unchecked item
/// never becomes unsupported merely because the request ran out of time.
public struct BatchApplicationPlan: Sendable {
    public enum StopReason: Sendable {
        case timedOut
        case cancelled
    }

    public let requestedIDs: [String]
    public let supportedIDs: [String]
    public let blockedIDs: [String]
    public let uninspectedIDs: [String]
    public let issues: [String: String]
    public let stopReason: StopReason?

    /// Reject overlapping or unrelated results so stale checks cannot grant
    /// permission to apply a different request. Result arrays retain UI order.
    public init?(requestedIDs: [String], supportedIDs: Set<String>,
                 issues: [String: String], stopReason: StopReason? = nil) {
        let requested = Set(requestedIDs)
        let blocked = Set(issues.keys)
        guard requested.count == requestedIDs.count,
              !requested.contains(""),
              supportedIDs.isSubset(of: requested), blocked.isSubset(of: requested),
              supportedIDs.isDisjoint(with: blocked) else { return nil }
        self.requestedIDs = requestedIDs
        self.supportedIDs = requestedIDs.filter { supportedIDs.contains($0) }
        blockedIDs = requestedIDs.filter { blocked.contains($0) }
        uninspectedIDs = requestedIDs.filter { !supportedIDs.contains($0) && !blocked.contains($0) }
        self.issues = issues
        self.stopReason = stopReason
    }

    public var isPreflightComplete: Bool { uninspectedIDs.isEmpty }

    /// A partial capability result is actionable only after every requested
    /// item was inspected. Stopping always wins, even after the final check.
    public var actionableIDs: [String] {
        stopReason == nil && isPreflightComplete ? supportedIDs : []
    }
}
