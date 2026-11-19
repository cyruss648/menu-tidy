import Foundation

/// Identity-only discovery is restricted to a direct canonical extras child
/// of an application with a managed or saved hidden choice. It never proves
/// geometry, visibility or permission to dispatch an action.
public enum HiddenApplicationInventoryPolicy {
    public static func accepts(isApplicationExtras: Bool, depth: Int, role: String,
                               ownerPID: Int32, rootPID: Int32, launchTime: TimeInterval,
                               bundleIdentifier: String?, hiddenApplicationBundles: Set<String>) -> Bool {
        guard isApplicationExtras, depth == 1, role == "AXMenuBarItem",
              ownerPID > 0, ownerPID == rootPID, launchTime.isFinite, launchTime > 0,
              let bundleIdentifier, hiddenApplicationBundles.contains(bundleIdentifier),
              NativeTrayChoices.acceptsObserved(bundle: bundleIdentifier) else { return false }
        return true
    }
}
