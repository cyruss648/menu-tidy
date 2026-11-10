import AppKit
import XCTest
@testable import MenuTidy

final class MenuBarProcessIdentityTests: XCTestCase {
    @MainActor
    func testLiveProcessWithMatchingEpochHasNotEnded() throws {
        let app = NSRunningApplication.current
        let launchTime = try XCTUnwrap(MenuBarProcessIdentity.launchTime(for: app))
        XCTAssertFalse(MenuBarProcessIdentity.hasEnded(pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier, launchTime: launchTime))
    }

    @MainActor
    func testReplacementEpochProvesThatTheOriginalProcessEnded() throws {
        let app = NSRunningApplication.current
        let launchTime = try XCTUnwrap(MenuBarProcessIdentity.launchTime(for: app))
        XCTAssertTrue(MenuBarProcessIdentity.hasEnded(pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier, launchTime: launchTime - 1))
    }

    func testReapedChildProcessIsPositiveExitEvidence() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(MenuBarProcessIdentity.hasEnded(pid: child.processIdentifier,
            bundleIdentifier: nil, launchTime: 1))
    }

    func testInvalidOrUnknownLifetimeDoesNotProveExit() {
        for pid: Int32 in [-1, 0] {
            XCTAssertFalse(MenuBarProcessIdentity.hasEnded(pid: pid, bundleIdentifier: nil, launchTime: 1))
        }
        for launchTime in [0.0, -1, .nan, .infinity] {
            XCTAssertFalse(MenuBarProcessIdentity.hasEnded(pid: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: nil, launchTime: launchTime))
        }
    }
}
