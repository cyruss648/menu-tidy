import CoreGraphics

/// Only Menu Tidy's exact owned records may be repositioned before native
/// arrangement. Preference order plans a repair; it never proves visibility.
public enum ManualArrangementBoundaryPolicy {
    public static let controlKey = MenuBarOwnBoundaryPlan.controlKey
    public static let regularKey = MenuBarOwnBoundaryPlan.dividerKey
    public static let alwaysKey = "status:dev.hdh.MenuTidy::MenuTidyAlwaysDivider"

    public struct Move: Equatable, Sendable {
        public let key: String
        public let beforeKey: String
    }

    /// Repair near the control first. Moving the always marker next to the
    /// old large blocker weight would strand both markers in system overflow.
    public static func moves(positions: [String: Double]) -> [Move]? {
        guard !positions.isEmpty, positions.values.allSatisfy(\.isFinite),
              let control = positions[controlKey], let regular = positions[regularKey],
              let always = positions[alwaysKey] else { return nil }
        if always > regular && regular > control { return [] }
        return [Move(key: regularKey, beforeKey: controlKey),
                Move(key: alwaysKey, beforeKey: regularKey)]
    }

    /// Callers supply frames with positive identity/center-hit evidence from
    /// one display. Placeholder, large spacer and overlapping frames cannot
    /// establish native boundary order, even if stored weights are ordered.
    public static func orderedFrames(_ frames: [CGRect]) -> Bool {
        guard frames.count >= 2, frames.allSatisfy({ frame in
            frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width > 0 && frame.width <= 120 && frame.height > 0 && frame.height <= 64
        }) else { return false }
        return zip(frames, frames.dropFirst()).allSatisfy { left, right in
            left.maxX <= right.minX && abs(left.midY - right.midY) < 8
        }
    }
}
