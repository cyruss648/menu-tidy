import XCTest
@testable import MenuTidyCore

final class ObservedItemGroupHistoryTests: XCTestCase {
    private let identity = ObservedItemGroupHistory.Identity(
        id: "session:42:item", pid: 42, bundleIdentifier: "example.app", launchTime: 100)

    func testPartialScanCanUseHistoryWithoutInventingCurrentObservation() {
        var history = ObservedItemGroupHistory()
        history.remember(.collapsible, for: identity, frozen: false)
        let current: ItemVisibility? = nil

        XCTAssertNil(current)
        XCTAssertTrue(HiddenItemsPanelPolicy.includes(savedVisibility: nil,
            observedVisibility: current ?? history.visibility(for: identity), includeAlwaysHidden: false))
        XCTAssertFalse(HiddenItemsPanelPolicy.includes(savedVisibility: .alwaysHidden,
            observedVisibility: history.visibility(for: identity), includeAlwaysHidden: false))
    }

    func testIdentityCannotTransferToAnotherProcessOrLaunch() {
        var history = ObservedItemGroupHistory()
        history.remember(.collapsible, for: identity, frozen: false)
        for other in [
            ObservedItemGroupHistory.Identity(id: identity.id, pid: 43, bundleIdentifier: "example.app", launchTime: 100),
            ObservedItemGroupHistory.Identity(id: identity.id, pid: 42, bundleIdentifier: "example.app", launchTime: 101),
            ObservedItemGroupHistory.Identity(id: identity.id, pid: 42, bundleIdentifier: "other.app", launchTime: 100),
            ObservedItemGroupHistory.Identity(id: "session:42:other", pid: 42, bundleIdentifier: "example.app", launchTime: 100)
        ] {
            XCTAssertNil(history.visibility(for: other))
        }
    }

    func testTemporaryVisibilityCannotOverwriteRememberedGroup() {
        var history = ObservedItemGroupHistory()
        history.remember(.alwaysHidden, for: identity, frozen: false)
        history.remember(.visible, for: identity, frozen: true)

        XCTAssertEqual(history.visibility(for: identity), .alwaysHidden)
        XCTAssertFalse(HiddenItemsPanelPolicy.includes(savedVisibility: nil,
            observedVisibility: history.visibility(for: identity), includeAlwaysHidden: false))
        history.remember(.visible, for: identity, frozen: false)
        XCTAssertEqual(history.visibility(for: identity), .visible)
    }

    func testExitedOwnersAndForgottenItemsAreRemoved() {
        var history = ObservedItemGroupHistory()
        history.remember(.collapsible, for: identity, frozen: false)
        history.retainOwners { $0.pid != 42 }
        XCTAssertNil(history.visibility(for: identity))

        history.remember(.collapsible, for: identity, frozen: false)
        history.remove(id: identity.id)
        XCTAssertNil(history.visibility(for: identity))
    }

    func testUnknownLifetimeCannotBeRemembered() {
        var history = ObservedItemGroupHistory()
        for launchTime in [0.0, -1.0, .infinity, .nan] {
            let unknown = ObservedItemGroupHistory.Identity(
                id: identity.id, pid: 42, bundleIdentifier: "example.app", launchTime: launchTime)
            history.remember(.collapsible, for: unknown, frozen: false)
            XCTAssertNil(history.visibility(for: unknown))
        }
    }
}
