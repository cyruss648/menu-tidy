import MenuTidyCore
import XCTest

final class UpdateSchedulingPolicyTests: XCTestCase {
    private func next(_ policy: inout UpdateSchedulingPolicy, busy: Bool = false,
                      automatic: Bool = true, session: Bool = false,
                      canCheck: Bool = true) -> UpdateSchedulingPolicy.Action? {
        policy.nextAction(operationInProgress: busy, automaticChecksEnabled: automatic,
                          updateSessionInProgress: session, canCheckForUpdates: canCheck)
    }

    private func started() -> UpdateSchedulingPolicy {
        var policy = UpdateSchedulingPolicy()
        XCTAssertEqual(next(&policy), .startUpdater)
        policy.didStartUpdater(successfully: true)
        return policy
    }

    func testInitialScanFinishesBeforeUpdaterStarts() {
        var policy = UpdateSchedulingPolicy()
        XCTAssertNil(next(&policy, busy: true, canCheck: false))
        XCTAssertNil(next(&policy, busy: true, canCheck: false))
        XCTAssertEqual(next(&policy, canCheck: false), .startUpdater)
        XCTAssertNil(next(&policy))
        policy.didStartUpdater(successfully: true)
        XCTAssertNil(next(&policy))
    }

    func testManualOnlyModeStillStartsUpdaterAfterScan() {
        var policy = UpdateSchedulingPolicy()
        XCTAssertNil(next(&policy, busy: true, automatic: false))
        XCTAssertEqual(next(&policy, automatic: false), .startUpdater)
        policy.didStartUpdater(successfully: true)
        XCTAssertNil(next(&policy, automatic: false))
    }

    func testFailedStartupDoesNotLoopOnFurtherModelChanges() {
        var policy = UpdateSchedulingPolicy()
        XCTAssertEqual(next(&policy), .startUpdater)
        policy.didStartUpdater(successfully: false)
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        for busy in [true, false, true, false] {
            XCTAssertNil(next(&policy, busy: busy))
        }
    }

    func testBusyRejectionsCoalesceAndWaitForOriginalSessionToEnd() {
        var policy = started()
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        XCTAssertNil(next(&policy, busy: true))
        XCTAssertNil(next(&policy, session: true))
        XCTAssertNil(next(&policy, canCheck: false))
        XCTAssertTrue(policy.hasDeferredBackgroundCheck)
        XCTAssertEqual(next(&policy), .checkInBackground)
        XCTAssertFalse(policy.hasDeferredBackgroundCheck)
        XCTAssertNil(next(&policy))
    }

    func testRetryThatHitsNewWorkWaitsForTheNextIdleEvent() {
        var policy = started()
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        XCTAssertEqual(next(&policy), .checkInBackground)
        // Work began between dispatch and Sparkle's asynchronous delegate gate.
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        for _ in 0..<5 { XCTAssertNil(next(&policy, busy: true)) }
        XCTAssertNil(next(&policy, session: true))
        XCTAssertEqual(next(&policy), .checkInBackground)
        XCTAssertNil(next(&policy))
    }

    func testDisablingAutomaticChecksCancelsPendingRetryEvenAfterReenable() {
        var policy = started()
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        policy.automaticChecksWereDisabled()
        XCTAssertNil(next(&policy, automatic: false))
        XCTAssertNil(next(&policy, automatic: true))
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: false)
        XCTAssertFalse(policy.hasDeferredBackgroundCheck)
    }

    func testExternalAutomaticPreferenceChangeAlsoClearsPendingRetry() {
        var policy = started()
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        XCTAssertNil(next(&policy, busy: true, automatic: false))
        XCTAssertFalse(policy.hasDeferredBackgroundCheck)
        XCTAssertNil(next(&policy, automatic: true))
    }

    func testManualChecksDoNotBecomeAutomaticChecks() {
        var policy = started()
        policy.checkWasDeferred(isBackgroundCheck: false, automaticChecksEnabled: true)
        XCTAssertNil(next(&policy))
        policy.checkWasDeferred(isBackgroundCheck: true, automaticChecksEnabled: true)
        policy.manualCheckWasRequested()
        XCTAssertNil(next(&policy))
    }
}
