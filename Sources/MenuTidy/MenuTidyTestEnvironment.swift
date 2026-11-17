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
    /// Production derives this from NSWorkspace. Tests can model a running
    /// application whose status item has not yet been returned by AX.
    var runningBundles: Set<String> = []
    /// Display metadata from NSWorkspace, independent of screenshot permission.
    var applicationIcons: [String: NSImage] = [:]
    var screenCaptureGranted = false
    var visibilityBatches: [[String: Bool]] = []
    var hiddenBundles: [String] = []
    var restoredBundles: [String] = []
    var beforeScan: (() async throws -> Void)?
    /// Root processes queried this round; host results may belong to other owners.
    var enumerationOwners: [MenuBarOwner]?
    var ownerReadFailures: [MenuBarOwnerReadFailure] = []
    var clientRecoveryBootIdentifier = "test-boot"
    var probeFreshMenuBarClient: ((MenuBarClientRecoveryPolicy.Owner) async -> Bool)?
    var beforeVisibilityReadForItem: ((String) async throws -> Void)?
    var beforeVisibilityRead: (() async throws -> Void)?
    var uptime: TimeInterval = 0
    var pointerInMenuBar = false
    var pointerInPanel = false
    var pressedMouseButtons = false
    var maintenanceTimer: Timer?
    var desktopSessionAvailable = true
    /// Opt in only for startup-rebind integration tests. Production always
    /// enables this path; existing fixtures keep their original clock behavior.
    var nativeStartupRecoveryEnabled = false
    /// Models macOS 27's application-wide assessment result when MenuBarAgent
    /// has replaced the source AX node during a visibility transition.
    var nativeAssessmentAuthoritative = false
    var revealedBundles: Set<String> = []
    var panelPressCount = 0
    var panelPressReturnsPresentation = true
    var panelStatusReadCount = 0
    var panelVisibilityReadCount = 0
    var rehiddenBundles: [String] = []
    var beforePanelPress: (() async throws -> Void)?
    var panelPresentationStatus: (() async -> MenuBarPresentationStatus)?
    /// A complete no-change observation is false; unreadable state is nil.
    var panelHasVisiblePresentation: (() async -> Bool?)?
    /// Positive process-exit evidence, independent of missing AX snapshots.
    var endedOwners: [ObservedItemGroupHistory.Identity] = []
    var beforeRehide: (() throws -> Void)?
    var beforeRestore: (() throws -> Void)?

    func isCurrent(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        if nativeAssessmentAuthoritative {
            return identities.values.contains {
                $0.pid == identity.pid &&
                    $0.bundleIdentifier == identity.bundleIdentifier &&
                    $0.launchTime == identity.launchTime
            }
        }
        return identities[identity.id] == identity
    }

    func visibility(id: String) -> Bool? {
        guard let item = snapshots.first(where: { $0.id == id }), let bundle = item.bundleIdentifier else { return nil }
        return observedVisibility[bundle] ?? allowed[bundle] ?? true
    }
}
