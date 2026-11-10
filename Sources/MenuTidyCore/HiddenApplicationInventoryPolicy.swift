import Foundation

/// Identity-only discovery is restricted to a direct canonical extras child
/// of an application already hidden by our native backend. It never proves
/// geometry, visibility or permission to dispatch an action.
public enum HiddenApplicationInventoryPolicy {
    public static func accepts(isApplicationExtras: Bool, depth: Int, role: String,
                               ownerPID: Int32, rootPID: Int32, launchTime: TimeInterval,
                               bundleIdentifier: String?, managedHiddenBundles: Set<String>) -> Bool {
        guard isApplicationExtras, depth == 1, role == "AXMenuBarItem",
              ownerPID > 0, ownerPID == rootPID, launchTime.isFinite, launchTime > 0,
              let bundleIdentifier, managedHiddenBundles.contains(bundleIdentifier),
              NativeTrayChoices.acceptsObserved(bundle: bundleIdentifier) else { return false }
        return true
    }
}
