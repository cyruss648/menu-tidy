import XCTest
@testable import MenuTidyCore

final class SystemModuleContinuityPolicyTests: XCTestCase {
    private func seed() -> SystemModuleContinuityPolicy {
        var policy = SystemModuleContinuityPolicy()
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 1, identifierMatchCount: 1, identifierMatchesOriginal: true,
            visiblyConfirmed: true), .enumerated)
        XCTAssertTrue(policy.hasVisibleSeed)
        return policy
    }

    func testEnumerationWithoutActualVisibilityCannotAuthorizeLaterAbsence() {
        var policy = SystemModuleContinuityPolicy()
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 1, identifierMatchCount: 1, identifierMatchesOriginal: true), .enumerated)
        XCTAssertFalse(policy.hasVisibleSeed)
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
    }

    func testVisibleThenAbsentObjectRetainsIdentityOnlyAfterEveryFreshCheck() {
        var policy = seed()
        for _ in 0..<20 {
            XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
                originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .retained)
        }
        // Observation has no hidden/visible result. Continuing identity is not
        // a time-limited geometry sample or evidence of successful hiding.
        XCTAssertTrue(policy.hasVisibleSeed)
    }

    func testMissingOriginalCannotSeedItselfEvenWithClaimedVisibleHit() {
        var policy = SystemModuleContinuityPolicy()
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false,
            visiblyConfirmed: true), .unconfirmed)
        XCTAssertFalse(policy.hasVisibleSeed)
    }

    func testIncompleteCensusOrUnreadableIdentityNeverReturnsCachedSuccess() {
        var policy = seed()
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: false,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
        XCTAssertEqual(policy.observe(identityCurrent: nil, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
        XCTAssertTrue(policy.hasVisibleSeed, "Unknown reads can be retried, but cannot authorize this observation")
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .retained)
    }

    func testChangedObjectIdentifierOrOwnerEpochRevokesEvenWhenCensusUnavailable() {
        var policy = seed()
        XCTAssertEqual(policy.observe(identityCurrent: false, completeCensus: false,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
        XCTAssertFalse(policy.hasVisibleSeed)
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
    }

    func testReplacementWithSameIdentifierCannotInheritOriginalProof() {
        var policy = seed()
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 1, identifierMatchesOriginal: false), .unconfirmed)
        XCTAssertFalse(policy.hasVisibleSeed)
    }

    func testDuplicateOriginalOrIdentifierRevokesSeed() {
        for (originals, identifiers, same) in [(2, 1, true), (1, 2, true), (1, 1, false), (1, 0, false)] {
            var policy = seed()
            XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
                originalMatchCount: originals, identifierMatchCount: identifiers,
                identifierMatchesOriginal: same), .unconfirmed)
            XCTAssertFalse(policy.hasVisibleSeed)
        }
    }

    func testRevokedSeedRequiresNewVisibleAndEnumeratedConfirmation() {
        var policy = seed()
        _ = policy.observe(identityCurrent: false, completeCensus: true,
            originalMatchCount: 1, identifierMatchCount: 1, identifierMatchesOriginal: true)
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 1, identifierMatchCount: 1, identifierMatchesOriginal: true), .enumerated)
        XCTAssertFalse(policy.hasVisibleSeed)
        XCTAssertEqual(policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 1, identifierMatchCount: 1, identifierMatchesOriginal: true,
            visiblyConfirmed: true), .enumerated)
        XCTAssertTrue(policy.hasVisibleSeed)
    }

    func testOneModulesSeedDoesNotAuthorizeAnotherMissingModule() {
        var first = seed()
        var second = SystemModuleContinuityPolicy()
        XCTAssertEqual(first.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .retained)
        XCTAssertEqual(second.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: 0, identifierMatchCount: 0, identifierMatchesOriginal: false), .unconfirmed)
    }
}
