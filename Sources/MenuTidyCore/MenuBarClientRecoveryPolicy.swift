/// A disabled AX client connection is different from an application without
/// a status item. Recovery needs repeated failures for the same process epoch
/// and independent, current evidence from a fresh client before relaunching.
public struct MenuBarClientRecoveryPolicy: Sendable {
    public struct Owner: Hashable, Sendable {
        public let pid: Int32
        public let bundleIdentifier: String
        public let launchTime: Double

        public init(pid: Int32, bundleIdentifier: String, launchTime: Double) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.launchTime = launchTime
        }

        public var isValid: Bool {
            pid > 0 && launchTime.isFinite && launchTime > 0 &&
                NativeTrayChoices.acceptsObserved(bundle: bundleIdentifier)
        }
    }

    public static let apiDisabledError: Int32 = -25211
    private var failures: [Owner: Int] = [:]
    private var checked: Set<Owner> = []

    public init() {}

    public mutating func reconcile(current: Set<Owner>, observed: Set<Owner>,
                                   queried: Set<Owner>, errors: [Owner: Int32]) {
        let current = Set(current.filter(\.isValid))
        failures = failures.filter { current.contains($0.key) && !observed.contains($0.key) }
        checked.formIntersection(current.subtracting(observed))
        for owner in queried.intersection(current).subtracting(observed) {
            if errors[owner] == Self.apiDisabledError {
                failures[owner] = min(3, (failures[owner] ?? 0) + 1)
            } else {
                failures.removeValue(forKey: owner)
                checked.remove(owner)
            }
        }
    }

    public func hasDisabledConnection(_ owner: Owner) -> Bool { failures[owner] != nil }

    public var nextAutomaticCandidate: Owner? {
        failures.keys.filter { failures[$0] == 3 && !checked.contains($0) }
            .sorted { $0.pid < $1.pid }.first
    }

    public mutating func markChecked(_ owner: Owner) { checked.insert(owner) }
}

/// Only a complete canonical census and a stable positive hit in the fresh
/// client can justify recycling the old client. This never supplies an AX
/// identity, geometry or action permission to the normal item inventory.
public struct MenuBarClientProbeEvidence: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        let role: String?
        let sourceOwnerMatches: Bool?
        let inCurrentChildren: Bool?
        let positiveSize: Bool?
        let frameStable: Bool?
        let centerHit: Bool?
    }

    let event: String?
    let ownerPID: Int32?
    let ownerEpoch: Double?
    let ownerCount: Int?
    let ownerCurrent: Bool?
    let ownerCurrentAtEnd: Bool?
    let censusComplete: Bool?
    let targetItemCount: Int?
    let items: [Item]?

    public func confirmsVisibleItem(for owner: MenuBarClientRecoveryPolicy.Owner) -> Bool {
        guard event == "sample", owner.isValid,
              ownerPID == owner.pid, ownerEpoch == owner.launchTime,
              ownerCount == 1, ownerCurrent == true, ownerCurrentAtEnd == true,
              censusComplete == true, let items, !items.isEmpty, items.count <= 64,
              targetItemCount == items.count else { return false }
        return items.contains {
            $0.role == "AXMenuBarItem" && $0.sourceOwnerMatches == true &&
                $0.inCurrentChildren == true && $0.positiveSize == true &&
                $0.frameStable == true && $0.centerHit == true
        }
    }
}
