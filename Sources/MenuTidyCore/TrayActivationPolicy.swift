import Foundation

/// A native status-item press is not a mouse-button event. Applications with
/// mouse-event-driven trays need an explicit app-window route, not a second
/// synthetic click after an uncertain AX action.
public enum TrayActivationPolicy {
    public enum Action: Sendable, Equatable { case nativeItem, application }

    public static func defaultAction(bundleIdentifier: String?) -> Action {
        bundleIdentifier == "io.github.clash-verge-rev.clash-verge-rev" ? .application : .nativeItem
    }
}
