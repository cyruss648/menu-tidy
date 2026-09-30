import Foundation

/// Monotonic retry scheduling for images that cannot currently be captured.
/// A lifecycle event or a changed inventory invalidates an in-flight attempt's
/// retry decision, so its completion cannot postpone newly available work.
public struct PassiveIconCaptureSchedule: Sendable {
    public static let retryIntervals: [TimeInterval] = [2, 5, 15, 30]
    public private(set) var missingIDs: Set<String> = []
    public private(set) var nextAttemptAt: TimeInterval?
    public private(set) var generation: UInt64 = 0
    private var retryIndex = 0

    public init() {}

    public mutating func updateMissingIDs(_ ids: Set<String>, at now: TimeInterval) {
        guard ids != missingIDs else { return }
        missingIDs = ids
        reset(at: now, immediately: false)
    }

    public mutating func requestAfterEvent(at now: TimeInterval) {
        reset(at: now, immediately: true)
    }

    public func isDue(at now: TimeInterval) -> Bool {
        guard now.isFinite, let nextAttemptAt else { return false }
        return now >= nextAttemptAt
    }

    public mutating func finishAttempt(generation attemptGeneration: UInt64,
                                      madeProgress: Bool, cancelled: Bool, at now: TimeInterval) {
        guard attemptGeneration == generation, !missingIDs.isEmpty, now.isFinite else { return }
        if madeProgress || cancelled { retryIndex = 0 }
        else { retryIndex = min(retryIndex + 1, Self.retryIntervals.count - 1) }
        nextAttemptAt = now + Self.retryIntervals[retryIndex]
    }

    private mutating func reset(at now: TimeInterval, immediately: Bool) {
        generation &+= 1
        retryIndex = 0
        nextAttemptAt = !missingIDs.isEmpty && now.isFinite
            ? now + (immediately ? 0 : Self.retryIntervals[0]) : nil
    }
}
