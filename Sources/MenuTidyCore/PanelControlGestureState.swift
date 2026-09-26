/// Resolves a status control press from its original intent, independently of
/// passive panel dismissal and asynchronous delivery of global mouse events.
public struct PanelControlGestureState: Sendable {
    public enum Phase: Sendable { case down, up }
    public enum Decision: Equatable, Sendable { case show, close, ignore }

    public struct MouseEvent: Equatable, Sendable {
        public let button: Int
        public let phase: Phase
        public let timestamp: Double
        public let eventNumber: Int

        public init(button: Int, phase: Phase, timestamp: Double, eventNumber: Int) {
            self.button = button
            self.phase = phase
            self.timestamp = timestamp
            self.eventNumber = eventNumber
        }
    }

    private struct Presentation: Sendable {
        let timestamp: Double
        let isPresented: Bool
        let generation: UInt64
    }
    private struct Press: Sendable {
        let down: MouseEvent
        let presentation: Presentation?
        var up: MouseEvent?
    }

    public private(set) var isPresented = false
    public private(set) var generation: UInt64 = 0
    private var history = [Presentation(timestamp: 0, isPresented: false, generation: 0)]
    private var presses: [Int: Press] = [:]
    private var controlPresses: [Int: Press] = [:]
    private var recentUps: [Int: [MouseEvent]] = [:]
    private var currentPresentationTime: Double?

    public init() {}

    public mutating func presentationChanged(isPresented: Bool, at timestamp: Double) {
        guard timestamp.isFinite, timestamp >= (history.last?.timestamp ?? 0),
              self.isPresented != isPresented else { return }
        self.isPresented = isPresented
        if isPresented {
            generation &+= 1
            currentPresentationTime = timestamp
        }
        history.append(Presentation(timestamp: timestamp, isPresented: isPresented, generation: generation))
        // Active presses retain their own original presentation even after pruning.
        if history.count > 128 { history.removeFirst(history.count - 128) }
    }

    public mutating func observe(_ event: MouseEvent) {
        guard valid(event) else { return }
        switch event.phase {
        case .down:
            if let current = presses[event.button], current.down == event { return }
            guard event.timestamp > (presses[event.button]?.down.timestamp ?? -1) else { return }
            // The global up copy may precede delivery of the down copy. Rebuild
            // their event-time order instead of using callback arrival order.
            let up = recentUps[event.button]?.first { $0.timestamp >= event.timestamp }
            presses[event.button] = Press(down: event, presentation: presentation(at: event.timestamp), up: up)
            controlPresses[event.button] = nil
        case .up:
            if recentUps[event.button]?.contains(event) != true {
                var ups = recentUps[event.button] ?? []
                ups.append(event)
                ups.sort { $0.timestamp < $1.timestamp }
                recentUps[event.button] = Array(ups.suffix(16))
            }
            if var press = presses[event.button], event.timestamp >= press.down.timestamp,
               press.up == nil || press.up == event {
                press.up = event
                presses[event.button] = press
            }
        }
    }

    /// Only the control's own mouse-down action arms a control press. Observing
    /// an unrelated outside click cannot make a later AXPress consume its intent.
    public mutating func beginControlPress(_ event: MouseEvent) {
        guard event.phase == .down, valid(event) else { return }
        observe(event)
        guard let press = presses[event.button], press.down == event else { return }
        controlPresses[event.button] = press
    }

    public func hasControlPress(for event: MouseEvent) -> Bool {
        guard event.phase == .up, valid(event), let press = controlPresses[event.button],
              event.timestamp >= press.down.timestamp else { return false }
        return presses[event.button]?.down == press.down && (presses[event.button]?.up == nil || presses[event.button]?.up == event)
    }

    public mutating func controlRelease(_ event: MouseEvent?) -> Decision {
        // Accessibility/keyboard activation has no control-down ticket. Never
        // borrow NSApplication.currentEvent's unrelated previous mouse click.
        guard let event else {
            controlPresses.removeAll()
            return isPresented ? .close : .show
        }
        guard hasControlPress(for: event), let press = controlPresses.removeValue(forKey: event.button),
              let original = press.presentation else { return .ignore }
        observe(event)
        // A separate GUI/keyboard action may have opened a newer presentation
        // while the mouse was held. Its panel belongs to that later action.
        guard generation == original.generation else { return .ignore }
        return original.isPresented ? .close : .show
    }

    public func shouldDismiss(for event: MouseEvent) -> Bool {
        guard valid(event), event.phase == .up, isPresented,
              let currentPresentationTime else { return false }
        // macOS's remote status-item host can send a synthetic down/up action
        // pair while the physical button is still held. Its later physical up
        // has a different timestamp, but still belongs to the same down. A new
        // observed down replaces this press and starts an independent gesture.
        if let press = presses[event.button], press.down.timestamp <= event.timestamp,
           press.down.timestamp < currentPresentationTime { return false }
        // In particular, the mouse-up that opened the panel cannot close it
        // when its global-monitor copy arrives after the control action.
        return event.timestamp >= currentPresentationTime
    }

    private func presentation(at timestamp: Double) -> Presentation? {
        history.last { $0.timestamp <= timestamp }
    }

    private func valid(_ event: MouseEvent) -> Bool {
        (0...31).contains(event.button) && event.timestamp.isFinite && event.timestamp >= 0
    }
}
