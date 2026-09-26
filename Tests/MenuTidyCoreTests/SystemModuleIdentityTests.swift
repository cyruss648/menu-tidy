import Foundation
import XCTest
@testable import MenuTidyCore

final class SystemModuleIdentityTests: XCTestCase {
    private let pairs = [
        ("com.apple.menuextra.airdrop", "module:AirDrop"),
        ("com.apple.menuextra.bluetooth", "module:Bluetooth"),
        ("com.apple.menuextra.wifi", "module:WiFi"),
        ("com.apple.menuextra.audiovideo", "module:AudioVideoModule"),
    ]

    func testFourExactIdentifiersHaveDistinctKeysOnlyForSystemOwner() {
        for (identifier, key) in pairs {
            XCTAssertEqual(SystemModuleIdentity.positionKey(ownerBundleIdentifier: "com.apple.MenuBarAgent",
                accessibilityIdentifier: identifier), key)
            XCTAssertTrue(SystemModuleIdentity.isSupportedPositionKey(key))
            for owner in [nil, "example.app", "com.apple.controlcenter", "com.apple.menubaragent"] {
                XCTAssertNil(SystemModuleIdentity.positionKey(ownerBundleIdentifier: owner,
                    accessibilityIdentifier: identifier))
            }
        }
        XCTAssertEqual(Set(pairs.map(\.1)).count, 4)
    }

    func testTitlesCaseChangesUnknownModulesAndProtectedItemsNeverMatch() {
        for identifier in [nil, "AirDrop", "Bluetooth", "蓝牙", "Wi-Fi", "com.apple.menuextra.AirDrop",
                           "com.apple.menuextra.bluetooth ", "com.apple.menuextra.bluetooth.extra",
                           "com.apple.menuextra.clock", "com.apple.menuextra.controlcenter",
                           "com.apple.menuextra.overflow", "com.apple.menuextra.unknown"] {
            XCTAssertNil(SystemModuleIdentity.positionKey(ownerBundleIdentifier: "com.apple.MenuBarAgent",
                accessibilityIdentifier: identifier))
        }
    }

    func testLedgerRoundTripsSupportedModulesWithoutRelaxingOtherModuleKeys() throws {
        for (_, key) in pairs {
            let entry = hidden(key: key)
            XCTAssertEqual(try MenuBarHiddenLedger.decode(MenuBarHiddenLedger.encode([entry])), [entry])
        }
        for key in ["module:Clock", "module:ControlCenter", "module:Overflow", "module:Unknown",
                    "module:airdrop", "module:AirDrop ", "module:AirDrop\n", "module:AirDrop::extra"] {
            XCTAssertFalse(SystemModuleIdentity.isSupportedPositionKey(key))
            XCTAssertThrowsError(try MenuBarHiddenLedger.encode([hidden(key: key)]))
        }
        let status = hidden(key: "status:example.app::original")
        XCTAssertEqual(try MenuBarHiddenLedger.decode(MenuBarHiddenLedger.encode([status])), [status])
    }

    private func hidden(key: String) -> MenuBarHiddenLedger.Entry {
        MenuBarHiddenLedger.Entry(key: key, originalValue: NSNumber(value: 80),
            hiddenValue: NSNumber(value: 50_000), lastAppWrite: NSNumber(value: 50_000), mode: .hidden)
    }
}
