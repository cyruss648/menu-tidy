/// A process identity includes its launch epoch, so a reused PID is a new
/// discovery target. Planning never acknowledges work: only a completed scan
/// consumes the selected discovery batch.
public struct MenuBarScanSchedule<Owner: Hashable & Sendable>: Sendable {
    private var known: Set<Owner> = []
    private var pending: [Owner] = []
    private var rotation = 0
    public let batchSize: Int

    public init(batchSize: Int = 8) { self.batchSize = max(1, batchSize) }

    public mutating func plan(current: [Owner], priority: Set<Owner>, discover: Bool) -> [Owner] {
        let currentSet = Set(current)
        known.formIntersection(currentSet)
        pending.removeAll { !currentSet.contains($0) }
        let newcomers = current.filter { !known.contains($0) }
        // New launches go ahead of the remaining startup backlog.
        pending = newcomers + pending
        known.formUnion(currentSet)
        var selected = current.filter { priority.contains($0) }
        guard discover else { return selected }
        let backlog = pending.filter { !priority.contains($0) }
        if !backlog.isEmpty {
            selected.append(contentsOf: backlog.prefix(batchSize))
        } else {
            // Manual refresh can discover an icon created after its owner's
            // original scan without walking every negative owner again.
            let other = current.filter { !priority.contains($0) }
            if !other.isEmpty {
                selected.append(contentsOf: (0..<min(batchSize, other.count)).map {
                    other[(rotation + $0) % other.count]
                })
            }
        }
        var unique: Set<Owner> = []
        return selected.filter { unique.insert($0).inserted }
    }

    public mutating func complete(scanned: [Owner]) {
        let scannedSet = Set(scanned)
        pending.removeAll { scannedSet.contains($0) }
        rotation += batchSize
    }

    public var hasPendingDiscovery: Bool { !pending.isEmpty }
}
