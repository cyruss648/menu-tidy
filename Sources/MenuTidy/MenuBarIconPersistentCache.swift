import AppKit
import CryptoKit
import Foundation
import OSLog

/// A small, disposable on-disk cache for verified menu-bar icon snapshots.
///
/// The cache is deliberately separate from the user's classification state. A
/// record is usable only when its stable display identity, owning bundle,
/// logical size, and captured screen environment match the current scan.
@MainActor
final class MenuBarIconPersistentCache {
    struct LoadedImage {
        let image: NSImage
        let logicalSize: CGSize
        let savedAt: Date
    }

    private struct Entry: Codable {
        let bundleIdentifier: String?
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let environmentSignature: String
        let isTemplate: Bool
        let savedAt: Date

        var logicalSize: CGSize { CGSize(width: logicalWidth, height: logicalHeight) }
    }

    private struct Index: Codable {
        let schemaVersion: Int
        var entries: [String: Entry]
    }

    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "IconPersistentCache")
    private static let schemaVersion = 1
    private static let maximumEntries = 128
    private static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    private let directory: URL
    private let indexURL: URL
    private var index: Index?

    init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory()
        self.directory = directory
        indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
    }

    @discardableResult
    func save(image: NSImage, key: String, bundleIdentifier: String?, logicalSize: CGSize,
              environmentSignature: String, savedAt: Date = Date()) -> Bool {
        guard logicalSize.width.isFinite, logicalSize.width > 0,
              logicalSize.height.isFinite, logicalSize.height > 0,
              let encoded = Self.pngData(for: image) else { return false }
        do {
            try ensureDirectory()
            var current = loadIndex()
            let fileName = Self.fileName(for: key)
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            let entry = Entry(bundleIdentifier: bundleIdentifier,
                logicalWidth: logicalSize.width, logicalHeight: logicalSize.height,
                pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight,
                environmentSignature: environmentSignature, isTemplate: image.isTemplate, savedAt: savedAt)

            if let previous = current.entries[key], Self.sameContent(previous, entry),
               let previousData = try? Data(contentsOf: fileURL), previousData == encoded.data {
                return true
            }

            try encoded.data.write(to: fileURL, options: [.atomic])
            try setPrivateFilePermissions(fileURL)
            current.entries[key] = entry
            current = prune(current)
            try writeIndex(current)
            index = current
            return true
        } catch {
            Self.logger.error("iconCache save failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func load(key: String, bundleIdentifier: String?, logicalSize: CGSize,
              environmentSignature: String) -> LoadedImage? {
        var current = loadIndex()
        guard let entry = current.entries[key],
              entry.bundleIdentifier == bundleIdentifier,
              entry.environmentSignature == environmentSignature,
              Self.sizesMatch(entry.logicalSize, logicalSize),
              Date().timeIntervalSince(entry.savedAt) <= Self.maximumAge,
              Date().timeIntervalSince(entry.savedAt) >= -60 else {
            return nil
        }
        let fileURL = directory.appendingPathComponent(Self.fileName(for: key), isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide == entry.pixelWidth, bitmap.pixelsHigh == entry.pixelHeight,
              let image = NSImage(data: data) else {
            current.entries.removeValue(forKey: key)
            try? writeIndex(current)
            index = current
            return nil
        }
        image.size = entry.logicalSize
        image.isTemplate = entry.isTemplate
        return LoadedImage(image: image, logicalSize: entry.logicalSize, savedAt: entry.savedAt)
    }

    private func loadIndex() -> Index {
        if let index { return index }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.menuTidy.decode(Index.self, from: data),
              decoded.schemaVersion == Self.schemaVersion else {
            let empty = Index(schemaVersion: Self.schemaVersion, entries: [:])
            index = empty
            return empty
        }
        let current = prune(decoded)
        index = current
        if current.entries.count != decoded.entries.count { try? writeIndex(current) }
        return current
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path)
    }

    private func setPrivateFilePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path)
    }

    private func writeIndex(_ index: Index) throws {
        try ensureDirectory()
        let data = try JSONEncoder.menuTidy.encode(index)
        try data.write(to: indexURL, options: [.atomic])
        try setPrivateFilePermissions(indexURL)
    }

    private func prune(_ index: Index) -> Index {
        let now = Date()
        var entries = index.entries
        let expired = entries.filter { now.timeIntervalSince($0.value.savedAt) > Self.maximumAge }.map(\.key)
        for key in expired {
            if entries.removeValue(forKey: key) != nil {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(for: key)))
            }
        }
        if entries.count > Self.maximumEntries {
            let overflow = entries.count - Self.maximumEntries
            let oldKeys = entries.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(overflow).map(\.key)
            for key in oldKeys {
                if entries.removeValue(forKey: key) != nil {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(for: key)))
                }
            }
        }
        return Index(schemaVersion: Self.schemaVersion, entries: entries)
    }

    private static func sameContent(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.logicalWidth == rhs.logicalWidth && lhs.logicalHeight == rhs.logicalHeight &&
            lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight &&
            lhs.environmentSignature == rhs.environmentSignature && lhs.isTemplate == rhs.isTemplate
    }

    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private static func pngData(for image: NSImage) -> (data: Data, pixelWidth: Int, pixelHeight: Int)? {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Menu Tidy/Icon Images/v1", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var menuTidy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var menuTidy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
