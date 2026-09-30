import Foundation

/// Only actual pending work keeps the application timer alive. Deadlines use
/// uptime rather than wall time, and an overdue deadline never creates a spin.
public enum BackgroundMaintenanceSchedule {
    public static let interactionInterval: TimeInterval = 1
    public static let permissionInterval: TimeInterval = 3

    public static func nextDelay(at now: TimeInterval, autoCollapseDue: TimeInterval?,
                                 permissionDue: TimeInterval?, passiveCaptureDue: TimeInterval?,
                                 recoveryDue: TimeInterval?) -> TimeInterval? {
        guard now.isFinite else { return nil }
        let deadlines = [autoCollapseDue, permissionDue, passiveCaptureDue, recoveryDue]
            .compactMap { $0 }.filter(\.isFinite)
        guard let deadline = deadlines.min() else { return nil }
        return max(0.05, deadline - now)
    }

    public static func tolerance(for delay: TimeInterval) -> TimeInterval {
        min(1, max(0, delay * 0.1))
    }
}
