/// One monotonic deadline for an entire accessibility inventory. Repeated
/// owners and descendants share it; a slow read never receives a fresh budget.
public struct AccessibilityScanBudget: Sendable {
    public let deadline: Double

    public init(startedAt: Double, duration: Double = 3) {
        deadline = startedAt + max(0, duration)
    }

    public func timeout(at now: Double, cancelled: Bool = false) -> Double? {
        guard !cancelled, now.isFinite, deadline.isFinite, now < deadline else { return nil }
        return min(0.12, deadline - now)
    }

    /// Partial inventories must not replace a previously complete inventory.
    public func canPublish(at now: Double, cancelled: Bool = false) -> Bool {
        timeout(at: now, cancelled: cancelled) != nil
    }
}
