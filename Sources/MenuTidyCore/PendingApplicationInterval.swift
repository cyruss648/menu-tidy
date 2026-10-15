import Foundation

public enum PendingApplicationInterval {
    public static let defaultValue: TimeInterval = 300
    public static let choices: [TimeInterval] = [60, 300, 900, 1800]

    public static func validated(_ value: TimeInterval) -> TimeInterval {
        choices.contains(value) ? value : defaultValue
    }
}
