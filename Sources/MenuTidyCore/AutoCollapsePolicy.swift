import Foundation

/// A pure policy; the app supplies monotonic elapsed time and interaction state.
public struct AutoCollapsePolicy: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 15
    public static let allowedDelay: ClosedRange<TimeInterval> = 3...300

    public let delay: TimeInterval

    public init(delay: TimeInterval = defaultDelay) {
        let finiteDelay = delay.isFinite ? delay : Self.defaultDelay
        self.delay = min(
            Self.allowedDelay.upperBound,
            max(Self.allowedDelay.lowerBound, finiteDelay)
        )
    }

    /// A user interaction always wins over an expired timer.
    public func shouldCollapse(
        elapsed: TimeInterval,
        isExpanded: Bool,
        isArranging: Bool,
        isPaused: Bool,
        pointerInMenuBar: Bool,
        mouseButtonDown: Bool,
        enabled: Bool
    ) -> Bool {
        enabled
            && isExpanded
            && !isArranging
            && !isPaused
            && !pointerInMenuBar
            && !mouseButtonDown
            && elapsed.isFinite
            && elapsed >= delay
    }
}
