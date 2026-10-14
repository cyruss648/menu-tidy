import XCTest
@testable import MenuTidyCore

final class MenuBarItemPresentationIdentityTests: XCTestCase {
    func testNativeApplicationSharesDisplayIdentityRegardlessOfAXIdentifier() {
        let bundle = "io.github.clash-verge-rev.clash-verge-rev"
        XCTAssertEqual(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle, accessibilityIdentifier: nil),
            .application(bundle: bundle))
        XCTAssertEqual(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle, accessibilityIdentifier: "changing-speed"),
            .application(bundle: bundle))
        XCTAssertNotEqual(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle, accessibilityIdentifier: nil),
            MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle + ".helper", accessibilityIdentifier: nil))
    }

    func testSystemModulesRequireExactHostAndIdentifierAndRemainSeparate() {
        let host = SystemModuleIdentity.ownerBundleIdentifier
        let live = "live-activity-pill-com.apple.chrono.WidgetRenderer-Activities"
        XCTAssertEqual(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: host, accessibilityIdentifier: live),
            .systemModule(identifier: live))
        XCTAssertNotEqual(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: host, accessibilityIdentifier: live),
            MenuBarItemPresentationIdentity.resolve(bundleIdentifier: host, accessibilityIdentifier: "com.apple.menuextra.wifi"))
        XCTAssertNil(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: "com.apple.controlcenter", accessibilityIdentifier: live))
        XCTAssertNil(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: host, accessibilityIdentifier: nil))
    }

    func testMalformedIdentitiesDoNotCreateDisplayGroups() {
        for bundle in [nil, "", "invalid", "org..example", "org.example/other", "com.apple.Fake"] {
            XCTAssertNil(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: bundle, accessibilityIdentifier: nil))
        }
        for identifier in ["", " ", "module\nother", String(repeating: "x", count: 513)] {
            XCTAssertNil(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: SystemModuleIdentity.ownerBundleIdentifier,
                accessibilityIdentifier: identifier))
        }
    }

    func testDisplayIdentityDoesNotBroadenSystemPreferenceOrPresentationDelegation() {
        let host = SystemModuleIdentity.ownerBundleIdentifier
        let live = "live-activity-pill-com.apple.chrono.WidgetRenderer-Activities"
        XCTAssertNotNil(MenuBarItemPresentationIdentity.resolve(bundleIdentifier: host, accessibilityIdentifier: live))
        XCTAssertNil(SystemModuleIdentity.positionKey(ownerBundleIdentifier: host, accessibilityIdentifier: live))
        XCTAssertNil(SystemModulePresentationIdentity.delegate(ownerBundleIdentifier: host, accessibilityIdentifier: live))
        XCTAssertNotEqual(MenuBarItemPresentationIdentity.application(bundle: "org.example.App").id,
            MenuBarItemPresentationIdentity.systemModule(identifier: "org.example.App").id)
    }
}
