import Foundation

/// Distinguishes delayed delivery of one posted drag event from an unexpected
/// pointer position. Event counters are intentionally not used as input proof.
public enum DragArrivalPolicy {
    public enum Decision: Equatable, Sendable {
        case arrived
        case waiting
        case timedOut
        case unexpectedInput
        case unavailablePosition
    }

    public static let positionTolerance: Double = 12
    public static let arrivalTimeout: Double = 0.15

    public static func evaluate(
        previous: CGPoint,
        target: CGPoint,
        current: CGPoint?,
        now: TimeInterval,
        arrivalDeadline: TimeInterval,
        operationDeadline: TimeInterval,
        hasUnexpectedInput: Bool
    ) -> Decision {
        if hasUnexpectedInput { return .unexpectedInput }
        guard let current,
              [previous.x, previous.y, target.x, target.y, current.x, current.y].allSatisfy(\.isFinite),
              now.isFinite, arrivalDeadline.isFinite, operationDeadline.isFinite else {
            return .unavailablePosition
        }
        let previousDistance = hypot(current.x - previous.x, current.y - previous.y)
        let targetDistance = hypot(current.x - target.x, current.y - target.y)
        guard previousDistance <= positionTolerance || targetDistance <= positionTolerance else {
            return .unexpectedInput
        }
        guard now < min(arrivalDeadline, operationDeadline) else { return .timedOut }

        // Overlapping tolerance regions must not confirm a pointer that is still
        // at the previous point. Compare with the last actual confirmed position,
        // not merely the previous command's requested coordinates.
        if targetDistance <= positionTolerance &&
            ((previous.x == target.x && previous.y == target.y) || targetDistance < previousDistance) {
            return .arrived
        }
        return .waiting
    }
}
