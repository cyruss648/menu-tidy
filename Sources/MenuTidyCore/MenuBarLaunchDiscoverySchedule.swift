import Foundation

/// Launch notifications can arrive before an application creates its status
/// item. Retry only reads for an exact process lifetime. Ordinary launches use
/// a bounded window; startup recovery may opt into a low-frequency persistent
/// retry until the live process is observed or exits.
public struct MenuBarLaunchDiscoverySchedule<Owner: Hashable & Sendable>: Sendable {
    private var attempts: [Owner: [TimeInterval]] = [:]
    private var persistentAttempts: [Owner: TimeInterval] = [:]
    public let persistentRetryInterval: TimeInterval

    public init(persistentRetryInterval: TimeInterval = 60) {
        self.persistentRetryInterval = persistentRetryInterval.isFinite && persistentRetryInterval > 0
            ? persistentRetryInterval : 60
    }

    public mutating func register(_ owner: Owner, at now: TimeInterval) {
        guard now.isFinite, attempts[owner] == nil else { return }
        attempts[owner] = [1, 3, 7, 15].map { now + $0 }
    }

    /// Keep a startup owner in the discovery priority set after the bounded
    /// launch window. Re-registering the same process lifetime never moves its
    /// deadline forward.
    public mutating func registerPersistent(_ owner: Owner, at now: TimeInterval,
                                            initialDelay: TimeInterval = 30) {
        guard now.isFinite, persistentAttempts[owner] == nil else { return }
        let delay = initialDelay.isFinite && initialDelay > 0 ? initialDelay : persistentRetryInterval
        persistentAttempts[owner] = now + delay
    }

    public var targets: Set<Owner> { Set(attempts.keys).union(persistentAttempts.keys) }
    public var nextAttemptAt: TimeInterval? {
        [attempts.values.compactMap(\.first).min(), persistentAttempts.values.min()]
            .compactMap { $0 }.min()
    }

    public mutating func consumeDue(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        var due = false
        for (owner, deadlines) in attempts {
            guard let first = deadlines.first, first <= now else { continue }
            due = true
            let remaining = deadlines.filter { $0 > now }
            attempts[owner] = remaining.isEmpty ? nil : remaining
        }
        for (owner, deadline) in persistentAttempts where deadline <= now {
            due = true
            persistentAttempts[owner] = now + persistentRetryInterval
        }
        return due
    }

    public mutating func reconcile(current: Set<Owner>, observed: Set<Owner>) {
        attempts = attempts.filter { current.contains($0.key) && !observed.contains($0.key) }
        persistentAttempts = persistentAttempts.filter {
            current.contains($0.key) && !observed.contains($0.key)
        }
    }
}
