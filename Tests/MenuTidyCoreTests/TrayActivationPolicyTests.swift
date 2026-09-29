import XCTest
@testable import MenuTidyCore

final class TrayActivationPolicyTests: XCTestCase {
    func testOnlyExactVerifiedBundleUsesApplicationRoute() {
        XCTAssertEqual(TrayActivationPolicy.defaultAction(bundleIdentifier: "io.github.clash-verge-rev.clash-verge-rev"), .application)
        for bundle in [nil, "", "Clash Verge", "io.github.clash-verge-rev.clash-verge-rev.helper", "com.apple.controlcenter", "example.app"] {
            XCTAssertEqual(TrayActivationPolicy.defaultAction(bundleIdentifier: bundle), .nativeItem)
        }
    }
}
