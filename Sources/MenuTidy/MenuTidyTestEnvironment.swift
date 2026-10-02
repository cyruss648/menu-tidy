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
    var managedBundles: Set<String> = []
    var hiddenBundles: [String] = []
    var restoredBundles: [String] = []
    var beforeVisibilityRead: (() async throws -> Void)?
    var uptime: TimeInterval = 0
    var pointerInMenuBar = false
    var pointerInPanel = false
    var pressedMouseButtons = false
    var maintenanceTimer: Timer?

    func isCurrent(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        identities[identity.id] == identity
    }

    func visibility(id: String) -> Bool? {
        guard let item = snapshots.first(where: { $0.id == id }), let bundle = item.bundleIdentifier else { return nil }
        return allowed[bundle] ?? true
    }
}
