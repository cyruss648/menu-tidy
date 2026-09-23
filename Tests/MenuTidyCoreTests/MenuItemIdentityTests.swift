import Foundation
import XCTest
@testable import MenuTidyCore

final class MenuItemIdentityTests: XCTestCase {
    func testStructuredPairPreventsSeparatorCollisions() throws {
        let first = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.app:status",
            accessibilityIdentifier: "primary",
            occurrenceCount: 1
        ))
        let second = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.app",
            accessibilityIdentifier: "status:primary",
            occurrenceCount: 1
        ))
        XCTAssertNotEqual(first, second)

        let punctuation = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.app",
            accessibilityIdentifier: #"status:[\"primary\"]\\secondary"#,
            occurrenceCount: 1
        ))
        XCTAssertEqual(try decode(punctuation), ["example.app", #"status:[\"primary\"]\\secondary"#])
    }

    func testSameAccessibilityIdentifierInDifferentApplicationsStaysDistinct() throws {
        let first = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.first", accessibilityIdentifier: "statusItem", occurrenceCount: 1
        ))
        let second = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.second", accessibilityIdentifier: "statusItem", occurrenceCount: 1
        ))
        XCTAssertNotEqual(first, second)
    }

    func testAmbiguousOrAbsentOccurrencesCannotPersistRules() {
        for count in [-1, 0, 2, 3, Int.max] {
            XCTAssertNil(MenuItemIdentity.persistentID(
                bundleIdentifier: "example.app", accessibilityIdentifier: "statusItem", occurrenceCount: count
            ))
        }
        XCTAssertNotNil(MenuItemIdentity.persistentID(
            bundleIdentifier: "example.app", accessibilityIdentifier: "statusItem", occurrenceCount: 1
        ))
    }

    func testBothStableIdentifiersAreRequired() {
        let invalidPairs: [(String?, String?)] = [
            (nil, "statusItem"), ("", "statusItem"),
            ("example.app", nil), ("example.app", ""),
            (nil, nil), ("", ""),
        ]
        for (bundle, identifier) in invalidPairs {
            XCTAssertNil(MenuItemIdentity.persistentID(
                bundleIdentifier: bundle, accessibilityIdentifier: identifier, occurrenceCount: 1
            ))
        }
    }

    func testUnicodeIdentityRoundTripsDeterministically() throws {
        let bundle = "example.菜单栏"
        let identifier = "状态 🛰️ / café / cafe\u{301}"
        let first = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: bundle, accessibilityIdentifier: identifier, occurrenceCount: 1
        ))
        let second = try XCTUnwrap(MenuItemIdentity.persistentID(
            bundleIdentifier: bundle, accessibilityIdentifier: identifier, occurrenceCount: 1
        ))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try decode(first), [bundle, identifier])
    }

    func testPersistentIdentityAPIContainsOnlyStableIdentifiersAndOccurrenceCount() throws {
        // The function signature intentionally has no title or label input.
        let makeIdentity: (String?, String?, Int) -> String? = MenuItemIdentity.persistentID
        let identity = try XCTUnwrap(makeIdentity("example.app", "stable-item-42", 1))
        XCTAssertTrue(identity.hasPrefix("item:"))
        XCTAssertEqual(try decode(identity), ["example.app", "stable-item-42"])
    }

    private func decode(_ identity: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(identity.dropFirst("item:".count).utf8))
    }
}
