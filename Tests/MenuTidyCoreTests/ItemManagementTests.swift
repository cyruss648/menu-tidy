import Foundation
import XCTest
@testable import MenuTidyCore

final class ItemManagementTests: XCTestCase {
    func testNormalSectionStatesUseExactlyTheIntendedBoundary() {
        let cases: [(collapsed: Bool, hasAlwaysHidden: Bool, regular: Bool, always: Bool)] = [
            (false, false, false, false),
            (false, true, false, true),
            (true, false, true, false),
            (true, true, true, false),
        ]
        for state in cases {
            let result = MenuBarSectionPolicy.separatorVisibility(
                isCollapsed: state.collapsed,
                hasAlwaysHidden: state.hasAlwaysHidden,
                isManaging: false,
                temporarilyRevealingAll: false
            )
            XCTAssertEqual(result.collapseRegular, state.regular)
            XCTAssertEqual(result.collapseAlways, state.always)
        }
    }

    func testManagingAndTemporaryRevealOverrideEveryCollapsedState() {
        let revealStates = [(true, false), (false, true), (true, true)]
        for (managing, revealing) in revealStates {
            for collapsed in [false, true] {
                for hasAlwaysHidden in [false, true] {
                    let result = MenuBarSectionPolicy.separatorVisibility(
                        isCollapsed: collapsed,
                        hasAlwaysHidden: hasAlwaysHidden,
                        isManaging: managing,
                        temporarilyRevealingAll: revealing
                    )
                    XCTAssertFalse(result.collapseRegular)
                    XCTAssertFalse(result.collapseAlways)
                }
            }
        }
    }

    func testUpdatingAnItemReplacesItsRuleWithoutLosingOtherItems() {
        let first = ItemRule(id: "app.one.status", name: "旧名称", bundleIdentifier: "app.one", visibility: .visible)
        let other = ItemRule(id: "app.two.status", name: "第二个应用", bundleIdentifier: "app.two", visibility: .alwaysHidden)
        var book = ItemRuleBook(rules: [first.id: first, other.id: other])
        let updated = ItemRule(id: first.id, name: "新名称", bundleIdentifier: "app.one", visibility: .collapsible)

        book.set(updated)

        XCTAssertEqual(book.rules.count, 2)
        XCTAssertEqual(book.rule(for: first.id), updated)
        XCTAssertEqual(book.rule(for: other.id), other)
    }

    func testItemsFromTheSameApplicationKeepIndependentChoices() {
        var book = ItemRuleBook()
        let first = ItemRule(id: "app.one.first", name: "状态", bundleIdentifier: "app.one", visibility: .visible)
        let second = ItemRule(id: "app.one.second", name: "工具", bundleIdentifier: "app.one", visibility: .alwaysHidden)

        book.set(first)
        book.set(second)
        book.remove(id: first.id)
        book.remove(id: "already.missing")

        XCTAssertNil(book.rule(for: first.id))
        XCTAssertEqual(book.rules.count, 1)
        XCTAssertEqual(book.rule(for: second.id), second)
    }

    func testRuleBookRoundTripPreservesEveryCategoryAndMissingBundleIdentifier() throws {
        var book = ItemRuleBook()
        for visibility in ItemVisibility.allCases {
            book.set(ItemRule(
                id: "item.\(visibility.rawValue)",
                name: "图标 · \(visibility.title)",
                bundleIdentifier: visibility == .alwaysHidden ? nil : "example.application",
                visibility: visibility
            ))
        }

        let encoded = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(ItemRuleBook.self, from: encoded)

        XCTAssertEqual(decoded, book)
        XCTAssertNil(decoded.rule(for: "item.alwaysHidden")?.bundleIdentifier)
        XCTAssertEqual(decoded.rule(for: "item.alwaysHidden")?.visibility, .alwaysHidden)
    }

    func testUnknownCategoryRejectsEntireRuleBookInsteadOfDroppingTheRule() {
        let json = #"{"rules":{"item.one":{"id":"item.one","name":"应用","visibility":"visible"},"item.two":{"id":"item.two","name":"重要应用","visibility":"futureCategory"}}}"#

        XCTAssertThrowsError(try JSONDecoder().decode(ItemRuleBook.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected an unknown category decoding error, got \(error)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "visibility")
        }
    }

    func testMismatchedDictionaryKeyRejectsEntireRuleBookInsteadOfApplyingAnotherItemsRule() {
        let json = #"{"rules":{"item.one":{"id":"item.one","name":"应用","visibility":"visible"},"item.two":{"id":"item.three","name":"另一个应用","visibility":"alwaysHidden"}}}"#

        XCTAssertThrowsError(try JSONDecoder().decode(ItemRuleBook.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected a mismatched rule identity decoding error, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["rules"])
        }
    }

    func testEmptyBookRoundTripDoesNotInventRules() throws {
        let book = ItemRuleBook()
        let decoded = try JSONDecoder().decode(ItemRuleBook.self, from: JSONEncoder().encode(book))
        XCTAssertTrue(decoded.rules.isEmpty)
        XCTAssertNil(decoded.rule(for: "missing.item"))
    }
}
