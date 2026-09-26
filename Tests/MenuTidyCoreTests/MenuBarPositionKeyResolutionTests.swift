import XCTest
import CoreGraphics
@testable import MenuTidyCore

final class MenuBarPositionKeyResolutionTests: XCTestCase {
    private let owner = "example.Owner"
    private let a = "status:example.Owner::Item-0"
    private let b = "status:example.Owner::Item-1"
    private let control = "status:example.Tidy::Control"
    private let identity = MenuBarPositionKeyResolution.Identity(sourceToken: UUID(), controlToken: UUID(),
        processIdentifier: 123, launchTime: 456, accessibilityIdentifier: "unique-item")
    private var positions: [String: Double] { [a: 600, b: 440, control: 200, "other": 100] }

    private func session(keys: [String]? = nil, positions input: [String: Double]? = nil) throws -> MenuBarPositionKeyResolution {
        try MenuBarPositionKeyResolution(candidateKeys: keys ?? [a, b], ownerBundleIdentifier: owner,
            controlKey: control, positions: input ?? positions, identity: identity)
    }

    private func sample(_ attempt: UUID, _ side: MenuBarPositionKeyResolution.Side, _ time: Double,
                        identity override: MenuBarPositionKeyResolution.Identity? = nil,
                        source: CGRect? = nil, controlFrame: CGRect? = nil, hit: Bool = true,
                        controlHit: Bool = true, complete: Bool = true, weight: Double = 200)
        -> MenuBarPositionKeyResolution.Observation {
        .init(attempt: attempt, side: side, identity: override ?? identity,
              sourceFrame: source ?? CGRect(x: side == .leftOfControl ? 100 : 150, y: 4, width: 20, height: 24),
              controlFrame: controlFrame ?? CGRect(x: 125, y: 4, width: 20, height: 24),
              sourceCenterHit: hit, controlCenterHit: controlHit, completeSingleSource: complete,
              controlWeight: weight, uptime: time)
    }

    private func prove(_ resolution: inout MenuBarPositionKeyResolution, attempt: UUID, start: Double = 1) throws {
        try resolution.record(sample(attempt, .leftOfControl, start))
        try resolution.record(sample(attempt, .leftOfControl, start + 0.2))
        XCTAssertEqual(resolution.phase, .right)
        try resolution.record(sample(attempt, .rightOfControl, start + 0.4))
        try resolution.record(sample(attempt, .rightOfControl, start + 0.6))
        XCTAssertEqual(resolution.phase, .restoring)
    }

    func testPositiveKeyReleasedOnlyAfterBothSidesAndConfirmedRestoration() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        let left = try resolution.placementPlan(positions: positions)
        XCTAssertGreaterThan(left.writtenWeight, positions[control]!)
        try resolution.record(sample(attempt, .leftOfControl, 1))
        try resolution.record(sample(attempt, .leftOfControl, 1.2))
        let right = try resolution.placementPlan(positions: try left.applying(to: positions))
        XCTAssertLessThan(right.writtenWeight, positions[control]!)
        try resolution.record(sample(attempt, .rightOfControl, 1.4))
        XCTAssertNil(resolution.validatedKey)
        try resolution.record(sample(attempt, .rightOfControl, 1.6))
        XCTAssertNil(resolution.validatedKey)
        XCTAssertEqual(try resolution.confirmRestoration(identity: identity,
            originalValueRestored: true, layoutRefreshed: true), a)
        XCTAssertEqual(resolution.validatedKey, a)
        XCTAssertEqual(resolution.phase, .finished)
        // The untested key receives no invalid/stale classification.
        XCTAssertEqual(resolution.candidateKeys, [a, b])
    }

    func testBothDirectionsMustBeActualNonoverlappingHits() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        for time in [1.0, 1.2] { try resolution.record(sample(attempt, .leftOfControl, time, hit: false)) }
        XCTAssertEqual(resolution.phase, .left)
        let overlap = CGRect(x: 120, y: 4, width: 20, height: 24)
        for time in [1.4, 1.6] { try resolution.record(sample(attempt, .leftOfControl, time, source: overlap)) }
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 2))
        try resolution.record(sample(attempt, .leftOfControl, 2.2))
        for time in [2.4, 2.6] {
            try resolution.record(sample(attempt, .rightOfControl, time,
                source: CGRect(x: 100, y: 4, width: 20, height: 24)))
        }
        XCTAssertEqual(resolution.phase, .right)
        XCTAssertNil(resolution.validatedKey)
    }

    func testOverlappingContentAndHostEdgesCanProveAKeyWithSeparatedStableHits() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        let controlFrame = CGRect(x: 1469.5, y: 0, width: 44, height: 33)
        let left = CGRect(x: 1434, y: 4.5, width: 36, height: 24)
        let rightControl = CGRect(x: 1435.5, y: 0, width: 44, height: 33)
        let right = CGRect(x: 1478, y: 4.5, width: 36, height: 24)
        XCTAssertEqual(left.maxX - controlFrame.minX, 0.5)
        XCTAssertEqual(rightControl.maxX - right.minX, 1.5)
        try resolution.record(sample(attempt, .leftOfControl, 1, source: left, controlFrame: controlFrame))
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.2, source: left, controlFrame: controlFrame))
        XCTAssertEqual(resolution.phase, .right)
        try resolution.record(sample(attempt, .rightOfControl, 1.4, source: right, controlFrame: rightControl))
        XCTAssertEqual(resolution.phase, .right)
        try resolution.record(sample(attempt, .rightOfControl, 1.6, source: right, controlFrame: rightControl))
        XCTAssertEqual(resolution.phase, .restoring)
        XCTAssertNil(resolution.validatedKey)
        XCTAssertEqual(try resolution.confirmRestoration(identity: identity,
            originalValueRestored: true, layoutRefreshed: true), a)
    }

    func testSourceCenterOnOppositeFrameEdgeIsRejectedOnBothSides() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        let controlFrame = CGRect(x: 125, y: 4, width: 20, height: 24)
        let left = CGRect(x: 115, y: 4, width: 20, height: 24)
        for time in [1.0, 1.2] {
            try resolution.record(sample(attempt, .leftOfControl, time, source: left, controlFrame: controlFrame))
        }
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.4))
        try resolution.record(sample(attempt, .leftOfControl, 1.6))
        XCTAssertEqual(resolution.phase, .right)
        let right = CGRect(x: 135, y: 4, width: 20, height: 24)
        for time in [1.8, 2.0] {
            try resolution.record(sample(attempt, .rightOfControl, time, source: right, controlFrame: controlFrame))
        }
        XCTAssertEqual(resolution.phase, .right)
        XCTAssertNil(resolution.validatedKey)
    }

    func testOrderingNeverAcceptsCrossedOrCoincidentCenters() {
        let controlFrame = CGRect(x: 125, y: 4, width: 0.2, height: 24)
        let crossedLeft = CGRect(x: 125.1, y: 4, width: 0.2, height: 24)
        let crossedRight = CGRect(x: 124.9, y: 4, width: 0.2, height: 24)
        XCTAssertFalse(MenuBarPositionKeyResolution.orderMatches(side: .leftOfControl,
            sourceFrame: crossedLeft, controlFrame: controlFrame))
        XCTAssertFalse(MenuBarPositionKeyResolution.orderMatches(side: .rightOfControl,
            sourceFrame: crossedRight, controlFrame: controlFrame))
        for side in [MenuBarPositionKeyResolution.Side.leftOfControl, .rightOfControl] {
            XCTAssertFalse(MenuBarPositionKeyResolution.orderMatches(side: side,
                sourceFrame: controlFrame, controlFrame: controlFrame))
        }
    }

    func testNeitherCenterMayTouchOrEnterTheOtherFrameDespiteRelativeCenterOrder() {
        let controlFrame = CGRect(x: 125, y: 4, width: 20, height: 24)
        let cases: [(MenuBarPositionKeyResolution.Side, CGRect)] = [
            (.leftOfControl, CGRect(x: 115, y: 4, width: 20, height: 24)),
            (.leftOfControl, CGRect(x: 115.1, y: 4, width: 20, height: 24)),
            (.leftOfControl, CGRect(x: 100, y: 4, width: 35, height: 24)),
            (.leftOfControl, CGRect(x: 100, y: 4, width: 35.1, height: 24)),
            (.rightOfControl, CGRect(x: 135, y: 4, width: 20, height: 24)),
            (.rightOfControl, CGRect(x: 134.9, y: 4, width: 20, height: 24)),
            (.rightOfControl, CGRect(x: 135, y: 4, width: 40, height: 24)),
            (.rightOfControl, CGRect(x: 134.9, y: 4, width: 40, height: 24))
        ]
        for (side, source) in cases {
            XCTAssertTrue(side == .leftOfControl ? source.midX < controlFrame.midX
                : source.midX > controlFrame.midX)
            XCTAssertFalse(MenuBarPositionKeyResolution.orderMatches(side: side,
                sourceFrame: source, controlFrame: controlFrame))
        }
    }

    func testSeparatedCentersStillRequireTwoMatchingFramesAndBothHits() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        let edge = CGRect(x: 105.5, y: 4, width: 20, height: 24)
        try resolution.record(sample(attempt, .leftOfControl, 1, source: edge))
        try resolution.record(sample(attempt, .leftOfControl, 1.2, source: edge, hit: false))
        try resolution.record(sample(attempt, .leftOfControl, 1.4, source: edge))
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.6, source: edge, controlHit: false))
        try resolution.record(sample(attempt, .leftOfControl, 1.8, source: edge))
        let changed = CGRect(x: 105.4, y: 4, width: 20, height: 24)
        try resolution.record(sample(attempt, .leftOfControl, 2.0, source: changed))
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 2.2, source: changed))
        XCTAssertEqual(resolution.phase, .right)
    }

    func testAnUntrustedSampleBreaksTheConsecutivePair() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        try resolution.record(sample(attempt, .leftOfControl, 1))
        try resolution.record(sample(attempt, .leftOfControl, 1.2, controlHit: false))
        try resolution.record(sample(attempt, .leftOfControl, 1.4))
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.6))
        XCTAssertEqual(resolution.phase, .right)
    }

    func testDuplicateOldAndTooCloseSamplesCannotSupplyTheSecondObservation() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        try resolution.record(sample(attempt, .leftOfControl, 1))
        for time in [1.0, 0.9, 1.01] { try resolution.record(sample(attempt, .leftOfControl, time)) }
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.2))
        XCTAssertEqual(resolution.phase, .right)
        // Delayed left-side samples do not count toward the right-side pair.
        try resolution.record(sample(attempt, .leftOfControl, 1.4))
        try resolution.record(sample(attempt, .rightOfControl, 1.6))
        XCTAssertEqual(resolution.phase, .right)
    }

    func testFramesMustSettleWithinEachSideButControlMayMoveBetweenSides() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        try resolution.record(sample(attempt, .leftOfControl, 1))
        let moved = CGRect(x: 101, y: 4, width: 20, height: 24)
        try resolution.record(sample(attempt, .leftOfControl, 1.2, source: moved))
        XCTAssertEqual(resolution.phase, .left)
        try resolution.record(sample(attempt, .leftOfControl, 1.4, source: moved))
        let rightSource = CGRect(x: 130, y: 4, width: 20, height: 24)
        let shiftedControl = CGRect(x: 105, y: 4, width: 20, height: 24)
        try resolution.record(sample(attempt, .rightOfControl, 1.6, source: rightSource, controlFrame: shiftedControl))
        try resolution.record(sample(attempt, .rightOfControl, 1.8, source: rightSource, controlFrame: shiftedControl))
        XCTAssertEqual(resolution.phase, .restoring)
    }

    func testOwnerEpochSourceOrControlTokenChangesInvalidateProof() throws {
        let replacements = [
            MenuBarPositionKeyResolution.Identity(sourceToken: identity.sourceToken, controlToken: identity.controlToken,
                processIdentifier: identity.processIdentifier, launchTime: 999, accessibilityIdentifier: identity.accessibilityIdentifier),
            MenuBarPositionKeyResolution.Identity(sourceToken: UUID(), controlToken: identity.controlToken,
                processIdentifier: identity.processIdentifier, launchTime: identity.launchTime, accessibilityIdentifier: identity.accessibilityIdentifier),
            MenuBarPositionKeyResolution.Identity(sourceToken: identity.sourceToken, controlToken: UUID(),
                processIdentifier: identity.processIdentifier, launchTime: identity.launchTime, accessibilityIdentifier: identity.accessibilityIdentifier)
        ]
        for changed in replacements {
            var resolution = try session()
            let attempt = try resolution.beginCandidate(key: a)
            XCTAssertThrowsError(try resolution.record(sample(attempt, .leftOfControl, 1, identity: changed)))
            XCTAssertEqual(resolution.phase, .restoring)
            XCTAssertNil(try resolution.confirmRestoration(identity: identity, originalValueRestored: true, layoutRefreshed: true))
            XCTAssertEqual(resolution.phase, .finished)
        }
    }

    func testIncompleteSourceCensusAndChangedControlWeightAreNotGeometryEvidence() throws {
        for incomplete in [true, false] {
            var resolution = try session()
            let attempt = try resolution.beginCandidate(key: a)
            XCTAssertThrowsError(try resolution.record(sample(attempt, .leftOfControl, 1,
                complete: !incomplete, weight: incomplete ? 200 : 201)))
            XCTAssertEqual(resolution.phase, .restoring)
            XCTAssertNil(resolution.validatedKey)
        }
    }

    func testRestorationFailureDoesNotReleasePositiveKeyOrAllowNextCandidate() throws {
        var resolution = try session()
        let attempt = try resolution.beginCandidate(key: a)
        try prove(&resolution, attempt: attempt)
        for pair in [(false, true), (true, false)] {
            XCTAssertThrowsError(try resolution.confirmRestoration(identity: identity,
                originalValueRestored: pair.0, layoutRefreshed: pair.1))
            XCTAssertNil(resolution.validatedKey)
            XCTAssertThrowsError(try resolution.beginCandidate(key: b))
        }
        XCTAssertEqual(try resolution.confirmRestoration(identity: identity,
            originalValueRestored: true, layoutRefreshed: true), a)
    }

    func testUnsuccessfulCandidateCanBeRestoredThenAnotherCandidateProven() throws {
        var resolution = try session()
        let oldAttempt = try resolution.beginCandidate(key: a)
        try resolution.record(sample(oldAttempt, .leftOfControl, 1, hit: false))
        try resolution.finishAttempt()
        XCTAssertNil(try resolution.confirmRestoration(identity: identity, originalValueRestored: true, layoutRefreshed: true))
        XCTAssertThrowsError(try resolution.beginCandidate(key: a))
        let attempt = try resolution.beginCandidate(key: b)
        try resolution.record(sample(oldAttempt, .leftOfControl, 2))
        try resolution.record(sample(oldAttempt, .leftOfControl, 2.2))
        XCTAssertEqual(resolution.phase, .left)
        try prove(&resolution, attempt: attempt, start: 3)
        XCTAssertEqual(try resolution.confirmRestoration(identity: identity,
            originalValueRestored: true, layoutRefreshed: true), b)
    }

    func testAllInconclusiveAttemptsFinishWithoutInventingAMapping() throws {
        var resolution = try session()
        for key in [a, b] {
            try resolution.beginCandidate(key: key)
            try resolution.finishAttempt()
            XCTAssertNil(try resolution.confirmRestoration(identity: identity,
                originalValueRestored: true, layoutRefreshed: true))
        }
        XCTAssertEqual(resolution.phase, .finished)
        XCTAssertNil(resolution.validatedKey)
    }

    func testCompleteSameOwnerCandidateSetIsRequiredAndFreshlyRevalidated() throws {
        XCTAssertThrowsError(try session(keys: [a]))
        XCTAssertThrowsError(try session(keys: [a, a]))
        XCTAssertThrowsError(try session(keys: [a, control]))
        let third = "status:example.Owner::Item-2"
        var expanded = positions
        expanded[third] = 700
        XCTAssertThrowsError(try session(positions: expanded))
        var resolution = try session()
        try resolution.beginCandidate(key: a)
        XCTAssertThrowsError(try resolution.placementPlan(positions: expanded))
        var changed = positions
        changed[control] = 201
        XCTAssertThrowsError(try resolution.placementPlan(positions: changed))
    }

    func testNeitherHiddenWeightsNorNegativeRightSlotsAreVisiblePlans() throws {
        var high = positions
        high[control] = 49_999
        high[b] = 60_000
        var leftResolution = try session(positions: high)
        try leftResolution.beginCandidate(key: a)
        XCTAssertThrowsError(try leftResolution.placementPlan(positions: high))
        var zero = positions
        zero[control] = 0
        var rightResolution = try session(positions: zero)
        let attempt = try rightResolution.beginCandidate(key: a)
        try rightResolution.record(sample(attempt, .leftOfControl, 1, weight: 0))
        try rightResolution.record(sample(attempt, .leftOfControl, 1.2, weight: 0))
        XCTAssertThrowsError(try rightResolution.placementPlan(positions: zero))
    }

    func testInvalidGeometryCannotBeConfirmed() throws {
        let invalid = [CGRect.zero, CGRect(x: 100, y: 4, width: 20, height: 65),
                       CGRect(x: 100, y: 100, width: 20, height: 24),
                       CGRect(x: 100, y: 4, width: -20, height: 24),
                       CGRect(x: Double.infinity, y: 4, width: 20, height: 24)]
        for frame in invalid {
            var resolution = try session()
            let attempt = try resolution.beginCandidate(key: a)
            try resolution.record(sample(attempt, .leftOfControl, 1, source: frame))
            try resolution.record(sample(attempt, .leftOfControl, 1.2, source: frame))
            XCTAssertEqual(resolution.phase, .left)
        }
    }
}
