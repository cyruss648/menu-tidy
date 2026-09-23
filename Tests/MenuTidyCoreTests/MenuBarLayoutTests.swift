import XCTest
@testable import MenuTidyCore

final class MenuBarLayoutTests: XCTestCase {
    func testModernLayoutPrefersTheRightRegionOfANotchedDisplay() {
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: 1_512,
                rightAreaWidth: 656,
                modernMenuBar: true
            ),
            604
        )
    }

    func testModernLayoutFallsBackToScreenMinusApplicationMenus() {
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: 1_920,
                rightAreaWidth: nil,
                applicationMenuWidth: 480,
                modernMenuBar: true
            ),
            1_388
        )
    }

    func testModernWidthRemainsBoundedWhenSpaceIsTight() {
        for availableWidth in [1.0, 20, 32, 64] {
            XCTAssertEqual(
                MenuBarLayout.collapsedLength(
                    screenWidth: 1_512,
                    rightAreaWidth: availableWidth,
                    modernMenuBar: true
                ),
                32
            )
        }
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: 200,
                rightAreaWidth: nil,
                modernMenuBar: true
            ),
            32
        )
    }

    func testInvalidRightRegionUsesFallbackGeometry() {
        for invalidWidth in [Double.nan, .infinity, -.infinity, 0, -100] {
            XCTAssertEqual(
                MenuBarLayout.collapsedLength(
                    screenWidth: 1_920,
                    rightAreaWidth: invalidWidth,
                    modernMenuBar: true
                ),
                1_568
            )
        }
    }

    func testModernSpacerLeavesRoomForBothOtherStatusItemsAndMargin() {
        // This display geometry previously produced 787.5 points of our own
        // items inside a 771.5-point region, before any external icons existed.
        let availableWidth = 771.5
        let spacer = MenuBarLayout.collapsedLength(
            screenWidth: 1_728,
            rightAreaWidth: availableWidth,
            modernMenuBar: true
        )
        let totalWidth = spacer + MenuBarLayout.controlWidth + MenuBarLayout.expandedLength

        XCTAssertEqual(spacer, 719.5)
        XCTAssertEqual(availableWidth - totalWidth, 4)
    }

    func testModernThreeItemWidthFitsEveryRegionAtOrAboveItsMinimum() {
        for availableWidth in [80.0, 81, 84, 85, 200, 656, 771.5, 1_440, 20_000] {
            let spacer = MenuBarLayout.collapsedLength(
                screenWidth: 1_728,
                rightAreaWidth: availableWidth,
                modernMenuBar: true
            )
            let totalWidth = spacer + MenuBarLayout.controlWidth + MenuBarLayout.expandedLength
            XCTAssertLessThanOrEqual(totalWidth, availableWidth)
        }
    }

    func testExtremelyNarrowRegionExplicitlyCannotFitTheRetainedSpacerMinimum() {
        let availableWidth = 79.0
        let spacer = MenuBarLayout.collapsedLength(
            screenWidth: 1_728,
            rightAreaWidth: availableWidth,
            modernMenuBar: true
        )
        let totalWidth = spacer + MenuBarLayout.controlWidth + MenuBarLayout.expandedLength

        XCTAssertEqual(spacer, 32)
        XCTAssertEqual(totalWidth, 80)
        XCTAssertGreaterThan(totalWidth, availableWidth)
    }

    func testLegacySpacerExtendsPastTheWidestScreen() {
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: 3_840,
                rightAreaWidth: 200,
                modernMenuBar: false
            ),
            7_680
        )
    }

    func testLegacyWidthHonorsMinimumAndMaximum() {
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: 100,
                rightAreaWidth: nil,
                modernMenuBar: false
            ),
            500
        )
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: .greatestFiniteMagnitude,
                rightAreaWidth: nil,
                modernMenuBar: false
            ),
            10_000
        )
    }

    func testModernWidthCapsExtremeGeometry() {
        XCTAssertEqual(
            MenuBarLayout.collapsedLength(
                screenWidth: .greatestFiniteMagnitude,
                rightAreaWidth: .greatestFiniteMagnitude,
                modernMenuBar: true
            ),
            10_000
        )
    }

    func testAllInvalidGeometryProducesFinitePositiveWidths() {
        for modern in [true, false] {
            let length = MenuBarLayout.collapsedLength(
                screenWidth: .nan,
                rightAreaWidth: .infinity,
                applicationMenuWidth: .nan,
                modernMenuBar: modern
            )
            XCTAssertTrue(length.isFinite)
            XCTAssertGreaterThanOrEqual(length, 32)
            XCTAssertLessThanOrEqual(length, 10_000)
        }
    }
}
