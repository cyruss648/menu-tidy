/// Move only Menu Tidy's own divider into the scalar gap between all ordinary
/// positions and the reserved hidden range. Old/unmatched numeric records still
/// constrain that gap; this planner never guesses whether another key is stale.
public struct MenuBarOwnBoundaryPlan: Equatable, Sendable {
    public enum PlanError: Error, Equatable, Sendable {
        case invalidPositions, missingOwnItem, invalidControlPosition, noFiniteGap, stalePlan
    }

    public static let dividerKey = "status:dev.hdh.MenuTidy::MenuTidyDivider"
    public static let controlKey = "status:dev.hdh.MenuTidy::MenuTidyControl"
    public let originalWeight: Double
    public let writtenWeight: Double
    public let controlWeight: Double
    public let maximumOrdinaryWeight: Double
    private let managedHiddenWeights: [String: Double]

    public var originalValues: [String: Double] { [Self.dividerKey: originalWeight] }
    public var writtenValues: [String: Double] { [Self.dividerKey: writtenWeight] }

    /// nil means the existing divider is already strictly inside the required
    /// interval, without creating a journal or changing its numeric value.
    public static func prepare(positions: [String: Double],
                               managedHiddenWeights: [String: Double] = [:]) throws -> MenuBarOwnBoundaryPlan? {
        guard !positions.isEmpty, positions.values.allSatisfy(\.isFinite) else { throw PlanError.invalidPositions }
        guard let original = positions[dividerKey], let control = positions[controlKey] else {
            throw PlanError.missingOwnItem
        }
        let ceiling = MenuBarHiddenLedger.minimumHiddenWeight
        guard control < ceiling, managedHiddenWeights[controlKey] == nil,
              managedHiddenWeights[dividerKey] == nil else { throw PlanError.invalidControlPosition }
        guard managedHiddenWeights.allSatisfy({ key, value in
            value.isFinite && value >= ceiling && positions[key] == value
        }) else { throw PlanError.invalidPositions }
        // The exact control key supplies an ordinary position even when all
        // other installed items are hidden. No external anchor is selected.
        // A large unknown value is still ordinary. It cannot be silently
        // classified as managed-hidden merely because it exceeds 50,000.
        guard let lower = positions.filter({ $0.key != dividerKey && managedHiddenWeights[$0.key] == nil }).values.max() else {
            throw PlanError.invalidPositions
        }
        guard lower < ceiling else { throw PlanError.noFiniteGap }
        if original > lower && original < ceiling { return nil }
        let span = ceiling - lower
        let midpoint = span.isFinite ? lower + span / 2 : lower / 2 + ceiling / 2
        let candidate = midpoint > lower && midpoint < ceiling ? midpoint : lower.nextUp
        guard candidate.isFinite, candidate > lower, candidate < ceiling else { throw PlanError.noFiniteGap }
        return MenuBarOwnBoundaryPlan(originalWeight: original, writtenWeight: candidate,
            controlWeight: control, maximumOrdinaryWeight: lower, managedHiddenWeights: managedHiddenWeights)
    }

    /// A fresh complete table must still produce this exact plan. Changes to
    /// unrelated positions are retained, while a new ordinary upper boundary,
    /// changed control/source, or a consumed floating-point gap rejects it.
    public func applying(to current: [String: Double]) throws -> [String: Double] {
        guard let fresh = try Self.prepare(positions: current, managedHiddenWeights: managedHiddenWeights),
              fresh == self else { throw PlanError.stalePlan }
        var result = current
        result[Self.dividerKey] = writtenWeight
        return result
    }
}
