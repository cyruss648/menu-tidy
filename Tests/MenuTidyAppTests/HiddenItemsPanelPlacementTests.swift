import Foundation
import XCTest
@testable import MenuTidy

final class HiddenItemsPanelPlacementTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let primaryAnchor = CGRect(x: 1700, y: 1058, width: 22, height: 22)

    func testClickOverridesPrimaryAnchorForEverySecondaryDisplayArrangement() throws {
        for secondary in [CGRect(x: 1920, y: 0, width: 1728, height: 1117),
                          CGRect(x: -1728, y: -37, width: 1728, height: 1117),
                          CGRect(x: 0, y: 1080, width: 1728, height: 1117),
                          CGRect(x: 0, y: -1117, width: 1728, height: 1117)] {
            let click = CGPoint(x: secondary.maxX - 100, y: secondary.maxY - 12)
            let placement = try XCTUnwrap(HiddenItemsPanelPlacement.resolve(
                screenFrames: [primary, secondary], clickPoint: click, anchor: primaryAnchor))
            XCTAssertEqual(placement.screenIndex, 1)
            XCTAssertEqual(placement.anchorX, click.x)
        }
    }

    func testPrimaryClickOverridesSecondaryAnchor() throws {
        let secondary = CGRect(x: 1920, y: 0, width: 1728, height: 1117)
        let placement = try XCTUnwrap(HiddenItemsPanelPlacement.resolve(screenFrames: [primary, secondary],
            clickPoint: CGPoint(x: 1750, y: 1068),
            anchor: CGRect(x: 3500, y: 1095, width: 22, height: 22), fallbackScreenIndex: 1))
        XCTAssertEqual(placement.screenIndex, 0)
        XCTAssertEqual(placement.anchorX, 1750)
    }

    func testQuartzAnchorConversionUsesPrimaryOriginForOffsetDisplays() throws {
        for (quartzY, appKitY) in [(CGFloat(-37), CGFloat(1095)),
                                  (CGFloat(-1117), CGFloat(2175)),
                                  (CGFloat(1080), CGFloat(-22))] {
            let converted = try XCTUnwrap(HiddenItemsPanelPlacement.appKitAnchor(
                fromQuartz: CGRect(x: -100, y: quartzY, width: 22, height: 22), primaryScreenFrame: primary))
            XCTAssertEqual(converted, CGRect(x: -100, y: appKitY, width: 22, height: 22))
        }
    }

    func testNoClickUsesConvertedAnchorBeforeActiveScreen() throws {
        let secondary = CGRect(x: 1920, y: 0, width: 1728, height: 1117)
        let anchor = HiddenItemsPanelPlacement.appKitAnchor(
            fromQuartz: CGRect(x: 3500, y: -37, width: 22, height: 22), primaryScreenFrame: primary)
        let placement = try XCTUnwrap(HiddenItemsPanelPlacement.resolve(
            screenFrames: [primary, secondary], clickPoint: nil, anchor: anchor))
        XCTAssertEqual(placement.screenIndex, 1)
        XCTAssertEqual(placement.anchorX, 3511)
    }

    func testUnavailableClickFallsBackWithoutSelectingOriginForZeroAnchor() throws {
        for click in [nil, CGPoint(x: 5000, y: 5000), CGPoint(x: CGFloat.infinity, y: 0)] {
            let placement = try XCTUnwrap(HiddenItemsPanelPlacement.resolve(screenFrames: [primary, primary],
                clickPoint: click, anchor: .zero, fallbackScreenIndex: 1))
            XCTAssertEqual(placement.screenIndex, 1)
            XCTAssertNil(placement.anchorX)
        }
        XCTAssertNil(HiddenItemsPanelPlacement.resolve(screenFrames: [], clickPoint: nil, anchor: nil))
        XCTAssertNil(HiddenItemsPanelPlacement.appKitAnchor(fromQuartz: .zero, primaryScreenFrame: primary))
    }
}
