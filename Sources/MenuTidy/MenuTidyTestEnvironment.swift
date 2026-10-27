import AppKit
import MenuTidyCore

/// In-memory system boundaries for application integration tests. The model's
/// test initializer is DEBUG-only; no command-line option enables this backend.
/// Classification, queues, persistence and row rebuilding stay in the model.
@MainActor
final class MenuTidyTestEnvironment {
    var snapshots: [MenuBarItemSnapshot] = []
    var identities: [String: ObservedItemGroupHistory.Identity] = [:]
    var allowed: [String: Bool] = [:]
    /// Optional physical-visibility substitute for integration tests. When
    /// absent, the fixture follows the native preference as before.
    var observedVisibility: [String: Bool] = [:]
    var managedBundles: Set<String> = []
    var visibilityBatches: [[String: Bool]] = []
    var hiddenBundles: [String] = []
    var restoredBundles: [String] = []
    var beforeScan: (() async throws -> Void)?
    /// Root processes queried this round; host results may belong to other owners.
    var enumerationOwners: [MenuBarOwner]?
    var beforeVisibilityReadForItem: ((String) async throws -> Void)?
    var beforeVisibilityRead: (() async throws -> Void)?
    var uptime: TimeInterval = 0
    var pointerInMenuBar = false
    var pointerInPanel = false
    var pressedMouseButtons = false
    var maintenanceTimer: Timer?
    var desktopSessionAvailable = true
    var revealedBundles: Set<String> = []
    var panelPressCount = 0
    var panelStatusReadCount = 0
    var rehiddenBundles: [String] = []
    var beforePanelPress: (() async throws -> Void)?
    var panelPresentationStatus: (() async -> MenuBarPresentationStatus)?
    var beforeRehide: (() throws -> Void)?

    func isCurrent(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        identities[identity.id] == identity
    }

    func visibility(id: String) -> Bool? {
        guard let item = snapshots.first(where: { $0.id == id }), let bundle = item.bundleIdentifier else { return nil }
        return observedVisibility[bundle] ?? allowed[bundle] ?? true
    }
}
