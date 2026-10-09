import Foundation

/// All placement inputs use AppKit's global screen coordinates.
struct HiddenItemsPanelPlacement: Equatable {
    let screenIndex: Int
    let anchorX: CGFloat?

    static func resolve(screenFrames: [CGRect], clickPoint: CGPoint?, anchor: CGRect?,
                        fallbackScreenIndex: Int = 0) -> Self? {
        if let clickPoint, clickPoint.x.isFinite, clickPoint.y.isFinite,
           let index = screenFrames.firstIndex(where: { $0.contains(clickPoint) }) {
            return Self(screenIndex: index, anchorX: clickPoint.x)
        }
        if let anchor, valid(anchor),
           let index = screenFrames.firstIndex(where: { $0.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }) {
            return Self(screenIndex: index, anchorX: anchor.midX)
        }
        guard !screenFrames.isEmpty else { return nil }
        return Self(screenIndex: screenFrames.indices.contains(fallbackScreenIndex) ? fallbackScreenIndex : 0,
            anchorX: nil)
    }

    /// AX/Quartz uses a top-left origin; AppKit uses the primary screen's
    /// bottom-left origin. Do not flip relative to a secondary display.
    static func appKitAnchor(fromQuartz frame: CGRect, primaryScreenFrame: CGRect) -> CGRect? {
        guard valid(frame), valid(primaryScreenFrame) else { return nil }
        return CGRect(x: frame.minX, y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
}
