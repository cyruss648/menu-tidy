import AppKit
import MenuTidyCore
import OSLog

/// Converts a bounded icon capture into a transparent glyph when its background
/// is unambiguous. Colourful/ambiguous images retain their original pixels.
enum MenuBarIconImage {
    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "IconAppearance")
    static func make(from capture: CGImage, size: CGSize) -> NSImage {
        let original = NSImage(cgImage: capture, size: size)
        let width = capture.width
        let height = capture.height
        guard width > 0, height > 0, width <= 1_024, height <= 256,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return original }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(capture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded, let matte = MenuBarIconMatte.process(width: width, height: height, pixels: pixels) else { return original }
        logger.debug("iconMatte width=\(width) height=\(height) removedBackground=\(matte.removedBackground) template=\(matte.isTemplate)")
        guard matte.removedBackground,
              let provider = CGDataProvider(data: Data(matte.pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return original }
        let result = NSImage(cgImage: image, size: size)
        result.isTemplate = matte.isTemplate
        return result
    }
}
