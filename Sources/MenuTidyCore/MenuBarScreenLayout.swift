import CoreGraphics

/// Geometry that can invalidate a measured menu-bar boundary. Notification
/// delivery alone is not evidence that any of these inputs changed.
public struct MenuBarScreenLayout: Equatable, Sendable {
    public struct Screen: Equatable, Sendable {
        public let displayID: UInt32
        public let frame: CGRect
        public let bounds: CGRect
        public let scale: Double
        public let safeAreaTop: Double
        public let auxiliaryTopLeftArea: CGRect?
        public let auxiliaryTopRightArea: CGRect?

        public init(displayID: UInt32, frame: CGRect, bounds: CGRect, scale: Double,
                    safeAreaTop: Double, auxiliaryTopLeftArea: CGRect?, auxiliaryTopRightArea: CGRect?) {
            self.displayID = displayID
            self.frame = frame
            self.bounds = bounds
            self.scale = scale
            self.safeAreaTop = safeAreaTop
            self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
            self.auxiliaryTopRightArea = auxiliaryTopRightArea
        }

        fileprivate var isValid: Bool {
            func valid(_ rect: CGRect, requiresArea: Bool) -> Bool {
                [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) &&
                    (requiresArea ? rect.size.width > 0 && rect.size.height > 0 :
                        rect.size.width >= 0 && rect.size.height >= 0)
            }
            return displayID != 0 && valid(frame, requiresArea: true) && valid(bounds, requiresArea: true) &&
                scale.isFinite && scale > 0 && safeAreaTop.isFinite && safeAreaTop >= 0 &&
                auxiliaryTopLeftArea.map { valid($0, requiresArea: false) } != false &&
                auxiliaryTopRightArea.map { valid($0, requiresArea: false) } != false
        }
    }

    public enum InvalidationReason: String, Sendable {
        case unavailableGeometry = "unavailable-geometry"
        case displaySetChanged = "display-set"
        case primaryDisplayChanged = "primary-display"
        case displayGeometryChanged = "display-geometry"
        case scaleChanged = "display-scale"
        case menuBarGeometryChanged = "menu-bar-geometry"
    }

    private let screens: [Screen]
    private let firstScreenID: UInt32
    private let mainDisplayID: UInt32
    private let menuBarThickness: Double

    /// The first AppKit screen and the Quartz main display both affect current
    /// layout calculations. Ordering of the remaining screens has no meaning.
    public init?(screens: [Screen], mainDisplayID: UInt32, menuBarThickness: Double) {
        guard let first = screens.first, screens.allSatisfy(\.isValid),
              Set(screens.map(\.displayID)).count == screens.count,
              screens.contains(where: { $0.displayID == mainDisplayID }),
              menuBarThickness.isFinite, menuBarThickness > 0 else { return nil }
        self.screens = screens.sorted { $0.displayID < $1.displayID }
        self.firstScreenID = first.displayID
        self.mainDisplayID = mainDisplayID
        self.menuBarThickness = menuBarThickness
    }

    /// Unknown geometry fails closed. An equal, valid layout alone permits a
    /// repeated notification to leave existing boundary evidence untouched.
    public static func invalidationReason(from previous: Self?, to current: Self?) -> InvalidationReason? {
        guard let previous, let current else { return .unavailableGeometry }
        guard previous.screens.map(\.displayID) == current.screens.map(\.displayID) else { return .displaySetChanged }
        guard previous.firstScreenID == current.firstScreenID,
              previous.mainDisplayID == current.mainDisplayID else { return .primaryDisplayChanged }
        for (old, new) in zip(previous.screens, current.screens) {
            if old.frame != new.frame || old.bounds != new.bounds { return .displayGeometryChanged }
            if old.scale != new.scale { return .scaleChanged }
            if old.safeAreaTop != new.safeAreaTop || old.auxiliaryTopLeftArea != new.auxiliaryTopLeftArea ||
                old.auxiliaryTopRightArea != new.auxiliaryTopRightArea { return .menuBarGeometryChanged }
        }
        return previous.menuBarThickness == current.menuBarThickness ? nil : .menuBarGeometryChanged
    }
}
