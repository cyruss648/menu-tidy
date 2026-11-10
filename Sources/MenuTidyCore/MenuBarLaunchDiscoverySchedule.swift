import Foundation

/// Launch notifications can arrive before an application creates its status
/// item. Retry only reads, for a bounded window and an exact process lifetime.
public struct MenuBarLaunchDiscoverySchedule<Owner: Hashable & Sendable>: Sendable {
    private var attempts: [Owner: [TimeInterval]] = [:]

    public init() {}

    public mutating func register(_ owner: Owner, at now: TimeInterval) {
        guard now.isFinite, attempts[owner] == nil else { return }
        attempts[owner] = [1, 3, 7, 15].map { now + $0 }
    }

    public var targets: Set<Owner> { Set(attempts.keys) }
    public var nextAttemptAt: TimeInterval? { attempts.values.compactMap(\.first).min() }

    public mutating func consumeDue(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        var due = false
        for (owner, deadlines) in attempts {
            guard let first = deadlines.first, first <= now else { continue }
            due = true
            let remaining = deadlines.filter { $0 > now }
            attempts[owner] = remaining.isEmpty ? nil : remaining
        }
        return due
    }

    public mutating func reconcile(current: Set<Owner>, observed: Set<Owner>) {
        attempts = attempts.filter { current.contains($0.key) && !observed.contains($0.key) }
    }
}
