/// Keeps departed owner epochs until their native visibility ownership can be
/// restored. Missing scan rows cannot erase this recovery intent. The caller
/// still performs live process checks and conditional preference restoration.
public struct NativeOwnerRecoveryQueue<Target: Hashable> {
    private struct Entry {
        var owners: [ObservedItemGroupHistory.Identity]
        var failed = false
    }

    private var entries: [Target: Entry] = [:]

    public init() {}

    public var pendingTargets: Set<Target> { Set(entries.keys) }
    public var failedTargets: Set<Target> { Set(entries.filter { $0.value.failed }.keys) }

    public mutating func register(target: Target, departedOwner: ObservedItemGroupHistory.Identity) {
        guard departedOwner.launchTime.isFinite, departedOwner.launchTime > 0 else { return }
        var entry = entries[target] ?? Entry(owners: [])
        if !entry.owners.contains(departedOwner) { entry.owners.append(departedOwner) }
        // A repeated discovery must never restart a failed recovery by itself.
        entries[target] = entry
    }

    public mutating func retainManagedTargets(_ targets: Set<Target>) {
        entries = entries.filter { targets.contains($0.key) }
    }

    /// Shared bundle settings remain untouched while any accepted item still
    /// has a live owner. A busy caller keeps all pending epochs for a later pass.
    public func readyTargets(canRestore: Bool, liveTargets: Set<Target>,
                             ownerIsCurrent: (ObservedItemGroupHistory.Identity) -> Bool) -> Set<Target> {
        guard canRestore else { return [] }
        return Set(entries.compactMap { target, entry in
            guard !entry.failed, !liveTargets.contains(target), !entry.owners.isEmpty,
                  entry.owners.allSatisfy({ !ownerIsCurrent($0) }) else { return nil }
            return target
        })
    }

    public mutating func recordFailure(target: Target) {
        entries[target]?.failed = true
    }

    public mutating func complete(target: Target) {
        entries.removeValue(forKey: target)
    }
}
