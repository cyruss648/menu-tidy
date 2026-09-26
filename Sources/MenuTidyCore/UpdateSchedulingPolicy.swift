/// Event-driven scheduling around menu-bar operations. A busy automatic check
/// is one coalesced request, not a reason to wait an entire update interval.
public struct UpdateSchedulingPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case startUpdater
        case checkInBackground
    }

    private enum Startup: Sendable { case pending, starting, started, failed }
    private var startup = Startup.pending
    public private(set) var hasDeferredBackgroundCheck = false

    public init() {}

    public mutating func nextAction(operationInProgress: Bool, automaticChecksEnabled: Bool,
                                   updateSessionInProgress: Bool, canCheckForUpdates: Bool) -> Action? {
        if !automaticChecksEnabled { hasDeferredBackgroundCheck = false }
        guard !operationInProgress else { return nil }
        switch startup {
        case .pending:
            // Start even with automatic checks off, so manual checks remain usable.
            startup = .starting
            return .startUpdater
        case .started:
            guard hasDeferredBackgroundCheck, automaticChecksEnabled,
                  !updateSessionInProgress, canCheckForUpdates else { return nil }
            hasDeferredBackgroundCheck = false
            return .checkInBackground
        case .starting, .failed:
            return nil
        }
    }

    public mutating func didStartUpdater(successfully: Bool) {
        startup = successfully ? .started : .failed
    }

    public mutating func checkWasDeferred(isBackgroundCheck: Bool, automaticChecksEnabled: Bool) {
        guard isBackgroundCheck, automaticChecksEnabled else { return }
        hasDeferredBackgroundCheck = true
    }

    public mutating func automaticChecksWereDisabled() { hasDeferredBackgroundCheck = false }
    public mutating func manualCheckWasRequested() { hasDeferredBackgroundCheck = false }
}
