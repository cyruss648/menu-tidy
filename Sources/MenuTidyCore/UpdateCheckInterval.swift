import Foundation

/// User-selected cadence for automatic update checks. Sparkle enforces a
/// one-hour floor on its own scheduler, so Menu Tidy times shorter choices.
public enum UpdateCheckInterval {
    public static let defaultValue: TimeInterval = 1800
    public static let choices: [TimeInterval] = [300, 600, 1800, 3600, 21600, 86400]

    public static func validated(_ value: TimeInterval) -> TimeInterval {
        choices.contains(value) ? value : defaultValue
    }

    /// A missing or overdue check waits one second. A future or invalid date
    /// waits a full interval instead of checking continuously.
    public static func delay(since lastCheck: Date?, interval: TimeInterval, now: Date) -> TimeInterval {
        let interval = validated(interval)
        guard let lastCheck else { return 1 }
        let elapsed = now.timeIntervalSince(lastCheck)
        guard elapsed.isFinite, elapsed >= 0 else { return interval }
        return max(1, interval - elapsed)
    }
}
