import Foundation

public enum MenuBarCaptureGeometry {
    /// Select the display that owns a menu-bar item. AX and ScreenCaptureKit
    /// report global coordinates, so the first AppKit screen is not a safe
    /// default when the item is on a secondary display.
    public static func displayBounds(containing frame: CGRect, candidates: [CGRect]) -> CGRect? {
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = candidates.first(where: { $0.contains(center) }) { return containing }
        return candidates
            .filter { $0.intersection(frame).isNull == false }
            .max { lhs, rhs in
                lhs.intersection(frame).width * lhs.intersection(frame).height <
                    rhs.intersection(frame).width * rhs.intersection(frame).height
            }
    }

    /// AX host containers may extend one point below the actual menu band.
    /// Keep identity verification on the original frame; capture only the band.
    public static func captureRectangle(for frame: CGRect, band: CGRect, display: CGRect) -> CGRect? {
        guard [frame, band, display].allSatisfy({ rect in
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) &&
                rect.width > 0 && rect.height > 0
        }), (4...256).contains(frame.width), (8...64).contains(frame.height), band.height <= 64,
              display.contains(band), frame.minX >= band.minX, frame.maxX <= band.maxX,
              frame.minY >= band.minY - 1, frame.maxY <= band.maxY + 1,
              band.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        let clipped = frame.integral.intersection(band)
        let result = CGRect(x: ceil(clipped.minX), y: ceil(clipped.minY),
            width: floor(clipped.maxX) - ceil(clipped.minX),
            height: floor(clipped.maxY) - ceil(clipped.minY))
        guard result.width >= 4, result.height >= 8, band.contains(result), display.contains(result) else { return nil }
        return result
    }
}
