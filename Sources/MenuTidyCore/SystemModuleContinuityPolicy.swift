/// Identity continuity for a system module that can leave the host's public
/// AX tree while hidden. This policy never supplies a visibility conclusion.
/// Its caller must freshly verify the exact object, identifier, process epoch
/// and live attributes, and completely enumerate the current source tree.
public struct SystemModuleContinuityPolicy: Sendable {
    public enum Observation: Equatable, Sendable { case enumerated, retained, unconfirmed }
    public private(set) var hasVisibleSeed = false
    public init() {}

    /// nil identity or an incomplete census is unknown, not cached success.
    /// Definite identity mismatch or identifier conflict revokes the seed.
    /// Only positive visibility together with current full membership arms it.
    public mutating func observe(identityCurrent: Bool?, completeCensus: Bool,
        originalMatchCount: Int, identifierMatchCount: Int,
        identifierMatchesOriginal: Bool, visiblyConfirmed: Bool = false) -> Observation {
        if identityCurrent == false {
            hasVisibleSeed = false
            return .unconfirmed
        }
        guard identityCurrent == true, completeCensus else { return .unconfirmed }
        if originalMatchCount == 1, identifierMatchCount == 1, identifierMatchesOriginal {
            if visiblyConfirmed { hasVisibleSeed = true }
            return .enumerated
        }
        if originalMatchCount == 0, identifierMatchCount == 0 {
            return hasVisibleSeed ? .retained : .unconfirmed
        }
        hasVisibleSeed = false
        return .unconfirmed
    }
}
