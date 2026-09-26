import Foundation

/// Foreground expiry must never invalidate the independent, bounded read that
/// confirms a position has been restored. Both phases still have a local limit.
public enum ManagementOperationBudget: Sendable {
    case foreground
    case cleanup

    public func deadline(startedUptime: TimeInterval, timeLimit: TimeInterval,
                         operationDeadline: TimeInterval?, outerDeadline: TimeInterval? = nil) -> TimeInterval {
        min(startedUptime + timeLimit, outerDeadline ?? .infinity,
            self == .foreground ? (operationDeadline ?? .infinity) : .infinity)
    }
}

/// One foreground request has one deadline. Cleanup deliberately lives outside
/// this budget: cancelling work must not abandon a pending position recovery.
public enum ManagementOperationKind: Sendable {
    case refresh
    case refreshImages
    case apply

    public func timeLimit(itemCount: Int) -> TimeInterval {
        switch self {
        case .refresh: 6
        case .refreshImages: 30
        case .apply: min(20, max(12, 8 + Double(max(0, itemCount)) * 1.5))
        }
    }
}

/// A token fences late completion, while uptime keeps clock changes from
/// extending a request. Cancellation marks the request; only awaited cleanup
/// finishing may release the foreground operation.
public struct ManagementOperationState: Sendable {
    public struct Active: Sendable {
        public let id: UUID
        public let kind: ManagementOperationKind
        public let startedAt: Date
        public let startedUptime: TimeInterval
        public let deadline: TimeInterval
        public fileprivate(set) var cancellationRequested = false
    }

    public private(set) var active: Active?

    public init() {}

    @discardableResult
    public mutating func begin(kind: ManagementOperationKind, itemCount: Int = 0,
                               at date: Date, uptime: TimeInterval) -> UUID {
        let id = UUID()
        active = Active(id: id, kind: kind, startedAt: date, startedUptime: uptime,
                        deadline: uptime + kind.timeLimit(itemCount: itemCount))
        return id
    }

    @discardableResult
    public mutating func requestCancellation() -> Bool {
        guard active != nil, active?.cancellationRequested == false else { return false }
        active?.cancellationRequested = true
        return true
    }

    @discardableResult
    public mutating func finish(token: UUID) -> Bool {
        guard active?.id == token else { return false }
        active = nil
        return true
    }

    public func hasExpired(uptime: TimeInterval) -> Bool {
        active.map { uptime >= $0.deadline } ?? false
    }

    public func elapsed(uptime: TimeInterval) -> TimeInterval {
        active.map { max(0, uptime - $0.startedUptime) } ?? 0
    }
}
