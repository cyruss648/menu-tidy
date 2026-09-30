/// A small deterministic LRU with both entry and cost limits. Presentation
/// values remain confined to the caller's actor; eviction changes no rules.
public struct BoundedValueCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
    }
    public let countLimit: Int
    public let costLimit: Int
    public private(set) var totalCost = 0
    public var count: Int { entries.count }
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    public init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }

    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.value
    }

    public mutating func insert(_ value: Value, for key: Key, cost: Int) {
        guard countLimit > 0, cost >= 0, cost <= costLimit else { return }
        remove(key)
        // Subtraction avoids overflow even when the supplied limits are Int.max.
        while entries.count >= countLimit || totalCost > costLimit - cost {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
        entries[key] = Entry(value: value, cost: cost)
        totalCost += cost
        recency.append(key)
    }

    public mutating func removeAll() {
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
    }

    private mutating func remove(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { totalCost -= removed.cost }
        recency.removeAll { $0 == key }
    }
}
