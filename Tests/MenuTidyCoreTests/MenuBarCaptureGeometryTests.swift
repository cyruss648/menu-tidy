import XCTest
@testable import MenuTidyCore

final class MenuBarCaptureGeometryTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let band = CGRect(x: 0, y: 0, width: 1728, height: 32)

    func testHostedThirtyThreePointIconIsClippedToMenuBand() {
        let actual = CGRect(x: 1428.5, y: 0, width: 41, height: 33)
        XCTAssertEqual(MenuBarCaptureGeometry.captureRectangle(for: actual, band: band, display: display),
            CGRect(x: 1428, y: 0, width: 42, height: 32))
    }

    func testFractionalIconRoundsOutwardWithinBand() {
        XCTAssertEqual(MenuBarCaptureGeometry.captureRectangle(
            for: CGRect(x: 1438, y: 4.5, width: 24, height: 24), band: band, display: display),
            CGRect(x: 1438, y: 4, width: 24, height: 25))
    }

    func testRejectsPopupAndOutOfBandFrames() {
        for frame in [CGRect(x: 900, y: 0, width: 30, height: 33.01),
                      CGRect(x: 900, y: 25, width: 24, height: 24),
                      CGRect(x: -1, y: 4, width: 24, height: 24),
                      CGRect(x: 1710, y: 4, width: 24, height: 24)] {
            XCTAssertNil(MenuBarCaptureGeometry.captureRectangle(for: frame, band: band, display: display))
        }
    }

    func testRejectsFullBarAndInvalidGeometry() {
        for frame in [band, CGRect(x: 0, y: 0, width: 0, height: 20),
                      CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)] {
            XCTAssertNil(MenuBarCaptureGeometry.captureRectangle(for: frame, band: band, display: display))
        }
    }

    func testWorksWithNonzeroDisplayOrigin() {
        let offsetDisplay = CGRect(x: -1728, y: 100, width: 1728, height: 1117)
        let offsetBand = CGRect(x: -1728, y: 100, width: 1728, height: 32)
        XCTAssertEqual(MenuBarCaptureGeometry.captureRectangle(for: CGRect(x: -300, y: 100, width: 30, height: 33),
            band: offsetBand, display: offsetDisplay), CGRect(x: -300, y: 100, width: 30, height: 32))
    }

    func testSelectsSecondaryDisplayFromGlobalItemFrame() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: -37, width: 1728, height: 1117)
        XCTAssertEqual(MenuBarCaptureGeometry.displayBounds(
            containing: CGRect(x: 3008, y: -32.5, width: 36, height: 24),
            candidates: [primary, secondary]), secondary)
    }

    func testDisplaySelectionFallsBackToLargestOverlap() {
        let upper = CGRect(x: 0, y: 0, width: 100, height: 100)
        let lower = CGRect(x: 0, y: 100, width: 100, height: 100)
        XCTAssertEqual(MenuBarCaptureGeometry.displayBounds(
            containing: CGRect(x: 10, y: 95, width: 20, height: 20),
            candidates: [upper, lower]), lower)
    }
}
