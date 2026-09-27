import CoreGraphics
import XCTest
@testable import MenuTidyCore

final class MenuBarScreenLayoutTests: XCTestCase {
    private func screen(_ id: UInt32 = 1, frame: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        bounds: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: Double = 2,
                        safeAreaTop: Double = 33, left: CGRect? = CGRect(x: 0, y: 1084, width: 799, height: 33),
                        right: CGRect? = CGRect(x: 929, y: 1084, width: 799, height: 33)) -> MenuBarScreenLayout.Screen {
        .init(displayID: id, frame: frame, bounds: bounds, scale: scale, safeAreaTop: safeAreaTop,
            auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right)
    }

    private func layout(_ screens: [MenuBarScreenLayout.Screen], main: UInt32 = 1,
                        thickness: Double = 24) throws -> MenuBarScreenLayout {
        try XCTUnwrap(MenuBarScreenLayout(screens: screens, mainDisplayID: main, menuBarThickness: thickness))
    }

    func testRepeatedNotificationWithRecreatedScreenValuesDoesNotInvalidate() throws {
        let previous = try layout([screen()])
        let current = try layout([screen()])
        XCTAssertNil(MenuBarScreenLayout.invalidationReason(from: previous, to: current))
    }

    func testOnlyNonPrimaryEnumerationOrderCanChangeWithoutInvalidation() throws {
        let previous = try layout([screen(), screen(2), screen(3)])
        XCTAssertNil(MenuBarScreenLayout.invalidationReason(from: previous,
            to: try layout([screen(), screen(3), screen(2)])))
        XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous,
            to: try layout([screen(2), screen(), screen(3)])), .primaryDisplayChanged)
        XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous,
            to: try layout([screen(), screen(2), screen(3)], main: 2)), .primaryDisplayChanged)
    }

    func testAddingRemovingOrReplacingADisplayInvalidatesEvenWithMatchingGeometry() throws {
        let previous = try layout([screen(), screen(2)])
        for screens in [[screen()], [screen(), screen(2), screen(3)], [screen(), screen(3)]] {
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous, to: try layout(screens)),
                .displaySetChanged)
        }
    }

    func testAppKitOrQuartzGeometryChangesOnAnyScreenInvalidate() throws {
        let previous = try layout([screen(), screen(2)])
        let moved = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let resized = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for changed in [screen(2, frame: moved), screen(2, bounds: moved),
                        screen(2, frame: resized), screen(2, bounds: resized)] {
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous,
                to: try layout([screen(), changed])), .displayGeometryChanged)
        }
    }

    func testScaleChangeInvalidatesEvenWhenPointGeometryIsUnchanged() throws {
        XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: try layout([screen()]),
            to: try layout([screen(scale: 1)])), .scaleChanged)
    }

    func testMenuBandAndAvailableNotchRegionsIndependentlyInvalidate() throws {
        let previous = try layout([screen()])
        for changed in [screen(safeAreaTop: 38), screen(left: nil), screen(right: nil),
                        screen(left: CGRect(x: 0, y: 1084, width: 750, height: 33)),
                        screen(right: CGRect(x: 950, y: 1084, width: 778, height: 33))] {
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous,
                to: try layout([changed])), .menuBarGeometryChanged)
        }
        XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous,
            to: try layout([screen()], thickness: 28)), .menuBarGeometryChanged)
    }

    func testDisplaysWithoutANotchCanRetainAnUnchangedValidLayout() throws {
        let previous = try layout([screen(safeAreaTop: 0, left: nil, right: nil)])
        let current = try layout([screen(safeAreaTop: 0, left: nil, right: nil)])
        XCTAssertNil(MenuBarScreenLayout.invalidationReason(from: previous, to: current))
    }

    func testIncompleteOrInvalidGeometryNeverSuppressesInvalidation() throws {
        let previous = try layout([screen()])
        let invalidLayouts: [MenuBarScreenLayout?] = [
            nil,
            MenuBarScreenLayout(screens: [], mainDisplayID: 1, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen(), screen()], mainDisplayID: 1, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen()], mainDisplayID: 9, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen()], mainDisplayID: 1, menuBarThickness: .nan),
            MenuBarScreenLayout(screens: [screen(scale: 0)], mainDisplayID: 1, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen(safeAreaTop: .infinity)], mainDisplayID: 1, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen(bounds: .zero)], mainDisplayID: 1, menuBarThickness: 24),
            MenuBarScreenLayout(screens: [screen(right: .null)], mainDisplayID: 1, menuBarThickness: 24)
        ]
        for invalid in invalidLayouts {
            XCTAssertNil(invalid)
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: previous, to: invalid), .unavailableGeometry)
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: invalid, to: previous), .unavailableGeometry)
            XCTAssertEqual(MenuBarScreenLayout.invalidationReason(from: invalid, to: invalid), .unavailableGeometry)
        }
    }
}
