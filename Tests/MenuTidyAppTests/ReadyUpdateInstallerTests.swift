import Foundation
import XCTest
@testable import MenuTidy

@MainActor
final class ReadyUpdateInstallerTests: XCTestCase {
    func testVerifiedHandlerRunsOnceAfterIdleAndNeverReenters() async throws {
        var calls = 0
        var announcements = 0
        let installer = ReadyUpdateInstaller(idleDelay: .milliseconds(20)) { announcements += 1 }
        installer.stage { calls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { true }
        XCTAssertEqual(calls, 0, "Never invoke Sparkle's handler before its delegate has returned")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(announcements, 1)
        XCTAssertTrue(installer.isInstalling)
        for _ in 0..<5 { installer.updateAutomaticInstallation(enabled: true) { true } }
        XCTAssertFalse(installer.install())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
    }

    func testActivityAndOptOutCancelThePendingIdleWindow() async throws {
        var calls = 0
        let installer = ReadyUpdateInstaller(idleDelay: .milliseconds(20)) {}
        installer.stage { calls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { false }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 0)
        installer.updateAutomaticInstallation(enabled: true) { true }
        installer.updateAutomaticInstallation(enabled: true) { false }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 0)
        installer.updateAutomaticInstallation(enabled: true) { true }
        installer.updateAutomaticInstallation(enabled: false) { true }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 0)
        installer.updateAutomaticInstallation(enabled: true) { true }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
    }

    func testInstallationRechecksEligibilityAtDispatch() async throws {
        var eligible = true
        var calls = 0
        let installer = ReadyUpdateInstaller(idleDelay: .milliseconds(20)) {}
        installer.stage { calls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { eligible }
        eligible = false
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 0, "A lock or new operation must prevent installation even before its notification")
        eligible = true
        installer.updateAutomaticInstallation(enabled: true) { eligible }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
    }

    func testClearedOrReplacedUpdateCannotInvokeAnOldHandler() async throws {
        var oldCalls = 0
        var newCalls = 0
        let installer = ReadyUpdateInstaller(idleDelay: .milliseconds(20)) {}
        installer.stage { oldCalls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { true }
        installer.stage { newCalls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { true }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(newCalls, 1)
        installer.stage { newCalls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { true }
        installer.clear()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(installer.hasUpdate)
        XCTAssertEqual(newCalls, 1)
    }

    func testCancelledTerminationRequiresAnExplicitRetry() async throws {
        var calls = 0
        let installer = ReadyUpdateInstaller(idleDelay: .milliseconds(20)) {}
        installer.stage { calls += 1 }
        installer.updateAutomaticInstallation(enabled: true) { true }
        try await Task.sleep(for: .milliseconds(80))
        installer.terminationWasCancelled()
        for _ in 0..<5 { installer.updateAutomaticInstallation(enabled: true) { true } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(installer.hasUpdate)
        XCTAssertTrue(installer.install())
        XCTAssertEqual(calls, 2)
    }
}
