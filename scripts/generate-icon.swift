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
    NSColor(srgbRed: 0.10, green: 0.39, blue: 0.36, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let topColor = NSColor(srgbRed: 0.20, green: 0.61, blue: 0.56, alpha: 1)
    let bottomColor = NSColor(srgbRed: 0.07, green: 0.38, blue: 0.35, alpha: 1)
    NSGradient(starting: bottomColor, ending: topColor)!.draw(in: tile, angle: 90)

    let edge = NSBezierPath(roundedRect: NSRect(x: 97, y: 97, width: 830, height: 830),
                            xRadius: 183, yRadius: 183)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    edge.lineWidth = 2
    edge.stroke()

    // Three menu items and a folding disclosure. The glyph remains clear at 16px.
    let menu = NSBezierPath()
    menu.lineWidth = 56
    menu.lineCapStyle = .round
    for y in [644.0, 512.0, 380.0] {
        menu.move(to: NSPoint(x: 282, y: y))
        menu.line(to: NSPoint(x: 532, y: y))
    }

    let fold = NSBezierPath()
    fold.lineWidth = 56
    fold.lineCapStyle = .round
    fold.lineJoinStyle = .round
    fold.move(to: NSPoint(x: 644, y: 610))
    fold.line(to: NSPoint(x: 742, y: 512))
    fold.line(to: NSPoint(x: 644, y: 414))

    NSColor(srgbRed: 0.96, green: 1.0, blue: 0.99, alpha: 1).setStroke()
    menu.stroke()
    fold.stroke()

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
