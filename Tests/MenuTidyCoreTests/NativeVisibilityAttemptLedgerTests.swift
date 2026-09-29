import XCTest
@testable import MenuTidyCore

final class NativeVisibilityAttemptLedgerTests: XCTestCase {
    func testFailedSharedSwitchIsAttemptedOnceAcrossSiblingsWhileOtherAppsContinue() {
        var attempts = NativeVisibilityAttemptLedger<String>()
        var attempted: [String] = []
        for target in ["example.fail", "example.fail", "example.other", "example.fail"] {
            guard attempts.claim(target) else { continue }
            attempted.append(target)
            if target == "example.fail" { continue } // A failed mutation has no successful completion.
        }
        XCTAssertEqual(attempted, ["example.fail", "example.other"])
    }

    func testOnlyANewExplicitBatchAllowsSharedTargetRetry() {
        var first = NativeVisibilityAttemptLedger<String>()
        XCTAssertTrue(first.claim("example.app"))
        XCTAssertFalse(first.claim("example.app"))
        var explicitRetry = NativeVisibilityAttemptLedger<String>()
        XCTAssertTrue(explicitRetry.claim("example.app"))
        XCTAssertFalse(first.claim("example.app"), "A second batch does not reopen the first batch's failed target.")
    }
}
