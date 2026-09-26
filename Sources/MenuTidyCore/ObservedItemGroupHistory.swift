/// Display-only history for partial menu-bar scans. It never supplies current
/// positions or evidence that a move has completed.
public struct ObservedItemGroupHistory {
    public struct Identity: Equatable, Sendable {
        public let id: String
        public let pid: Int32
        public let bundleIdentifier: String?
        public let launchTime: Double

        public init(id: String, pid: Int32, bundleIdentifier: String?, launchTime: Double) {
            self.id = id
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.launchTime = launchTime
        }

        fileprivate var hasKnownLifetime: Bool { launchTime.isFinite && launchTime > 0 }
    }

    private struct Entry {
        let identity: Identity
        let visibility: ItemVisibility
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func remember(_ visibility: ItemVisibility, for identity: Identity, frozen: Bool) {
        guard !frozen, identity.hasKnownLifetime else { return }
        entries[identity.id] = Entry(identity: identity, visibility: visibility)
    }

    public func visibility(for identity: Identity) -> ItemVisibility? {
        guard identity.hasKnownLifetime, let entry = entries[identity.id], entry.identity == identity else { return nil }
        return entry.visibility
    }

    public mutating func retainOwners(where isCurrent: (Identity) -> Bool) {
        entries = entries.filter { isCurrent($0.value.identity) }
    }

    public mutating func remove(id: String) {
        entries.removeValue(forKey: id)
    }
}
