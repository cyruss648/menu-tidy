import XCTest
@testable import MenuTidyCore

final class SystemModulePresentationIdentityTests: XCTestCase {
    func testOnlyThreeVerifiedModulesMapToFixedSystemDelegateAndMatchingHeader() throws {
        let expected = [("airdrop", "airdrop-header"), ("bluetooth", "bluetooth-header"), ("wifi", "wifi-header")]
        for (module, header) in expected {
            let target = try XCTUnwrap(SystemModulePresentationIdentity.delegate(
                ownerBundleIdentifier: "com.apple.MenuBarAgent", accessibilityIdentifier: "com.apple.menuextra.\(module)"))
            XCTAssertEqual(target.bundleIdentifier, "com.apple.controlcenter")
            XCTAssertEqual(target.bundlePath, "/System/Library/CoreServices/ControlCenter.app")
            XCTAssertEqual(target.headerIdentifier, header)
        }
    }

    func testOrderingSupportDoesNotGrantAudioVideoOrOtherModulesPresentationDelegation() {
        for identifier in ["com.apple.menuextra.audiovideo", "com.apple.menuextra.clock",
                           "com.apple.menuextra.controlcenter", "com.apple.menuextra.overflow", "module:WiFi"] {
            XCTAssertNil(SystemModulePresentationIdentity.delegate(ownerBundleIdentifier: "com.apple.MenuBarAgent",
                accessibilityIdentifier: identifier))
        }
    }

    func testThirdPartyOrDelegateItselfCannotClaimOriginalMenuBarIdentity() {
        for owner in [nil, "example.app", "com.apple.controlcenter", "com.apple.menubaragent", "com.apple.MenuBarAgent.extra"] {
            for identifier in ["com.apple.menuextra.airdrop", "com.apple.menuextra.bluetooth", "com.apple.menuextra.wifi"] {
                XCTAssertNil(SystemModulePresentationIdentity.delegate(ownerBundleIdentifier: owner,
                    accessibilityIdentifier: identifier))
            }
        }
    }

    func testDisplayNamesCaseVariantsSuffixesAndMissingIdentifiersNeverDelegate() {
        for identifier in [nil, "AirDrop", "蓝牙", "Wi-Fi", "wifi-header", "com.apple.menuextra.WiFi",
                           "com.apple.menuextra.bluetooth ", "com.apple.menuextra.airdrop.extra"] {
            XCTAssertNil(SystemModulePresentationIdentity.delegate(ownerBundleIdentifier: "com.apple.MenuBarAgent",
                accessibilityIdentifier: identifier))
        }
    }
}
