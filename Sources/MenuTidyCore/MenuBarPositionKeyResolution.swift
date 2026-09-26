import Foundation
import CoreGraphics

/// Positive, process-lifetime evidence that one existing key controls one AX
/// item. This type neither performs writes nor proves that other keys are stale.
/// Its result is deliberately not Codable and must never become a saved mapping.
public struct MenuBarPositionKeyResolution: Sendable {
    public struct Identity: Equatable, Sendable {
        /// The caller binds these tokens to the exact originating AX objects;
        /// re-enumerating by name, geometry, or PID alone cannot renew them.
        public let sourceToken: UUID
        public let controlToken: UUID
        public let processIdentifier: Int32
        public let launchTime: Double
        public let accessibilityIdentifier: String

        public init(sourceToken: UUID, controlToken: UUID, processIdentifier: Int32,
                    launchTime: Double, accessibilityIdentifier: String) {
            self.sourceToken = sourceToken
            self.controlToken = controlToken
            self.processIdentifier = processIdentifier
            self.launchTime = launchTime
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    public enum Side: Equatable, Sendable { case leftOfControl, rightOfControl }
    public enum Phase: Equatable, Sendable { case idle, left, right, restoring, finished }
    public enum ResolutionError: Error, Equatable {
        case invalidCandidates, invalidIdentity, invalidState, changedCandidates
        case changedControl, identityChanged, nonVisiblePlan, restorationUnconfirmed
    }

    public struct Observation: Sendable {
        public let attempt: UUID
        public let side: Side
        public let identity: Identity
        public let sourceFrame: CGRect
        public let controlFrame: CGRect
        public let sourceCenterHit: Bool
        public let controlCenterHit: Bool
        /// A fresh complete census proves one source and a unique exact AXID.
        public let completeSingleSource: Bool
        public let controlWeight: Double
        public let uptime: Double

        public init(attempt: UUID, side: Side, identity: Identity, sourceFrame: CGRect,
                    controlFrame: CGRect, sourceCenterHit: Bool, controlCenterHit: Bool,
                    completeSingleSource: Bool, controlWeight: Double, uptime: Double) {
            self.attempt = attempt
            self.side = side
            self.identity = identity
            self.sourceFrame = sourceFrame
            self.controlFrame = controlFrame
            self.sourceCenterHit = sourceCenterHit
            self.controlCenterHit = controlCenterHit
            self.completeSingleSource = completeSingleSource
            self.controlWeight = controlWeight
            self.uptime = uptime
        }
    }

    public let candidateKeys: [String]
    public let controlKey: String
    public let identity: Identity
    public private(set) var phase: Phase = .idle
    public private(set) var validatedKey: String?
    private let ownerPrefix: String
    private let controlWeight: Double
    private var attempted: Set<String> = []
    private var candidate: String?
    private var attempt: UUID?
    private var previous: Observation?
    private var lastUptime = -Double.infinity
    private var hasPositiveProof = false
    private var invalidated = false

    public init(candidateKeys: [String], ownerBundleIdentifier: String, controlKey: String,
                positions: [String: Double], identity: Identity) throws {
        let prefix = "status:\(ownerBundleIdentifier)::"
        guard !ownerBundleIdentifier.isEmpty, (2...4).contains(candidateKeys.count),
              Set(candidateKeys).count == candidateKeys.count,
              candidateKeys.allSatisfy({ $0.hasPrefix(prefix) && $0.count > prefix.count }),
              Set(positions.keys.filter { $0.hasPrefix(prefix) }) == Set(candidateKeys),
              !candidateKeys.contains(controlKey), !positions.isEmpty,
              positions.values.allSatisfy(\.isFinite),
              let weight = positions[controlKey], weight >= 0, weight < 50_000 else {
            throw ResolutionError.invalidCandidates
        }
        guard identity.processIdentifier > 0, identity.launchTime.isFinite, identity.launchTime > 0,
              !identity.accessibilityIdentifier.isEmpty, identity.sourceToken != identity.controlToken else {
            throw ResolutionError.invalidIdentity
        }
        self.candidateKeys = candidateKeys
        self.controlKey = controlKey
        self.identity = identity
        self.ownerPrefix = prefix
        self.controlWeight = weight
    }

    /// A candidate is tried at most once in this bounded session. Even an
    /// unsuccessful attempt must finish restoration before another can start.
    @discardableResult
    public mutating func beginCandidate(key: String) throws -> UUID {
        guard phase == .idle, !invalidated, candidateKeys.contains(key), attempted.insert(key).inserted else {
            throw ResolutionError.invalidState
        }
        candidate = key
        let token = UUID()
        attempt = token
        previous = nil
        hasPositiveProof = false
        phase = .left
        return token
    }

    /// Pure weight planning only: actual visible geometry must still be
    /// established independently after each conditional write and refresh.
    public func placementPlan(positions: [String: Double]) throws -> MenuBarPositionPlan {
        guard let candidate, phase == .left || phase == .right else { throw ResolutionError.invalidState }
        guard Set(positions.keys.filter { $0.hasPrefix(ownerPrefix) }) == Set(candidateKeys) else {
            throw ResolutionError.changedCandidates
        }
        guard positions[controlKey] == controlWeight else { throw ResolutionError.changedControl }
        let plan = try phase == .left
            ? MenuBarPositionPlan.moving(candidate, before: controlKey, positions: positions)
            : MenuBarPositionPlan.moving(candidate, after: controlKey, positions: positions)
        guard plan.writtenWeight >= 0, plan.writtenWeight < 50_000 else { throw ResolutionError.nonVisiblePlan }
        return plan
    }

    /// Stale/duplicate samples cannot count twice. Untrusted geometry resets a
    /// pair; changed identity/control invalidates this entire session.
    public mutating func record(_ observation: Observation) throws {
        guard phase == .left || phase == .right else { throw ResolutionError.invalidState }
        guard observation.attempt == attempt else { return }
        guard observation.identity == identity, observation.completeSingleSource else {
            invalidated = true; phase = .restoring; previous = nil
            throw ResolutionError.identityChanged
        }
        guard observation.controlWeight == controlWeight else {
            invalidated = true; phase = .restoring; previous = nil
            throw ResolutionError.changedControl
        }
        guard (phase == .left && observation.side == .leftOfControl) ||
              (phase == .right && observation.side == .rightOfControl) else { return }
        guard observation.uptime.isFinite, observation.uptime > lastUptime else { return }
        lastUptime = observation.uptime
        guard observation.sourceCenterHit, observation.controlCenterHit,
              Self.valid(observation.sourceFrame), Self.valid(observation.controlFrame),
              abs(observation.sourceFrame.midY - observation.controlFrame.midY) <= 8,
              Self.orderMatches(side: observation.side, sourceFrame: observation.sourceFrame,
                                controlFrame: observation.controlFrame) else {
            previous = nil
            return
        }
        if let previous,
           observation.uptime - previous.uptime >= 0.1,
           observation.sourceFrame == previous.sourceFrame,
           observation.controlFrame == previous.controlFrame {
            self.previous = nil
            if phase == .left { phase = .right }
            else { hasPositiveProof = true; phase = .restoring }
        } else if previous == nil || observation.sourceFrame != previous?.sourceFrame ||
                    observation.controlFrame != previous?.controlFrame {
            previous = observation
        }
    }

    /// Timeout or cancellation leaves no negative-key claim; it only requests
    /// cleanup of the current candidate's exact original numeric value.
    public mutating func finishAttempt() throws {
        guard phase == .left || phase == .right || phase == .restoring else { throw ResolutionError.invalidState }
        phase = .restoring
        previous = nil
    }

    /// `originalValueRestored` means the store confirmed the exact NSNumber,
    /// conditionally, without overwriting external edits. `layoutRefreshed`
    /// acknowledges the native refresh, not visibility of an overflow baseline.
    @discardableResult
    public mutating func confirmRestoration(identity currentIdentity: Identity,
                                            originalValueRestored: Bool,
                                            layoutRefreshed: Bool) throws -> String? {
        guard phase == .restoring else { throw ResolutionError.invalidState }
        guard currentIdentity == identity else { invalidated = true; throw ResolutionError.identityChanged }
        guard originalValueRestored, layoutRefreshed else { throw ResolutionError.restorationUnconfirmed }
        if hasPositiveProof && !invalidated { validatedKey = candidate }
        candidate = nil
        attempt = nil
        phase = validatedKey != nil || invalidated || attempted.count == candidateKeys.count ? .finished : .idle
        return validatedKey
    }

    /// Source-content and host-container edges need not have identical padding.
    /// Each independently hit center must lie strictly outside the other frame
    /// on the requested side. Edges may overlap, but centers cannot be shared,
    /// contained, or reversed. `record` separately requires stable geometry,
    /// both actual hits, unchanged identity, and proof on both sides.
    public static func orderMatches(side: Side, sourceFrame: CGRect, controlFrame: CGRect) -> Bool {
        guard valid(sourceFrame), valid(controlFrame) else { return false }
        switch side {
        case .leftOfControl:
            return sourceFrame.midX < controlFrame.minX && controlFrame.midX > sourceFrame.maxX
        case .rightOfControl:
            return sourceFrame.midX > controlFrame.maxX && controlFrame.midX < sourceFrame.minX
        }
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite) &&
            frame.size.width > 0 && frame.size.height > 0 && frame.size.height <= 64
    }
}
