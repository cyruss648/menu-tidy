/// The visibility state of the user-managed menu bar group.
///
/// Arrangement is a separate state so an ordinary click or delayed auto-collapse
/// cannot hide items while the user is moving them.
public struct VisibilityState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case expanded
        case collapsed
        case arranging
    }

    public private(set) var mode: Mode = .expanded

    public init() {}

    public mutating func toggle() {
        switch mode {
        case .expanded:
            mode = .collapsed
        case .collapsed:
            mode = .expanded
        case .arranging:
            break
        }
    }

    public mutating func expand() {
        guard mode != .arranging else { return }
        mode = .expanded
    }

    public mutating func collapse() {
        guard mode != .arranging else { return }
        mode = .collapsed
    }

    public mutating func beginArrangement() {
        mode = .arranging
    }

    public mutating func finishArrangement(collapse: Bool) {
        guard mode == .arranging else { return }
        mode = collapse ? .collapsed : .expanded
    }
}
