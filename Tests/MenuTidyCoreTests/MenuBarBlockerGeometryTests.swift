import XCTest
@testable import MenuTidyCore

final class MenuBarBlockerGeometryTests: XCTestCase {
    func testUsesLocalRightEdgeBudgetInsteadOfWholeScreenWidth() throws {
        let width = try XCTUnwrap(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_158.5, leftEdge: 956.5, requested: 20, actual: 36))
        XCTAssertEqual(width, 166)
        XCTAssertEqual(width + 16, 1_158.5 - 956.5 - 20)
        XCTAssertLessThan(width, 202)
    }

    func testNoHostOverheadDoesNotAddAnInventedAdjustment() {
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 300, leftEdge: 100, requested: 20, actual: 20), 180)
    }

    func testReusingTheAppliedPhysicalFrameDoesNotGrowOnEachPass() throws {
        let first = try XCTUnwrap(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_158.5, leftEdge: 956.5, requested: 20, actual: 36))
        let repeated = MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_158.5, leftEdge: 956.5, requested: first, actual: first + 16)
        XCTAssertEqual(repeated, first)
    }

    func testShrinksWithinANewSmallerVerifiedBudget() {
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 190, leftEdge: 0, requested: 166, actual: 182), 154)
    }

    func testNotchStraddlingVerifiedHostFrameOnlyShrinksIntoTheRightArea() throws {
        // Build 41: x=928.5, width=186; a restored neighbour moved our
        // divider left of the real 956.5-point right-area boundary.
        let fitted = try XCTUnwrap(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_114.5, leftEdge: 956.5, requested: 170, actual: 186))
        XCTAssertEqual(fitted, 122)
        XCTAssertLessThan(fitted, 170)
        XCTAssertEqual(1_114.5 - (fitted + 16), 956.5 + MenuBarBlockerGeometry.leadingReserve)
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_114.5, leftEdge: 956.5, requested: fitted, actual: fitted + 16), fitted)
    }

    func testNotchShrinkDoesNotInventSpaceOrTrustAnIgnoredRequest() {
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_010, leftEdge: 956.5, requested: 170, actual: 186))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 956.5, leftEdge: 956.5, requested: 170, actual: 186))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 950, leftEdge: 956.5, requested: 170, actual: 186))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_114.5, leftEdge: 956.5, requested: 200, actual: 186))
    }

    func testNotchShrinkSupportsTranslatedNegativeScreenCoordinates() {
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: -613.5, leftEdge: -771.5, requested: 170, actual: 186), 122)
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: -613.5, leftEdge: -613.5, requested: 170, actual: 186))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: -613.5, leftEdge: -771.5, requested: 170, actual: -186))
    }

    func testExactMinimumFitsButSmallerBudgetIsRejected() {
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 56, leftEdge: 0, requested: 20, actual: 36), 20)
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 55.99, leftEdge: 0, requested: 20, actual: 36))
    }

    func testIgnoredOversizedRequestCannotBecomeCalibrationEvidence() {
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 300, leftEdge: 0, requested: 500, actual: 36))
    }

    func testPartlyOffscreenFrameAndReversedEdgesAreRejected() {
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 30, leftEdge: 0, requested: 20, actual: 36))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(
            frameRight: 0, leftEdge: 1, requested: 20, actual: 36))
    }

    func testNegativeGlobalScreenCoordinatesPreserveTranslationInvariance() {
        XCTAssertEqual(MenuBarBlockerGeometry.fittedWidth(
            frameRight: -1_000, leftEdge: -1_202, requested: 20, actual: 36), 166)
    }

    func testInvalidValuesAndArithmeticOverflowNeverProduceAWidth() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: invalid, leftEdge: 0, requested: 20, actual: 36))
            XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: 200, leftEdge: invalid, requested: 20, actual: 36))
            XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: 200, leftEdge: 0, requested: invalid, actual: 36))
            XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: 200, leftEdge: 0, requested: 20, actual: invalid))
        }
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: .greatestFiniteMagnitude,
            leftEdge: -.greatestFiniteMagnitude, requested: 20, actual: 36))
        XCTAssertNil(MenuBarBlockerGeometry.fittedWidth(frameRight: 200, leftEdge: 0, requested: 0, actual: 36))
    }

    func testSingleItemReservationPreservesHostPaddingAndLeftEdge() throws {
        let reserved = try XCTUnwrap(MenuBarBlockerGeometry.reservedWidth(
            requested: 166, actual: 182, targetHostWidth: 41))
        XCTAssertEqual(reserved, 125)
        XCTAssertEqual(reserved + 16, 182 - 41)
        let refitted = MenuBarBlockerGeometry.fittedWidth(
            frameRight: 1_158.5 - 41, leftEdge: 956.5, requested: reserved, actual: reserved + 16)
        XCTAssertEqual(refitted, reserved)
    }

    func testReservationRejectsTheShortMarkerLength() {
        XCTAssertEqual(MenuBarBlockerGeometry.reservedWidth(requested: 141, actual: 157, targetHostWidth: 120), 21)
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 140, actual: 156, targetHostWidth: 120))
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 139.99, actual: 155.99, targetHostWidth: 120))
    }

    func testReservationRejectsIgnoredLengthsAndUnboundedTargets() {
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 166, actual: 36, targetHostWidth: 24))
        for target in [0.0, -1, 120.01, .infinity, .nan] {
            XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 166, actual: 182, targetHostWidth: target))
        }
    }

    func testInvalidReservationGeometryCannotYieldARequest() {
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: .nan, actual: 182, targetHostWidth: 24))
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 166, actual: .infinity, targetHostWidth: 24))
        XCTAssertNil(MenuBarBlockerGeometry.reservedWidth(requested: 0, actual: 20, targetHostWidth: 4))
    }

}
