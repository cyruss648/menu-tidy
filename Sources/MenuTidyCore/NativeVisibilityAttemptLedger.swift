/// One foreground batch can observe several icons controlled by one native
/// switch. A target stays claimed after failure as well as success; only a new
/// explicit batch gets a fresh ledger. Unmanaged positive-only observations
/// do not claim a shared target because each icon needs its own evidence.
public struct NativeVisibilityAttemptLedger<Target: Hashable & Sendable>: Sendable {
    private var attempted: Set<Target> = []

    public init() {}

    public mutating func claim(_ target: Target) -> Bool {
        attempted.insert(target).inserted
    }
}
