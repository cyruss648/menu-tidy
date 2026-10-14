/// Display identity only. It never authorizes a preference write, an AX action,
/// or rebinding one source object to another source's geometry.
public enum MenuBarItemPresentationIdentity: Hashable, Sendable {
    case application(bundle: String)
    case systemModule(identifier: String)

    public var id: String {
        switch self {
        case .application(let bundle): "presentation:application:" + bundle
        case .systemModule(let identifier): "presentation:system-module:" + identifier
        }
    }

    public static func resolve(bundleIdentifier: String?, accessibilityIdentifier: String?) -> Self? {
        guard let bundleIdentifier else { return nil }
        if bundleIdentifier == SystemModuleIdentity.ownerBundleIdentifier {
            guard let accessibilityIdentifier, !accessibilityIdentifier.isEmpty,
                  accessibilityIdentifier.utf8.count <= 512,
                  accessibilityIdentifier.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else { return nil }
            return .systemModule(identifier: accessibilityIdentifier)
        }
        guard NativeTrayChoices.accepts(bundle: bundleIdentifier, excluding: []) else { return nil }
        return .application(bundle: bundleIdentifier)
    }
}
