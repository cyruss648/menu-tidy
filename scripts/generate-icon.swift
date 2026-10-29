#!/usr/bin/env swift
import AppKit
import Foundation

// Deterministic native vector artwork. Run `swift scripts/generate-icon.swift`.
// Optional arguments override the .icns output and PNG preview paths, respectively.
// No downloaded assets, fonts, or third-party rendering tools are required.

enum IconError: Error, CustomStringConvertible {
    case bitmapAllocation(Int)
    case pngEncoding(Int)
    case iconutil(Int32)

    var description: String {
        switch self {
        case .bitmapAllocation(let size): "Could not allocate a \(size)-pixel icon bitmap."
        case .pngEncoding(let size): "Could not encode the \(size)-pixel icon as PNG."
        case .iconutil(let status): "iconutil failed with exit status \(status)."
        }
    }
}

@MainActor
func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.bitmapAllocation(size)
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setShouldAntialias(true)
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // The transparent margin and rounded square follow macOS icon proportions.
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                            xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.08, green: 0.08, blue: 0.20, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let topColor = NSColor(srgbRed: 0.38, green: 0.31, blue: 0.83, alpha: 1)
    let bottomColor = NSColor(srgbRed: 0.10, green: 0.16, blue: 0.43, alpha: 1)
    NSGradient(starting: bottomColor, ending: topColor)!.draw(in: tile, angle: 90)

    let edge = NSBezierPath(roundedRect: NSRect(x: 97, y: 97, width: 830, height: 830),
                            xRadius: 183, yRadius: 183)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    edge.lineWidth = 3
    edge.stroke()

    // A tidy stack: three rounded layers merge into a compact tray mark. The
    // small violet notch gives the glyph a distinctive silhouette at 16px.
    let layers = [
        NSRect(x: 236, y: 604, width: 458, height: 78),
        NSRect(x: 236, y: 472, width: 390, height: 78),
        NSRect(x: 236, y: 340, width: 322, height: 78),
    ]
    NSColor.white.withAlphaComponent(0.96).setFill()
    for layer in layers {
        NSBezierPath(roundedRect: layer, xRadius: 39, yRadius: 39).fill()
    }

    let tray = NSBezierPath(roundedRect: NSRect(x: 626, y: 314, width: 142, height: 410),
                            xRadius: 71, yRadius: 71)
    NSColor(srgbRed: 0.99, green: 0.56, blue: 0.38, alpha: 1).setFill()
    tray.fill()
    let notch = NSBezierPath()
    notch.lineWidth = 28
    notch.lineCapStyle = .round
    notch.move(to: NSPoint(x: 664, y: 518))
    notch.line(to: NSPoint(x: 708, y: 562))
    notch.line(to: NSPoint(x: 752, y: 518))
    NSColor(srgbRed: 0.12, green: 0.14, blue: 0.38, alpha: 1).setStroke()
    notch.stroke()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncoding(size)
    }
    return data
}

@MainActor
func generateIcon() throws {
    let manager = FileManager.default
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let arguments = Array(CommandLine.arguments.dropFirst())
    let output = arguments.first.map { URL(fileURLWithPath: $0) }
        ?? repository.appendingPathComponent("Resources/AppIcon.icns")
    let preview = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        ?? repository.appendingPathComponent(".local/icon-preview.png")
    let temporary = manager.temporaryDirectory.appendingPathComponent("MenuTidyIcon-\(UUID().uuidString)")
    let iconset = temporary.appendingPathComponent("AppIcon.iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }

    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let filename = "icon_\(points)x\(points)\(suffix).png"
            try renderIcon(size: points * scale).write(to: iconset.appendingPathComponent(filename))
        }
    }

    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw IconError.iconutil(iconutil.terminationStatus) }

    try manager.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try renderIcon(size: 1024).write(to: preview)
    print("Generated: \(output.path)")
    print("Preview: \(preview.path)")
}

do {
    try MainActor.assumeIsolated { try generateIcon() }
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
    exit(1)
}
