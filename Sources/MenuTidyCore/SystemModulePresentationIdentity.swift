/// Only the native delegations verified on macOS are listed here. Ordering
/// support is a separate capability: it must not broaden presentation owners.
public enum SystemModulePresentationIdentity {
    public struct Delegate: Equatable, Sendable {
        public let bundleIdentifier: String
        public let bundlePath: String
        public let headerIdentifier: String
    }

    public static let controlCenterBundleIdentifier = "com.apple.controlcenter"
    public static let controlCenterBundlePath = "/System/Library/CoreServices/ControlCenter.app"

    public static func delegate(ownerBundleIdentifier: String?, accessibilityIdentifier: String?) -> Delegate? {
        guard ownerBundleIdentifier == SystemModuleIdentity.ownerBundleIdentifier,
              let accessibilityIdentifier else { return nil }
        let header: String
        switch accessibilityIdentifier {
        case "com.apple.menuextra.airdrop": header = "airdrop-header"
        case "com.apple.menuextra.bluetooth": header = "bluetooth-header"
        case "com.apple.menuextra.wifi": header = "wifi-header"
        default: return nil
        }
        return Delegate(bundleIdentifier: controlCenterBundleIdentifier,
            bundlePath: controlCenterBundlePath, headerIdentifier: header)
    }
}
