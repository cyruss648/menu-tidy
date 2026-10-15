import XCTest
@testable import MenuTidyCore

final class MenuBarScanWindowPolicyTests: XCTestCase {
    func testAtollNotchDialogStopsBeforeItsImageAndTimerReachDiscovery() {
        let path: [(String, Int32)] = [("AXWindow", 78165), ("AXUnknown", 78165),
            ("AXApplication", 986), ("AXSystemDialog", 986), ("AXGroup", 986), ("AXImage", 986)]
        let excluded = path.enumerated().first {
            MenuBarScanWindowPolicy.excludesRemoteWindow(role: $0.element.0, depth: $0.offset,
                nodePID: $0.element.1, hostPID: 78165)
        }
        XCTAssertEqual(excluded?.offset, 3)
        XCTAssertEqual(excluded?.element.0, "AXSystemDialog")
    }

    func testRemoteStatusItemInsideHostWindowKeepsItsOriginalOwner() {
        let path: [(String, Int32)] = [("AXWindow", 78165), ("AXGroup", 78165), ("AXMenuBarItem", 986)]
        XCTAssertFalse(path.enumerated().contains {
            MenuBarScanWindowPolicy.excludesRemoteWindow(role: $0.element.0, depth: $0.offset,
                nodePID: $0.element.1, hostPID: 78165)
        })
    }

    func testHostOwnedPresentationWindowsAndSystemModuleGroupsArePreserved() {
        for role in ["AXWindow", "AXSystemDialog", "AXGroup", "AXUnknown", "AXMenuBarItem"] {
            XCTAssertFalse(MenuBarScanWindowPolicy.excludesRemoteWindow(role: role, depth: 2,
                nodePID: 78165, hostPID: 78165))
        }
    }

    func testUnknownTransportCannotBeUsedToDiscardAnOldHiddenSource() {
        for pid: Int32? in [nil, 0, -1] {
            XCTAssertFalse(MenuBarScanWindowPolicy.excludesRemoteWindow(role: "AXWindow", depth: 2,
                nodePID: pid, hostPID: 78165))
        }
        XCTAssertFalse(MenuBarScanWindowPolicy.excludesRemoteWindow(role: "", depth: 2,
            nodePID: 986, hostPID: 78165))
    }

    func testTopLevelRootIsNotRejectedAsARemoteChild() {
        XCTAssertFalse(MenuBarScanWindowPolicy.excludesRemoteWindow(role: "AXWindow", depth: 0,
            nodePID: 986, hostPID: 78165))
        XCTAssertTrue(MenuBarScanWindowPolicy.excludesRemoteWindow(role: "AXPopover", depth: 2,
            nodePID: 986, hostPID: 78165))
    }
}
