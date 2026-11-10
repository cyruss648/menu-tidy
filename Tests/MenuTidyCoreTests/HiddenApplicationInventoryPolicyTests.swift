import XCTest
@testable import MenuTidyCore

final class HiddenApplicationInventoryPolicyTests: XCTestCase {
    private let bundle = "org.example.Hidden"

    func testManagedCanonicalExtrasChildCanBeDiscoveredWithoutGeometry() {
        XCTAssertTrue(accepts())
    }

    func testVisibleUnmanagedAndSystemApplicationsCannotUseIdentityOnlyDiscovery() {
        XCTAssertFalse(accepts(managed: []))
        XCTAssertFalse(accepts(bundle: "com.apple.controlcenter", managed: ["com.apple.controlcenter"]))
        XCTAssertFalse(accepts(bundle: nil))
    }

    func testHostMirrorsNestedChildrenAndOrdinaryWindowControlsAreExcluded() {
        XCTAssertFalse(accepts(extras: false))
        for depth in [0, 2, 3] { XCTAssertFalse(accepts(depth: depth)) }
        for role in ["AXButton", "AXImage", "AXStaticText", "AXMenuItem", "AXMenuBar"] {
            XCTAssertFalse(accepts(role: role))
        }
    }

    func testRemoteOrUnknownProcessIdentityCannotBorrowTheRootOwner() {
        XCTAssertFalse(accepts(pid: 0))
        XCTAssertFalse(accepts(pid: 11, root: 12))
        for epoch in [0, -1, .nan, .infinity] { XCTAssertFalse(accepts(epoch: epoch)) }
    }

    private func accepts(extras: Bool = true, depth: Int = 1, role: String = "AXMenuBarItem",
                         pid: Int32 = 11, root: Int32 = 11, epoch: Double = 100,
                         bundle: String? = "org.example.Hidden", managed: Set<String>? = nil) -> Bool {
        HiddenApplicationInventoryPolicy.accepts(isApplicationExtras: extras, depth: depth,
            role: role, ownerPID: pid, rootPID: root, launchTime: epoch, bundleIdentifier: bundle,
            managedHiddenBundles: managed ?? [self.bundle])
    }
}
