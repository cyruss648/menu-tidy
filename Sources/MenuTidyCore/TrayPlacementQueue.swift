import Foundation

/// Serializes native placement work while retaining the latest user choice for
/// every queued item. Persistence and the actual placement belong to the caller.
public struct TrayPlacementQueue: Sendable {
    public struct Request: Equatable, Sendable {
        public let token: UUID
        public let id: String
        public let desiredInTray: Bool
    }

    public private(set) var active: Request?
    private var pendingOrder: [String] = []
    private var pendingValues: [String: Bool] = [:]

    public init() {}

    /// Updating an already queued item preserves its first place in the FIFO.
    /// A new choice for the active item is queued separately; the active request
    /// remains an immutable description of the operation already in flight.
    public mutating func enqueue(id: String, desiredInTray: Bool) {
        if pendingValues[id] == nil { pendingOrder.append(id) }
        pendingValues[id] = desiredInTray
    }

    public var pendingIDs: [String] { pendingOrder }

    /// UI displays the newer queued choice while an older placement completes.
    /// nil means this queue has no intent for the item; consult saved rules then.
    public func desired(id: String) -> Bool? {
        if let pending = pendingValues[id] { return pending }
        return active.flatMap { $0.id == id ? $0.desiredInTray : nil }
    }

    /// Only one native placement may be claimed until its matching completion.
    public mutating func claimNext() -> Request? {
        guard active == nil, let id = pendingOrder.first,
              let desiredInTray = pendingValues[id] else { return nil }
        pendingOrder.removeFirst()
        pendingValues.removeValue(forKey: id)
        let request = Request(token: UUID(), id: id, desiredInTray: desiredInTray)
        active = request
        return request
    }

    /// Use on success, failure, or cancellation after awaited native cleanup.
    /// Failure does not enqueue a retry. Only a later explicit choice survives
    /// in pending, and an old completion cannot release a newer active request.
    @discardableResult
    public mutating func finish(token: UUID) -> Bool {
        guard active?.token == token else { return false }
        active = nil
        return true
    }

    /// Stops not-yet-started work without pretending the active operation ended.
    /// The caller must cancel and await that operation before finishing its token.
    public mutating func cancelAllPending() {
        pendingOrder.removeAll(keepingCapacity: true)
        pendingValues.removeAll(keepingCapacity: true)
    }
}
