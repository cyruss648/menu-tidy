/// Exact macOS MenuBarAgent module identities. These mappings select an
/// existing preference key only after the caller proves the current AX source.
/// Display names, titles, case folding and inferred module names are excluded.
public enum SystemModuleIdentity {
    public static let ownerBundleIdentifier = "com.apple.MenuBarAgent"

    private static let keysByIdentifier = [
        "com.apple.menuextra.airdrop": "module:AirDrop",
        "com.apple.menuextra.bluetooth": "module:Bluetooth",
        "com.apple.menuextra.wifi": "module:WiFi",
        "com.apple.menuextra.audiovideo": "module:AudioVideoModule",
    ]

    public static func positionKey(ownerBundleIdentifier: String?, accessibilityIdentifier: String?) -> String? {
        guard ownerBundleIdentifier == self.ownerBundleIdentifier,
              let accessibilityIdentifier else { return nil }
        return keysByIdentifier[accessibilityIdentifier]
    }

    /// A ledger may restore only the same four module keys; this never grants
    /// permission to bind a live item or create a missing system preference.
    public static func isSupportedPositionKey(_ key: String) -> Bool {
        keysByIdentifier.values.contains(key)
    }
}
