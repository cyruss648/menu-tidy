import XCTest
@testable import MenuTidyCore

final class MenuBarIconMatteTests: XCTestCase {
    private let green: [UInt8] = [24, 100, 52, 255]
    private let white: [UInt8] = [255, 255, 255, 255]
    private let purple: [UInt8] = [170, 55, 205, 255]

    func testWhiteGlyphOnGreenBecomesBlackTemplateWithCoverage() throws {
        var pixels = bitmap(width: 9, height: 9)
        set(&pixels, width: 9, x: 4, y: 4, color: white)
        set(&pixels, width: 9, x: 3, y: 4, color: [140, 178, 154, 255])
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertTrue(result.isTemplate)
        XCTAssertTrue(result.removedBackground)
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 4, y: 4), [0, 0, 0, 255])
        XCTAssertLessThanOrEqual(abs(Int(pixel(result.pixels, width: 9, x: 3, y: 4)[3]) - 128), 1)
        XCTAssertTrue(result.pixels.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 })
    }

    func testBlackGlyphUsesBlackEndpoint() throws {
        var pixels = bitmap(width: 9, height: 9)
        set(&pixels, width: 9, x: 4, y: 4, color: [0, 0, 0, 255])
        set(&pixels, width: 9, x: 4, y: 3, color: [12, 50, 26, 255])
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 4, y: 4), [0, 0, 0, 255])
        XCTAssertLessThanOrEqual(abs(Int(pixel(result.pixels, width: 9, x: 4, y: 3)[3]) - 128), 1)
    }

    func testPurpleBadgeKeepsWhiteAndColoredPixelsUntouchedEvenAtBorder() throws {
        var pixels = bitmap(width: 11, height: 11)
        set(&pixels, width: 11, x: 5, y: 5, color: white)
        set(&pixels, width: 11, x: 9, y: 0, color: purple)
        set(&pixels, width: 11, x: 9, y: 1, color: purple)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 11, height: 11, pixels: pixels))
        XCTAssertFalse(result.isTemplate)
        XCTAssertTrue(result.removedBackground)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 5, y: 5), white)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 9, y: 0), purple)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 9, y: 1), purple)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 0, y: 0), [0, 0, 0, 0])
    }

    func testProvenMonochromeRingClearsEnclosedGreenHole() throws {
        var pixels = ring()
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 4, y: 4), [0, 0, 0, 0])
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 3, y: 4), [0, 0, 0, 255])

        set(&pixels, width: 9, x: 6, y: 6, color: purple)
        let colored = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertFalse(colored.isTemplate)
        XCTAssertEqual(pixel(colored.pixels, width: 9, x: 4, y: 4), [0, 0, 0, 0])
        XCTAssertEqual(pixel(colored.pixels, width: 9, x: 6, y: 6), purple)
        XCTAssertEqual(pixel(colored.pixels, width: 9, x: 0, y: 0), [0, 0, 0, 0])
    }

    func testFloodFillUsesFixedBackgroundInsteadOfFollowingColorGradient() throws {
        var pixels = bitmap(width: 11, height: 11)
        set(&pixels, width: 11, x: 5, y: 1, color: [34, 110, 62, 255])
        set(&pixels, width: 11, x: 5, y: 2, color: [44, 120, 72, 255])
        set(&pixels, width: 11, x: 7, y: 7, color: purple)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 11, height: 11, pixels: pixels))
        XCTAssertFalse(result.isTemplate)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 5, y: 1), [0, 0, 0, 0])
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 5, y: 2), [44, 120, 72, 255])
    }

    func testUniformBackdropInsideColoredGlyphIsClearedWithoutRemovingGlyph() throws {
        var pixels = bitmap(width: 9, height: 9)
        for (x, y) in [(3, 4), (4, 3), (5, 4), (4, 5)] {
            set(&pixels, width: 9, x: x, y: y, color: purple)
        }
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertFalse(result.isTemplate)
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 4, y: 4), [0, 0, 0, 0])
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 3, y: 4), purple)
        XCTAssertEqual(pixel(result.pixels, width: 9, x: 3, y: 3), [0, 0, 0, 0])
    }

    func testNonuniformBorderIsPreserved() throws {
        var pixels = bitmap(width: 9, height: 9)
        for x in 0..<9 { set(&pixels, width: 9, x: x, y: 0, color: purple) }
        set(&pixels, width: 9, x: 4, y: 4, color: white)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertEqual(result.pixels, pixels)
        XCTAssertFalse(result.isTemplate)
        XCTAssertFalse(result.removedBackground)
    }

    func testGlyphTouchingOneEdgeKeepsShapeAndRemovesBackground() throws {
        var pixels = bitmap(width: 11, height: 11)
        for y in 2...8 { set(&pixels, width: 11, x: 0, y: y, color: white) }
        set(&pixels, width: 11, x: 1, y: 5, color: white)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 11, height: 11, pixels: pixels))
        XCTAssertTrue(result.removedBackground)
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 0, y: 5), [0, 0, 0, 255])
        XCTAssertEqual(pixel(result.pixels, width: 11, x: 0, y: 0), [0, 0, 0, 0])
    }

    func testOverallMajorityStillRequiresConsistentMultipleSides() throws {
        var pixels = bitmap(width: 31, height: 5)
        for y in 0..<5 { set(&pixels, width: 31, x: 0, y: y, color: purple) }
        set(&pixels, width: 31, x: 15, y: 2, color: white)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 31, height: 5, pixels: pixels))
        XCTAssertEqual(result.pixels, pixels)
        XCTAssertFalse(result.removedBackground)
    }

    func testUniformPatchHasNoProvenForeground() throws {
        let pixels = bitmap(width: 9, height: 9)
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertEqual(result.pixels, pixels)
        XCTAssertFalse(result.isTemplate)
        XCTAssertFalse(result.removedBackground)
    }

    func testTransparentInputIsNotReinterpretedAsOpaqueOrUnpremultiplied() throws {
        var pixels = bitmap(width: 9, height: 9)
        set(&pixels, width: 9, x: 4, y: 4, color: [20, 10, 30, 80])
        let result = try XCTUnwrap(MenuBarIconMatte.process(width: 9, height: 9, pixels: pixels))
        XCTAssertEqual(result.pixels, pixels)
        XCTAssertFalse(result.isTemplate)
        XCTAssertFalse(result.removedBackground)
    }

    func testInvalidDimensionsAndBuffersAreRejectedWithoutOverflow() {
        XCTAssertNil(MenuBarIconMatte.process(width: 0, height: 9, pixels: []))
        XCTAssertNil(MenuBarIconMatte.process(width: -1, height: 9, pixels: []))
        XCTAssertNil(MenuBarIconMatte.process(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 15)))
        XCTAssertNil(MenuBarIconMatte.process(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 20)))
        XCTAssertNil(MenuBarIconMatte.process(width: Int.max, height: 2, pixels: []))
        XCTAssertNil(MenuBarIconMatte.process(width: Int.max / 2, height: 1, pixels: []))
    }

    private func bitmap(width: Int, height: Int) -> [UInt8] {
        (0..<(width * height)).flatMap { _ in green }
    }

    private func set(_ pixels: inout [UInt8], width: Int, x: Int, y: Int, color: [UInt8]) {
        let start = (y * width + x) * 4
        pixels.replaceSubrange(start..<(start + 4), with: color)
    }

    private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(pixels[start..<(start + 4)])
    }

    private func ring() -> [UInt8] {
        var pixels = bitmap(width: 9, height: 9)
        for y in 3...5 {
            for x in 3...5 where x != 4 || y != 4 {
                set(&pixels, width: 9, x: x, y: y, color: white)
            }
        }
        return pixels
    }
}
