import Foundation
import XCTest
@testable import MenuTidyCore

final class MenuItemIdentityTests: XCTestCase {
    func testInputMenuIdentitySupportsSavedThreeStateDraftsWithoutSessionBinding() throws {
        let id = MenuItemIdentity.systemInputMenuID
        XCTAssertEqual(try decode(id), ["native-system-input-v1", "com.apple.TextInputMenuAgent", "singleton"])
        XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: id, bundleIdentifier: "com.apple.TextInputMenuAgent"))
        for group in [ItemVisibility.visible, .collapsible, .alwaysHidden] {
            let rule = ItemRule(id: id, name: "输入法切换", bundleIdentifier: "com.apple.TextInputMenuAgent", visibility: group)
            let drafts = try TrayPlacementPolicy.replacingDrafts(in: PendingDraftStore(),
                targets: [.init(rule: rule, identity: nil)], group: group)
            let loaded = try JSONDecoder().decode(PendingDraftStore.self, from: JSONEncoder().encode(drafts))
            XCTAssertEqual(loaded.record(for: id, sessionIdentity: nil)?.rule, rule)
        }
    }

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

    func testPositionIdentityPreservesExactKeyWithoutProcessOrDisplayIdentity() throws {
        let makeIdentity: (String?, String) -> String? = MenuItemIdentity.persistentPositionID
        let key = "status:example.app::primary"
        let first = try XCTUnwrap(makeIdentity("example.app", key))
        XCTAssertEqual(first, makeIdentity("example.app", key))
        XCTAssertNotEqual(first, makeIdentity("example.app", "status:example.app::replacement"))
        XCTAssertEqual(MenuItemIdentity.positionKey(inPersistentID: first, bundleIdentifier: "example.app"), key)
        XCTAssertEqual(try decode(first), ["menu-bar-position-v1", "example.app", key])
    }

    func testPositionIdentityCannotCollideWithExistingAccessibilityIdentity() throws {
        let key = "status:example.app::primary"
        let position = try XCTUnwrap(MenuItemIdentity.persistentPositionID(bundleIdentifier: "example.app", positionKey: key))
        let accessibility = try XCTUnwrap(MenuItemIdentity.persistentID(bundleIdentifier: "example.app",
            accessibilityIdentifier: key, occurrenceCount: 1))
        XCTAssertNotEqual(position, accessibility)
        XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: accessibility, bundleIdentifier: "example.app"))
        XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: "session:42:old", bundleIdentifier: "example.app"))
    }

    func testPositionIdentityRejectsMissingOrInexactOwnerAndEmptyAutosaveName() {
        for (bundle, key) in [(nil as String?, "status:example.app::primary"),
                              ("", "status:::primary"),
                              ("example.app", "status:example.other::primary"),
                              ("example.app", "status:example.application::primary"),
                              ("example.app", "status:example.app::"),
                              ("example.app", "primary")] {
            XCTAssertNil(MenuItemIdentity.persistentPositionID(bundleIdentifier: bundle, positionKey: key))
        }
    }

    func testRetainedPositionIdentityRejectsDifferentOwnerUnsupportedVersionAndNoncanonicalData() throws {
        let identity = try XCTUnwrap(MenuItemIdentity.persistentPositionID(bundleIdentifier: "example.app",
            positionKey: "status:example.app::primary"))
        XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: identity, bundleIdentifier: "example.other"))
        XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: identity, bundleIdentifier: nil))
        for invalid in [identity.replacingOccurrences(of: "menu-bar-position-v1", with: "menu-bar-position-v2"),
                        "item: [\"menu-bar-position-v1\",\"example.app\",\"status:example.app::primary\"]",
                        "item:[\"menu-bar-position-v1\",\"example.app\"]",
                        "item:not-json"] {
            XCTAssertNil(MenuItemIdentity.positionKey(inPersistentID: invalid, bundleIdentifier: "example.app"))
        }
    }

    func testPositionIdentityKeepsPunctuationAndUnicodeKeysExact() throws {
        let bundle = "example.菜单栏"
        let key = "status:\(bundle)::状态 🛰️ / café / cafe\u{301} / \"quoted\" \\ value"
        let identity = try XCTUnwrap(MenuItemIdentity.persistentPositionID(bundleIdentifier: bundle, positionKey: key))
        XCTAssertEqual(MenuItemIdentity.positionKey(inPersistentID: identity, bundleIdentifier: bundle), key)
        let other = try XCTUnwrap(MenuItemIdentity.persistentPositionID(bundleIdentifier: bundle,
            positionKey: key + "::another"))
        XCTAssertNotEqual(identity, other)
    }

    private func decode(_ identity: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(identity.dropFirst("item:".count).utf8))
    }
}
