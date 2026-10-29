import AppKit
import XCTest
@testable import MenuTidy

@MainActor
final class MenuBarIconPersistentCacheTests: XCTestCase {
    func testImageSurvivesStoreRecreation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(color: .systemBlue)
        let first = MenuBarIconPersistentCache(directory: directory)
        XCTAssertTrue(first.save(image: image, key: "presentation:application:com.example.ClashVerge",
            bundleIdentifier: "com.example.ClashVerge", logicalSize: CGSize(width: 22, height: 22),
            environmentSignature: "dark|screen-1"))

        let second = MenuBarIconPersistentCache(directory: directory)
        let loaded = second.load(key: "presentation:application:com.example.ClashVerge",
            bundleIdentifier: "com.example.ClashVerge", logicalSize: CGSize(width: 22, height: 22),
            environmentSignature: "dark|screen-1")
        XCTAssertNotNil(loaded)
        let loadedSize = try XCTUnwrap(loaded?.image.size)
        XCTAssertEqual(loadedSize.width, 22, accuracy: 0.01)
        XCTAssertEqual(loadedSize.height, 22, accuracy: 0.01)
    }

    func testChangedIdentityGeometryOrEnvironmentDoesNotRestoreImage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(color: .systemOrange)
        let store = MenuBarIconPersistentCache(directory: directory)
        let key = "presentation:application:com.example.ClashVerge"
        XCTAssertTrue(store.save(image: image, key: key, bundleIdentifier: "com.example.ClashVerge",
            logicalSize: CGSize(width: 22, height: 22), environmentSignature: "dark|screen-1"))

        XCTAssertNil(store.load(key: key, bundleIdentifier: "com.example.Other",
            logicalSize: CGSize(width: 22, height: 22), environmentSignature: "dark|screen-1"))
        XCTAssertNil(store.load(key: key, bundleIdentifier: "com.example.ClashVerge",
            logicalSize: CGSize(width: 44, height: 22), environmentSignature: "dark|screen-1"))
        XCTAssertNil(store.load(key: key, bundleIdentifier: "com.example.ClashVerge",
            logicalSize: CGSize(width: 22, height: 22), environmentSignature: "aqua|screen-1"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-tidy-icon-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeImage(color: NSColor) throws -> NSImage {
        let image = NSImage(size: CGSize(width: 22, height: 22))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard image.tiffRepresentation != nil else { throw NSError(domain: "MenuTidyIconCacheTests", code: 1) }
        return image
    }
}
