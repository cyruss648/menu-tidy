/// A system menu-bar host can expose ordinary remote application windows next
/// to real status items. A window intersecting the menu band is not a status
/// item. Exclude only positively identified remote window subtrees; keep the
/// host's own presentation windows and unknown transport results separate.
public enum MenuBarScanWindowPolicy {
    public static func excludesRemoteWindow(role: String, depth: Int,
                                           nodePID: Int32?, hostPID: Int32) -> Bool {
        guard depth > 0, hostPID > 0, let nodePID, nodePID > 0, nodePID != hostPID else { return false }
        return ["AXWindow", "AXDialog", "AXSystemDialog", "AXSheet", "AXPopover", "AXDrawer"].contains(role)
    }
}
