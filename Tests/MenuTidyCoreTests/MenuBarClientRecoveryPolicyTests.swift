import Foundation
import XCTest
@testable import MenuTidyCore

final class MenuBarClientRecoveryPolicyTests: XCTestCase {
    private let owner = MenuBarClientRecoveryPolicy.Owner(pid: 937,
        bundleIdentifier: "org.example.InputMethod", launchTime: 100)

    func testRepeatedDisabledConnectionNeedsIndependentCheckOnlyOncePerEpisode() {
        var policy = MenuBarClientRecoveryPolicy()
        for attempt in 1...3 {
            fail(&policy)
            XCTAssertTrue(policy.hasDisabledConnection(owner))
            XCTAssertEqual(policy.nextAutomaticCandidate, attempt == 3 ? owner : nil)
        }
        policy.markChecked(owner)
        fail(&policy)
        XCTAssertNil(policy.nextAutomaticCandidate)

        policy.reconcile(current: [owner], observed: [], queried: [owner], errors: [:])
        XCTAssertFalse(policy.hasDisabledConnection(owner))
        for _ in 0..<3 { fail(&policy) }
        XCTAssertEqual(policy.nextAutomaticCandidate, owner)
    }

    func testAbsentOrUnsupportedIconDoesNotTriggerClientRecycling() {
        for error: Int32 in [-25212, -25205, -25204, -25202] {
            var policy = MenuBarClientRecoveryPolicy()
            for _ in 0..<5 {
                policy.reconcile(current: [owner], observed: [], queried: [owner], errors: [owner: error])
            }
            XCTAssertFalse(policy.hasDisabledConnection(owner))
            XCTAssertNil(policy.nextAutomaticCandidate)
        }
    }

    func testIncrementalScanDoesNotCountAnUnqueriedOwnerAgain() {
        var policy = MenuBarClientRecoveryPolicy()
        fail(&policy)
        for _ in 0..<5 { policy.reconcile(current: [owner], observed: [], queried: [], errors: [:]) }
        XCTAssertTrue(policy.hasDisabledConnection(owner))
        XCTAssertNil(policy.nextAutomaticCandidate)
    }

    func testObservationExitAndReplacementEpochDiscardTheOldFailure() {
        var policy = MenuBarClientRecoveryPolicy()
        for _ in 0..<3 { fail(&policy) }
        policy.reconcile(current: [owner], observed: [owner], queried: [], errors: [:])
        XCTAssertFalse(policy.hasDisabledConnection(owner))
        for _ in 0..<3 { fail(&policy) }
        let replacement = MenuBarClientRecoveryPolicy.Owner(pid: owner.pid,
            bundleIdentifier: owner.bundleIdentifier, launchTime: 200)
        policy.reconcile(current: [replacement], observed: [], queried: [], errors: [:])
        XCTAssertFalse(policy.hasDisabledConnection(owner))
        XCTAssertNil(policy.nextAutomaticCandidate)
    }

    func testInvalidOrProtectedOwnerNeverBecomesARecoveryCandidate() {
        for invalid in [
            MenuBarClientRecoveryPolicy.Owner(pid: 0, bundleIdentifier: "org.example.App", launchTime: 1),
            MenuBarClientRecoveryPolicy.Owner(pid: 1, bundleIdentifier: "org.example.App", launchTime: .nan),
            MenuBarClientRecoveryPolicy.Owner(pid: 1, bundleIdentifier: "com.apple.MenuBarAgent", launchTime: 1)
        ] {
            var policy = MenuBarClientRecoveryPolicy()
            for _ in 0..<4 {
                policy.reconcile(current: [invalid], observed: [], queried: [invalid],
                    errors: [invalid: MenuBarClientRecoveryPolicy.apiDisabledError])
            }
            XCTAssertNil(policy.nextAutomaticCandidate)
        }
    }

    func testFreshEvidenceRequiresExactCurrentOwnerAndAStableVisibleCanonicalSource() throws {
        let valid = evidence()
        XCTAssertTrue(try decode(valid).confirmsVisibleItem(for: owner))
        for (key, value): (String, Any) in [
            ("ownerPID", 938), ("ownerEpoch", 200), ("ownerCount", 2),
            ("ownerCurrent", false), ("ownerCurrentAtEnd", false),
            ("censusComplete", false), ("targetItemCount", 0), ("event", "unavailable")
        ] {
            var invalid = valid
            invalid[key] = value
            XCTAssertFalse(try decode(invalid).confirmsVisibleItem(for: owner), key)
        }
        for (key, value): (String, Any) in [
            ("role", "AXWindow"), ("sourceOwnerMatches", false), ("inCurrentChildren", false),
            ("positiveSize", false), ("frameStable", false), ("centerHit", false)
        ] {
            var invalid = valid
            var item = (invalid["items"] as! [[String: Any]])[0]
            item[key] = value
            invalid["items"] = [item]
            XCTAssertFalse(try decode(invalid).confirmsVisibleItem(for: owner), key)
        }
        XCTAssertFalse(try decode(["event": "unavailable"]).confirmsVisibleItem(for: owner))
    }

    private func fail(_ policy: inout MenuBarClientRecoveryPolicy) {
        policy.reconcile(current: [owner], observed: [], queried: [owner],
            errors: [owner: MenuBarClientRecoveryPolicy.apiDisabledError])
    }

    private func evidence() -> [String: Any] {
        ["event": "sample", "ownerPID": owner.pid, "ownerEpoch": owner.launchTime,
         "ownerCount": 1, "ownerCurrent": true, "ownerCurrentAtEnd": true,
         "censusComplete": true, "targetItemCount": 1,
         "items": [["role": "AXMenuBarItem", "sourceOwnerMatches": true,
            "inCurrentChildren": true, "positiveSize": true, "frameStable": true, "centerHit": true]]]
    }

    private func decode(_ value: [String: Any]) throws -> MenuBarClientProbeEvidence {
        try JSONDecoder().decode(MenuBarClientProbeEvidence.self,
            from: JSONSerialization.data(withJSONObject: value))
    }
}
