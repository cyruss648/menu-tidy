import AppKit
import ApplicationServices
import Combine
import Darwin
import MenuTidyCore
import OSLog
import ServiceManagement

struct ManagedItemRow: Identifiable {
    let id: String
    let name: String
    let ownerName: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let group: ItemVisibility
    let isAvailable: Bool
    let canMove: Bool
    let detail: String
    let isPending: Bool

    func replacingGroup(_ group: ItemVisibility) -> ManagedItemRow {
        ManagedItemRow(id: id, name: name, ownerName: ownerName, bundleIdentifier: bundleIdentifier,
            icon: icon, group: group, isAvailable: isAvailable, canMove: canMove, detail: detail, isPending: isPending)
    }
}

private enum MenuTidyManagementError: LocalizedError {
    case anchorCount(identifier: String, count: Int)
    case positionApplication(String)
    case operationTimedOut

    var errorDescription: String? {
        switch self {
        case .operationTimedOut:
            return "系统未能及时提供可验证的结果，已停止继续尝试。已确认的结果和未应用的选择均会保留。"
        case .positionApplication(let detail):
            return detail
        case .anchorCount(let identifier, let count):
            let name = switch identifier {
            case "menu-tidy-toggle": "菜单栏入口"
            case "menu-tidy-divider": "收起区定位项"
            case "menu-tidy-always-divider": "常隐区定位项"
            default: "分组定位项"
            }
            return "「\(name)」匹配到 \(count) 个，无法唯一确认位置。请刷新后重试。"
        }
    }
}

@MainActor
final class MenuTidyModel: ObservableObject {
    private static let diagnosticLogger = Logger(subsystem: "dev.hdh.MenuTidy", category: "Management")
    private static let ownAnchorIdentifiers = ["menu-tidy-toggle", "menu-tidy-divider", "menu-tidy-always-divider"]
    @Published private(set) var isCollapsed = false { didSet { if oldValue != isCollapsed { cancelPassiveIconCapture() } } }
    @Published private(set) var isArranging = false { didSet { if isArranging { cancelPassiveIconCapture() } } }
    @Published var autoCollapseEnabled: Bool { didSet { defaults.set(autoCollapseEnabled, forKey: "autoCollapse"); resetIdleTime() } }
    @Published var autoCollapseDelay: Double { didSet { defaults.set(autoCollapseDelay, forKey: "autoCollapseDelay"); resetIdleTime() } }
    @Published var startCollapsed: Bool { didSet { defaults.set(startCollapsed, forKey: "startCollapsed") } }
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: "shortcutEnabled"); configureShortcut() } }
    @Published private(set) var shortcutIssue: String?
    @Published var layoutIssue: String?
    @Published private(set) var environmentIssue: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var loginIssue: String?
    @Published private(set) var hasCompletedSetup: Bool
    @Published private(set) var items: [ManagedItemRow] = []
    @Published private(set) var accessibilityGranted = false { didSet { if !accessibilityGranted { cancelPassiveIconCapture() } } }
    @Published private(set) var screenCaptureGranted = CGPreflightScreenCaptureAccess() { didSet { if !screenCaptureGranted { cancelPassiveIconCapture() } } }
    @Published private(set) var isPanelPresented = false { didSet { if isPanelPresented { cancelPassiveIconCapture() } } }
    @Published private(set) var isActivatingPanelItem = false { didSet { if isActivatingPanelItem { cancelPassiveIconCapture() } } }
    @Published private(set) var panelItemProgress: String?
    @Published private(set) var panelError: String?
    @Published private(set) var panelActivationError: String?
    @Published private(set) var activePanelItemID: String?
    @Published private(set) var trayItemErrors: [String: String] = [:]
    @Published private var trayPlacementQueue = TrayPlacementQueue()
    @Published private var trayPlacementErrors: [String: String] = [:]
    @Published private var trayReconnectIDs: Set<String> = []
    @Published private var itemsNeedingPositionKeyResolution: Set<String> = []
    @Published private(set) var iconImageWarning: String?
    @Published private(set) var iconImageWarningDetails: String?
    @Published private(set) var panelImages: [String: NSImage] = [:]
    @Published private(set) var panelUsesCachedImages = false
    @Published private(set) var panelLastCaptureDate: Date?
    @Published private(set) var permissionCheckMessage: String?
    @Published private(set) var nativeVisibilityAccessAvailable = false
    @Published private(set) var nativeVisibilityAccessMessage: String?
    @Published private(set) var nativeSystemVisibilityAccessNeeded = false
    @Published private(set) var nativeSystemVisibilityAccessMessage: String?
    @Published private(set) var menuBarPositionAccessAvailable = false
    @Published private(set) var menuBarPositionAccessMessage: String?
    @Published private(set) var positionRecoveryMessage: String?
    @Published private(set) var isRecoveringPositions = false
    @Published private(set) var isRefreshing = false { didSet { if isRefreshing { cancelPassiveIconCapture() } } }
    @Published private(set) var isApplying = false { didSet { if isApplying { cancelPassiveIconCapture() } } }
    @Published private(set) var managementMessage: String?
    @Published private(set) var managementError: String?
    @Published private(set) var itemApplicationIssues: [String: String] = [:]
    @Published private var operationState = ManagementOperationState()
    @Published private(set) var temporarilyRevealingAll = false
    @Published private(set) var hasPendingChanges = false
    @Published private(set) var actionablePendingCount = 0
    @Published private(set) var offlineDrafts: [PendingDraftRecord] = []
    @Published private(set) var draftPersistenceIssue: String?
    var settingsVisible = false { didSet { resetIdleTime() } }
    var contextMenuVisible = false { didSet { resetIdleTime(); if contextMenuVisible { cancelPassiveIconCapture() } } }
    var onShowSettings: (() -> Void)?

    private let defaults: UserDefaults
    private var state = VisibilityState()
    private var statusBar: StatusBarController?
    // The isolated UI preview must never load the user's recovery journals.
    private lazy var positionStore = MenuBarPositionStore()
    private lazy var positionAccess = MenuBarPositionAccess()
    private lazy var nativeVisibilityStore = NativeMenuBarVisibilityStore()
    private lazy var nativeSystemVisibilityStore = NativeSystemMenuBarVisibilityStore()
    fileprivate enum NativeVisibilityTarget: Hashable, Sendable {
        case application(bundle: String)
        case system(key: String)
    }
    private struct NativeVisibilityEvidence {
        let identity: ObservedItemGroupHistory.Identity
        /// nil is a visible, unmanaged item; it grants no preference write access.
        let target: NativeVisibilityTarget?
        let group: ItemVisibility
    }
    private var nativeVisibilityEvidence: [String: NativeVisibilityEvidence] = [:]
    private var nativeOwnerRecoveries = NativeOwnerRecoveryQueue<NativeVisibilityTarget>()
    private var nativeTrayChoices = NativeTrayChoices()
    private var nativeChoicesLoadIssue: String?
    var usesNativeVisibility: Bool {
        isUIPreview || (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && !demoMode)
    }
    var usesIndependentTray: Bool { usesNativeVisibility || usesPositionHiding }
    var needsLegacyPositionRecovery: Bool {
        !isUIPreview && (!positionStore.managedHiddenEntries.isEmpty || !positionStore.pendingTransactions.isEmpty ||
            positionStore.recoveryJournalIssue != nil || positionStore.hiddenLedgerRecoveryIssue != nil)
    }
    private var pendingPositionRecoveries: [MenuBarPositionStore.Transaction] = []
    private var positionLayoutRecoveryNeeded = false {
        didSet { defaults.set(positionLayoutRecoveryNeeded, forKey: "positionLayoutReviewNeeded.v1") }
    }
    private var positionRecoveryFrames: [String: CGRect] = [:]
    private var verifiedPositionGroups: [String: ItemVisibility] = [:]
    private struct VerifiedPositionEvidence {
        let identity: ObservedItemGroupHistory.Identity
        let key: String
        let value: Double
    }
    private var verifiedPositionEvidence: [String: VerifiedPositionEvidence] = [:]
    private struct VerifiedHostedFootprint {
        let identity: ObservedItemGroupHistory.Identity
        let width: CGFloat
    }
    private var verifiedHostedFootprints: [String: VerifiedHostedFootprint] = [:]
    private var activeBlockerReservation: (key: String, token: StatusBarController.PositionHidingBlockerReservation)?
    /// Explicit image refresh temporarily changes managed weights without
    /// changing the accepted classification or its original evidence.
    private var isRefreshingManagedIcons = false
    private var needsPositionRevalidation = false
    private var positionRecoveryGeneration = 0
    var usesPositionHiding: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && !demoMode && !usesNativeVisibility
    }
    private let shortcut = GlobalShortcut()
    private var timer: Timer?
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var workspaceObservers: [NSObjectProtocol] = []
    private let demoMode = CommandLine.arguments.contains("--demo-items")
    let isUIPreview = CommandLine.arguments.contains("--preview-ui")
    private let access = MenuBarAccessibility()
    private var rules = ItemRuleBook()
    private var drafts = ItemRuleBook()
    private var pendingDrafts = PendingDraftStore()
    private var rowDraftIDs: [String: UUID] = [:]
    private var applicationIcons: [String: NSImage] = [:]
    private var snapshots: [MenuBarItemSnapshot] = []
    private var actualGroups: [String: ItemVisibility] = [:]
    private var lastKnownObservedGroups = ObservedItemGroupHistory()
    private var workTask: Task<Void, Never>?
    private var visibilityDiagnosticTask: Task<Void, Never>?
    private var visibilityDiagnosticSequence = 0
    private var visibilityDiagnosticsStopped = false
    private var lastPermissionCheck = 0.0
    private var anchorScanSequence = 0
    private var stopping = false
    private var arrangementSequence = 0
    private var beforeTemporaryRevealCollapsed: Bool?
    private var usesNativeAlwaysSection = false
    private let iconCapture = MenuBarIconCapture()
    private var iconPanel: HiddenItemsPanelController?
    private let controlRouter = PanelControlRouter()
    private var panelTask: Task<Void, Never>?
    private var panelIncludesAlwaysHidden = false
    private var panelActivationTask: Task<Void, Never>?
    private var trayPlacementTask: Task<Void, Never>?
    private var panelIsPreparingNativeAction = false
    private var trayConnectionAttempts: [String: ObservedItemGroupHistory.Identity] = [:]
    private var trayDiscoveryNeeded = false
    private var passiveIconCaptureTask: Task<Void, Never>?
    private var passiveIconCaptureID: UUID?
    private var lastPassiveIconCaptureAttempt = -Double.infinity
    private var passiveOverflowRebindAttempts = 0
    private var lastPassiveOverflowRebind = -Double.infinity
    private var passiveOverflowRebindNeedsRetry = false
    private var iconImagePreparationIssues: [String] = []
    private var preparingToTerminate = false
    var isPanelItemOperationRunning: Bool { panelActivationTask != nil }
    var panelInteractionBusy: Bool {
        isRecoveringPositions || isApplying || isRefreshing || isArranging || isActivatingPanelItem || preparingToTerminate
    }
    var panelItems: [ManagedItemRow] {
        items.filter { item in
            item.isAvailable && item.canMove && TrayPlacementPolicy.includesInPanel(
                group: trayPlacementGroup(id: item.id),
                verifiedGroup: actualGroups[item.id] ?? verifiedPositionGroups[item.id],
                includeAlwaysHidden: panelIncludesAlwaysHidden)
        }
    }

    func trayPlacementIsPending(id: String) -> Bool {
        if trayPlacementQueue.desiredGroup(id: id) != nil || (isApplying && trayReconnectIDs.contains(id)) { return true }
        guard usesNativeVisibility, let bundle = items.first(where: { $0.id == id })?.bundleIdentifier,
              nativeTrayChoices.group(bundle: bundle) != nil else { return false }
        let queuedIDs = Set(trayPlacementQueue.pendingIDs + [trayPlacementQueue.active?.id].compactMap { $0 })
        return items.contains { queuedIDs.contains($0.id) && $0.bundleIdentifier == bundle }
    }

    func trayPlacementGroup(id: String) -> ItemVisibility {
        // Native application choices own every current sibling, including one
        // whose earlier immutable request is still finishing.
        if usesNativeVisibility, let bundle = items.first(where: { $0.id == id })?.bundleIdentifier,
           let group = nativeTrayChoices.group(bundle: bundle) { return group }
        return trayPlacementQueue.desiredGroup(id: id) ??
            items.first(where: { $0.id == id })?.group ?? rules.rule(for: id)?.visibility ?? .visible
    }

    func trayPlacementIsInTray(id: String) -> Bool { trayPlacementGroup(id: id) != .visible }

    func trayPlacementFailure(id: String) -> String? { trayPlacementErrors[id] ?? itemApplicationIssues[id] }

    func trayPlacementMessage(id: String) -> String? {
        if let error = trayPlacementFailure(id: id) { return error }
        if items.first(where: { $0.id == id })?.isPending == true && !trayPlacementIsPending(id: id) {
            return "此图标尚未连接到当前托盘，点击重试即可重新确认。"
        }
        return nil
    }

    /// Changing a choice may supersede work in flight. Recovery and requested
    /// cancellation must complete before accepting another operation.
    var trayPlacementBlockedReason: String? {
        if stopping || preparingToTerminate { return "正在退出，暂时无法更改分类。" }
        if isRecoveringPositions || positionRecoveryMessage != nil || (usesNativeVisibility && needsLegacyPositionRecovery) {
            return "请先完成图标恢复，再应用分类。"
        }
        if operationCancellationRequested { return "正在停止并恢复，请稍候。" }
        if isArranging { return "请先结束手动整理。" }
        if !accessibilityGranted { return "请先授权辅助功能，再更改图标分类。" }
        if let environmentIssue { return environmentIssue }
        if usesNativeVisibility, let nativeChoicesLoadIssue { return nativeChoicesLoadIssue }
        return nil
    }

    var trayPlacementSelectionAllowed: Bool { trayPlacementBlockedReason == nil }
    var trayPlacementBatchActionsAllowed: Bool {
        trayPlacementSelectionAllowed && !panelInteractionBusy && trayPlacementTask == nil
    }

    private var trayPlacementCandidates: [TrayPlacementPolicy.Candidate] {
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        return items.map { row in
            TrayPlacementPolicy.Candidate(id: row.id, group: trayPlacementGroup(id: row.id),
                isAvailable: row.isAvailable, canMove: row.canMove,
                hasUniqueIdentity: isUIPreview || counts[row.id] == 1,
                isPending: row.isPending, hasFailure: trayPlacementFailure(id: row.id) != nil,
                needsIdentification: trayPlacementNeedsIdentification(id: row.id),
                isQueued: trayPlacementIsPending(id: row.id))
        }
    }

    var trayPendingApplicationCount: Int {
        TrayPlacementPolicy.candidates(trayPlacementCandidates, for: .applyPending).count
    }
    var trayRetryCount: Int {
        TrayPlacementPolicy.candidates(trayPlacementCandidates, for: .retryFailed).count
    }
    var trayPlacementOutstandingCount: Int { trayPlacementCandidates.filter(\.isOutstanding).count }

    func applyPendingTrayPlacements() {
        if isUIPreview { previewApplyPending(retryOnly: false); return }
        enqueueTrayPlacements(action: .applyPending)
    }

    func retryFailedTrayPlacements() {
        if isUIPreview { previewApplyPending(retryOnly: true); return }
        enqueueTrayPlacements(action: .retryFailed)
    }

    private func enqueueTrayPlacements(action: TrayPlacementPolicy.Action) {
        guard trayPlacementBatchActionsAllowed else { return }
        let candidates = TrayPlacementPolicy.candidates(trayPlacementCandidates, for: action)
        // The same request path preserves exact groups, persistence checks and
        // FIFO serialization. A confirmed sibling is skipped when claimed.
        for candidate in candidates {
            requestTrayPlacement(id: candidate.id, group: candidate.group)
        }
    }

    func openTraySettings() {
        closeIconPanel()
        onShowSettings?()
    }

    func trayPlacementRetryTitle(id: String) -> String {
        trayPlacementNeedsIdentification(id: id) ? "识别并连接" : "重试"
    }

    func trayPlacementNeedsIdentification(id: String) -> Bool { itemsNeedingPositionKeyResolution.contains(id) }

    func retryTrayPlacement(id: String) {
        requestTrayPlacement(id: id, group: trayPlacementGroup(id: id), resolveAmbiguousKey: true)
    }

    /// User intent is saved immediately; only the newest intent for a source
    /// enters the serial native mutation path. Displaying the tray never waits
    /// for this queue, and stale completion cannot consume a newer choice.
    func requestTrayPlacement(id: String, inTray: Bool, resolveAmbiguousKey: Bool = false) {
        let group: ItemVisibility = inTray
            ? (trayPlacementGroup(id: id) == .alwaysHidden ? .alwaysHidden : .collapsible) : .visible
        requestTrayPlacement(id: id, group: group, resolveAmbiguousKey: resolveAmbiguousKey)
    }

    func requestTrayPlacement(id: String, group: ItemVisibility, resolveAmbiguousKey: Bool = false) {
        if isUIPreview { previewSetGroup(id: id, group: group); return }
        guard trayPlacementSelectionAllowed,
              let row = items.first(where: { $0.id == id && $0.canMove && $0.isAvailable }),
              snapshots.filter({ $0.id == id }).count == 1 else { return }
        var updatedChoices = nativeTrayChoices
        let sharesApplicationSwitch = usesNativeVisibility && row.bundleIdentifier.map {
            updatedChoices.set(bundle: $0, group: group,
                excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
        } == true
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        let affected = sharesApplicationSwitch ? items.filter {
            $0.isAvailable && $0.canMove && $0.bundleIdentifier == row.bundleIdentifier && counts[$0.id] == 1
        } : [row]
        do {
            // Prepare sibling drafts atomically. An unbound old session record
            // rejects the request without changing the application-wide choice.
            let updatedDrafts = try TrayPlacementPolicy.replacingDrafts(in: pendingDrafts,
                targets: affected.map {
                    TrayPlacementPolicy.DraftTarget(rule: ItemRule(id: $0.id, name: $0.name,
                        bundleIdentifier: $0.bundleIdentifier, visibility: group),
                        identity: draftSessionIdentity(for: $0.id))
                }, group: group)
            try saveTrayIntent(drafts: updatedDrafts, nativeChoices: sharesApplicationSwitch ? updatedChoices : nil)
        } catch PendingDraftStore.StoreError.targetHasDraft {
            trayPlacementErrors[id] = "此应用有尚未关联的旧草稿，请先在离线草稿中明确关联或删除后重试。"
            return
        } catch {
            trayPlacementErrors[id] = "当前图标身份无法确认，选择未执行。请重新检测后再试。"
            return
        }
        for sibling in affected {
            trayPlacementErrors.removeValue(forKey: sibling.id)
            itemApplicationIssues.removeValue(forKey: sibling.id)
            if let identity = draftSessionIdentity(for: sibling.id) { trayConnectionAttempts[sibling.id] = identity }
        }
        // Keep this item's FIFO position while removing obsolete queued choices
        // for other icons controlled by the same native application switch.
        trayPlacementQueue.removePending(ids: Set(affected.map(\.id)).subtracting([id]))
        trayPlacementQueue.enqueue(id: id, group: group, resolveAmbiguousKey: resolveAmbiguousKey)
        rebuildRows()
        drainTrayPlacements()
    }

    private func drainTrayPlacements() {
        guard trayPlacementTask == nil else { return }
        trayPlacementTask = Task { [weak self] in
            guard let self else { return }
            defer { self.trayPlacementTask = nil }
            while !Task.isCancelled && !self.stopping && !self.preparingToTerminate {
                if let blocked = self.trayPlacementBlockedReason {
                    for id in self.trayPlacementQueue.pendingIDs { self.trayPlacementErrors[id] = blocked }
                    self.trayPlacementQueue.cancelAllPending()
                    return
                }
                // Read-only discovery and an open native menu may finish
                // before the next mutation. No extra AX operation is launched.
                if self.panelInteractionBusy {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                guard let request = self.trayPlacementQueue.claimNext() else { return }
                guard let row = self.items.first(where: { $0.id == request.id && $0.isAvailable && $0.canMove }),
                      self.snapshots.filter({ $0.id == request.id }).count == 1 else {
                    _ = self.trayPlacementQueue.finish(token: request.token)
                    continue
                }
                if self.trayPlacementGroup(id: request.id) != request.group {
                    _ = self.trayPlacementQueue.finish(token: request.token)
                    continue
                }
                var requestedIDs: Set<String> = [request.id]
                if self.usesNativeVisibility, let bundle = row.bundleIdentifier,
                   self.nativeTrayChoices.group(bundle: bundle) != nil {
                    let counts = Dictionary(grouping: self.snapshots, by: \.id).mapValues(\.count)
                    requestedIDs.formUnion(self.items.filter {
                        $0.isAvailable && $0.canMove && $0.bundleIdentifier == bundle && counts[$0.id] == 1
                    }.map(\.id))
                }
                // Skip native work only when the entire shared choice is
                // confirmed. A confirmed source cannot stand in for a sibling
                // that has yet to supply its own positive visibility evidence.
                if requestedIDs.allSatisfy({ self.rules.rule(for: $0)?.visibility == request.group &&
                    self.actualGroups[$0] == request.group }) {
                    for confirmedRow in self.items where requestedIDs.contains(confirmedRow.id) {
                        self.pendingDrafts.removeVerified(ItemRule(id: confirmedRow.id, name: confirmedRow.name,
                            bundleIdentifier: confirmedRow.bundleIdentifier, visibility: request.group),
                            sessionIdentity: self.draftSessionIdentity(for: confirmedRow.id))
                        self.trayPlacementErrors.removeValue(forKey: confirmedRow.id)
                        self.itemApplicationIssues.removeValue(forKey: confirmedRow.id)
                    }
                    self.persistDrafts()
                    _ = self.trayPlacementQueue.finish(token: request.token)
                    self.rebuildRows()
                    continue
                }
                // A shared hidden switch confirms its siblings in one native
                // operation. An unmanaged visible application instead needs a
                // separate positive observation of each sibling in this batch.
                self.applyItemRules(requestedItemIDs: requestedIDs, preservePanel: true,
                    resolveAmbiguousKeyFor: request.resolveAmbiguousKey ? request.id : nil,
                    requestedGroups: Dictionary(uniqueKeysWithValues: requestedIDs.map { ($0, request.group) }))
                if self.isApplying { await self.workTask?.value }
                let confirmed = self.rules.rule(for: request.id)?.visibility == request.group &&
                    self.actualGroups[request.id] == request.group
                _ = self.trayPlacementQueue.finish(token: request.token)
                if self.trayPlacementQueue.desiredGroup(id: request.id) == nil &&
                    self.trayPlacementGroup(id: request.id) == request.group {
                    if confirmed {
                        self.trayPlacementErrors.removeValue(forKey: request.id)
                        self.trayItemErrors.removeValue(forKey: request.id)
                    } else {
                        self.trayPlacementErrors[request.id] = self.itemApplicationIssues[request.id] ??
                            self.positionRecoveryMessage ?? self.managementError ??
                            "未能确认此图标的显示位置。原选择已保留，可重试。"
                    }
                }
                self.rebuildRows()
            }
        }
    }

    /// Reconnect saved intent once per process lifetime. A manual refresh of
    /// the same processes does not restart rejected work or create a retry loop.
    private func reconnectDiscoveredTrayItems() {
        guard usesIndependentTray, hasCompletedSetup, !panelInteractionBusy, trayPlacementTask == nil,
              accessibilityGranted, (usesNativeVisibility ? nativeVisibilityAccessAvailable : menuBarPositionAccessAvailable), positionRecoveryMessage == nil,
              !stopping, !preparingToTerminate else { return }
        let ids = items.compactMap { row -> String? in
            guard row.isAvailable, row.canMove, row.isPending,
                  let identity = draftSessionIdentity(for: row.id),
                  trayConnectionAttempts[row.id] != identity else { return nil }
            trayConnectionAttempts[row.id] = identity
            return row.id
        }
        guard !ids.isEmpty else { return }
        trayReconnectIDs = Set(ids)
        Self.diagnosticLogger.notice("tray reconnectStarted=true items=\(ids.count)")
        applyItemRules(requestedItemIDs: Set(ids), preservePanel: true)
        let reconnectTask = workTask
        Task { [weak self] in
            await reconnectTask?.value
            self?.trayReconnectIDs = []
        }
    }
    var permissionSettingsName: String { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能" }
    var applicationPath: String { Bundle.main.bundleURL.path }
    var hasAlwaysHiddenItems: Bool { usesNativeAlwaysSection || rules.rules.values.contains { $0.visibility == .alwaysHidden } }
    var operationStartedAt: Date? { operationState.active?.startedAt }
    var operationElapsedSeconds: TimeInterval { operationState.elapsed(uptime: ProcessInfo.processInfo.systemUptime) }
    var operationCancellationRequested: Bool { operationState.active?.cancellationRequested == true }
    var canCancelCurrentOperation: Bool {
        operationState.active != nil && !operationCancellationRequested && !preparingToTerminate && !isRecoveringPositions
    }
    var explicitDraftCount: Int { items.filter { $0.isPending && rowDraftIDs[$0.id] != nil }.count }
    var savedRulesNeedingVerificationCount: Int { items.filter { $0.isPending && rowDraftIDs[$0.id] == nil }.count }
    private var operationDeadline: TimeInterval? { operationState.active?.deadline }

    private func beginOperation(kind: ManagementOperationKind, itemCount: Int = 0) -> UUID {
        let token = operationState.begin(kind: kind, itemCount: itemCount,
            at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        Self.diagnosticLogger.notice("managementOperation started kind=\(String(describing: kind), privacy: .public) items=\(itemCount)")
        return token
    }

    private func finishOperation(token: UUID) {
        guard let active = operationState.active, active.id == token else { return }
        let elapsed = operationState.elapsed(uptime: ProcessInfo.processInfo.systemUptime)
        Self.diagnosticLogger.notice("managementOperation finished kind=\(String(describing: active.kind), privacy: .public) elapsed=\(elapsed) cancelled=\(active.cancellationRequested) failed=\(self.managementError != nil) recoveryPending=\(self.positionRecoveryMessage != nil)")
        operationState.finish(token: token)
    }

    private func checkOperationDeadline(budget: ManagementOperationBudget = .foreground) throws {
        try Task.checkCancellation()
        if budget == .foreground, operationState.hasExpired(uptime: ProcessInfo.processInfo.systemUptime) {
            throw MenuTidyManagementError.operationTimedOut
        }
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation, operationState.requestCancellation() else { return }
        trayPlacementQueue.cancelAllPending()
        managementMessage = "正在停止本次操作并完成必要的位置恢复…"
        // Keep the operation and busy gates until its awaited cleanup returns.
        // A detached cancellation message could reach the AX actor after the
        // next operation starts, so cancellation travels with the owning Task.
        workTask?.cancel()
    }

    init() {
        defaults = CommandLine.arguments.contains("--preview-ui")
            ? UserDefaults(suiteName: "dev.hdh.MenuTidy.preview.\(UUID().uuidString)")!
            : (CommandLine.arguments.contains("--demo-items") ? UserDefaults(suiteName: "dev.hdh.MenuTidy.demo")! : .standard)
        defaults.register(defaults: ["autoCollapse": false, "autoCollapseDelay": 15.0, "startCollapsed": false, "shortcutEnabled": true])
        autoCollapseEnabled = defaults.bool(forKey: "autoCollapse")
        autoCollapseDelay = AutoCollapsePolicy(delay: defaults.double(forKey: "autoCollapseDelay")).delay
        startCollapsed = defaults.bool(forKey: "startCollapsed")
        shortcutEnabled = defaults.bool(forKey: "shortcutEnabled")
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        if isUIPreview {
            configureUIPreview()
            return
        }
        usesNativeAlwaysSection = defaults.bool(forKey: "usesNativeAlwaysSection")
        if let data = defaults.data(forKey: "itemRules.v1") {
            do { rules = try JSONDecoder().decode(ItemRuleBook.self, from: data) }
            catch {
                defaults.set(data, forKey: "itemRules.unreadableBackup")
                managementError = "已保存的分类无法读取，原始设置已备份。请刷新图标后重新分类。"
            }
        }
        if let data = defaults.data(forKey: "nativeTrayChoices.v1") {
            do { nativeTrayChoices = try JSONDecoder().decode(NativeTrayChoices.self, from: data) }
            catch {
                defaults.set(data, forKey: "nativeTrayChoices.unreadableBackup")
                nativeChoicesLoadIssue = "托盘分类记录无法读取，原始数据已保留并备份。已停止自动隐藏，请先检查分类记录。"
                managementError = nativeChoicesLoadIssue
            }
        }
        if nativeChoicesLoadIssue == nil {
            nativeTrayChoices.migrate(saved: rules, excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
            if let encoded = try? JSONEncoder().encode(nativeTrayChoices) {
                defaults.set(encoded, forKey: "nativeTrayChoices.v1")
            }
        }
        drafts = rules
        if let data = defaults.data(forKey: "itemDrafts.v1") {
            do { pendingDrafts = try JSONDecoder().decode(PendingDraftStore.self, from: data) }
            catch {
                defaults.set(data, forKey: "itemDrafts.unreadableBackup")
                draftPersistenceIssue = "待应用草稿无法读取，原始数据已备份；已应用规则不受影响。"
            }
        }
        accessibilityGranted = AXIsProcessTrusted()
        positionLayoutRecoveryNeeded = defaults.bool(forKey: "positionLayoutReviewNeeded.v1")
        pendingPositionRecoveries = positionStore.pendingTransactions
        if !pendingPositionRecoveries.isEmpty || positionLayoutRecoveryNeeded {
            positionRecoveryMessage = "上次排序有未结束的恢复记录。可重试恢复原位置，或保留当前布局后重新分类。"
        } else if let issue = positionStore.recoveryJournalIssue ?? positionStore.hiddenLedgerRecoveryIssue {
            positionRecoveryMessage = issue
        }
        recheckMenuBarPositionAccess()
        recheckNativeVisibilityAccess()
        if usesNativeVisibility, let issue = nativeRecoveryIssue { positionRecoveryMessage = issue }
        rebuildRows()
    }

    func start() {
        guard !isUIPreview else { return }
        controlRouter.start(model: self)
        statusBar = StatusBarController(model: self, demoMode: demoMode)
        shortcut.onPress = { [weak self] in self?.toggleVisibility() }
        configureShortcut()
        refreshLoginStatus()
        refreshEnvironment()
        // Recover our own exact preference writes even if AX was revoked
        // while this application was stopped. Recovery never needs AX input.
        if needsLegacyPositionRecovery {
            let recoveryGeneration = beginPositionRecovery()
            workTask = Task {
                defer { finishPositionRecovery(recoveryGeneration) }
                do {
                    for transaction in positionStore.pendingTransactions {
                        let restored = try positionStore.rollback(transaction)
                        try await statusBar?.refreshPreferredPositions()
                        guard restored.isComplete else { throw MenuBarAccessError.rejected }
                    }
                    let pending = try positionStore.recoverPendingHiddenWrites()
                    try await completeHiddenLayoutRefresh(pending.requiresLayoutRefresh)
                    let restored = try positionStore.restoreAllHidden()
                    try await completeHiddenLayoutRefresh(restored.requiresLayoutRefresh)
                    guard pending.isComplete && restored.isComplete else { throw MenuBarAccessError.rejected }
                    finishPositionRecovery(recoveryGeneration)
                    if usesNativeVisibility { recoverNativeVisibilityAndRefresh() }
                    else if accessibilityGranted { refreshMenuItems(collapseWhenFinished: startCollapsed && hasCompletedSetup) }
                } catch {
                    await refreshAfterHiddenFailure(error)
                    positionRecoveryMessage = "上次隐藏位置尚未恢复：\(error.localizedDescription)"
                }
            }
        } else if usesNativeVisibility && hasManagedNativeTargets {
            recoverNativeVisibilityAndRefresh()
        } else if accessibilityGranted {
            refreshMenuItems(collapseWhenFinished: startCollapsed && hasCompletedSetup && !demoMode)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkAutoCollapse()
                guard let self else { return }
                if self.needsPositionRevalidation { self.recoverVisibility() }
                if (self.settingsVisible || self.isArranging) && ProcessInfo.processInfo.systemUptime - self.lastPermissionCheck > 2 {
                    self.refreshPermissions()
                }
                self.schedulePassiveIconCapture()
                if self.trayDiscoveryNeeded && !self.panelInteractionBusy {
                    self.trayDiscoveryNeeded = false
                    self.refreshMenuItems()
                }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.registerDepartedNativeOwners()
                    self?.scheduleNativeOwnerRecoveryDiscoveryIfNeeded()
                    self?.pruneObservedGroupHistory()
                    self?.rebuildRows()
                    self?.refreshEnvironment()
                    self?.trayDiscoveryNeeded = true
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverVisibility() }
            })
        }
    }

    func requestAccessibility() {
        if isUIPreview { accessibilityGranted = true; permissionCheckMessage = "预览：已模拟辅助功能授权。"; return }
        // This asks macOS to guide the user; it never edits the privacy database.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        managementMessage = "请在系统设置的「\(permissionSettingsName)」中开启 Menu Tidy。回到这里后会自动检测并读取图标。"
        openAccessibilitySettings()
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        if isUIPreview { managementMessage = "预览不会打开或修改系统设置。"; return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        if isUIPreview { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func recheckPermissions() {
        if isUIPreview { permissionCheckMessage = "预览：当前权限来自模拟数据。"; return }
        refreshPermissions()
        recheckMenuBarPositionAccess()
        permissionCheckMessage = accessibilityGranted
            ? "检测完成：macOS 已允许当前运行的 Menu Tidy 访问辅助功能。"
            : "检测完成：macOS 尚未允许当前版本访问。如果系统开关已经打开，请按下方「已开启仍未识别？」更新旧的授权记录。"
    }

    func recheckMenuBarPositionAccess() {
        if isUIPreview { return }
        do {
            _ = try positionStore.readPositions()
            menuBarPositionAccessAvailable = true
            menuBarPositionAccessMessage = "已读取系统排序记录。实际支持的图标会在应用分组时逐项验证。"
        } catch {
            menuBarPositionAccessAvailable = false
            menuBarPositionAccessMessage = "尚不能读取菜单栏排序记录，请点击「授权排序目录…」完成系统目录授权。"
        }
    }

    func requestMenuBarPositionAccess() {
        if isUIPreview { menuBarPositionAccessAvailable = true; return }
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
        Task {
            do {
                guard try await positionAccess.request() else { return }
                recheckMenuBarPositionAccess()
                if menuBarPositionAccessAvailable { managementError = nil }
            } catch {
                menuBarPositionAccessMessage = error.localizedDescription
            }
        }
    }

    func retryPositionRecovery() {
        if isUIPreview { positionRecoveryMessage = nil; return }
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
        if usesNativeVisibility && !needsLegacyPositionRecovery {
            trayConnectionAttempts.removeAll()
            recoverNativeVisibilityAndRefresh(reconnect: false)
            return
        }
        cancelPassiveIconCapture()
        let recoveryGeneration = beginPositionRecovery()
        workTask = Task {
            defer { finishPositionRecovery(recoveryGeneration) }
            do {
                let hidden = try positionStore.restoreAllHidden()
                try await completeHiddenLayoutRefresh(hidden.requiresLayoutRefresh)
                guard hidden.isComplete else { throw MenuBarAccessError.rejected }
                verifiedPositionGroups.removeAll()
                verifiedPositionEvidence.removeAll()
                actualGroups.removeAll()
                rebuildRows()
                for token in positionStore.pendingTransactions {
                    let result = try positionStore.rollback(token)
                    if !result.isComplete {
                        throw MenuTidyManagementError.positionApplication("有图标已被其他操作改变，未覆盖这些位置。可保留当前布局后重新分类。")
                    }
                }
                pendingPositionRecoveries = positionStore.pendingTransactions
                if let statusBar { try await statusBar.refreshPreferredPositions() }
                try await scanNow()
                if positionRecoveryFrames.isEmpty {
                    // On relaunch the journal proves original preferences, not
                    // an old screen coordinate. Keep that distinction visible.
                    positionRecoveryMessage = "原排序记录已恢复；原生显示位置尚待检查。确认当前布局后，可继续分类。"
                    positionLayoutRecoveryNeeded = true
                } else {
                    try await verifyPositionRecoveryFrames()
                    positionLayoutRecoveryNeeded = false
                    positionRecoveryMessage = nil
                    positionRecoveryFrames.removeAll()
                }
            } catch {
                await refreshAfterHiddenFailure(error)
                pendingPositionRecoveries = positionStore.pendingTransactions
                positionRecoveryMessage = error.localizedDescription
            }
        }
    }

    func keepCurrentPositionLayout() {
        if isUIPreview { positionRecoveryMessage = nil; return }
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
        if usesNativeVisibility && !needsLegacyPositionRecovery {
            _ = reloadAllNativeRecoveryJournalsIfNeeded()
            let failed = nativeVisibilityStore.restoreAll()
            let failedSystems = nativeSystemVisibilityStore.restoreAll()
            do { for bundle in failed { try nativeVisibilityStore.forgetExternallyChanged(bundle: bundle) } }
            catch { positionRecoveryMessage = error.localizedDescription; return }
            guard failedSystems.isEmpty, nativeRecoveryIssue == nil else {
                positionRecoveryMessage = nativeRecoveryIssue ?? "系统图标的显示设置已变化，恢复记录已保留；请先重试恢复。"
                return
            }
            nativeVisibilityEvidence.removeAll()
            positionRecoveryMessage = nil
            for item in snapshots {
                if let identity = observedItemIdentity(item) { trayConnectionAttempts[item.id] = identity }
            }
            refreshMenuItems()
            return
        }
        cancelPassiveIconCapture()
        let recoveryGeneration = beginPositionRecovery()
        workTask = Task {
            defer { finishPositionRecovery(recoveryGeneration) }
            do {
                // Restore every position still owned by this application before
                // abandoning only the conflicting/missing records. Otherwise
                // an unrelated conflict could strand ordinary hidden icons.
                let result = try positionStore.restoreAllHidden()
                try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                guard result.pendingRecoveryKeys.isEmpty else { throw MenuBarAccessError.rejected }
                for token in positionStore.pendingTransactions { try positionStore.abandon(token) }
                try positionStore.abandonAllHidden()
                verifiedPositionGroups.removeAll()
                verifiedPositionEvidence.removeAll()
                actualGroups.removeAll()
                rebuildRows()
                pendingPositionRecoveries.removeAll()
                positionLayoutRecoveryNeeded = false
                positionRecoveryFrames.removeAll()
                positionRecoveryMessage = nil
                managementMessage = "已恢复本应用仍在管理的隐藏位置，并保留外部改动；未确认的分类仍待处理。"
            } catch {
                await refreshAfterHiddenFailure(error)
                positionRecoveryMessage = error.localizedDescription
            }
        }
    }

    func refreshPermissions() {
        guard !isUIPreview else { return }
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !screenCaptureGranted { panelImages = [:] }
        if !accessibilityGranted && wasGranted {
            permissionCheckMessage = "macOS 已撤销当前应用的辅助功能访问，请重新授权。"
            workTask?.cancel()
            panelActivationTask?.cancel()
            Task { await access.cancel() }
            if usesNativeVisibility {
                restoreNativeAfterPermissionLoss()
                return
            }
            if usesPositionHiding {
                restoreHiddenAfterPermissionLoss()
                managementError = "辅助功能权限已关闭。已停止自动整理，正在恢复本应用隐藏的位置。"
                return
            }
            if isActivatingPanelItem {
                panelError = "辅助功能权限已撤销，后台操作已停止。请重新授权后重试。"
                return
            }
            if isArranging { leaveArrangementExpanded() }
            beforeTemporaryRevealCollapsed = nil
            temporarilyRevealingAll = true
            state.expand()
            if !isApplying { applyState() }
            managementError = "辅助功能权限已关闭。已停止自动整理，请重新授权后刷新。"
        }
        if accessibilityGranted && !wasGranted {
            permissionCheckMessage = "已自动检测到授权，正在读取菜单栏图标。"
            managementError = nil
            managementMessage = "辅助功能已授权，正在读取菜单栏图标。"
            refreshMenuItems()
        }
    }

    private func beginPositionRecovery() -> Int {
        positionRecoveryGeneration += 1
        isRecoveringPositions = true
        return positionRecoveryGeneration
    }

    private func finishPositionRecovery(_ generation: Int) {
        if positionRecoveryGeneration == generation { isRecoveringPositions = false }
    }

    private func restoreHiddenAfterPermissionLoss() {
        // Termination already owns recovery. A permission notification must not
        // replace its generation or install a new workTask while it is awaited.
        guard !preparingToTerminate, !stopping else { return }
        cancelPassiveIconCapture()
        closeIconPanel()
        let previousWork = workTask
        let previousActivation = panelActivationTask
        let recoveryGeneration = beginPositionRecovery()
        workTask = Task {
            defer { finishPositionRecovery(recoveryGeneration) }
            await previousWork?.value
            await previousActivation?.value
            do {
                let result = try positionStore.restoreAllHidden()
                try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                guard result.isComplete else { throw MenuBarAccessError.rejected }
                verifiedPositionGroups.removeAll()
                verifiedPositionEvidence.removeAll()
                actualGroups.removeAll()
                rebuildRows()
                temporarilyRevealingAll = false
                state.collapse()
                applyState()
                managementMessage = "本应用隐藏的位置已恢复；重新授权后可继续整理。"
            } catch {
                await refreshAfterHiddenFailure(error)
                positionRecoveryMessage = "权限变化后恢复隐藏位置未完成：\(error.localizedDescription)"
            }
        }
    }

    func requestScreenCapture() {
        if isUIPreview { screenCaptureGranted = true; return }
        _ = CGRequestScreenCaptureAccess()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !screenCaptureGranted {
            panelError = "请在系统设置中允许 Menu Tidy 录制屏幕。授权后返回重新检测；若系统要求重新打开，请退出后重新打开应用。"
            openScreenCaptureSettings()
        } else { panelError = nil }
    }

    func openScreenCaptureSettings() {
        if isUIPreview { managementMessage = "预览不会打开或修改系统设置。"; return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshMenuItems(collapseWhenFinished: Bool = false, prepareOverflow: Bool = false) {
        if isUIPreview { managementMessage = "预览：图标列表已更新，当前选择已保留。"; return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        guard accessibilityGranted else { managementError = "先在权限页开启辅助功能权限，再读取菜单栏图标。"; return }
        if prepareOverflow { closeIconPanel() }
        isRefreshing = true
        managementError = nil
        let preparesIconInventory = prepareOverflow && screenCaptureGranted
        let refreshesManagedIcons = preparesIconInventory && usesPositionHiding
        let operationToken = beginOperation(kind: preparesIconInventory ? .refreshImages : .refresh)
        managementMessage = preparesIconInventory
            ? "正在读取原始图标；仅请求系统提供的后台接口，不移动鼠标。"
            : "正在更新图标列表，保留现有分组与选择。"
        applyState()
        workTask = Task { [weak self] in
            guard let self else { return }
            var scanSucceeded = false
            var inventoryIssues: [String] = []
            defer {
                self.isRefreshing = false
                self.finishOperation(token: operationToken)
                self.applyState()
                if collapseWhenFinished, scanSucceeded, !Task.isCancelled, !self.stopping,
                   !self.settingsVisible, !self.contextMenuVisible, !self.isPanelPresented {
                    self.collapseIfSafe()
                }
                if scanSucceeded && !Task.isCancelled { self.reconnectDiscoveredTrayItems() }
            }
            do {
                await self.passiveIconCaptureTask?.value
                try self.checkImageRefreshCancellation()
                try self.checkOperationDeadline()
                if preparesIconInventory && !refreshesManagedIcons && !self.usesNativeVisibility {
                    do {
                        try await self.scanManagementAnchors()
                        _ = try await self.access.revealSystemOverflowForManagement(
                            requiredIDs: self.snapshots.filter(\.canMove).map(\.id), forIconInventory: true)
                    } catch {
                        try self.checkImageRefreshCancellation(error)
                        inventoryIssues.append("准备系统溢出区：\(error.localizedDescription)")
                    }
                }
                try self.checkImageRefreshCancellation()
                try await self.scanNow(allowNativeOwnerRecovery: true)
                try self.checkOperationDeadline()
                // Discovery can first restore our ownership for a departed
                // process. ScreenCaptureKit and temporary
                // native presentation belong only to explicit image refresh.
                if preparesIconInventory {
                    if refreshesManagedIcons {
                        let issues = try await self.refreshManagedHiddenIconImages()
                        inventoryIssues.append(contentsOf: issues)
                        // Temporary weights have been restored; resume normal
                        // evidence checks before the remaining passive capture.
                        try self.checkImageRefreshCancellation()
                        try await self.scanNow()
                    }
                    do { try await self.prepareIconImages() }
                    catch {
                        try self.checkImageRefreshCancellation(error)
                        inventoryIssues.append("采集图标图像：\(error.localizedDescription)")
                    }
                    try self.checkImageRefreshCancellation()
                    let coverage = self.hiddenImageCoverage()
                    var available: Set<String> = []
                    do { available = try self.iconCapture.availableCachedImageIDs(matching: self.snapshots) }
                    catch {
                        try self.checkImageRefreshCancellation(error)
                        inventoryIssues.append("检查可用图像：\(error.localizedDescription)")
                    }
                    try self.checkImageRefreshCancellation()
                    self.updateIconImageWarning(
                        summary: ImageAvailabilitySummary(requested: coverage.requested, available: available),
                        unobservedConfiguredCount: coverage.unobservedConfiguredCount,
                        issues: inventoryIssues)
                }
                try self.checkOperationDeadline()
                try Task.checkCancellation()
                guard !self.stopping else { throw MenuBarAccessError.cancelled }
                scanSucceeded = true
                self.managementMessage = self.items.isEmpty
                    ? "没有读到菜单栏项目。请退出全屏、展开其他整理器后重试。"
                    : "列表已更新，共 \(self.items.filter(\.isAvailable).count) 个项目。" +
                        (self.savedRulesNeedingVerificationCount > 0
                            ? "有 \(self.savedRulesNeedingVerificationCount) 项已保存分组待验证，可明确应用后检查；刷新列表不会自动修改位置。"
                            : "现有分组与待应用选择已保留。")
            } catch {
                do {
                    try self.checkImageRefreshCancellation(error)
                    self.managementError = error.localizedDescription
                } catch {
                    // Cancellation is handled once here, not converted into an
                    // unsupported capability or a failed classification.
                    self.managementMessage = "本次刷新已停止，现有列表与选择已保留。"
                }
            }
            if preparesIconInventory && !refreshesManagedIcons && !self.usesNativeVisibility { await self.access.restoreSystemOverflowAfterManagement() }
        }
    }

    /// Only an explicit icon refresh calls this method. No timer/startup path
    /// reveals managed items, and no saved rule or draft is modified here.
    private func refreshManagedHiddenIconImages() async throws -> [String] {
        guard usesPositionHiding, !positionStore.managedHiddenEntries.isEmpty else { return [] }
        guard !positionLayoutRecoveryNeeded, positionStore.pendingTransactions.isEmpty,
              positionStore.pendingHiddenRecoveryKeys.isEmpty,
              positionStore.hiddenLedgerRecoveryIssue == nil else {
            throw MenuTidyManagementError.positionApplication("仍有待恢复的位置记录，请先恢复位置，再刷新隐藏图标。")
        }
        try checkManagedIconRefreshPermission()
        let controls = snapshots.filter { $0.ownIdentifier == "menu-tidy-toggle" }
        guard controls.count == 1, let controlID = controls.first?.id else { throw MenuBarAccessError.disappeared }
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        let targets = snapshots.filter { item in
            let saved = rules.rule(for: item.id)?.visibility
            return counts[item.id] == 1 && item.canMove && item.ownIdentifier == nil &&
                (saved == .collapsible || saved == .alwaysHidden)
        }
        let deadline = min(operationDeadline ?? .infinity,
            ProcessInfo.processInfo.systemUptime + min(90, max(20, Double(targets.count) * 6)))
        var issues: [String] = []
        isRefreshingManagedIcons = true
        defer { isRefreshingManagedIcons = false }
        for (index, item) in targets.enumerated() {
            try checkManagedIconRefreshPermission()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                issues.append("本次隐藏图标刷新已达到时限，其余项目保留原快照，可再次刷新。")
                break
            }
            var candidates: [MenuBarPositionCandidate] = []
            var revealedKey: String?
            var itemError: Error?
            var revealVerified = false
            do {
                candidates = try await access.prepareBackgroundPositionCandidates(ids: [item.id, controlID],
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                guard let target = candidates.first(where: { $0.id == item.id }),
                      let control = candidates.first(where: { $0.id == controlID }) else { throw MenuBarAccessError.disappeared }
                if let held = positionStore.managedHiddenEntries.first(where: { $0.key == target.key }) {
                    guard held.mode == .hidden, !held.recoveryPending else {
                        throw MenuTidyManagementError.positionApplication("该图标仍有临时显示或待恢复状态，请先恢复位置。")
                    }
                    try checkManagedIconRefreshPermission()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw MenuTidyManagementError.positionApplication("本次采集已达到时限，保留原快照。")
                    }
                    managementMessage = "正在刷新隐藏图标 \(index + 1)/\(targets.count)：\(item.name)。采集后恢复隐藏，不移动鼠标。"
                    try await access.validateBackgroundPositionCandidates(candidates,
                        positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                    // Install cleanup intent before the store call: a thrown
                    // write may already have reached the shared preferences.
                    revealedKey = target.key
                    let revealed = try await temporarilyRevealManagedItem(id: item.id, key: target.key, before: control.key)
                    try await completeHiddenLayoutRefresh(revealed.requiresLayoutRefresh)
                    guard revealed.isComplete else { throw MenuBarAccessError.rejected }
                    guard let visibleFrame = try await waitForPositionVisibility(id: item.id, visible: true,
                        candidates: candidates, until: deadline) else { throw MenuBarAccessError.invalidGeometry }
                    revealVerified = true
                    try checkManagedIconRefreshPermission()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw MenuTidyManagementError.positionApplication("本次采集已达到时限，保留原快照。")
                    }
                    let current = snapshots.filter { $0.id == item.id && $0.processIdentifier == target.processIdentifier }
                    guard current.count == 1, let currentItem = current.first else { throw MenuBarAccessError.disappeared }
                    let confirmed = snapshotForVerifiedIconCapture(currentItem, frame: visibleFrame)
                    _ = try await captureAndVerifyIconImages([confirmed])
                    panelLastCaptureDate = iconCapture.lastCacheDate
                    Self.diagnosticLogger.notice("managedIconRefresh captured=true ordinal=\(index + 1)")
                }
                // No ledger means no temporary mutation. The normal passive
                // capture below still considers that item's visible snapshot.
            } catch {
                await refreshAfterHiddenFailure(error)
                itemError = error
            }

            var cleanupError: Error?
            if let key = revealedKey {
                let retainedCandidates = candidates
                let hadVisibleProof = revealVerified
                let cleanup = Task { @MainActor in
                    do {
                        let restored = try self.restoreTemporaryManagedItem(key: key)
                        try await self.completeHiddenLayoutRefresh(restored.requiresLayoutRefresh)
                        guard restored.isComplete else { throw MenuBarAccessError.rejected }
                        // Cancellation of refresh never cancels restoration.
                        // Verify native hiding when AX remains available; this
                        // read-only wait has its own fixed three-second limit,
                        // independent of an expired foreground refresh budget.
                        if AXIsProcessTrusted(), self.accessibilityGranted,
                           !self.stopping, !self.preparingToTerminate {
                            _ = try await self.waitForPositionVisibility(id: item.id, visible: false,
                                candidates: retainedCandidates, hadVerifiedReveal: hadVisibleProof, budget: .cleanup)
                        }
                        Self.diagnosticLogger.notice("managedIconRefresh hiddenPositionRestored=true ordinal=\(index + 1)")
                        return Optional<Error>.none
                    } catch {
                        await self.refreshAfterHiddenFailure(error)
                        self.verifiedPositionGroups.removeValue(forKey: item.id)
                        self.verifiedPositionEvidence.removeValue(forKey: item.id)
                        self.actualGroups.removeValue(forKey: item.id)
                        self.rebuildRows()
                        self.positionLayoutRecoveryNeeded = true
                        self.positionRecoveryMessage = "刷新「\(item.name)」后恢复隐藏未完成：\(error.localizedDescription)"
                        return Optional(error)
                    }
                }
                cleanupError = await cleanup.value
            }
            await access.discardBackgroundPositionCandidates(candidates)
            if let cleanupError {
                issues.append("「\(item.name)」恢复隐藏失败：\(cleanupError.localizedDescription)")
                throw MenuTidyManagementError.positionApplication(issues.joined(separator: "\n"))
            }
            if let itemError {
                try checkImageRefreshCancellation(itemError)
                issues.append("「\(item.name)」未更新，保留仍有效的原快照：\(itemError.localizedDescription)")
            }
            try checkImageRefreshCancellation()
        }
        return issues
    }

    private func checkManagedIconRefreshPermission() throws {
        try checkImageRefreshCancellation()
        try checkOperationDeadline()
        guard accessibilityGranted, AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard screenCaptureGranted, CGPreflightScreenCaptureAccess() else {
            throw MenuBarIconCapture.CaptureError.permissionRequired
        }
    }

    private func checkImageRefreshCancellation(_ error: Error? = nil) throws {
        if error is CancellationError { throw CancellationError() }
        if let accessError = error as? MenuBarAccessError, case .cancelled = accessError { throw CancellationError() }
        if let overflowError = error as? MenuBarOverflowError, case .cancelled = overflowError { throw CancellationError() }
        try Task.checkCancellation()
        if stopping || preparingToTerminate { throw CancellationError() }
    }

    private func hiddenImageCoverage() -> (requested: Set<String>, unobservedConfiguredCount: Int) {
        // Share the panel's accepted/observed membership; drafts are not inputs.
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        let requested = Set(snapshots.filter { item in
            counts[item.id] == 1 && item.canMove && item.ownIdentifier == nil &&
                HiddenItemsPanelPolicy.includes(
                    savedVisibility: rules.rule(for: item.id)?.visibility,
                    observedVisibility: observedGroupForDisplay(id: item.id),
                    includeAlwaysHidden: true)
        }.map(\.id))
        let configuredHidden = Set(rules.rules.values.filter {
            $0.visibility == .collapsible || $0.visibility == .alwaysHidden
        }.map(\.id)).union(requested)
        return (requested, configuredHidden.subtracting(requested).count)
    }

    private func updateIconImageWarning(summary: ImageAvailabilitySummary,
                                        unobservedConfiguredCount: Int, issues: [String]? = nil,
                                        clearPanelError: Bool = true) {
        if let issues { iconImagePreparationIssues = issues }
        // A preparation failure is not a missing image when a valid snapshot
        // already supplies every requested item. Do not retain that false alarm.
        if clearPanelError { panelError = nil }
        guard summary.hasMissingImages || (summary.requested.isEmpty && unobservedConfiguredCount > 0) else {
            iconImageWarning = nil
            iconImageWarningDetails = nil
            return
        }
        var details: [String]
        if summary.requested.isEmpty {
            iconImageWarning = "本次未能核对隐藏图标图像"
            details = ["已保存的 \(unobservedConfiguredCount) 个隐藏图标本次均未能确认；应用可能未运行，或图标暂时无法唯一读取。本次检查范围为 0，不代表这些图标的图像已经齐全。"]
        } else {
            iconImageWarning = "部分图标图像尚未获取（\(summary.missing.count)/\(summary.requested.count)）"
            details = ["仅统计本次读取到的 \(summary.requested.count) 个「收起后隐藏」或「始终隐藏」图标，其中 \(summary.captured.count) 个已有可用图像；不包含常驻显示、系统保护项或未读取到的项目。"]
            if unobservedConfiguredCount > 0 {
                details.append("另有 \(unobservedConfiguredCount) 个已保存的隐藏图标本次未能确认，不计入上述范围。")
            }
        }
        for issue in iconImagePreparationIssues where !details.contains(issue) { details.append(issue) }
        details.append("可展开系统溢出区并保持片刻；应用会在图标可见且身份确认后自动补采，不会移动鼠标。图像获取结果不代表分类是否已应用。")
        iconImageWarningDetails = details.joined(separator: "\n")
    }

    /// Derive coverage after the capture checkpoint has accepted or restored
    /// its images. A prior missing-count message is never an availability source.
    /// This read-only recount must not clear a separate panel operation error.
    private func recomputeIconImageWarning() {
        let coverage = hiddenImageCoverage()
        let available = (try? iconCapture.availableCachedImageIDs(matching: snapshots)) ?? []
        updateIconImageWarning(summary: ImageAvailabilitySummary(requested: coverage.requested, available: available),
            unobservedConfiguredCount: coverage.unobservedConfiguredCount, clearPanelError: false)
        panelLastCaptureDate = iconCapture.lastCacheDate
    }

    func setGroup(id: String, group: ItemVisibility) {
        if usesIndependentTray {
            requestTrayPlacement(id: id, group: group)
            return
        }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, let row = items.first(where: { $0.id == id }), row.canMove, row.isAvailable,
              snapshots.filter({ $0.id == id }).count == 1 else { return }
        cancelPassiveIconCapture()
        itemApplicationIssues.removeValue(forKey: id)
        managementError = nil
        let identity = draftSessionIdentity(for: id)
        do {
            if rules.rule(for: id)?.visibility == group {
                if let record = pendingDrafts.record(for: id, sessionIdentity: identity) { pendingDrafts.remove(id: record.id) }
            } else {
                try pendingDrafts.set(ItemRule(id: id, name: row.name, bundleIdentifier: row.bundleIdentifier,
                    visibility: group), sessionIdentity: identity)
            }
            persistDrafts()
        } catch PendingDraftStore.StoreError.targetHasDraft {
            managementError = "此图标已有待关联草稿。请在下方离线草稿中明确关联，或删除旧草稿后重新选择。"
        } catch {
            managementError = "暂时无法确认此图标身份，选择尚未保存为草稿。请刷新图标后重试。"
        }
        rebuildRows()
    }

    func pendingDraftID(for itemID: String) -> UUID? { rowDraftIDs[itemID] }

    func discardDraft(id: UUID) {
        if isUIPreview { offlineDrafts.removeAll { $0.id == id }; return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        cancelPassiveIconCapture()
        if let itemID = rowDraftIDs.first(where: { $0.value == id })?.key {
            itemApplicationIssues.removeValue(forKey: itemID)
        }
        pendingDrafts.remove(id: id)
        persistDrafts()
        rebuildRows()
    }

    @discardableResult
    func reassociateDraft(id: UUID, to itemID: String) -> Bool {
        if isUIPreview { return false }
        guard !stopping, !preparingToTerminate, !isRecoveringPositions, !isActivatingPanelItem,
              !isApplying, !isRefreshing, !isArranging, trayPlacementTask == nil,
              (!usesNativeVisibility || nativeChoicesLoadIssue == nil),
              offlineDrafts.contains(where: { $0.id == id }),
              let row = items.first(where: { $0.id == itemID && $0.isAvailable && $0.canMove }),
              snapshots.filter({ $0.id == itemID }).count == 1 else { return false }
        cancelPassiveIconCapture()
        do {
            let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
            let currentTargets = items.filter { $0.isAvailable && $0.canMove && counts[$0.id] == 1 }.map {
                TrayPlacementPolicy.DraftTarget(rule: ItemRule(id: $0.id, name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier, visibility: $0.group),
                    identity: draftSessionIdentity(for: $0.id))
            }
            let target = TrayPlacementPolicy.DraftTarget(rule: ItemRule(id: row.id, name: row.name,
                bundleIdentifier: row.bundleIdentifier, visibility: row.group),
                identity: draftSessionIdentity(for: row.id))
            let prepared = try TrayPlacementPolicy.reassociatingDraft(in: pendingDrafts, id: id,
                to: target, currentTargets: currentTargets,
                nativeChoices: usesNativeVisibility ? nativeTrayChoices : nil,
                excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
            try saveTrayIntent(drafts: prepared.drafts, nativeChoices: prepared.nativeChoices)
            for affectedID in prepared.affectedIDs {
                itemApplicationIssues.removeValue(forKey: affectedID)
                trayPlacementErrors.removeValue(forKey: affectedID)
                // Association promises to save only. A routine refresh of this
                // process must not turn it into an automatic native mutation.
                if let identity = draftSessionIdentity(for: affectedID) { trayConnectionAttempts[affectedID] = identity }
            }
            managementError = nil
            managementMessage = "草稿已关联，原分类选择已保留。点击应用后生效。"
            rebuildRows()
            return true
        } catch PendingDraftStore.StoreError.targetHasDraft {
            managementError = "此应用还有其他待关联草稿，未覆盖任何选择。请先处理对应草稿，或选择其他图标。"
        } catch {
            managementError = "图标身份已变化或草稿暂时无法保存，未关联草稿。请刷新列表后重新选择。"
        }
        return false
    }

    /// Pre-encode every changed intent store before assigning either in memory
    /// or UserDefaults. Encoding failure leaves both previous choices intact.
    private func saveTrayIntent(drafts updatedDrafts: PendingDraftStore,
                                nativeChoices updatedChoices: NativeTrayChoices?) throws {
        let encodedDrafts = try JSONEncoder().encode(updatedDrafts)
        let encodedChoices = try updatedChoices.map { try JSONEncoder().encode($0) }
        pendingDrafts = updatedDrafts
        defaults.set(encodedDrafts, forKey: "itemDrafts.v1")
        if let updatedChoices, let encodedChoices {
            nativeTrayChoices = updatedChoices
            defaults.set(encodedChoices, forKey: "nativeTrayChoices.v1")
        }
        draftPersistenceIssue = nil
    }

    func forgetItemAffectsApplication(id: String) -> Bool {
        guard usesNativeVisibility,
              let row = items.first(where: { $0.id == id }), let bundle = row.bundleIdentifier,
              rules.rule(for: id)?.bundleIdentifier == bundle || isUIPreview else { return false }
        return NativeTrayChoices.canForget(bundle: bundle, liveBundles: [],
            excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
    }

    func canForgetItem(id: String) -> Bool {
        guard !stopping, !preparingToTerminate, !isRecoveringPositions, !isActivatingPanelItem,
              !isApplying, !isRefreshing, !isArranging, trayPlacementTask == nil,
              let row = items.first(where: { $0.id == id && !$0.isAvailable }),
              !items.contains(where: { $0.id == id && $0.isAvailable }) else { return false }
        guard forgetItemAffectsApplication(id: id) else { return true }
        guard nativeChoicesLoadIssue == nil, let bundle = row.bundleIdentifier else { return false }
        return NativeTrayChoices.canForget(bundle: bundle,
            liveBundles: Set(items.filter(\.isAvailable).compactMap(\.bundleIdentifier)),
            excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
    }

    func forgetItem(id: String) {
        guard canForgetItem(id: id) else { return }
        if isUIPreview { items.removeAll { $0.id == id }; return }
        cancelPassiveIconCapture()
        if forgetItemAffectsApplication(id: id), let bundle = rules.rule(for: id)?.bundleIdentifier {
            let liveBundles = Set(items.filter(\.isAvailable).compactMap(\.bundleIdentifier))
            var updatedChoices = nativeTrayChoices
            updatedChoices.remove(bundle: bundle, liveBundles: liveBundles,
                excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
            var updatedDrafts = pendingDrafts
            updatedDrafts.removeAll(bundleIdentifier: bundle)
            var updatedRules = rules
            let forgottenIDs = Set(rules.rules.values.filter { $0.bundleIdentifier == bundle }.map(\.id))
            for forgottenID in forgottenIDs { updatedRules.remove(id: forgottenID) }
            do {
                let persistentRules = ItemRuleBook(rules: updatedRules.rules.filter { !$0.key.hasPrefix("session:") })
                let encodedRules = try JSONEncoder().encode(persistentRules)
                try saveTrayIntent(drafts: updatedDrafts, nativeChoices: updatedChoices)
                rules = updatedRules
                defaults.set(encodedRules, forKey: "itemRules.v1")
                for forgottenID in forgottenIDs {
                    drafts.remove(id: forgottenID)
                    lastKnownObservedGroups.remove(id: forgottenID)
                    trayPlacementErrors.removeValue(forKey: forgottenID)
                    itemApplicationIssues.removeValue(forKey: forgottenID)
                    trayConnectionAttempts.removeValue(forKey: forgottenID)
                }
                managementMessage = "已忘记此应用的离线分类与草稿。下次出现时将重新选择；必要的恢复记录仍保留。"
            } catch {
                managementError = "暂时无法保存忘记操作，原有规则和草稿均已保留。"
                return
            }
        } else {
            rules.remove(id: id)
            drafts.remove(id: id)
            lastKnownObservedGroups.remove(id: id)
            persistRules()
        }
        rebuildRows()
        applyState()
    }

    func applyItemRules(onlySavedRules: Bool = false, requestedItemIDs: Set<String>? = nil,
                        preservePanel: Bool = false, resolveAmbiguousKeyFor resolutionID: String? = nil,
                        requestedGroups: [String: ItemVisibility]? = nil) {
        if isUIPreview { previewApplyPending(retryOnly: false); return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        if !preservePanel { closeIconPanel() }
        panelTask?.cancel()
        panelTask = nil
        guard accessibilityGranted else { requestAccessibility(); return }
        refreshEnvironment()
        guard environmentIssue == nil else { managementError = "请先退出其他菜单栏整理器，再应用分类，以免两个工具同时移动图标。"; return }
        let requestedIDs = items.filter {
            $0.isPending && $0.isAvailable && $0.canMove && (!onlySavedRules || rowDraftIDs[$0.id] == nil) &&
                (requestedItemIDs == nil || requestedItemIDs?.contains($0.id) == true)
        }.map(\.id)
        let requestedIDSet = Set(requestedIDs)
        guard !requestedIDs.isEmpty else { return }
        let fixedRules = requestedItemIDs.map { _ in
            items.filter { requestedIDSet.contains($0.id) }.map {
                ItemRule(id: $0.id, name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                    visibility: requestedGroups?[$0.id] ?? $0.group)
            }
        }
        for id in requestedIDs { itemApplicationIssues.removeValue(forKey: id) }
        let previousState = state
        let previousTemporaryReveal = temporarilyRevealingAll
        let previousBeforeTemporaryReveal = beforeTemporaryRevealCollapsed
        cancelPassiveIconCapture()
        isApplying = true
        let operationToken = beginOperation(kind: .apply, itemCount: requestedIDs.count)
        managementError = nil
        managementMessage = "正在检查全部图标和菜单栏空间…"
        workTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var stage = "检查后台分组能力"
            var failureMessage: String?
            defer {
                self.isApplying = false
                self.finishOperation(token: operationToken)
                if !succeeded {
                    self.state = previousState
                    self.temporarilyRevealingAll = previousTemporaryReveal
                    self.beforeTemporaryRevealCollapsed = previousBeforeTemporaryReveal
                } else {
                    self.collapseIfSafe()
                    if self.isCollapsed {
                        let skipped = requestedIDSet.intersection(self.itemApplicationIssues.keys).count
                        self.managementMessage = "已应用并确认 \(requestedIDs.count - skipped) 项分类。" +
                            (skipped > 0 ? "另有 \(skipped) 项未自动应用，选择已保留；可筛选查看原因。" : "点击菜单栏「···」可打开图标栏。") +
                            (self.offlineDrafts.isEmpty ? "" : "另有 \(self.offlineDrafts.count) 条离线草稿保留，未参与本次应用。")
                    }
                }
                self.rebuildRows()
                self.applyState()
                if succeeded { self.schedulePassiveIconCapture() }
            }
            do {
                await self.passiveIconCaptureTask?.value
                try self.checkOperationDeadline()
                if self.usesPositionHiding, let resolutionID, requestedIDs == [resolutionID] {
                    stage = "识别图标对应的位置记录"
                    self.managementMessage = "正在识别此图标的位置记录，完成后继续连接托盘…"
                    try await self.resolveAmbiguousPositionKeyIfNeeded(id: resolutionID)
                    try self.checkOperationDeadline()
                }
                stage = self.usesNativeVisibility ? "更新图标显示设置" : "应用后台排序"
                if !(try await self.applyStoredPositionRules(requestedIDs: requestedIDs, confirmedRules: fixedRules)) {
                    try await self.access.validateBackgroundMoveSupport(ids: requestedIDs)
                    try self.checkOperationDeadline()
                    self.applyState()
                    stage = "等待菜单栏展开"
                    try await Task.sleep(for: .milliseconds(400))
                    stage = "扫描菜单栏"
                    try await self.scanManagementAnchors()
                    stage = "展开系统溢出区域"
                    _ = try await self.access.revealSystemOverflowForManagement()
                    stage = "展开系统溢出区域后重新扫描"
                    try await self.scanNow()
                    stage = "恢复 Menu Tidy 菜单栏入口"
                    try await self.access.recoverControlFromSystemOverflow()
                    try await self.scanNow()
                    stage = "识别本应用三个定位项"
                    let anchors = try self.anchorIDs()
                    // Repair only our own boundary order, then read the settled positions.
                    if let regular = await self.access.currentFrame(id: anchors.regular), let control = await self.access.currentFrame(id: anchors.control), regular.minX >= control.minX {
                        stage = "修复收起区定位项"
                        try await self.access.move(id: anchors.regular, before: anchors.control)
                    }
                    if let always = await self.access.currentFrame(id: anchors.always), let regular = await self.access.currentFrame(id: anchors.regular), always.minX >= regular.minX {
                        stage = "修复常隐区定位项"
                        try await self.access.move(id: anchors.always, before: anchors.regular)
                    }
                    stage = "修复定位项后重新扫描"
                    try await self.scanNow()
                    let pending = self.items.filter { requestedIDSet.contains($0.id) && $0.isAvailable && $0.canMove && $0.isPending }
                        .map { row in row.replacingGroup(fixedRules?.first(where: { $0.id == row.id })?.visibility ?? row.group) }
                    guard Set(pending.map(\.id)) == requestedIDSet else { throw MenuBarAccessError.invalidGeometry }
                    for (index, row) in pending.enumerated() {
                        stage = "移动「\(row.name)」至\(row.group.title)"
                        try self.checkOperationDeadline()
                        self.managementMessage = "正在整理 \(index + 1)/\(pending.count)：将「\(row.name)」设为\(row.group.title)。不会接管鼠标。"
                        let anchor = row.group == .alwaysHidden ? anchors.always : (row.group == .collapsible ? anchors.regular : anchors.control)
                        try await self.access.move(id: row.id, before: anchor)
                        stage = "连续两次验证「\(row.name)」的\(row.group.title)分类"
                        try await self.verify(id: row.id, group: row.group, anchors: anchors)
                        // Save a rule only after the actual AX order agrees twice.
                        let verifiedRule = ItemRule(id: row.id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: row.group)
                        self.rules.set(verifiedRule)
                        self.persistRules()
                        self.pendingDrafts.removeVerified(verifiedRule, sessionIdentity: self.draftSessionIdentity(for: row.id))
                        self.persistDrafts()
                    }
                }
            } catch {
                failureMessage = "\(stage)失败：\(error.localizedDescription)"
            }

            // Cleanup is awaited on every path, including cancellation. Access
            // restores only an overflow presentation it opened for this operation.
            await self.access.restoreSystemOverflowAfterManagement()

            if !Task.isCancelled && !self.stopping {
                do {
                    stage = "恢复系统溢出区域后最终扫描"
                    try await self.scanNow()
                    if failureMessage == nil {
                        stage = "确认全部待应用分类的实际结果"
                        if self.items.contains(where: { row in
                            guard requestedIDSet.contains(row.id), self.itemApplicationIssues[row.id] == nil else { return false }
                            if let fixed = fixedRules?.first(where: { $0.id == row.id }) {
                                return self.actualGroups[row.id] != fixed.visibility
                            }
                            return row.isPending
                        }) {
                            throw MenuBarAccessError.rejected
                        }
                    }
                } catch {
                    let finalFailure = "\(stage)失败：\(error.localizedDescription)"
                    failureMessage = failureMessage.map { "\($0) \(finalFailure)" } ?? finalFailure
                }
            } else if failureMessage == nil {
                failureMessage = MenuBarAccessError.cancelled.localizedDescription
            }

            if self.operationCancellationRequested {
                self.managementError = nil
                self.managementMessage = self.positionRecoveryMessage == nil
                    ? "本次应用已停止。已确认的分类保留，其余选择仍待处理。"
                    : "本次应用已停止。仍有位置需要恢复，请使用上方恢复入口；分类选择已保留。"
            } else if let failureMessage {
                self.managementError = "\(failureMessage) 本次分类尚未全部生效：已确认的项目已保存，其余选择仍待应用。不支持后台调整的图标仍保留为待应用，不会回退到模拟拖动。"
                self.managementMessage = nil
            } else if requestedIDSet.isSubset(of: Set(self.itemApplicationIssues.keys)) {
                self.managementMessage = "本次没有可自动整理的项目，未修改图标位置。选择已保留，可筛选「未自动应用」查看原因。"
            } else {
                // Screenshots are optional presentation data. Successful
                // grouping completes without waiting for another capture pass.
                self.hasCompletedSetup = true
                self.defaults.set(true, forKey: "hasCompletedSetup")
                self.temporarilyRevealingAll = false
                self.beforeTemporaryRevealCollapsed = nil
                self.state.expand()
                let hasUnknownOrder = self.items.contains {
                    $0.isAvailable && $0.canMove && self.rules.rule(for: $0.id) != nil && self.actualGroups[$0.id] == nil
                }
                self.managementMessage = hasUnknownOrder
                    ? "分组移动已确认并保存。系统尚未提供全部项目的可信顺序；隐藏／展开效果仍需实际检查。"
                    : "分组移动已确认并保存。请实际检查普通展开／收起和「始终隐藏」的显示效果。"
                succeeded = true
            }
        }
    }

    /// macOS 27 owns status-item order in a shared preference store. This path
    /// is selected before the unrelated AXPosition/overflow-action preflight.
    /// A written preference is committed only after fresh native order checks.
    private func applyStoredPositionRules(requestedIDs: [String], confirmedRules: [ItemRule]? = nil) async throws -> Bool {
        if usesNativeVisibility {
            return try await applyNativeVisibilityRules(requestedIDs: requestedIDs, confirmedRules: confirmedRules)
        }
        pendingPositionRecoveries = positionStore.pendingTransactions
        if let issue = positionStore.recoveryJournalIssue {
            positionRecoveryMessage = issue
            throw MenuTidyManagementError.positionApplication(issue)
        }
        guard pendingPositionRecoveries.isEmpty else {
            throw MenuTidyManagementError.positionApplication("上次排序的恢复尚未确认，已保留恢复记录，未继续修改位置。")
        }
        if positionLayoutRecoveryNeeded {
            throw MenuTidyManagementError.positionApplication("上次布局恢复尚未确认，请先重试恢复或确认保留当前布局。")
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return false }
        if usesPositionHiding { return try await applyPositionHidingRules(requestedIDs: requestedIDs, confirmedRules: confirmedRules) }
        let initialPositions: [String: Double]
        do { initialPositions = try positionStore.readPositions() }
        catch {
            menuBarPositionAccessAvailable = false
            Self.diagnosticLogger.error("backgroundPositionStore capabilityUnavailable=\(error.localizedDescription, privacy: .public)")
            throw MenuTidyManagementError.positionApplication("无法读取系统排序记录。请先点击「授权排序目录…」完成目录授权，再应用分组。分类选择已保留。")
        }
        menuBarPositionAccessAvailable = true
        try await scanManagementAnchors()
        let anchors = try anchorIDs()
        let own = try await access.prepareBackgroundPositionCandidates(
            ids: [anchors.control, anchors.regular, anchors.always], positions: initialPositions,
            owners: menuBarScanInputs().owners)
        var leases = own
        defer {
            let tokens = leases
            Task { await access.discardBackgroundPositionCandidates(tokens) }
        }
        var prepared: [(row: ManagedItemRow, candidate: MenuBarPositionCandidate)] = []
        var failures: [String] = []
        for id in requestedIDs {
            try checkOperationDeadline()
            guard let row = items.first(where: { $0.id == id && $0.isAvailable && $0.canMove }) else {
                failures.append("有一个待应用图标已退出或身份变化")
                continue
            }
            do {
                let result = try await access.prepareBackgroundPositionCandidates(
                    ids: [id], positions: initialPositions, owners: menuBarScanInputs().owners)
                guard let candidate = result.first else { throw MenuBarAccessError.disappeared }
                let fixedGroup = confirmedRules?.first(where: { $0.id == row.id })?.visibility ?? row.group
                prepared.append((row.replacingGroup(fixedGroup), candidate))
                leases.append(candidate)
            } catch {
                if Task.isCancelled || (error as? MenuBarPositionBindingError)?.reason == .cancelled {
                    throw MenuBarAccessError.cancelled
                }
                failures.append("「\(row.name)」：\(error.localizedDescription)")
            }
        }
        guard !prepared.isEmpty else {
            throw MenuTidyManagementError.positionApplication(failures.joined(separator: "\n"))
        }
        let byID = Dictionary(uniqueKeysWithValues: own.map { ($0.id, $0) })
        guard let control = byID[anchors.control], let regular = byID[anchors.regular],
              let always = byID[anchors.always], statusBar != nil else {
            throw MenuBarAccessError.disappeared
        }
        managementMessage = "正在通过系统排序整理图标，不移动鼠标。"
        applyState() // Shorten only our boundaries while validating real order.
        try await Task.sleep(for: .milliseconds(400))
        try await scanNow()
        // An overflowed item reports a shared placeholder rather than its true
        // position. Ask the native button once and verify its actual state;
        // never infer a successful grouping from the preference readback alone.
        // Moving a target does not require its old position to be visible. The
        // prepared source identity is checked again around the write, and the
        // resulting group still has to pass two real-position observations.
        // Only our reference boundaries need a visible starting layout.
        _ = try await access.revealSystemOverflowForManagement()
        try await scanNow()

        // Existing boundaries normally already have this order. Repair only an
        // inverted owned pair; never renumber unrelated system preference keys.
        for (left, right) in [(regular, control), (always, regular)] {
            let values = try positionStore.readPositions()
            guard let leftValue = values[left.key], let rightValue = values[right.key] else {
                throw MenuBarAccessError.disappeared
            }
            if leftValue <= rightValue {
                try await performStoredPositionMove(left, before: right, validating: own) {
                    try await self.verifyPositionPair(left.id, before: right.id)
                }
            }
        }

        for (index, entry) in prepared.enumerated() {
            try checkOperationDeadline()
            managementMessage = "正在整理 \(index + 1)/\(prepared.count)：\(entry.row.name)。不会接管鼠标。"
            let anchor = entry.row.group == .alwaysHidden ? always :
                (entry.row.group == .collapsible ? regular : control)
            do {
                try await performStoredPositionMove(entry.candidate, before: anchor,
                    validating: own + [entry.candidate]) {
                    try await self.verify(id: entry.row.id, group: entry.row.group, anchors: anchors)
                }
                let rule = ItemRule(id: entry.row.id, name: entry.row.name,
                    bundleIdentifier: entry.row.bundleIdentifier, visibility: entry.row.group)
                rules.set(rule)
                persistRules()
                pendingDrafts.removeVerified(rule, sessionIdentity: draftSessionIdentity(for: entry.row.id))
                persistDrafts()
            } catch {
                failures.append("「\(entry.row.name)」：\(error.localizedDescription)")
                if !pendingPositionRecoveries.isEmpty || positionLayoutRecoveryNeeded || Task.isCancelled { break }
            }
        }
        guard failures.isEmpty else {
            throw MenuTidyManagementError.positionApplication(failures.joined(separator: "\n"))
        }
        return true
    }

    /// The system owns overflow on macOS 27. Exact weights put hidden items
    /// behind our measured boundary; neither a weight nor a spacer by itself
    /// proves concealment. The lifetime ledger preserves every original value.
    private func applyPositionHidingRules(requestedIDs: [String], confirmedRules: [ItemRule]? = nil) async throws -> Bool {
        guard let statusBar else { throw MenuBarAccessError.disappeared }
        let recovery = try positionStore.recoverPendingHiddenWrites()
        guard recovery.isComplete else {
            throw MenuTidyManagementError.positionApplication("上次隐藏操作仍有待恢复记录，请先恢复位置。")
        }
        try checkOperationDeadline()
        try await scanNow()
        let controls = snapshots.filter { $0.ownIdentifier == "menu-tidy-toggle" }
        guard controls.count == 1, let controlID = controls.first?.id else { throw MenuBarAccessError.disappeared }
        let managedKeys = Set(positionStore.managedHiddenEntries.map(\.key))
        let priorTargets = verifiedPositionGroups.compactMap { id, group -> PositionHidingBatchTarget? in
            guard group != .visible, let evidence = verifiedPositionEvidence[id],
                  managedKeys.contains(evidence.key), let rule = rules.rule(for: id),
                  rule.visibility == group else { return nil }
            return PositionHidingBatchTarget(rule: rule, identity: evidence.identity,
                key: evidence.key, hadVerifiedReveal: true)
        }
        let requested = Set(requestedIDs)
        let displayedRules = items.filter { requested.contains($0.id) && $0.isAvailable && $0.canMove }.map { row in
            ItemRule(id: row.id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: row.group)
        }
        guard let requestedRules = ManualArrangementRules.applicationRules(requestedIDs: requestedIDs,
            displayed: displayedRules, confirmed: confirmedRules) else { throw MenuBarAccessError.disappeared }
        let scope = HiddenStagingScope(previouslyManagedKeys: managedKeys, priorTargets: priorTargets,
            requestedRules: requestedRules, bootstrap: statusBar.positionHidingBlockerWidth == nil)
        let outcome: Result<Bool, Error>
        do {
            try await preflightPositionHidingTargets(controlID: controlID, statusBar: statusBar, scope: scope)
            try checkOperationDeadline()
            if scope.requestedRules.isEmpty {
                outcome = .success(true)
            } else {
                scope.didBeginApplication = true
                outcome = .success(try await applyStagedPositionHidingRules(requestedIDs: scope.requestedRules.map(\.id),
                    controlID: controlID, statusBar: statusBar, scope: scope))
            }
        } catch {
            if scope.didBeginApplication {
                invalidateHiddenPositionEvidence()
                for id in requestedIDs {
                    verifiedPositionGroups.removeValue(forKey: id)
                    verifiedPositionEvidence.removeValue(forKey: id)
                    actualGroups.removeValue(forKey: id)
                }
            } else {
                // A rejected read-only preflight does not invalidate unrelated
                // accepted groups. Still revoke proof changed by another app.
                await reconcileVerifiedPositionEvidence()
                actualGroups = verifiedPositionGroups
            }
            rebuildRows()
            outcome = .failure(error)
        }
        let layoutChanged = await restoreUnverifiedStagedHiddenPositions(scope)
        await access.discardBackgroundPositionCandidates(scope.preparedCandidates)
        switch outcome {
        case .success(let result):
            guard !layoutChanged else {
                throw MenuTidyManagementError.positionApplication("恢复未确认项目后菜单栏布局已改变，隐藏选择已保留为待应用，请重新应用。")
            }
            return result
        case .failure(let error): throw error
        }
    }

    @MainActor
    private final class HiddenStagingScope {
        let previouslyManagedKeys: Set<String>
        let priorTargets: [PositionHidingBatchTarget]
        var requestedRules: [ItemRule]
        let bootstrap: Bool
        var didBeginApplication = false
        var preparedCandidates: [MenuBarPositionCandidate] = []
        var newlyStagedKeysByID: [String: String] = [:]
        var stagedTargets: [String: PositionHidingBatchTarget] = [:]
        var confirmedIDs: Set<String> = []

        init(previouslyManagedKeys: Set<String>, priorTargets: [PositionHidingBatchTarget],
            requestedRules: [ItemRule], bootstrap: Bool) {
            self.previouslyManagedKeys = previouslyManagedKeys
            self.priorTargets = priorTargets
            self.requestedRules = requestedRules
            self.bootstrap = bootstrap
        }
    }

    private struct PositionHidingBatchTarget {
        let rule: ItemRule
        let identity: ObservedItemGroupHistory.Identity
        let key: String
        var hadVerifiedReveal: Bool

        func matches(_ candidate: MenuBarPositionCandidate) -> Bool {
            candidate.id == rule.id && candidate.key == key && candidate.processIdentifier == identity.pid &&
                candidate.launchTime == identity.launchTime && candidate.bundleIdentifier == identity.bundleIdentifier
        }
    }

    /// A menu host can rebuild its child list during a layout change. Retry
    /// only an incomplete read, before any mutation or candidate is returned.
    /// Ambiguous keys, replaced objects and changed owners remain failures.
    private func prepareStablePositionCandidates(ids: [String]) async throws -> [MenuBarPositionCandidate] {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await access.prepareBackgroundPositionCandidates(ids: ids,
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
            } catch let error as MenuBarPositionBindingError where error.reason == .incompleteSource && attempt < 2 {
                Self.diagnosticLogger.notice("backgroundPositionBinding incompleteReadRetry=\(attempt + 1)")
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw MenuBarAccessError.rejected
    }

    /// Fail before the first target write when the boundary host, a source, or
    /// an exact preference key is unavailable. Ordinary Apply never probes unknown
    /// keys by repeatedly moving an application to discover its identity.
    private func preflightPositionHidingTargets(controlID: String, statusBar: StatusBarController,
        scope: HiddenStagingScope) async throws {
        let deadline = min(operationDeadline ?? .infinity, ProcessInfo.processInfo.systemUptime + 4)
        func checkPreflight() throws {
            try checkOperationDeadline()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MenuTidyManagementError.positionApplication("系统未能及时完成检查，尚未修改本次图标位置。请稍后刷新列表。")
            }
        }
        try checkPreflight()
        scope.preparedCandidates = try await prepareStablePositionCandidates(ids: [controlID])
        let requestedRules = scope.requestedRules
        var supportedIDs: Set<String> = []
        var issues: [String: String] = [:]
        for (index, rule) in requestedRules.enumerated() {
            try checkPreflight()
            managementMessage = "正在检查 \(index + 1)/\(requestedRules.count)：\(rule.name)"
            do {
                let candidate = try await prepareStablePositionCandidates(ids: [rule.id])
                scope.preparedCandidates += candidate
                if rule.visibility != .visible { try await access.validateItemActionSupport(id: rule.id) }
                try checkPreflight()
                supportedIDs.insert(rule.id)
                itemsNeedingPositionKeyResolution.remove(rule.id)
            } catch let error as MenuBarPositionBindingError {
                // Cancellation and exhausted time are operation outcomes, not
                // evidence that an application is unsupported.
                try checkPreflight()
                if error.reason == .cancelled { throw MenuBarAccessError.cancelled }
                if error.reason == .ambiguousKey { itemsNeedingPositionKeyResolution.insert(rule.id) }
                issues[rule.id] = error.reason == .ambiguousKey
                    ? "此应用有多个位置记录。点击“识别并连接”可确认当前图标对应的记录，再完成设置。"
                    : error.localizedDescription
            } catch let error as MenuBarAccessError {
                try checkPreflight()
                switch error {
                case .actionUnavailable, .actionRejected:
                    issues[rule.id] = "此图标暂未提供可用的托盘打开接口，未将它隐藏。可保留常驻菜单栏后直接使用。"
                default: throw error
                }
            }
        }
        guard let plan = BatchApplicationPlan(requestedIDs: requestedRules.map(\.id),
            supportedIDs: supportedIDs, issues: issues), plan.uninspectedIDs.isEmpty else {
            throw MenuBarAccessError.disappeared
        }
        // A one-item placement must not erase another source's diagnosis.
        for rule in requestedRules { itemApplicationIssues.removeValue(forKey: rule.id) }
        itemApplicationIssues.merge(issues) { _, current in current }
        let actionable = Set(plan.actionableIDs)
        scope.requestedRules = requestedRules.filter { actionable.contains($0.id) }
        // A skipped existing hidden item still needs final proof. Never drop
        // its recovery record merely to allow the rest of the batch through.
        let accountableKeys = Set(scope.priorTargets.map(\.key))
            .union(scope.preparedCandidates.filter { actionable.contains($0.id) }.map(\.key))
        guard scope.previouslyManagedKeys.isSubset(of: accountableKeys) else {
            let message = "现有隐藏项中仍有无法确认身份的项目，请先恢复原排序，再应用支持的分类。选择已保留。"
            positionLayoutRecoveryNeeded = true
            positionRecoveryMessage = message
            throw MenuTidyManagementError.positionApplication(message)
        }
        guard !scope.requestedRules.isEmpty else { return }
        for prior in scope.priorTargets where !actionable.contains(prior.rule.id) {
            try checkPreflight()
            do {
                let candidates = try await prepareStablePositionCandidates(ids: [prior.rule.id])
                scope.preparedCandidates += candidates
                guard candidates.count == 1, let candidate = candidates.first,
                      prior.matches(candidate) else { throw MenuBarAccessError.disappeared }
            } catch {
                try checkPreflight()
                throw MenuTidyManagementError.positionApplication("现有隐藏项「\(prior.rule.name)」的身份无法重新确认，尚未修改本次图标。请先恢复原排序，再重新应用。")
            }
        }
        let visibleIDs = Set(scope.requestedRules.filter { $0.visibility == .visible }.map(\.id))
        let restoringKeys = Set(scope.preparedCandidates.filter { visibleIDs.contains($0.id) }.map(\.key))
        let needsBoundary = !scope.previouslyManagedKeys.subtracting(restoringKeys).isEmpty ||
            scope.requestedRules.contains { $0.visibility != .visible }
        // Restoring the last hidden item removes the blocker. A broken current
        // hiding boundary must not prevent that request from making it visible.
        if needsBoundary {
            try checkPreflight()
            guard let dividerID = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-divider" })?.id else {
                throw MenuBarAccessError.disappeared
            }
            scope.preparedCandidates += try await prepareStablePositionCandidates(ids: [dividerID])
            let requested = statusBar.positionHidingBlockerRequestedWidth
            guard let frame = await access.currentOwnDividerHostFrame(),
                  statusBar.canPreparePositionHidingBlocker(verifiedFrame: frame, expectedRequestedWidth: requested) else {
                throw MenuTidyManagementError.positionApplication("当前菜单栏的隐藏边界尚不可用，尚未修改图标位置。请先关闭菜单弹窗，再刷新列表。")
            }
        }
        var keys: Set<String> = []
        for rule in scope.requestedRules {
            try checkPreflight()
            guard let target = scope.preparedCandidates.first(where: { $0.id == rule.id }),
                  let identity = draftSessionIdentity(for: rule.id), keys.insert(target.key).inserted else {
                throw MenuBarAccessError.disappeared
            }
            var expected = PositionHidingBatchTarget(rule: rule, identity: identity,
                key: target.key, hadVerifiedReveal: scope.priorTargets.contains { $0.matches(target) && $0.hadVerifiedReveal })
            guard expected.matches(target) else { throw MenuBarAccessError.disappeared }
            if rule.visibility != .visible {
                // A currently visible source already supplies the transition
                // seed and footprint. Do not hide/reveal/hide it just to take a
                // screenshot before finally applying its requested group.
                let inspection = await access.inspectVisibility(id: rule.id)
                if inspection.centerHit, let frame = await access.verifiedVisibleHostFrame(id: rule.id) {
                    expected.hadVerifiedReveal = true
                    verifiedHostedFootprints[rule.id] = VerifiedHostedFootprint(identity: identity, width: frame.width)
                }
                if expected.hadVerifiedReveal || !scope.bootstrap {
                    try await access.ensureSystemModuleContinuityBeforeHiding(id: rule.id)
                }
            }
            scope.stagedTargets[rule.id] = expected
        }
        try checkPreflight()
        try await access.validateBackgroundPositionCandidates(scope.preparedCandidates,
            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
        try checkPreflight()
    }

    private func stageRequestedHiddenPositions(requestedIDs: [String], controlID: String,
        scope: HiddenStagingScope, failures: inout [String]) async throws -> [String: String] {
        var stagedKeys: [String: String] = [:]
        for id in requestedIDs {
            try checkOperationDeadline()
            guard let expected = scope.stagedTargets[id], expected.rule.visibility != .visible else { continue }
            let candidates = scope.preparedCandidates.filter { $0.id == id || $0.id == controlID }
            do {
                guard let target = candidates.first(where: { $0.id == id }), expected.matches(target),
                      draftSessionIdentity(for: id) == expected.identity else { throw MenuBarAccessError.disappeared }
                try await access.validateBackgroundPositionCandidates(candidates,
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                try checkOperationDeadline()
                stagedKeys[id] = target.key
                if !scope.previouslyManagedKeys.contains(target.key) {
                    scope.newlyStagedKeysByID[id] = target.key
                }
                let result = try positionStore.hide(key: target.key)
                guard result.isComplete else { throw MenuBarAccessError.rejected }
            } catch {
                await refreshAfterHiddenFailure(error)
                failures.append("「\(expected.rule.name)」暂未准备好隐藏：\(error.localizedDescription)")
                // An unexpected runtime change stops this batch immediately.
                // The enclosing scope restores every unaccepted new write.
                break
            }
        }
        return stagedKeys
    }

    private func applyStagedPositionHidingRules(requestedIDs: [String], controlID: String,
        statusBar: StatusBarController, scope: HiddenStagingScope) async throws -> Bool {
        var failures: [String] = []
        let stagedKeys = try await stageRequestedHiddenPositions(requestedIDs: requestedIDs,
            controlID: controlID, scope: scope, failures: &failures)
        guard failures.isEmpty else {
            throw MenuTidyManagementError.positionApplication(failures.joined(separator: "\n"))
        }
        if !stagedKeys.isEmpty {
            try await completeHiddenLayoutRefresh(true)
            // A bootstrap source without a measured footprint still needs a
            // narrow divider for its first reveal. Otherwise fit immediately
            // against the real staged layout, before per-item processing.
            if !scope.bootstrap || scope.stagedTargets.values.allSatisfy({
                $0.rule.visibility == .visible || $0.hadVerifiedReveal
            }) {
                try await fitPositionHidingBlocker()
            }
        }
        var completedTargets: [String: PositionHidingBatchTarget] = [:]
        for (index, rule) in scope.requestedRules.enumerated() {
            let id = rule.id
            try checkOperationDeadline()
            managementMessage = "正在应用 \(index + 1)/\(scope.requestedRules.count)：\(rule.name)"
            if rule.visibility != .visible, let expected = scope.stagedTargets[id], expected.hadVerifiedReveal {
                // The exact source was seen before staging. The final batch
                // proves its disappearance; an extra reveal and capture adds
                // no grouping evidence and needlessly disturbs native layout.
                completedTargets[id] = expected
                continue
            }
            var candidates: [MenuBarPositionCandidate] = []
            var managedKey: String? = stagedKeys[id]
            do {
                candidates = try await prepareStablePositionCandidates(ids: [id, controlID])
                guard let target = candidates.first(where: { $0.id == id }),
                      let control = candidates.first(where: { $0.id == controlID }),
                      let identity = draftSessionIdentity(for: id) else { throw MenuBarAccessError.disappeared }
                var expected = scope.stagedTargets[id] ?? PositionHidingBatchTarget(rule: rule,
                    identity: identity, key: target.key, hadVerifiedReveal: false)
                guard expected.identity == identity, expected.matches(target) else { throw MenuBarAccessError.disappeared }
                managedKey = target.key
                managementMessage = "正在整理「\(rule.name)」，不会移动鼠标。"
                if rule.visibility == .visible {
                    if positionStore.managedHiddenEntries.contains(where: { $0.key == target.key }) {
                        let result = try positionStore.restoreHidden(key: target.key)
                        guard result.isComplete else { throw MenuBarAccessError.rejected }
                        try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                    }
                    // A restored native position may still be in system overflow.
                    // Explicitly place a requested visible item beside our control.
                    let visible = await access.inspectVisibility(id: id)
                    if !visible.centerHit {
                        try await performStoredPositionMove(target, before: control, validating: candidates) {
                            _ = try await self.waitForPositionVisibility(id: id, visible: true, candidates: candidates)
                        }
                    }
                    // With no new move, the final two full-batch observations
                    // provide the fresh proof. Do not rescan the entire menu
                    // bar for every already-visible item here.
                } else {
                    guard scope.bootstrap || statusBar.positionHidingBlockerWidth != nil else {
                        throw MenuTidyManagementError.positionApplication("原有隐藏边界已失效，本次操作已停止，请重新应用分组。")
                    }
                    try await access.validateBackgroundPositionCandidates(candidates,
                        positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                    let hidden = try positionStore.hide(key: target.key)
                    try await completeHiddenLayoutRefresh(hidden.requiresLayoutRefresh)
                    guard hidden.isComplete else { throw MenuBarAccessError.rejected }
                    // Bootstrap captures while the divider is still narrow.
                    // With an existing blocker, the helper reserves this exact
                    // item's measured footprint without clearing that blocker.
                    let revealed = try await temporarilyRevealManagedItem(id: id, key: target.key, before: control.key)
                    guard revealed.isComplete else { throw MenuBarAccessError.rejected }
                    try await completeHiddenLayoutRefresh(revealed.requiresLayoutRefresh)
                    let visibleFrame = try await waitForPositionVisibility(id: id, visible: true, candidates: candidates)
                    guard draftSessionIdentity(for: id) == expected.identity else { throw MenuBarAccessError.disappeared }
                    expected.hadVerifiedReveal = true
                    _ = visibleFrame // Actual visibility is required; screenshot availability is independent.
                    let concealed = try restoreTemporaryManagedItem(key: target.key)
                    guard concealed.isComplete else { throw MenuBarAccessError.rejected }
                    try await statusBar.refreshPreferredPositions()
                    if !scope.bootstrap {
                        _ = try await waitForPositionVisibility(id: id, visible: false, candidates: candidates,
                            hadVerifiedReveal: expected.hadVerifiedReveal)
                    }
                }
                guard draftSessionIdentity(for: id) == expected.identity else { throw MenuBarAccessError.disappeared }
                completedTargets[id] = expected
                Self.diagnosticLogger.notice("positionHiding capturePrepared=true hidden=\(rule.visibility != .visible) bootstrap=\(scope.bootstrap)")
            } catch {
                let originalError = error
                await refreshAfterHiddenFailure(error)
                // End an outstanding single-item presentation before the
                // wrapper restores every newly staged item in this batch.
                if let key = managedKey {
                    do {
                        let cleanup = Task { @MainActor in
                            guard self.positionStore.managedHiddenEntries.contains(where: { $0.key == key }) else { return }
                            let recovery = try self.restoreTemporaryManagedItem(key: key)
                            try await self.completeHiddenLayoutRefresh(recovery.requiresLayoutRefresh)
                            guard recovery.isComplete else { throw MenuBarAccessError.rejected }
                        }
                        try await cleanup.value
                    } catch {
                        await refreshAfterHiddenFailure(error)
                        positionLayoutRecoveryNeeded = true
                        positionRecoveryMessage = "位置恢复尚未完成：\(error.localizedDescription)"
                    }
                }
                await access.discardBackgroundPositionCandidates(candidates)
                throw MenuTidyManagementError.positionApplication("「\(rule.name)」：\(originalError.localizedDescription)")
            }
            await access.discardBackgroundPositionCandidates(candidates)
            try checkOperationDeadline()
            guard !positionLayoutRecoveryNeeded else { throw MenuBarAccessError.rejected }
        }
        guard Set(completedTargets.keys) == Set(requestedIDs) else { throw MenuBarAccessError.disappeared }
        // No temporary preference writes follow this final fit. Earlier
        // successful captures did not commit a rule or remove a user draft.
        managementMessage = "正在确认全部图标的最终显示结果…"
        if !positionStore.managedHiddenEntries.isEmpty { try await fitPositionHidingBlocker() }
        var expected = Dictionary(uniqueKeysWithValues: scope.priorTargets.map { ($0.rule.id, $0) })
        expected.merge(completedTargets) { _, requested in requested }
        let evidence = try await verifyFinalHiddenPositions(expected: expected)
        try Task.checkCancellation()
        try commitPositionHidingBatch(expected: expected, evidence: evidence, scope: scope)
        return true
    }

    /// Main-actor synchronous acceptance: all identities and values must still
    /// match final proof before any rule or draft is changed.
    private func commitPositionHidingBatch(expected: [String: PositionHidingBatchTarget],
        evidence: [String: VerifiedPositionEvidence], scope: HiddenStagingScope) throws {
        let positions = try positionStore.readPositions()
        guard Set(evidence.keys) == Set(expected.keys), expected.allSatisfy({ id, target in
            guard let proof = evidence[id] else { return false }
            return proof.identity == target.identity && proof.key == target.key &&
                positions[target.key] == proof.value && draftSessionIdentity(for: id) == target.identity
        }) else { throw MenuBarAccessError.disappeared }
        for (id, target) in expected {
            verifiedPositionGroups[id] = target.rule.visibility
            verifiedPositionEvidence[id] = evidence[id]
            actualGroups[id] = target.rule.visibility
        }
        for rule in scope.requestedRules {
            rules.set(rule)
            itemApplicationIssues.removeValue(forKey: rule.id)
            pendingDrafts.removeVerified(rule, sessionIdentity: expected[rule.id]?.identity)
        }
        persistRules()
        persistDrafts()
        scope.confirmedIDs = Set(scope.requestedRules.map(\.id))
        rebuildRows()
        recomputeIconImageWarning()
        Self.diagnosticLogger.notice("positionHiding applicationVerified=true committed=\(scope.confirmedIDs.count) bootstrap=\(scope.bootstrap)")
    }

    /// A batch can stop before reaching newly staged items, or a final check
    /// can invalidate an earlier success. Restore only this batch's unaccepted
    /// additions; an existing managed item never becomes owned by this cleanup.
    /// Run independently of cancellation so a stopped apply still restores its
    /// durable intent, and retain unresolved records instead of deleting them.
    private func restoreUnverifiedStagedHiddenPositions(_ scope: HiddenStagingScope) async -> Bool {
        let retainedKeys = Set(scope.newlyStagedKeysByID.compactMap { id, key -> String? in
            guard scope.confirmedIDs.contains(id),
                  let group = verifiedPositionGroups[id], group != .visible,
                  verifiedPositionEvidence[id]?.key == key else { return nil }
            return key
        })
        let restoring = scope.newlyStagedKeysByID.filter {
            !scope.previouslyManagedKeys.contains($0.value) && !retainedKeys.contains($0.value)
        }
        guard !restoring.isEmpty else { return false }
        let cleanup = Task { @MainActor in
            var failed = 0
            var layoutChanged = false
            for key in Set(restoring.values).sorted() {
                guard self.positionStore.managedHiddenEntries.contains(where: { $0.key == key }) else { continue }
                do {
                    let result = try self.positionStore.restoreHidden(key: key)
                    if result.requiresLayoutRefresh {
                        layoutChanged = true
                        self.invalidateHiddenPositionEvidence()
                    }
                    try await self.completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                    guard result.isComplete else { throw MenuBarAccessError.rejected }
                } catch {
                    if (error as? MenuBarPositionStore.StoreFailure)?.requiresLayoutRefresh == true {
                        layoutChanged = true
                        self.invalidateHiddenPositionEvidence()
                    }
                    await self.refreshAfterHiddenFailure(error)
                    failed += 1
                }
            }
            for id in restoring.keys {
                self.verifiedPositionGroups.removeValue(forKey: id)
                self.verifiedPositionEvidence.removeValue(forKey: id)
                self.actualGroups.removeValue(forKey: id)
            }
            if failed > 0 {
                self.positionLayoutRecoveryNeeded = true
                self.positionRecoveryMessage = "本次预隐藏中有 \(failed) 项尚未恢复，已保留位置记录；请重试恢复。"
            }
            self.rebuildRows()
            Self.diagnosticLogger.notice("positionHiding stagedCleanup attempted=\(Set(restoring.values).count) unresolved=\(failed) layoutChanged=\(layoutChanged) previouslyManagedPreserved=true")
            return layoutChanged
        }
        return await cleanup.value
    }

    /// Hidden observations belong to the layout in which they were obtained.
    /// Restoring another item or clearing the boundary invalidates that layout,
    /// while saved choices and lifetime recovery records must remain intact.
    private func invalidateHiddenPositionEvidence() {
        let hiddenIDs = Set(verifiedPositionGroups.filter { $0.value != .visible }.keys)
            .union(actualGroups.filter { $0.value != .visible }.keys)
        for id in hiddenIDs {
            verifiedPositionGroups.removeValue(forKey: id)
            verifiedPositionEvidence.removeValue(forKey: id)
            actualGroups.removeValue(forKey: id)
        }
        rebuildRows()
    }

    /// A successful per-item operation can be invalidated by a later layout.
    /// Check the entire managed set again at the final layout before accepting
    /// the batch. Stored weights and earlier observations are not visibility.
    private func verifyFinalHiddenPositions(expected: [String: PositionHidingBatchTarget]) async throws
        -> [String: VerifiedPositionEvidence] {
        guard let controlID = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-toggle" })?.id else {
            throw MenuBarAccessError.disappeared
        }
        var passed = false
        defer {
            Self.diagnosticLogger.notice("positionHiding finalBatchVerified=\(passed) checked=\(expected.count)")
        }
        let hiddenKeys = Set(expected.values.filter { $0.rule.visibility != .visible }.map(\.key))
        guard !expected.isEmpty, Set(expected.values.map(\.key)).count == expected.count,
              Set(positionStore.managedHiddenEntries.map(\.key)) == hiddenKeys else {
            throw MenuTidyManagementError.positionApplication("受管理隐藏项尚未全部取得明确的验证目标，不能确认整批已生效。")
        }
        // Two complete rounds share two scans. The previous implementation
        // performed a separate five-second polling loop (and boundary fit) for
        // every item before starting a final pass, multiplying batch latency.
        var evidence: [String: VerifiedPositionEvidence] = [:]
        for round in 0..<2 {
            try checkOperationDeadline()
            if round > 0 { try await Task.sleep(for: .milliseconds(120)) }
            try await scanNow()
            var currentRound: [String: VerifiedPositionEvidence] = [:]
            for id in expected.keys.sorted() {
                try checkOperationDeadline()
                guard let target = expected[id] else { throw MenuBarAccessError.disappeared }
                let current = try await verifyPositionHidingBatchTarget(target, controlID: controlID, waitForStable: false)
                if round > 0 {
                    guard let previous = evidence[id], current.identity == previous.identity,
                          current.key == previous.key, current.value == previous.value else {
                        throw MenuBarAccessError.rejected
                    }
                }
                currentRound[id] = current
            }
            evidence = currentRound
        }
        passed = true
        return evidence
    }

    private func verifyPositionHidingBatchTarget(_ expected: PositionHidingBatchTarget, controlID: String,
        waitForStable: Bool) async throws -> VerifiedPositionEvidence {
        let id = expected.rule.id
        var candidates: [MenuBarPositionCandidate] = []
        do {
            candidates = try await access.prepareBackgroundPositionCandidates(ids: [id, controlID],
                positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
            guard let target = candidates.first(where: { $0.id == id }), expected.matches(target),
                  draftSessionIdentity(for: id) == expected.identity else { throw MenuBarAccessError.disappeared }
            let visible = expected.rule.visibility == .visible
            if waitForStable {
                _ = try await waitForPositionVisibility(id: id, visible: visible, candidates: candidates,
                    hadVerifiedReveal: expected.hadVerifiedReveal)
            }
            let positions = try positionStore.readPositions()
            try await access.validateBackgroundPositionCandidates(candidates,
                positions: positions, owners: menuBarScanInputs().owners)
            guard draftSessionIdentity(for: id) == expected.identity,
                  let value = positions[target.key] else { throw MenuBarAccessError.disappeared }
            let inspection = await access.inspectVisibility(id: id)
            let reference = await access.inspectVisibility(id: controlID)
            guard reference.centerHit else { throw MenuBarAccessError.invalidGeometry }
            if visible {
                guard inspection.centerHit, let frame = inspection.frame, let controlFrame = reference.frame,
                      frame.width > 0, frame.width <= 120, sameDisplay(frame, controlFrame),
                      abs(frame.midY - controlFrame.midY) < 8 else { throw MenuBarAccessError.invalidGeometry }
            } else {
                guard let held = positionStore.managedHiddenEntries.first(where: { $0.key == target.key }),
                      held.mode == .hidden, !held.recoveryPending, value == held.hiddenValue,
                      held.lastAppWrite == held.hiddenValue, !inspection.centerHit,
                      await access.inspectPositionHidden(candidate: target,
                        allowVerifiedHostWindow: expected.hadVerifiedReveal) == true else {
                    throw MenuBarAccessError.invalidGeometry
                }
            }
            await access.discardBackgroundPositionCandidates(candidates)
            return VerifiedPositionEvidence(identity: expected.identity, key: target.key, value: value)
        } catch {
            await access.discardBackgroundPositionCandidates(candidates)
            throw MenuTidyManagementError.positionApplication("「\(expected.rule.name)」未通过整批最终验证：\(error.localizedDescription)")
        }
    }

    /// A failed store operation may still have changed (or restored) a value.
    /// Refresh our own item even when the calling task was cancelled so the
    /// native host does not keep displaying a stale intermediate layout.
    private func refreshAfterHiddenFailure(_ error: Error) async {
        guard (error as? MenuBarPositionStore.StoreFailure)?.requiresLayoutRefresh == true else { return }
        do { try await completeHiddenLayoutRefresh(true) }
        catch {
            positionLayoutRecoveryNeeded = true
            positionRecoveryMessage = "系统排序已写入恢复记录，但菜单栏刷新未完成：\(error.localizedDescription)"
        }
    }

    private func completeHiddenLayoutRefresh(_ required: Bool) async throws {
        // The preference may already equal its original value (for example,
        // after an external restore), so removing the final ledger entry can
        // require no write while our now-unneeded native blocker still exists.
        let removesBlocker = positionStore.managedHiddenEntries.isEmpty &&
            (statusBar?.positionHidingBlockerWidth != nil || activeBlockerReservation != nil)
        guard required || removesBlocker else { return }
        if positionStore.managedHiddenEntries.isEmpty {
            statusBar?.clearPositionHidingBlocker()
            activeBlockerReservation = nil
        }
        let previouslyNeeded = positionLayoutRecoveryNeeded
        positionLayoutRecoveryNeeded = true
        let cleanup = Task { @MainActor in
            guard let statusBar = self.statusBar else { throw MenuBarAccessError.disappeared }
            try await statusBar.refreshPreferredPositions()
        }
        try await cleanup.value
        positionLayoutRecoveryNeeded = previouslyNeeded
    }

    /// Only our own divider changes size. Position preferences stay journaled;
    /// host geometry is re-read after every asynchronous layout refresh.
    private func fitPositionHidingBlocker(reposition: Bool = true,
                                          budget: ManagementOperationBudget = .foreground) async throws {
        guard let statusBar, usesPositionHiding, !positionStore.managedHiddenEntries.isEmpty else { return }
        var transaction: MenuBarPositionStore.Transaction?
        var candidates: [MenuBarPositionCandidate] = []
        do {
            try checkOperationDeadline(budget: budget)
            if reposition {
                guard let dividerID = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-divider" })?.id,
                      let controlID = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-toggle" })?.id else {
                    throw MenuBarAccessError.disappeared
                }
                candidates = try await access.prepareBackgroundPositionCandidates(ids: [dividerID, controlID],
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                transaction = try positionStore.positionOwnDividerAtHiddenBoundary()
                if transaction != nil { try await statusBar.refreshPreferredPositions() }
            }
            var fitted = false
            for _ in 0..<3 {
                try checkOperationDeadline(budget: budget)
                let requested = statusBar.positionHidingBlockerRequestedWidth
                if let frame = await access.currentOwnDividerHostFrame(),
                   let plan = statusBar.positionHidingBlockerPlan(verifiedFrame: frame,
                       expectedRequestedWidth: requested) {
                    guard statusBar.setPositionHidingBlocker(verifiedFrame: frame,
                        expectedRequestedWidth: requested) else { throw MenuBarAccessError.invalidGeometry }
                    if plan == requested {
                        // No length changed. The strict host query already
                        // re-read this exact source and physical frame twice.
                        fitted = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(120))
                    if let actual = await access.currentOwnDividerHostFrame(),
                       actual.width >= statusBar.positionHidingBlockerRequestedWidth,
                       abs(actual.maxX - frame.maxX) <= 1 {
                        fitted = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(80))
            }
            guard fitted else {
                throw MenuTidyManagementError.positionApplication("菜单栏布局尚未确认稳定，未能建立可靠的隐藏边界。本次选择已保留，可重新应用。")
            }
            if let transaction { try positionStore.commit(transaction) }
            await access.discardBackgroundPositionCandidates(candidates)
        } catch {
            let originalError = error
            // A previous width cannot be reused after staging changed the set.
            // Clear it even when the divider weight already needed no write.
            statusBar.clearPositionHidingBlocker()
            invalidateHiddenPositionEvidence()
            let token = transaction ?? (error as? MenuBarPositionStore.StoreFailure)?.recoveryTransaction
            let cleanup = Task { @MainActor in
                var recoveryError: Error?
                if let token {
                    do {
                        let result = try self.positionStore.rollback(token)
                        guard result.isComplete else { throw MenuBarAccessError.rejected }
                    } catch { recoveryError = error }
                }
                do { try await statusBar.refreshPreferredPositions() }
                catch {
                    if recoveryError == nil { recoveryError = error }
                }
                if let recoveryError { throw recoveryError }
            }
            do { try await cleanup.value }
            catch {
                positionLayoutRecoveryNeeded = true
                positionRecoveryMessage = "隐藏边界恢复未完成：\(error.localizedDescription)"
            }
            await access.discardBackgroundPositionCandidates(candidates)
            throw originalError
        }
    }

    /// Keep the enclosing boundary in place while making room for one item.
    /// The cached footprint is a previously measured width, not new proof of
    /// visibility; callers must still verify the final native layout.
    private func temporarilyRevealManagedItem(id: String, key: String, before controlKey: String) async throws
        -> MenuBarPositionStore.HiddenMutationResult {
        guard let statusBar, statusBar.positionHidingBlockerWidth != nil else {
            return try positionStore.temporarilyReveal(key: key, before: controlKey)
        }
        guard activeBlockerReservation == nil,
              let footprint = verifiedHostedFootprints[id],
              footprint.identity == draftSessionIdentity(for: id),
              Self.observedOwnerIsCurrent(footprint.identity) else {
            throw MenuTidyManagementError.positionApplication("尚未取得此图标的实际占用宽度，暂不能单独显示。请先完成图标分组和采集。")
        }
        try await fitPositionHidingBlocker(reposition: false)
        let requested = statusBar.positionHidingBlockerRequestedWidth
        guard let dividerFrame = await access.currentOwnDividerHostFrame(),
              let token = statusBar.beginPositionHidingBlockerReservation(targetHostWidth: footprint.width,
                  verifiedDividerFrame: dividerFrame, expectedRequestedWidth: requested) else {
            throw MenuTidyManagementError.positionApplication("当前菜单栏没有足够空间临时显示此图标，保留其他项目隐藏。")
        }
        // No await between reserving space and the exact preference write.
        // Retain the token on a failed write until conditional cleanup succeeds.
        activeBlockerReservation = (key, token)
        return try positionStore.temporarilyReveal(key: key, before: controlKey)
    }

    private func restoreTemporaryManagedItem(key: String) throws -> MenuBarPositionStore.HiddenMutationResult {
        let result = try positionStore.restoreTemporaryReveal(key: key)
        if result.isComplete, let reservation = activeBlockerReservation, reservation.key == key {
            _ = statusBar?.endPositionHidingBlockerReservation(reservation.token)
            activeBlockerReservation = nil
        }
        return result
    }

    /// Only an explicit single-item retry may enter the bounded identification
    /// path. Ordinary placement, discovery and batch work remain read-only here.
    private func resolveAmbiguousPositionKeyIfNeeded(id: String) async throws {
        try checkOperationDeadline()
        try await scanNow()
        do {
            let candidates = try await prepareStablePositionCandidates(ids: [id])
            await access.discardBackgroundPositionCandidates(candidates)
            itemsNeedingPositionKeyResolution.remove(id)
            return
        } catch let error as MenuBarPositionBindingError where error.reason == .ambiguousKey {
            itemsNeedingPositionKeyResolution.insert(id)
        }
        let controls = snapshots.filter { $0.ownIdentifier == "menu-tidy-toggle" }
        guard controls.count == 1, let controlID = controls.first?.id else { throw MenuBarAccessError.disappeared }
        try await resolvePositionKey(id: id, controlID: controlID)
        itemsNeedingPositionKeyResolution.remove(id)
    }

    /// Some applications leave multiple autosave keys behind. A candidate is
    /// accepted only when the same original AX item visibly follows it to both
    /// sides of our control, and its exact original preference is restored.
    private func resolvePositionKey(id: String, controlID: String) async throws {
        guard let statusBar else { throw MenuBarAccessError.disappeared }
        let handle = try await access.prepareBackgroundPositionKeyChallenge(id: id, controlID: controlID,
            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
        var transaction: MenuBarPositionStore.Transaction?
        do {
            for key in handle.candidateKeys {
                try checkOperationDeadline()
                guard !preparingToTerminate, !stopping,
                      !positionStore.managedHiddenEntries.contains(where: { $0.key == key }) else {
                    throw MenuBarAccessError.cancelled
                }
                var plan = try await access.beginBackgroundPositionKeyChallenge(handle, key: key,
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                var phase = MenuBarPositionKeyResolution.Phase.left
                while phase == .left || phase == .right {
                    let observingPhase = phase
                    positionLayoutRecoveryNeeded = true
                    transaction = try plan.placement == .before
                        ? positionStore.move(key: key, before: handle.controlKey)
                        : positionStore.move(key: key, after: handle.controlKey)
                    guard transaction?.writtenValues == plan.writtenValues else { throw MenuBarAccessError.rejected }
                    try await statusBar.refreshPreferredPositions()
                    let started = ProcessInfo.processInfo.systemUptime
                    let deadline = min(handle.deadline - 0.7, started + 3)
                    var retriedLayout = false
                    while phase == observingPhase && ProcessInfo.processInfo.systemUptime < deadline {
                        try checkOperationDeadline()
                        try await scanNow()
                        phase = try await access.observeBackgroundPositionKeyChallenge(handle,
                            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                        if phase == observingPhase {
                            if !retriedLayout && ProcessInfo.processInfo.systemUptime - started > 1 {
                                retriedLayout = true
                                try await statusBar.refreshPreferredPositions()
                            }
                            try await Task.sleep(for: .milliseconds(120))
                        }
                    }
                    // Each side uses a separate journal beginning at the exact
                    // original value, so a crash never preserves a probe slot.
                    guard let active = transaction else { throw MenuBarAccessError.rejected }
                    let restored = try positionStore.rollback(active)
                    try await statusBar.refreshPreferredPositions()
                    guard restored.isComplete else { throw MenuBarAccessError.rejected }
                    transaction = nil
                    positionLayoutRecoveryNeeded = false
                    if phase == observingPhase {
                        try await access.finishBackgroundPositionKeyChallengeAttempt(handle)
                        phase = .restoring
                    } else if phase == .right {
                        plan = try await access.backgroundPositionKeyChallengePlan(handle,
                            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                    }
                }
                if try await access.confirmBackgroundPositionKeyChallengeRestoration(handle,
                    originalValueRestored: true, layoutRefreshed: true,
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners) != nil {
                    await access.discardBackgroundPositionKeyChallenge(handle)
                    return
                }
            }
            throw MenuBarPositionBindingError(id: id, reason: .ambiguousKey)
        } catch {
            let originalError = error
            let recovery = transaction ?? (error as? MenuBarPositionStore.StoreFailure)?.recoveryTransaction
            let refreshRequired = recovery != nil || positionLayoutRecoveryNeeded ||
                (error as? MenuBarPositionStore.StoreFailure)?.requiresLayoutRefresh == true
            let cleanup = Task { @MainActor in
                do {
                    let result = try recovery.map { try self.positionStore.rollback($0) }
                    if refreshRequired { try await statusBar.refreshPreferredPositions() }
                    guard result?.isComplete != false else { throw MenuBarAccessError.rejected }
                    self.positionLayoutRecoveryNeeded = false
                } catch {
                    await self.refreshAfterHiddenFailure(error)
                    self.positionLayoutRecoveryNeeded = true
                    self.positionRecoveryMessage = "确认图标身份后恢复原位置未完成：\(error.localizedDescription)"
                }
                self.pendingPositionRecoveries = self.positionStore.pendingTransactions
            }
            await cleanup.value
            await access.discardBackgroundPositionKeyChallenge(handle)
            throw originalError
        }
    }

    /// A hidden weight alone is insufficient: validate the retained source and
    /// owner on every observation, and require it to lose a real main-bar hit.
    /// This predicate is based on the installed three-stage macOS 27 experiment.
    private func waitForPositionVisibility(id: String, visible: Bool,
                                           candidates: [MenuBarPositionCandidate],
                                           until outerDeadline: TimeInterval? = nil,
                                           hadVerifiedReveal: Bool = false,
                                           budget: ManagementOperationBudget = .foreground) async throws -> CGRect? {
        guard let target = candidates.first(where: { $0.id == id }),
              let control = candidates.first(where: { $0.id != id }) else { throw MenuBarAccessError.disappeared }
        if usesPositionHiding, statusBar?.positionHidingBlockerWidth != nil {
            try await fitPositionHidingBlocker(reposition: false, budget: budget)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = budget.deadline(startedUptime: started, timeLimit: 3,
            operationDeadline: operationDeadline, outerDeadline: outerDeadline)
        var refreshedAgain = false
        var scanned = false
        var matches = 0
        var matchedFrame: CGRect?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkOperationDeadline(budget: budget)
            // Fresh AX geometry/identity is read below on every observation.
            // Refresh the inventory once if native layout needs another nudge,
            // instead of enumerating every running app on each 120 ms poll.
            if !scanned {
                try await scanNow()
                scanned = true
            }
            let positions = try positionStore.readPositions()
            try await access.validateBackgroundPositionCandidates(candidates,
                positions: positions, owners: menuBarScanInputs().owners)
            if let held = positionStore.managedHiddenEntries.first(where: { $0.key == target.key }) {
                guard positions[target.key] == held.lastAppWrite,
                      visible || positions[target.key] == held.hiddenValue else { throw MenuBarAccessError.rejected }
            }
            let inspection = await access.inspectVisibility(id: id)
            let reference = await access.inspectVisibility(id: control.id)
            let agrees: Bool
            if visible, let frame = inspection.frame, let controlFrame = reference.frame {
                agrees = inspection.centerHit && reference.centerHit && frame.width > 0 && frame.width <= 120 &&
                    sameDisplay(frame, controlFrame) && abs(frame.midY - controlFrame.midY) < 8 &&
                    (matchedFrame == nil || matchedFrame == frame)
            } else if !visible {
                let held = positionStore.managedHiddenEntries.first(where: { $0.key == target.key })
                let confirmedHiddenWrite = held.map {
                    $0.mode == .hidden && !$0.recoveryPending && $0.lastAppWrite == $0.hiddenValue &&
                        positions[target.key] == $0.hiddenValue
                } == true
                let hidden = await access.inspectPositionHidden(candidate: target,
                    allowVerifiedHostWindow: hadVerifiedReveal && confirmedHiddenWrite)
                // An overflow placeholder can remain occupied by a different
                // item while this source is still visible at its host position.
                agrees = !inspection.centerHit && reference.centerHit && hidden == true
            } else { agrees = false }
            Self.diagnosticLogger.notice("positionHidingObservation requestedVisible=\(visible) hasEntry=\(inspection.hasEntry) targetFrame=\(inspection.frame.map(NSStringFromRect) ?? "nil", privacy: .public) targetHit=\(inspection.centerHit) controlHit=\(reference.centerHit) agrees=\(agrees)")
            if !agrees && !refreshedAgain && ProcessInfo.processInfo.systemUptime - started > 1 {
                refreshedAgain = true
                try await statusBar?.refreshPreferredPositions()
                scanned = false
            }
            matches = agrees ? matches + 1 : 0
            matchedFrame = inspection.frame
            if matches >= 2 {
                try Task.checkCancellation()
                try await access.validateBackgroundPositionCandidates(candidates,
                    positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
                if visible {
                    if let hostFrame = await access.verifiedVisibleHostFrame(id: id),
                       let identity = draftSessionIdentity(for: id) {
                        verifiedHostedFootprints[id] = VerifiedHostedFootprint(identity: identity, width: hostFrame.width)
                    } else { verifiedHostedFootprints.removeValue(forKey: id) }
                    if activeBlockerReservation != nil {
                        for (otherID, group) in verifiedPositionGroups where otherID != id && group != .visible {
                            if await access.inspectVisibility(id: otherID).centerHit {
                                throw MenuTidyManagementError.positionApplication("临时显示时其他隐藏图标重新出现，已停止本次打开操作并准备恢复。")
                            }
                        }
                    }
                }
                return matchedFrame
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw MenuTidyManagementError.positionApplication(visible
            ? "图标尚未进入可操作的菜单栏位置，已停止本次操作。"
            : "尚未确认图标从主菜单栏隐藏，已保留原选择。")
    }

    private func performStoredPositionMove(_ target: MenuBarPositionCandidate,
                                          before anchor: MenuBarPositionCandidate,
                                          validating candidates: [MenuBarPositionCandidate],
                                          verifyOrder: () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await access.validateBackgroundPositionCandidates(candidates,
            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
        var transaction: MenuBarPositionStore.Transaction?
        let originalTargetFrame = snapshots.first(where: { $0.id == target.id && $0.hasReliableGeometry })?.frame
        let pointerBefore = CGEvent(source: nil)?.location
        defer {
            let pointerAfter = CGEvent(source: nil)?.location
            Self.diagnosticLogger.notice("backgroundPositionStore pointerAvailable=\(pointerBefore != nil && pointerAfter != nil) pointerUnchanged=\(pointerBefore != nil && pointerBefore == pointerAfter)")
        }
        do {
            try Task.checkCancellation()
            guard !stopping, !preparingToTerminate else { throw MenuBarAccessError.cancelled }
            positionLayoutRecoveryNeeded = true
            transaction = try positionStore.move(key: target.key, before: anchor.key)
            Self.diagnosticLogger.notice("backgroundPositionStore writeReadbackConfirmed=true awaitingNativeOrder=true")
            guard let statusBar else { throw MenuBarAccessError.disappeared }
            try await statusBar.refreshPreferredPositions()
            try await verifyOrder()
            try await access.validateBackgroundPositionCandidates(candidates,
                positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
            try Task.checkCancellation()
            guard !stopping, !preparingToTerminate else { throw MenuBarAccessError.cancelled }
            if let transaction { try positionStore.commit(transaction) }
            positionLayoutRecoveryNeeded = false
            Self.diagnosticLogger.notice("backgroundPositionStore nativeOrderConfirmed=true committed=true")
        } catch {
            let originalError = error
            let storeFailure = error as? MenuBarPositionStore.StoreFailure
            let recovery = transaction ?? storeFailure?.recoveryTransaction
            let needsRefresh = transaction != nil || storeFailure?.requiresLayoutRefresh == true
            if !needsRefresh && recovery == nil { positionLayoutRecoveryNeeded = false }
            var recoveryIssue: String?
            if let recovery {
                do {
                    let result = try positionStore.rollback(recovery)
                    if !result.isComplete {
                        pendingPositionRecoveries.append(recovery)
                        recoveryIssue = "位置在操作中被外部更改；已保留分类草稿和恢复记录，没有覆盖外部修改。"
                    }
                } catch {
                    if !pendingPositionRecoveries.contains(where: { $0.id == recovery.id }) {
                        pendingPositionRecoveries.append(recovery)
                    }
                    recoveryIssue = "恢复状态仍需检查：\(error.localizedDescription)"
                }
            }
            if needsRefresh {
                // An independent task permits cleanup after caller cancellation.
                // Even an internally completed rollback needs a host refresh.
                positionLayoutRecoveryNeeded = true
                if let originalTargetFrame { positionRecoveryFrames[target.id] = originalTargetFrame }
                if let statusBar {
                    let refresh = Task { try await statusBar.refreshPreferredPositions() }
                    switch await refresh.result {
                    case .success:
                        if originalTargetFrame != nil {
                            let verification = Task { try await self.verifyPositionRecoveryFrames() }
                            if case .success = await verification.result {
                                positionLayoutRecoveryNeeded = false
                                positionRecoveryFrames.removeAll()
                            }
                        }
                    case .failure(let error):
                        recoveryIssue = (recoveryIssue.map { $0 + " " } ?? "") + "菜单栏布局刷新未完成：\(error.localizedDescription)"
                    }
                } else {
                    recoveryIssue = (recoveryIssue.map { $0 + " " } ?? "") + "菜单栏入口不可用，布局刷新尚未完成。"
                }
                if positionLayoutRecoveryNeeded {
                    positionRecoveryMessage = recoveryIssue ?? "已尝试恢复原排序记录，但原生位置尚未确认。请检查当前布局，再重试恢复或保留当前布局。"
                }
            }
            if let recoveryIssue {
                throw MenuTidyManagementError.positionApplication("实际排序未确认，\(recoveryIssue)")
            }
            throw originalError
        }
    }

    private func verifyPositionRecoveryFrames() async throws {
        guard !positionRecoveryFrames.isEmpty else { throw MenuBarAccessError.invalidGeometry }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var matches = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await scanNow()
            let restored = positionRecoveryFrames.allSatisfy { id, oldFrame in
                guard let item = snapshots.first(where: { $0.id == id && $0.hasReliableGeometry }) else { return false }
                return abs(item.frame.minX - oldFrame.minX) < 1 && abs(item.frame.minY - oldFrame.minY) < 1 &&
                    abs(item.frame.width - oldFrame.width) < 1 && abs(item.frame.height - oldFrame.height) < 1
            }
            matches = restored ? matches + 1 : 0
            if matches >= 2 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MenuBarAccessError.invalidGeometry
    }

    private func verifyPositionPair(_ id: String, before anchorID: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var matches = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await scanNow()
            if let left = snapshots.first(where: { $0.id == id }),
               let right = snapshots.first(where: { $0.id == anchorID }),
               left.hasReliableGeometry, right.hasReliableGeometry,
               left.frame.maxX <= right.frame.minX, sameDisplay(left.frame, right.frame),
               abs(left.frame.midY - right.frame.midY) < 8 {
                matches += 1
                if matches >= 2 { return }
            } else { matches = 0 }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MenuBarAccessError.invalidGeometry
    }

    private func anchorIDs() throws -> (control: String, regular: String, always: String) {
        func identifier(_ name: String) throws -> String {
            let matches = snapshots.filter { $0.ownIdentifier == name }
            guard matches.count == 1 else {
                throw MenuTidyManagementError.anchorCount(identifier: name, count: matches.count)
            }
            return matches[0].id
        }
        return try (identifier("menu-tidy-toggle"), identifier("menu-tidy-divider"), identifier("menu-tidy-always-divider"))
    }

    private func scanManagementAnchors() async throws {
        // Remote-hosted status views can be absent for one layout snapshot.
        // Retry reads before changing section geometry; never guess an anchor.
        for attempt in 0..<3 {
            try await scanNow()
            do { _ = try anchorIDs(); return }
            catch {
                if attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func verify(id: String, group: ItemVisibility, anchors: (control: String, regular: String, always: String)) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var attempt = 0
        var consecutiveMatches = 0
        var lastFailure = MenuBarAccessError.invalidGeometry
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, !stopping else { throw MenuBarAccessError.cancelled }
            attempt += 1
            do {
                // Refresh the actor's AX entries as well as the value snapshots;
                // MenuBarAgent may replace hosted elements after a native move.
                try await scanNow()
            } catch {
                if Task.isCancelled || stopping { throw MenuBarAccessError.cancelled }
                throw error
            }
            guard !Task.isCancelled, !stopping else { throw MenuBarAccessError.cancelled }
            let targetItems = snapshots.filter { $0.id == id }
            let alwaysItems = snapshots.filter { $0.id == anchors.always && $0.ownIdentifier == "menu-tidy-always-divider" }
            let regularItems = snapshots.filter { $0.id == anchors.regular && $0.ownIdentifier == "menu-tidy-divider" }
            let withinDeadline = ProcessInfo.processInfo.systemUptime < deadline
            var observation = "untrusted-or-missing-geometry"
            if withinDeadline, targetItems.count == 1, alwaysItems.count == 1, regularItems.count == 1,
               let item = targetItems.first, let always = alwaysItems.first, let regular = regularItems.first,
               item.hasReliableGeometry, always.hasReliableGeometry, regular.hasReliableGeometry,
               always.frame.width > 0, always.frame.width <= 44,
               regular.frame.width > 0, regular.frame.width <= 44,
               always.frame.maxX <= regular.frame.minX,
               abs(always.frame.midY - regular.frame.midY) < 8, sameDisplay(always.frame, regular.frame),
               abs(item.frame.midY - regular.frame.midY) < 8, sameDisplay(item.frame, regular.frame) {
                let observed: ItemVisibility? = item.frame.maxX <= always.frame.minX ? .alwaysHidden :
                    (item.frame.minX >= always.frame.maxX && item.frame.maxX <= regular.frame.minX ? .collapsible :
                        (item.frame.minX >= regular.frame.maxX ? .visible : nil))
                if observed == group {
                    consecutiveMatches += 1
                    observation = "trusted-match"
                } else {
                    consecutiveMatches = 0
                    lastFailure = .rejected
                    observation = "trusted-order-mismatch"
                }
            } else {
                consecutiveMatches = 0
                lastFailure = .invalidGeometry
                if !withinDeadline { observation = "deadline-exceeded" }
            }
            let itemGeometry = verificationGeometrySummary(targetItems)
            let alwaysGeometry = verificationGeometrySummary(alwaysItems)
            let regularGeometry = verificationGeometrySummary(regularItems)
            // Geometry and static outcomes only: no target labels, IDs, or rules.
            Self.diagnosticLogger.notice("groupVerification attempt=\(attempt) outcome=\(observation, privacy: .public) consecutiveMatches=\(consecutiveMatches) item=\(itemGeometry, privacy: .public) always=\(alwaysGeometry, privacy: .public) regular=\(regularGeometry, privacy: .public)")
            if consecutiveMatches == 2 { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            do { try await Task.sleep(for: .seconds(min(0.1, remaining))) }
            catch { throw MenuBarAccessError.cancelled }
        }
        guard !Task.isCancelled, !stopping else { throw MenuBarAccessError.cancelled }
        throw lastFailure
    }

    private func verificationGeometrySummary(_ matches: [MenuBarItemSnapshot]) -> String {
        let geometry = matches.map { "\(NSStringFromRect($0.frame)) reliable=\($0.hasReliableGeometry)" }.joined(separator: "; ")
        return "count=\(matches.count) frames=[\(geometry)]"
    }

    private func menuBarScanInputs() -> (owners: [MenuBarOwner], bands: [CGRect]) {
        let owners = NSWorkspace.shared.runningApplications.map {
            MenuBarOwner(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                         name: $0.localizedName ?? "应用 \($0.processIdentifier)", launchTime: MenuBarProcessIdentity.launchTime(for: $0) ?? 0)
        }
        let bands = NSScreen.screens.prefix(1).compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        }
        return (owners, bands)
    }

    private func scanNow(allowNativeOwnerRecovery: Bool = false) async throws {
        registerDepartedNativeOwners()
        if allowNativeOwnerRecovery && isRefreshing && !isApplying && !isActivatingPanelItem &&
            !isRecoveringPositions && !isArranging && !preparingToTerminate && !stopping &&
            positionRecoveryMessage == nil {
            restoreDepartedNativeOwnersBeforeScan()
        } else {
            scheduleNativeOwnerRecoveryDiscoveryIfNeeded()
        }
        anchorScanSequence += 1
        let scanID = anchorScanSequence
        let (owners, bands) = menuBarScanInputs()
        let newSnapshots: [MenuBarItemSnapshot]
        do {
            newSnapshots = try await access.scan(owners: owners, menuBands: bands,
                positions: usesNativeVisibility && !needsLegacyPositionRecovery ? [:] : ((try? positionStore.readPositions()) ?? [:]),
                retainHiddenIDs: Set(nativeVisibilityEvidence.filter {
                    $0.value.group != .visible && Self.observedOwnerIsCurrent($0.value.identity)
                }.keys))
        } catch {
            logOwnAnchors(nil, scanID: scanID)
            throw error
        }
        logOwnAnchors(newSnapshots, scanID: scanID)
        guard !stopping, !Task.isCancelled, scanID == anchorScanSequence else { throw MenuBarAccessError.cancelled }
        // A process can exit while AX scanning is suspended. Retain its
        // recovery intent before reconciliation discards the old evidence.
        registerDepartedNativeOwners()
        scheduleNativeOwnerRecoveryDiscoveryIfNeeded()
        snapshots = newSnapshots
        actualGroups.removeAll()
        if usesNativeVisibility && !isArranging {
            await reconcileNativeVisibilityEvidence()
            actualGroups = nativeVisibilityEvidence.mapValues(\.group)
        }
        if (!usesIndependentTray || isArranging), statusBar?.areGroupBoundariesExpanded == true,
           let always = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-always-divider" }),
           let regular = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-divider" }),
           always.hasReliableGeometry, regular.hasReliableGeometry,
           always.frame.width > 0, always.frame.width <= (isArranging ? 120 : 44),
           regular.frame.width > 0, regular.frame.width <= (isArranging ? 120 : 44),
           always.frame.maxX <= regular.frame.minX,
           abs(always.frame.midY - regular.frame.midY) < 8, sameDisplay(always.frame, regular.frame) {
            for item in snapshots where item.hasReliableGeometry && abs(item.frame.midY - regular.frame.midY) < 8 && sameDisplay(item.frame, regular.frame) {
                if item.frame.maxX <= always.frame.minX { actualGroups[item.id] = .alwaysHidden }
                else if item.frame.minX >= always.frame.maxX && item.frame.maxX <= regular.frame.minX { actualGroups[item.id] = .collapsible }
                else if item.frame.minX >= regular.frame.maxX { actualGroups[item.id] = .visible }
            }
        }
        if usesPositionHiding && !isArranging {
            if !isApplying && !isActivatingPanelItem && !isRefreshingManagedIcons {
                await reconcileVerifiedPositionEvidence()
            }
            actualGroups = verifiedPositionGroups
        }
        rememberObservedGroups(scannedOwners: owners)
        rebuildRows()
    }

    /// Reconcile historical acceptance using read-only current evidence. This
    /// is also safe after a preflight failure that performed no layout writes.
    private func reconcileVerifiedPositionEvidence() async {
        let currentPositions = try? positionStore.readPositions()
        verifiedPositionGroups = verifiedPositionGroups.filter { id, _ in
            guard let evidence = verifiedPositionEvidence[id],
                  currentPositions?[evidence.key] == evidence.value,
                  Self.observedOwnerIsCurrent(evidence.identity),
                  let current = snapshots.first(where: { $0.id == id }),
                  observedItemIdentity(current) == evidence.identity else { return false }
            return true
        }
        // A direct hit revokes hidden proof even when weights are unchanged.
        for (id, group) in verifiedPositionGroups where group != .visible {
            let observed = await access.inspectVisibility(id: id)
            if observed.centerHit {
                verifiedPositionGroups.removeValue(forKey: id)
                Self.diagnosticLogger.notice("positionHiding historicalProofRevoked=true reason=visible-again")
            }
        }
        verifiedPositionEvidence = verifiedPositionEvidence.filter { verifiedPositionGroups[$0.key] != nil }
    }

    private static func observedOwnerIsCurrent(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.bundleIdentifier == identity.bundleIdentifier,
              MenuBarProcessIdentity.launchTime(for: app) == identity.launchTime else { return false }
        return true
    }

    private func observedItemIdentity(_ item: MenuBarItemSnapshot) -> ObservedItemGroupHistory.Identity? {
        guard let app = NSRunningApplication(processIdentifier: item.processIdentifier), !app.isTerminated,
              app.bundleIdentifier == item.bundleIdentifier,
              let launchTime = MenuBarProcessIdentity.launchTime(for: app),
              launchTime.isFinite, launchTime > 0 else { return nil }
        return ObservedItemGroupHistory.Identity(id: item.id, pid: item.processIdentifier,
            bundleIdentifier: item.bundleIdentifier, launchTime: launchTime)
    }

    private func pruneObservedGroupHistory() {
        // An absent AX item is not an exited owner. Keep partial-scan history
        // only while its original process lifetime can still be confirmed.
        lastKnownObservedGroups.retainOwners { Self.observedOwnerIsCurrent($0) }
    }

    private func rememberObservedGroups(scannedOwners: [MenuBarOwner]) {
        pruneObservedGroupHistory()
        // Temporary native presentation changes physical order deliberately.
        // Freeze every remembered group until that operation has recovered.
        guard !isActivatingPanelItem else { return }
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        for item in snapshots where item.canMove && item.ownIdentifier == nil &&
            item.bundleIdentifier != Bundle.main.bundleIdentifier && counts[item.id] == 1 {
            guard let group = actualGroups[item.id], let identity = observedItemIdentity(item),
                  scannedOwners.contains(where: { $0.pid == identity.pid &&
                      $0.bundleIdentifier == identity.bundleIdentifier && $0.launchTime == identity.launchTime }) else { continue }
            lastKnownObservedGroups.remember(group, for: identity, frozen: false)
        }
    }

    private func observedGroupForDisplay(id: String) -> ItemVisibility? {
        if let current = actualGroups[id] { return current }
        let matches = snapshots.filter { $0.id == id }
        guard matches.count == 1, let item = matches.first,
              let identity = observedItemIdentity(item) else { return nil }
        return lastKnownObservedGroups.visibility(for: identity)
    }

    /// Only our fixed identifiers and geometry are logged, never third-party
    /// application names, identifiers, menu labels, or the requested categories.
    private func logOwnAnchors(_ scannedItems: [MenuBarItemSnapshot]?, scanID: Int) {
        for identifier in Self.ownAnchorIdentifiers {
            let summary: String
            if let scannedItems {
                let matches = scannedItems.filter { $0.ownIdentifier == identifier }
                if matches.isEmpty {
                    summary = "count=0 missing"
                } else {
                    let frames = matches.map { "\(NSStringFromRect($0.frame)) reliableGeometry=\($0.hasReliableGeometry)" }.joined(separator: "; ")
                    summary = "count=\(matches.count) frames(CG points)=[\(frames)]"
                }
            } else {
                summary = "unavailable: scan failed before producing snapshots"
            }
            Self.diagnosticLogger.notice("anchor scan=\(scanID) identifier=\(identifier, privacy: .public) \(summary, privacy: .public)")
        }
    }

    private func sameDisplay(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return bounds.contains(CGPoint(x: lhs.midX, y: lhs.midY)) && bounds.contains(CGPoint(x: rhs.midX, y: rhs.midY))
        }
    }

    private func rebuildRows() {
        pendingDrafts.retainSessionBindings { Self.observedOwnerIsCurrent($0) }
        drafts = rules
        rowDraftIDs.removeAll()
        let external = snapshots.filter { $0.ownIdentifier == nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        let counts = Dictionary(grouping: external, by: \.id).mapValues(\.count)
        for item in external where item.canMove && counts[item.id] == 1 {
            if let record = pendingDrafts.record(for: item.id, sessionIdentity: observedItemIdentity(item)) {
                drafts.set(record.rule)
                rowDraftIDs[item.id] = record.id
            }
        }
        var result: [ManagedItemRow] = external.map { item in
            let draft = drafts.rule(for: item.id)
            // System recovery controls can move with the overflow presentation,
            // but never belong to a user-managed hidden section.
            let nativeChoice = usesNativeVisibility ? item.bundleIdentifier.flatMap { nativeTrayChoices.group(bundle: $0) } : nil
            let group: ItemVisibility = item.canMove ? (nativeChoice ?? draft?.visibility ?? rules.rule(for: item.id)?.visibility ?? observedGroupForDisplay(id: item.id) ?? .visible) : .visible
            // Concealed overflow items may have no usable AX order. An unknown
            // observation is not evidence that an already verified rule moved.
            let observedMismatch = actualGroups[item.id].map { $0 != group } ?? false
            var details = item.detail.isEmpty ? [] : [item.detail]
            if rowDraftIDs[item.id] != nil { details.append("草稿已保留，尚未应用。") }
            if item.canMove && actualGroups[item.id] == nil {
                if draft != nil || rules.rule(for: item.id) != nil {
                    details.append("当前实际分组位置未确认；保留已保存或待应用的选择。")
                } else if observedGroupForDisplay(id: item.id) != nil {
                    details.append("当前实际位置未确认；暂按本次运行中最近确认的分类显示。")
                } else {
                    details.append("当前实际分组位置未确认；选择显示方式后应用。")
                }
            }
            let icon = applicationIcon(for: item.bundleIdentifier)
            return ManagedItemRow(id: item.id, name: item.name, ownerName: item.ownerName, bundleIdentifier: item.bundleIdentifier,
                icon: icon, group: group, isAvailable: true, canMove: item.canMove, detail: details.joined(separator: " · "),
                isPending: item.canMove && counts[item.id] == 1 &&
                    (rowDraftIDs[item.id] != nil || ((nativeChoice != nil || rules.rule(for: item.id) != nil) &&
                        (observedMismatch || (usesIndependentTray && actualGroups[item.id] == nil)))))
        }
        let boundDraftIDs = Set(rowDraftIDs.values)
        offlineDrafts = pendingDrafts.records.filter { !boundDraftIDs.contains($0.id) }
            .sorted { $0.rule.name.localizedStandardCompare($1.rule.name) == .orderedAscending }
        let offlineTargetIDs = Set(offlineDrafts.map(\.rule.id))
        for rule in rules.rules.values where !result.contains(where: { $0.id == rule.id }) && !offlineTargetIDs.contains(rule.id) {
            if usesNativeVisibility, let bundle = rule.bundleIdentifier,
               nativeTrayChoices.group(bundle: bundle) != nil,
               result.contains(where: { $0.isAvailable && $0.bundleIdentifier == bundle }) { continue }
            result.append(ManagedItemRow(id: rule.id, name: rule.name, ownerName: rule.bundleIdentifier ?? "尚未运行的应用",
                bundleIdentifier: rule.bundleIdentifier, icon: nil, group: rule.visibility, isAvailable: false, canMove: false,
                detail: "已应用规则；当前未读到此图标。启动对应应用后刷新。", isPending: false))
        }
        items = result.sorted { $0.isAvailable != $1.isAvailable ? $0.isAvailable : $0.ownerName.localizedStandardCompare($1.ownerName) == .orderedAscending }
        actionablePendingCount = items.filter { $0.isPending && $0.isAvailable && $0.canMove }.count
        hasPendingChanges = actionablePendingCount > 0 || !offlineDrafts.isEmpty
    }

    /// Repeated layout observations rebuild rows frequently. App icons are
    /// display metadata; looking them up again must not lengthen each check.
    private func applicationIcon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = applicationIcons[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        applicationIcons[bundleIdentifier] = icon
        return icon
    }

    private func draftSessionIdentity(for id: String) -> ObservedItemGroupHistory.Identity? {
        let matches = snapshots.filter { $0.id == id }
        guard matches.count == 1, let item = matches.first else { return nil }
        return observedItemIdentity(item)
    }

    private func persistDrafts() {
        do {
            defaults.set(try JSONEncoder().encode(pendingDrafts), forKey: "itemDrafts.v1")
            draftPersistenceIssue = nil
        } catch {
            draftPersistenceIssue = "待应用选择暂时无法写入设置，当前选择仍留在内存中。退出前请重试；已应用规则不受影响。"
        }
    }

    private func persistRules() {
        let persistent = ItemRuleBook(rules: rules.rules.filter { !$0.key.hasPrefix("session:") })
        if let data = try? JSONEncoder().encode(persistent) { defaults.set(data, forKey: "itemRules.v1") }
    }

    func revealAllTemporarily() {
        if isUIPreview { temporarilyRevealingAll = true; return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        showIconPanel(includeAlwaysHidden: true)
    }

    func endTemporaryReveal() {
        if isUIPreview { temporarilyRevealingAll = false; return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, temporarilyRevealingAll else { return }
        let shouldCollapse = beforeTemporaryRevealCollapsed == true
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        if shouldCollapse { state.collapse() } else { state.expand() }
        applyState()
    }

    /// This operates only our own separators. A pending automatic move or a
    /// missing screenshot must not make the existing native group unusable.
    func collapseNativeGroups() {
        if isUIPreview { isPanelPresented = false; return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        closeIconPanel()
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        state.collapse()
        statusBar?.restoreControlVisibility()
        applyState()
        managementMessage = usesIndependentTray
            ? "已收起图标栏；未应用的分类选择仍保留。"
            : "已收起现有菜单栏分组；未应用的分类选择仍保留，不代表这些图标已移动。"
    }

    func toggleVisibility() {
        if isUIPreview { isPanelPresented.toggle(); return }
        if isArranging { finishArrangement(); return }
        if isPanelPresented { closeIconPanel(); return }
        if temporarilyRevealingAll {
            temporarilyRevealingAll = false
            beforeTemporaryRevealCollapsed = nil
        }
        showIconPanel(includeAlwaysHidden: false)
    }

    func controlClicked(event: NSEvent?) {
        cancelPassiveIconCapture()
        if isArranging {
            if event?.type != .leftMouseDown && event?.type != .rightMouseDown { finishArrangement() }
            return
        }
        controlRouter.controlClicked(event: event)
    }

    func showIconPanelFromControl() {
        if isUIPreview { isPanelPresented = true; return }
        guard !isArranging, !preparingToTerminate else { return }
        showIconPanel(includeAlwaysHidden: false)
    }

    func iconPanelContains(_ point: NSPoint) -> Bool { iconPanel?.contains(point) == true }

    private var canPassivelyCaptureIcons: Bool {
        !demoMode && !stopping && !preparingToTerminate && accessibilityGranted && screenCaptureGranted &&
            !isRecoveringPositions && !isRefreshing && !isApplying && !isArranging && !isActivatingPanelItem &&
            !isPanelPresented && !contextMenuVisible && panelActivationTask == nil &&
            NSEvent.pressedMouseButtons == 0 && AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
    }

    private func cancelPassiveIconCapture() {
        // Keep the handle until its final read-only verification completes.
        // Normal capture paths await it before touching the same cache.
        passiveIconCaptureTask?.cancel()
    }

    private func checkPassiveIconCapture(_ id: UUID) throws {
        try Task.checkCancellation()
        guard passiveIconCaptureID == id, canPassivelyCaptureIcons else { throw CancellationError() }
    }

    private func schedulePassiveIconCapture() {
        guard #available(macOS 15.2, *) else { return }
        guard canPassivelyCaptureIcons else { cancelPassiveIconCapture(); return }
        guard passiveIconCaptureTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPassiveIconCaptureAttempt >= 2 else { return }
        let coverage = hiddenImageCoverage()
        guard !coverage.requested.isEmpty,
              let available = try? iconCapture.availableCachedImageIDs(matching: snapshots) else { return }
        let summary = ImageAvailabilitySummary(requested: coverage.requested, available: available)
        guard summary.hasMissingImages else { return }
        lastPassiveIconCaptureAttempt = now
        let id = UUID()
        passiveIconCaptureID = id
        let candidates = snapshots.filter { summary.missing.contains($0.id) }
        passiveIconCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.passiveIconCaptureID == id {
                    self.passiveIconCaptureTask = nil
                    self.passiveIconCaptureID = nil
                }
            }
            do {
                try self.checkPassiveIconCapture(id)
                let expanded = await self.access.isSystemOverflowExpandedForPassiveCapture()
                try self.checkPassiveIconCapture(id)
                if expanded == false {
                    // Only a fresh, definite closed state grants the next open
                    // a new budget. Unknown/timeout must not renew retries.
                    self.passiveOverflowRebindAttempts = 0
                    self.passiveOverflowRebindNeedsRetry = false
                }
                var inspected = try await self.inspectPassiveIconCandidates(candidates, taskID: id)
                let rebindTime = ProcessInfo.processInfo.systemUptime
                let firstRebindNeeded = self.passiveOverflowRebindAttempts == 0 && inspected.visible.count < candidates.count
                let retryRebindNeeded = self.passiveOverflowRebindAttempts == 1 && self.passiveOverflowRebindNeedsRetry
                if expanded == true, firstRebindNeeded || retryRebindNeeded,
                   rebindTime - self.lastPassiveOverflowRebind >= 2 {
                    let fresh = try await self.rebindPassiveIconCandidates(candidates, taskID: id)
                    inspected = try await self.inspectPassiveIconCandidates(fresh, taskID: id)
                    self.passiveOverflowRebindNeedsRetry = fresh.count < candidates.count || inspected.hasMissingBinding
                    Self.diagnosticLogger.notice("passiveIconRebind attempt=\(self.passiveOverflowRebindAttempts) requested=\(candidates.count) rebound=\(fresh.count) visible=\(inspected.visible.count) missingBinding=\(self.passiveOverflowRebindNeedsRetry)")
                }
                let visible = inspected.visible
                guard !visible.isEmpty else { return }
                try self.checkPassiveIconCapture(id)
                let captured = try await self.captureAndVerifyIconImages(visible)
                try self.checkPassiveIconCapture(id)
                let currentCoverage = self.hiddenImageCoverage()
                let currentAvailable = try self.iconCapture.availableCachedImageIDs(matching: self.snapshots)
                let currentSummary = ImageAvailabilitySummary(requested: currentCoverage.requested, available: currentAvailable)
                self.updateIconImageWarning(summary: currentSummary,
                    unobservedConfiguredCount: currentCoverage.unobservedConfiguredCount)
                self.panelLastCaptureDate = self.iconCapture.lastCacheDate
                Self.diagnosticLogger.notice("passiveIconCapture candidates=\(visible.count) captured=\(captured.count) remaining=\(currentSummary.missing.count)")
            } catch is CancellationError {
                // Cancellation never removes a previously valid cached image.
            } catch {
                // A hidden or changed item is retried only while still missing.
                // Do not replace an actionable explicit-refresh message every
                // timer tick or turn absence of visibility into an app failure.
                Self.diagnosticLogger.debug("passiveIconCapture captureUnavailable=true")
            }
        }
    }

    private func inspectPassiveIconCandidates(_ candidates: [MenuBarItemSnapshot], taskID: UUID) async throws
        -> (visible: [MenuBarItemSnapshot], hasMissingBinding: Bool) {
        var visible: [MenuBarItemSnapshot] = []
        var hasMissingBinding = false
        for item in candidates {
            try checkPassiveIconCapture(taskID)
            let inspection = await access.inspectVisibility(id: item.id)
            try checkPassiveIconCapture(taskID)
            if !inspection.hasEntry || !inspection.hasFrame { hasMissingBinding = true }
            guard inspection.centerHit, let frame = inspection.frame else { continue }
            visible.append(MenuBarItemSnapshot(id: item.id, processIdentifier: item.processIdentifier,
                name: item.name, ownerName: item.ownerName, bundleIdentifier: item.bundleIdentifier,
                frame: frame, hasReliableGeometry: true, canMove: item.canMove, detail: item.detail,
                persistentIdentity: item.persistentIdentity, ownIdentifier: item.ownIdentifier))
        }
        return (visible, hasMissingBinding)
    }

    private func rebindPassiveIconCandidates(_ candidates: [MenuBarItemSnapshot], taskID: UUID) async throws -> [MenuBarItemSnapshot] {
        try checkPassiveIconCapture(taskID)
        guard passiveOverflowRebindAttempts < 2 else { return [] }
        let expected = Dictionary(uniqueKeysWithValues: candidates.compactMap { item in
            observedItemIdentity(item).map { (item.id, $0) }
        })
        let (owners, bands) = menuBarScanInputs()
        // Charge before awaiting, so a failed/cancelled scan cannot create an
        // unbounded retry loop while the same overflow presentation stays open.
        passiveOverflowRebindAttempts += 1
        lastPassiveOverflowRebind = ProcessInfo.processInfo.systemUptime
        passiveOverflowRebindNeedsRetry = true
        let fresh = try await access.scan(owners: owners, menuBands: bands, positions: (try? positionStore.readPositions()) ?? [:])
        try checkPassiveIconCapture(taskID)
        let counts = Dictionary(grouping: fresh, by: \.id).mapValues(\.count)
        // Refresh the AX actor's bindings only. Never assign model snapshots,
        // rebuild rows, infer actualGroups or touch accepted rules/drafts here.
        return fresh.filter { item in
            guard counts[item.id] == 1, item.canMove, item.ownIdentifier == nil,
                  let identity = expected[item.id] else { return false }
            return observedItemIdentity(item) == identity
        }
    }

    @discardableResult
    private func prepareIconImages() async throws -> Set<String> {
        defer { recomputeIconImageWarning() }
        cancelPassiveIconCapture()
        await passiveIconCaptureTask?.value
        try Task.checkCancellation()
        try await iconCapture.refreshBindings(snapshots: snapshots)
        var confirmed: [MenuBarItemSnapshot] = []
        for item in snapshots where item.canMove && item.hasReliableGeometry && item.ownIdentifier == nil {
            try Task.checkCancellation()
            let inspection = await access.inspectVisibility(id: item.id)
            if inspection.centerHit && inspection.frame == item.frame { confirmed.append(item) }
        }
        guard !confirmed.isEmpty else { return [] }
        let verified = try await captureAndVerifyIconImages(confirmed)
        panelError = nil
        return verified
    }

    private func snapshotForVerifiedIconCapture(_ item: MenuBarItemSnapshot, frame: CGRect) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(id: item.id, processIdentifier: item.processIdentifier,
            name: item.name, ownerName: item.ownerName, bundleIdentifier: item.bundleIdentifier,
            frame: frame, hasReliableGeometry: true, canMove: item.canMove, detail: item.detail,
            persistentIdentity: item.persistentIdentity, ownIdentifier: item.ownIdentifier)
    }

    private func captureAndVerifyIconImages(_ confirmed: [MenuBarItemSnapshot]) async throws -> Set<String> {
        let requested = Set(confirmed.map(\.id))
        let checkpoint = try iconCapture.beginVisibleCaptureValidation(ids: Array(requested))
        var invalid = requested
        defer {
            iconCapture.finishVisibleCaptureValidation(checkpoint, invalidIDs: invalid)
            recomputeIconImageWarning()
        }
        let captured = try await iconCapture.captureVisibleIcons(snapshots: confirmed)
        // Capture commits an uncancelled batch. Complete its read-only identity
        // verification before propagating a later cancellation; never discard
        // every old, valid cache entry just because a refresh was cancelled.
        for item in confirmed where captured[item.id] != nil {
            let inspection = await access.inspectVisibility(id: item.id)
            if inspection.centerHit && inspection.frame == item.frame { invalid.remove(item.id) }
        }
        let verifiedIDs = Set(captured.keys).subtracting(invalid)
        Self.diagnosticLogger.notice("iconImages postCaptureVerified=\(verifiedIDs.count) discarded=\(invalid.count)")
        try Task.checkCancellation()
        guard !verifiedIDs.isEmpty else { throw MenuBarIconCapture.CaptureError.noCapturedImages }
        return verifiedIDs
    }

    private func showIconPanel(includeAlwaysHidden: Bool) {
        cancelPassiveIconCapture()
        refreshPermissions()
        closeIconPanel()
        panelIncludesAlwaysHidden = includeAlwaysHidden
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        if !panelInteractionBusy { collapseIfSafe() }
        isPanelPresented = true
        resetIdleTime()
        controlRouter.presentationChanged(isPresented: true)
        panelError = nil
        // Cache lookup never captures or enumerates windows. Without screen
        // permission the tray still opens using labelled application icons.
        panelImages = (try? iconCapture.cachedImages(matching: snapshots)) ?? [:]
        statusBar?.apply(collapsed: true, arranging: false)
        let controller = iconPanel ?? HiddenItemsPanelController()
        iconPanel = controller
        let anchor = snapshots.first { $0.ownIdentifier == "menu-tidy-toggle" }?.frame
        controller.show(model: self, anchor: anchor)
        Self.diagnosticLogger.notice("tray presented=true items=\(self.panelItems.count) cachedImages=\(self.panelImages.count)")
        guard screenCaptureGranted, !panelInteractionBusy else { return }
        panelTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.passiveIconCaptureTask?.value
                try Task.checkCancellation()
                while self.isPanelPresented && !Task.isCancelled {
                    let ids = self.panelItems.map(\.id)
                    let images = try await self.iconCapture.capture(ids: ids)
                    try Task.checkCancellation()
                    self.panelImages = images
                    self.recomputeIconImageWarning()
                    self.panelUsesCachedImages = self.iconCapture.usesCachedImages
                    self.panelLastCaptureDate = self.iconCapture.lastCacheDate
                    self.panelError = nil
                    try await Task.sleep(for: .milliseconds(750))
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isPanelPresented && !Task.isCancelled else { return }
                self.panelImages = (try? self.iconCapture.cachedImages(matching: self.snapshots)) ?? [:]
                self.panelError = nil
            }
        }
    }

    func closeIconPanel() {
        if isUIPreview { isPanelPresented = false; return }
        panelTask?.cancel()
        panelTask = nil
        isPanelPresented = false
        controlRouter.presentationChanged(isPresented: false)
        panelImages = [:]
        iconPanel?.close()
        statusBar?.apply(collapsed: isCollapsed, arranging: isArranging)
    }

    func dismissIconPanelForFocusChange() {
        // Preparing the target may momentarily transfer focus. Keep its local
        // progress/error available until a real native presentation is known.
        guard !panelIsPreparingNativeAction else { return }
        closeIconPanel()
    }

    /// Use one native AX action. A managed item is temporarily placed beside
    /// our control, then returned to its hidden weight after its presentation closes.
    func activatePanelItem(id: String) {
        if isUIPreview { return }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging,
              !preparingToTerminate, isPanelPresented,
              panelItems.contains(where: { $0.id == id }) else { return }
        refreshPermissions()
        guard accessibilityGranted else { requestAccessibility(); return }
        panelTask?.cancel()
        panelTask = nil
        isActivatingPanelItem = true
        activePanelItemID = id
        panelIsPreparingNativeAction = true
        trayItemErrors.removeValue(forKey: id)
        panelActivationError = nil
        panelError = nil
        panelItemProgress = "正在打开目标图标…"
        panelActivationTask = Task { [weak self] in
            guard let self else { return }
            let actionStarted = ProcessInfo.processInfo.systemUptime
            Self.diagnosticLogger.notice("backgroundItemAction started=true")
            var candidates: [MenuBarPositionCandidate] = []
            var revealedKey: String?
            var nativeRevealedTarget: NativeVisibilityTarget?
            var presentation: MenuBarItemPresentation?
            var revealVerified = false
            var pressAttempted = false
            var presentationClosed = false
            var canRestore = true
            var suspendedPanelToken: UUID?
            defer {
                self.panelActivationTask = nil
                self.isActivatingPanelItem = false
                self.activePanelItemID = nil
                self.panelIsPreparingNativeAction = false
                self.panelItemProgress = nil
                if let suspendedPanelToken, self.isPanelPresented, !self.preparingToTerminate, !self.stopping {
                    self.iconPanel?.restoreAfterNativePresentationFailure(token: suspendedPanelToken)
                }
                self.statusBar?.apply(collapsed: self.isCollapsed, arranging: self.isArranging)
            }
            do {
                await self.passiveIconCaptureTask?.value
                try Task.checkCancellation()
                try await self.scanNow()
                if self.usesNativeVisibility {
                    guard let evidence = self.nativeVisibilityEvidence[id],
                          Self.observedOwnerIsCurrent(evidence.identity),
                          let target = evidence.target, self.nativeTargetIsManaged(target) else {
                        throw MenuTidyManagementError.positionApplication("此图标尚未连接到托盘，请在图标设置中重试。")
                    }
                    nativeRevealedTarget = target
                    try self.temporarilyRevealNativeTarget(target)
                    try await self.waitForNativeVisibility(id: id, target: target,
                        identity: evidence.identity, visible: true)
                    // AirDrop's old source is removed while hidden. Bind its
                    // newly shown source before asking for actions or pressing.
                    try await self.scanNow()
                    revealVerified = true
                }
                try await self.access.validateItemActionSupport(id: id)
                if self.usesPositionHiding,
                   let controlID = self.snapshots.first(where: { $0.ownIdentifier == "menu-tidy-toggle" })?.id {
                    candidates = try await self.access.prepareBackgroundPositionCandidates(ids: [id, controlID],
                        positions: self.positionStore.readPositions(), owners: self.menuBarScanInputs().owners)
                    if let target = candidates.first(where: { $0.id == id }),
                       let control = candidates.first(where: { $0.id == controlID }),
                       self.positionStore.managedHiddenEntries.contains(where: { $0.key == target.key }) {
                        revealedKey = target.key
                        let result = try await self.temporarilyRevealManagedItem(id: id, key: target.key, before: control.key)
                        try await self.completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                        guard result.isComplete else { throw MenuBarAccessError.rejected }
                        _ = try await self.waitForPositionVisibility(id: id, visible: true, candidates: candidates)
                        revealVerified = true
                    }
                }
                // Yield the popup layer before the source opens its own menu.
                // Keep the existing tray view so failures can return in place.
                suspendedPanelToken = self.iconPanel?.suspendForNativePresentation()
                let baseline = try await self.access.prepareItemPresentation(id: id)
                pressAttempted = true
                presentation = try await self.access.pressItem(id: id, baseline: baseline)
                if let presentation {
                    self.panelIsPreparingNativeAction = false
                    self.closeIconPanel()
                    let actionElapsed = ProcessInfo.processInfo.systemUptime - actionStarted
                    Self.diagnosticLogger.notice("backgroundItemAction presentationConfirmed=true elapsedSeconds=\(actionElapsed)")
                    if revealedKey != nil || nativeRevealedTarget != nil {
                        // Popovers are often exposed as AXWindow. Moving their
                        // anchor immediately can dismiss them before interaction.
                        self.panelItemProgress = "目标界面已打开，关闭后自动恢复隐藏。"
                        var unknownSince: TimeInterval?
                        while !Task.isCancelled && !self.preparingToTerminate {
                            switch await self.access.presentationStatus(presentation) {
                            case .closed:
                                presentationClosed = true
                                break
                            case .open:
                                unknownSince = nil
                                try await Task.sleep(for: .milliseconds(200))
                                continue
                            case .unavailable:
                                let now = ProcessInfo.processInfo.systemUptime
                                if unknownSince == nil { unknownSince = now }
                                if now - (unknownSince ?? now) < 3 {
                                    try await Task.sleep(for: .milliseconds(200))
                                    continue
                                }
                                canRestore = false
                                if !self.usesNativeVisibility { self.positionLayoutRecoveryNeeded = true }
                                self.positionRecoveryMessage = "目标界面状态暂时无法确认。图标保留可见，关闭后可重试恢复位置。"
                            }
                            break
                        }
                    }
                } else {
                    // Never retry a possibly dispatched AX request.
                    self.panelActivationError = "已发送一次后台操作，但未确认新菜单或窗口。没有补发点击。"
                    Self.diagnosticLogger.notice("backgroundItemAction presentationConfirmed=false")
                }
            } catch is CancellationError {
                self.panelActivationError = "后台操作已取消。"
            } catch {
                await self.refreshAfterHiddenFailure(error)
                self.panelActivationError = error.localizedDescription
                Self.diagnosticLogger.notice("backgroundItemAction failed=true")
            }
            if canRestore, (revealedKey != nil || nativeRevealedTarget != nil), pressAttempted, !presentationClosed,
               !self.preparingToTerminate, !self.stopping {
                let retainedPresentation = presentation
                let wasCancelled = Task.isCancelled
                let checkClosure = Task { @MainActor in
                    if let retainedPresentation {
                        if wasCancelled, retainedPresentation.kind == .menu {
                            await self.access.cancelCurrentMenuPresentation()
                        }
                        for _ in 0..<4 {
                            if await self.access.presentationStatus(retainedPresentation) == .closed { return true }
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                        return false
                    }
                    return await self.access.hasVisiblePresentation(id: id) == false
                }
                canRestore = await checkClosure.value
                if !canRestore {
                    if !self.usesNativeVisibility { self.positionLayoutRecoveryNeeded = true }
                    self.positionRecoveryMessage = "目标界面尚未确认关闭。图标保留可见，关闭后可重试恢复位置。"
                }
            }
            if let presentation { await self.access.discardPresentation(presentation) }
            // Cleanup is independent of the caller's cancellation; the ledger
            // remains authoritative if conditional restoration cannot complete.
            if canRestore, let key = revealedKey {
                let retainedCandidates = candidates
                let hadVisibleProof = revealVerified
                let cleanup = Task { @MainActor in
                    var verificationCandidates: [MenuBarPositionCandidate] = []
                    do {
                        let result = try self.restoreTemporaryManagedItem(key: key)
                        try await self.completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                        guard result.isComplete else { throw MenuBarAccessError.rejected }
                        if AXIsProcessTrusted(), self.accessibilityGranted,
                           !self.stopping, !self.preparingToTerminate {
                            // The target window may remain open longer than
                            // a position lease. Renew proof, never its expiry.
                            try await self.scanNow()
                            verificationCandidates = try await self.access.prepareBackgroundPositionCandidates(
                                ids: retainedCandidates.map(\.id), positions: self.positionStore.readPositions(),
                                owners: self.menuBarScanInputs().owners)
                            guard verificationCandidates.count == retainedCandidates.count,
                                  verificationCandidates.allSatisfy({ fresh in
                                      retainedCandidates.contains { old in
                                          old.id == fresh.id && old.key == fresh.key &&
                                              old.processIdentifier == fresh.processIdentifier &&
                                              old.launchTime == fresh.launchTime && old.bundleIdentifier == fresh.bundleIdentifier
                                      }
                                  }) else { throw MenuBarAccessError.disappeared }
                            _ = try await self.waitForPositionVisibility(id: id, visible: false,
                                candidates: verificationCandidates, hadVerifiedReveal: hadVisibleProof, budget: .cleanup)
                        }
                        Self.diagnosticLogger.notice("backgroundItemAction hiddenPositionRestored=true")
                    } catch {
                        await self.refreshAfterHiddenFailure(error)
                        self.verifiedPositionGroups.removeValue(forKey: id)
                        self.verifiedPositionEvidence.removeValue(forKey: id)
                        self.actualGroups.removeValue(forKey: id)
                        self.rebuildRows()
                        self.positionLayoutRecoveryNeeded = true
                        self.positionRecoveryMessage = "临时显示位置尚未恢复：\(error.localizedDescription)"
                    }
                    await self.access.discardBackgroundPositionCandidates(verificationCandidates)
                }
                await cleanup.value
            }
            if canRestore, let target = nativeRevealedTarget {
                let cleanup = Task { @MainActor in
                    do {
                        let shouldHide = !self.stopping && !self.preparingToTerminate && AXIsProcessTrusted() &&
                            self.latestNativeGroup(id: id, target: target) != .visible
                        if shouldHide { try self.rehideNativeTarget(target) }
                        else { try self.restoreNativeTarget(target) }
                        if shouldHide, let evidence = self.nativeVisibilityEvidence[id] {
                            try await self.waitForNativeVisibility(id: id, target: target,
                                identity: evidence.identity, visible: false)
                        }
                        if !shouldHide {
                            self.removeNativeEvidence(target: target)
                        }
                        Self.diagnosticLogger.notice("backgroundItemAction nativeHiddenRestored=true")
                    } catch {
                        self.removeNativeEvidence(target: target)
                        self.rebuildRows()
                        self.positionRecoveryMessage = "图标显示状态尚未恢复：\(error.localizedDescription)"
                    }
                }
                await cleanup.value
            }
            await self.access.discardBackgroundPositionCandidates(candidates)
            if let error = self.panelActivationError ?? self.positionRecoveryMessage {
                self.trayItemErrors[id] = error
            }
        }
    }

    func cancelPanelItemActivation() {
        panelActivationTask?.cancel()
    }

    func beginArrangement() {
        if isUIPreview { managementMessage = "预览不会移动真实菜单栏图标。"; return }
        guard !usesNativeVisibility else { openTraySettings(); return }
        guard !preparingToTerminate, !stopping, !isRecoveringPositions, !isActivatingPanelItem,
              !isApplying, !isRefreshing, !isArranging else { return }
        closeIconPanel()
        refreshPermissions()
        guard accessibilityGranted else { requestAccessibility(); onShowSettings?(); return }
        guard !isRefreshing, !isRecoveringPositions else { return }
        refreshEnvironment()
        guard environmentIssue == nil else {
            managementError = "请先退出其他菜单栏整理器，再使用菜单栏拖拽分组。"
            onShowSettings?()
            return
        }
        guard usesPositionHiding else { enterArrangement(); return }
        cancelPassiveIconCapture()
        let recoveryGeneration = beginPositionRecovery()
        managementError = nil
        managementMessage = "正在恢复原始位置并确认拖拽分界…"
        workTask = Task {
            defer {
                finishPositionRecovery(recoveryGeneration)
                applyState()
            }
            do {
                await passiveIconCaptureTask?.value
                try Task.checkCancellation()
                guard !stopping, !preparingToTerminate, accessibilityGranted,
                      positionStore.pendingTransactions.isEmpty,
                      positionStore.recoveryJournalIssue == nil,
                      positionStore.hiddenLedgerRecoveryIssue == nil,
                      !positionLayoutRecoveryNeeded else {
                    throw MenuTidyManagementError.positionApplication("仍有未完成的位置恢复，请先处理恢复记录，再开始拖拽。")
                }
                // Restore only our last written values. An external edit is a
                // conflict, not permission to replace the user's current order.
                let result = try positionStore.restoreAllHidden()
                try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
                verifiedPositionGroups.removeAll()
                verifiedPositionEvidence.removeAll()
                actualGroups.removeAll()
                rebuildRows()
                guard result.isComplete else {
                    throw MenuTidyManagementError.positionApplication("部分位置已被外部修改，已保留恢复记录，没有覆盖这些修改。")
                }
                try Task.checkCancellation()
                guard !stopping, !preparingToTerminate, accessibilityGranted else { throw MenuBarAccessError.cancelled }
                try await prepareNativeArrangementBoundaries()
                try Task.checkCancellation()
                guard !stopping, !preparingToTerminate, accessibilityGranted,
                      positionRecoveryGeneration == recoveryGeneration else { throw MenuBarAccessError.cancelled }
                positionRecoveryMessage = nil
                enterArrangement()
            } catch {
                await refreshAfterHiddenFailure(error)
                guard !stopping, !preparingToTerminate,
                      positionRecoveryGeneration == recoveryGeneration else { return }
                managementMessage = nil
                positionRecoveryMessage = "拖拽前的位置或分界准备未完成：\(error.localizedDescription)"
                managementError = positionRecoveryMessage
            }
        }
    }

    private func enterArrangement() {
        arrangementSequence += 1
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        managementError = nil
        managementMessage = "按住 ⌘ 拖动图标：「常隐」左侧始终隐藏；「常隐」与「收起」之间收起后隐藏；「收起」右侧常驻。拖好后点击「···」完成并收起。"
        state.beginArrangement()
        applyState()
    }

    private func prepareNativeArrangementBoundaries() async throws {
        guard let statusBar else { throw MenuBarAccessError.disappeared }
        // The recovery latch still owns this preparation. Only short, labeled
        // owned markers are shown; the user's dragging session starts later.
        statusBar.apply(collapsed: false, arranging: true)
        try await statusBar.refreshPreferredPositions()
        try await scanManagementAnchors()
        let ids = try anchorIDs()
        guard Set([ids.control, ids.regular, ids.always]).count == 3 else { throw MenuBarAccessError.disappeared }
        let candidates = try await access.prepareBackgroundPositionCandidates(
            ids: [ids.control, ids.regular, ids.always], positions: positionStore.readPositions(),
            owners: menuBarScanInputs().owners)
        defer { Task { await access.discardBackgroundPositionCandidates(candidates) } }
        let expected = [ids.control: ManualArrangementBoundaryPolicy.controlKey,
                        ids.regular: ManualArrangementBoundaryPolicy.regularKey,
                        ids.always: ManualArrangementBoundaryPolicy.alwaysKey]
        guard candidates.count == 3, Set(candidates.map(\.id)).count == 3,
              candidates.allSatisfy({ candidate in
                  expected[candidate.id] == candidate.key && candidate.processIdentifier == getpid() &&
                      candidate.bundleIdentifier == Bundle.main.bundleIdentifier
              }), let moves = ManualArrangementBoundaryPolicy.moves(positions: try positionStore.readPositions()) else {
            throw MenuBarAccessError.disappeared
        }
        let byKey = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0) })
        for move in moves {
            try Task.checkCancellation()
            guard let source = byKey[move.key], let anchor = byKey[move.beforeKey] else {
                throw MenuBarAccessError.disappeared
            }
            try await performStoredPositionMove(source, before: anchor, validating: candidates) {
                try await self.verifyNativeArrangementBoundaries(ids: [source.id, anchor.id])
            }
        }
        try await access.validateBackgroundPositionCandidates(candidates,
            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
        try await verifyNativeArrangementBoundaries(ids: [ids.always, ids.regular, ids.control])
        try await access.validateBackgroundPositionCandidates(candidates,
            positions: positionStore.readPositions(), owners: menuBarScanInputs().owners)
    }

    private func verifyNativeArrangementBoundaries(ids: [String]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var previous: [CGRect]?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard !stopping, !preparingToTerminate, accessibilityGranted else { throw MenuBarAccessError.cancelled }
            try await scanNow()
            var frames: [CGRect] = []
            for id in ids {
                let matches = snapshots.filter { $0.id == id && $0.processIdentifier == getpid() &&
                    $0.ownIdentifier != nil && $0.hasReliableGeometry }
                guard matches.count == 1 else { break }
                let inspection = await access.inspectVisibility(id: id)
                guard inspection.hasEntry, inspection.centerHit, let frame = inspection.frame else { break }
                frames.append(frame)
            }
            let valid = frames.count == ids.count && ManualArrangementBoundaryPolicy.orderedFrames(frames) &&
                frames.dropFirst().allSatisfy { sameDisplay(frames[0], $0) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if valid, previous == frames { return }
            previous = valid ? frames : nil
            try await Task.sleep(for: .milliseconds(120))
        }
        throw MenuTidyManagementError.positionApplication("自有分界的实际位置尚未确认。请在主菜单栏留出空间后重试；尚未进入拖拽整理。")
    }

    /// Native dragging belongs to macOS. We only read the settled positions;
    /// never run synthetic moves or acquire the automated overflow pointer lease.
    func finishArrangement() {
        if isUIPreview { return }
        guard !preparingToTerminate, !stopping, !isRecoveringPositions,
              isArranging, !isApplying, !isRefreshing else { return }
        refreshPermissions()
        guard isArranging, accessibilityGranted else { return }
        refreshEnvironment()
        guard environmentIssue == nil else {
            managementError = "检测到其他菜单栏整理器，请退出它后再完成拖拽。"
            applyState()
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            managementError = "请松开鼠标后，再点击「完成拖拽并收起」。"
            return
        }
        let sequence = arrangementSequence
        isRefreshing = true
        managementError = nil
        managementMessage = "正在确认拖拽后的分组位置…"
        applyState()
        workTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.arrangementSequence == sequence {
                    self.isRefreshing = false
                    self.applyState()
                }
            }
            var nativeGroupsConfirmed = false
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await self.scanNow()
                let first = try self.manualArrangementObservation()
                try await Task.sleep(for: .milliseconds(200))
                try await self.scanNow()
                let second = try self.manualArrangementObservation()
                guard !Task.isCancelled, !self.stopping, self.isArranging,
                      self.arrangementSequence == sequence, AXIsProcessTrusted(),
                      NSEvent.pressedMouseButtons == 0 else { throw MenuBarAccessError.cancelled }
                let confirmed = second.values.filter { first[$0.id]?.visibility == $0.visibility }
                let merged = ManualArrangementRules.reconcile(saved: self.rules, drafts: self.drafts,
                                                              observed: Array(confirmed))
                self.rules = merged.saved
                self.drafts = merged.drafts
                self.persistRules()
                for rule in confirmed {
                    self.pendingDrafts.removeVerified(rule, sessionIdentity: self.draftSessionIdentity(for: rule.id))
                }
                self.persistDrafts()
                // Native placement remains authoritative for the always-hidden
                // boundary, even for unidentifiable/session-only overflow items.
                self.usesNativeAlwaysSection = true
                self.defaults.set(true, forKey: "usesNativeAlwaysSection")
                self.hasCompletedSetup = true
                self.defaults.set(true, forKey: "hasCompletedSetup")
                nativeGroupsConfirmed = true
                self.temporarilyRevealingAll = false
                self.state.finishArrangement(collapse: true)
                self.rebuildRows()
                if self.usesPositionHiding {
                    self.isArranging = false
                    self.applyState()
                    _ = try await self.applyPositionHidingRules(requestedIDs: confirmed.map(\.id),
                        confirmedRules: Array(confirmed))
                }
                if self.screenCaptureGranted {
                    do { try await self.prepareIconImages() }
                    catch { self.panelError = error.localizedDescription }
                }
                guard !Task.isCancelled, !self.stopping, self.arrangementSequence == sequence else { return }
                let available = self.items.filter { $0.isAvailable && $0.canMove }.count
                let unknown = max(0, available - confirmed.count)
                self.managementMessage = "\(confirmed.count) 个图标分类已确认并同步。" +
                    (unknown > 0 ? "另有 \(unknown) 个图标位置未确认，保留原有记录。" : "") +
                    (self.hasPendingChanges ? "界面中尚未应用的选择已保留。" : "")
            } catch {
                guard !Task.isCancelled, !self.stopping, self.arrangementSequence == sequence else { return }
                self.managementError = nativeGroupsConfirmed
                    ? "拖拽分类已确认并保存，但后台隐藏尚未完成：\(error.localizedDescription) 可在管理页重试应用；未提交的界面草稿仍保留。"
                    : "暂时无法确认拖拽结果：\(error.localizedDescription) 请确认从左到右为「常隐」「收起」「···」，空间不足时打开系统溢出区，再重试完成；也可保持全部展开退出。"
                self.managementMessage = nil
            }
        }
    }

    private func manualArrangementObservation() throws -> [String: ItemRule] {
        guard NSEvent.pressedMouseButtons == 0 else { throw MenuBarAccessError.cancelled }
        let ids = try anchorIDs()
        guard let always = snapshots.first(where: { $0.id == ids.always }),
              let regular = snapshots.first(where: { $0.id == ids.regular }),
              let control = snapshots.first(where: { $0.id == ids.control }),
              always.hasReliableGeometry, regular.hasReliableGeometry, control.hasReliableGeometry,
              always.frame.maxX <= regular.frame.minX + 1,
              regular.frame.maxX <= control.frame.minX + 1,
              abs(always.frame.midY - regular.frame.midY) < 8,
              abs(control.frame.midY - regular.frame.midY) < 8,
              sameDisplay(always.frame, regular.frame), sameDisplay(control.frame, regular.frame) else {
            throw MenuBarAccessError.invalidGeometry
        }
        var observed: [String: ItemRule] = [:]
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        for item in snapshots where item.ownIdentifier == nil && item.canMove &&
            item.bundleIdentifier != Bundle.main.bundleIdentifier && counts[item.id] == 1 &&
            item.hasReliableGeometry && abs(item.frame.midY - regular.frame.midY) < 8 &&
            sameDisplay(item.frame, regular.frame) {
            guard !item.frame.intersects(always.frame), !item.frame.intersects(regular.frame),
                  !item.frame.intersects(control.frame) else { continue }
            let group: ItemVisibility = item.frame.minX < always.frame.minX ? .alwaysHidden :
                (item.frame.minX < regular.frame.minX ? .collapsible : .visible)
            observed[item.id] = ItemRule(id: item.id, name: item.name,
                                        bundleIdentifier: item.bundleIdentifier, visibility: group)
        }
        return observed
    }

    func leaveArrangementExpanded() {
        if isUIPreview { return }
        guard !preparingToTerminate, !stopping, !isRecoveringPositions, isArranging else { return }
        arrangementSequence += 1
        workTask?.cancel()
        isRefreshing = false
        state.finishArrangement(collapse: false)
        beforeTemporaryRevealCollapsed = false
        temporarilyRevealingAll = true
        managementError = nil
        managementMessage = "已退出拖拽并保持全部展开。原生拖动的位置不会撤销，未确认的分类没有写入规则。"
        applyState()
    }

    func recoverVisibility() {
        if isUIPreview { return }
        if usesNativeVisibility {
            guard !preparingToTerminate, !stopping else { return }
            statusBar?.restoreControlVisibility()
            trayDiscoveryNeeded = true
            return
        }
        if usesPositionHiding {
            needsPositionRevalidation = true
            guard !preparingToTerminate, !stopping, !isRecoveringPositions, !isActivatingPanelItem,
                  !isApplying, !isRefreshing, !isArranging, accessibilityGranted else { return }
            needsPositionRevalidation = false
            closeIconPanel()
            statusBar?.restoreControlVisibility()
            verifiedPositionGroups.removeAll()
            verifiedPositionEvidence.removeAll()
            actualGroups.removeAll()
            rebuildRows()
            temporarilyRevealingAll = false
            beforeTemporaryRevealCollapsed = nil
            state.collapse()
            applyState()
            refreshMenuItems()
            return
        }
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying else { return }
        closeIconPanel()
        if isArranging { leaveArrangementExpanded() }
        if !temporarilyRevealingAll { beforeTemporaryRevealCollapsed = state.mode == .collapsed }
        temporarilyRevealingAll = true
        state.expand()
        statusBar?.restoreControlVisibility()
        applyState()
    }
    private func collapseIfSafe() {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, (usesIndependentTray || statusBar?.validateOrder() != false) else { return }
        state.collapse()
        applyState()
    }
    private func applyState() {
        isCollapsed = state.mode == .collapsed
        isArranging = state.mode == .arranging
        statusBar?.apply(collapsed: isCollapsed, arranging: isArranging)
        resetIdleTime()
        scheduleVisibilityDiagnostics()
    }

    private func cancelVisibilityDiagnostics() {
        visibilityDiagnosticSequence += 1
        visibilityDiagnosticTask?.cancel()
        visibilityDiagnosticTask = nil
    }

    private func visibilityDiagnosticIsCurrent(_ sequence: Int) -> Bool {
        !Task.isCancelled && !stopping && !visibilityDiagnosticsStopped && accessibilityGranted &&
            !isActivatingPanelItem && !isApplying && !isRefreshing && !isArranging && visibilityDiagnosticSequence == sequence
    }

    private func scheduleVisibilityDiagnostics() {
        cancelVisibilityDiagnostics()
        let sequence = visibilityDiagnosticSequence
        guard visibilityDiagnosticIsCurrent(sequence) else { return }
        let stateDescription = "collapsed=\(isCollapsed) arranging=\(isArranging) temporaryReveal=\(temporarilyRevealingAll)"
        // Inspect only accepted rules and our fixed anchors. The anonymous rule
        // ordinal is local to this snapshot; names and identifiers are not logged.
        var targets: [(id: String?, label: String, group: String, snapshotMatches: Int)] = rules.rules.values
            .sorted { $0.id < $1.id }
            .enumerated().map { index, rule in
                (rule.id, "saved-rule-\(index + 1)", rule.visibility.rawValue,
                 snapshots.filter { $0.id == rule.id }.count)
            }
        for identifier in Self.ownAnchorIdentifiers {
            let matches = snapshots.filter { $0.ownIdentifier == identifier }
            targets.append((matches.count == 1 ? matches[0].id : nil, identifier, "anchor", matches.count))
        }
        visibilityDiagnosticTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard let self, self.visibilityDiagnosticIsCurrent(sequence) else { return }
            defer {
                if self.visibilityDiagnosticSequence == sequence { self.visibilityDiagnosticTask = nil }
            }
            for target in targets {
                guard self.visibilityDiagnosticIsCurrent(sequence) else { return }
                let inspection: MenuBarVisibilityInspection?
                if let id = target.id { inspection = await self.access.inspectVisibility(id: id) }
                else { inspection = nil }
                // An AX read already in flight may finish after a new toggle.
                // Suppress its result rather than attributing it to the new state.
                guard self.visibilityDiagnosticIsCurrent(sequence) else { return }
                let frameDescription = inspection?.frame.map { NSStringFromRect($0) } ?? "unavailable"
                let hasEntry = inspection?.hasEntry ?? false
                let hasFrame = inspection?.hasFrame ?? false
                let centerHit = inspection?.centerHit ?? false
                Self.diagnosticLogger.notice("visibilityInspection sequence=\(sequence) state=[\(stateDescription, privacy: .public)] target=\(target.label, privacy: .public) group=\(target.group, privacy: .public) snapshotMatches=\(target.snapshotMatches) hasEntry=\(hasEntry) hasFrame=\(hasFrame) frame=\(frameDescription, privacy: .public) centerHit=\(centerHit)")
            }
        }
    }
    private func resetIdleTime() { lastInteraction = ProcessInfo.processInfo.systemUptime }
    private func checkAutoCollapse() {
        let pointer = NSEvent.mouseLocation
        let pointerInMenuBar = NSScreen.screens.contains { screen in
            let menuHeight = max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            return NSRect(x: screen.frame.minX, y: screen.frame.maxY - menuHeight, width: screen.frame.width, height: menuHeight).contains(pointer)
        }
        let buttonDown = NSEvent.pressedMouseButtons != 0
        let pointerInPanel = isPanelPresented && iconPanelContains(pointer)
        let paused = (settingsVisible && !isPanelPresented) || contextMenuVisible || isApplying || isRefreshing ||
            isActivatingPanelItem ||
            pointerInPanel || temporarilyRevealingAll || !hasCompletedSetup
        if pointerInMenuBar || buttonDown || paused { resetIdleTime() }
        if AutoCollapsePolicy(delay: autoCollapseDelay).shouldCollapse(elapsed: ProcessInfo.processInfo.systemUptime - lastInteraction,
            isExpanded: isPanelPresented || !isCollapsed, isArranging: isArranging, isPaused: paused, pointerInMenuBar: pointerInMenuBar,
            mouseButtonDown: buttonDown, enabled: autoCollapseEnabled) {
            if isPanelPresented { closeIconPanel() }
            if !isCollapsed { collapseIfSafe() }
        }
    }
    private func configureShortcut() {
        guard !isUIPreview else { return }
        shortcutIssue = nil
        if shortcutEnabled { shortcutIssue = shortcut.register() } else { shortcut.unregister() }
    }
    private func refreshEnvironment() {
        let managerNames: Set<String> = ["Barbee", "Bartender", "Bartender 7", "Bartender 6", "Ice", "Hidden Bar", "Hidden", "Dozer"]
        let active = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName)).intersection(managerNames).sorted()
        environmentIssue = active.isEmpty ? nil : "检测到 \(active.joined(separator: "、")) 正在运行。应用分类前请先退出其他整理器，避免重复控制图标。"
    }
    func refreshLoginStatus() {
        guard !isUIPreview else { return }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        if loginIssue == "请在系统设置的登录项中允许 Menu Tidy。" { loginIssue = nil }
        if SMAppService.mainApp.status == .requiresApproval { loginIssue = "请在系统设置的登录项中允许 Menu Tidy。" }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        if isUIPreview { launchAtLoginEnabled = enabled; return }
        loginIssue = nil
        if demoMode { loginIssue = "演示模式不修改登录项。"; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginIssue = "登录项设置未生效：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func showSystemLoginSettings() { if !isUIPreview { SMAppService.openSystemSettingsLoginItems() } }
    var requiresTerminationCleanup: Bool {
        !isUIPreview && (preparingToTerminate || isApplying || isRefreshing || isRecoveringPositions || trayPlacementTask != nil ||
            panelActivationTask != nil || passiveIconCaptureTask != nil ||
            !positionStore.managedHiddenEntries.isEmpty || !positionStore.pendingTransactions.isEmpty ||
            positionLayoutRecoveryNeeded || !nativeVisibilityStore.managedBundles.isEmpty ||
            !nativeSystemVisibilityStore.managedKeys.isEmpty || nativeRecoveryIssue != nil)
    }

    func quit() { NSApp.terminate(nil) }

    func prepareForTermination() async -> Bool {
        if isUIPreview { return true }
        preparingToTerminate = true
        // Hold the shared operation gate across every suspension in cleanup.
        // An older task's defer may clear its own busy flag, but its recovery
        // generation cannot unlock this newer one and admit another mutation.
        let recoveryGeneration = beginPositionRecovery()
        let previousWork = workTask
        let previousActivation = panelActivationTask
        let previousCapture = passiveIconCaptureTask
        let previousPlacement = trayPlacementTask
        visibilityDiagnosticsStopped = true
        cancelPassiveIconCapture()
        cancelVisibilityDiagnostics()
        closeIconPanel()
        previousWork?.cancel()
        previousActivation?.cancel()
        previousPlacement?.cancel()
        trayPlacementQueue.cancelAllPending()
        await access.cancel()
        await previousWork?.value
        await previousActivation?.value
        await previousCapture?.value
        await previousPlacement?.value
        // Native recovery is independent of the legacy position journal too.
        // Always try both native owners before any earlier recovery can throw.
        let nativeRestored = restoreAllNativeTargets()
        do {
            for transaction in positionStore.pendingTransactions {
                let rollback = try positionStore.rollback(transaction)
                try await statusBar?.refreshPreferredPositions()
                guard rollback.isComplete else { throw MenuBarAccessError.rejected }
            }
            let result = try positionStore.restoreAllHidden()
            try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
            guard result.isComplete else { throw MenuBarAccessError.rejected }
            guard nativeRestored, nativeRecoveryIssue == nil else {
                throw MenuTidyManagementError.positionApplication("原生显示设置尚未恢复，请保留应用并重试恢复。")
            }
            nativeVisibilityEvidence.removeAll()
            verifiedPositionGroups.removeAll()
            positionLayoutRecoveryNeeded = false
        } catch {
            await refreshAfterHiddenFailure(error)
            preparingToTerminate = false
            visibilityDiagnosticsStopped = false
            finishPositionRecovery(recoveryGeneration)
            positionRecoveryMessage = "退出前恢复图标未完成：\(error.localizedDescription)"
            onShowSettings?()
            return false
        }
        // Keep the gate held until applicationWillTerminate. Repeated quit
        // requests must continue through AppDelegate's existing terminationTask.
        return true
    }
    func stop() {
        guard !isUIPreview else { return }
        closeIconPanel()
        controlRouter.stop()
        stopping = true
        cancelPassiveIconCapture()
        arrangementSequence += 1
        visibilityDiagnosticsStopped = true
        cancelVisibilityDiagnostics()
        workTask?.cancel()
        trayPlacementTask?.cancel()
        trayPlacementQueue.cancelAllPending()
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        shortcut.unregister()
        statusBar?.stop()
        statusBar = nil
    }
}

@MainActor
private extension MenuTidyModel {
    var nativeRecoveryIssue: String? {
        nativeVisibilityStore.pendingRecoveryIssue ?? nativeSystemVisibilityStore.pendingRecoveryIssue
    }
    var hasManagedNativeTargets: Bool {
        !nativeVisibilityStore.managedBundles.isEmpty || !nativeSystemVisibilityStore.managedKeys.isEmpty
    }

    var managedNativeTargets: Set<NativeVisibilityTarget> {
        Set(nativeVisibilityStore.managedBundles.map { .application(bundle: $0) })
            .union(nativeSystemVisibilityStore.managedKeys.map { .system(key: $0) })
    }

    func registerDepartedNativeOwners() {
        guard usesNativeVisibility else { return }
        let managed = managedNativeTargets
        nativeOwnerRecoveries.retainManagedTargets(managed)
        for evidence in nativeVisibilityEvidence.values {
            guard let target = evidence.target, managed.contains(target),
                  !Self.observedOwnerIsCurrent(evidence.identity) else { continue }
            nativeOwnerRecoveries.register(target: target, departedOwner: evidence.identity)
        }
    }

    func departedNativeTargetsReadyForRecovery() -> Set<NativeVisibilityTarget> {
        let liveTargets = Set(nativeVisibilityEvidence.values.compactMap { evidence in
            Self.observedOwnerIsCurrent(evidence.identity) ? evidence.target : nil
        })
        // Unknown process metadata is not evidence of an ended lifecycle.
        return nativeOwnerRecoveries.readyTargets(canRestore: true, liveTargets: liveTargets,
            ownerIsCurrent: { !Self.nativeOwnerHasEnded($0) })
    }

    func scheduleNativeOwnerRecoveryDiscoveryIfNeeded() {
        guard usesNativeVisibility, !preparingToTerminate, !stopping,
              positionRecoveryMessage == nil,
              !departedNativeTargetsReadyForRecovery().isEmpty else { return }
        // This Boolean is coalesced with normal application discovery. Failed
        // targets are excluded by the queue and cannot create a retry loop.
        trayDiscoveryNeeded = true
    }

    /// Runs synchronously inside the existing exclusive refresh operation.
    /// Restores only receipt-owned preferences; it never adopts the new owner.
    func restoreDepartedNativeOwnersBeforeScan() {
        guard usesNativeVisibility else { return }
        var failed = false
        let targets = departedNativeTargetsReadyForRecovery()
        for target in targets {
            // External process lifetimes may change between two store writes.
            // Recheck immediately before each independent conditional restore.
            guard nativeTargetIsManaged(target),
                  departedNativeTargetsReadyForRecovery().contains(target) else { continue }
            do {
                try reloadNativeRecoveryJournalIfNeeded(for: target)
                try restoreNativeTarget(target)
                guard !nativeTargetIsManaged(target) else { throw MenuBarAccessError.rejected }
                nativeOwnerRecoveries.complete(target: target)
                removeNativeEvidence(target: target)
                Self.diagnosticLogger.notice("nativeOwnerRecovery restored=true departedEpochConfirmed=true")
            } catch {
                nativeOwnerRecoveries.recordFailure(target: target)
                failed = true
                Self.diagnosticLogger.notice("nativeOwnerRecovery restored=false explicitRecoveryRequired=true")
            }
        }
        nativeOwnerRecoveries.retainManagedTargets(managedNativeTargets)
        if failed {
            positionRecoveryMessage = "应用重新启动后，部分图标的原显示设置尚未恢复。恢复记录已保留，请点击“重试恢复”；不会自动反复重试。"
            recheckNativeVisibilityAccess()
        }
    }

    static func nativeOwnerHasEnded(_ identity: ObservedItemGroupHistory.Identity) -> Bool {
        guard identity.pid > 0, identity.launchTime.isFinite, identity.launchTime > 0 else { return false }
        if let app = NSRunningApplication(processIdentifier: identity.pid) {
            if app.isTerminated { return true }
            guard let currentLaunch = MenuBarProcessIdentity.launchTime(for: app) else { return false }
            if currentLaunch != identity.launchTime { return true }
            guard let currentBundle = app.bundleIdentifier, let previousBundle = identity.bundleIdentifier else { return false }
            return currentBundle != previousBundle
        }
        // Signal zero only tests process existence. EPERM and other failures
        // remain unknown; only ESRCH proves that this PID no longer exists.
        return kill(identity.pid, 0) == -1 && errno == ESRCH
    }

    func nativeTarget(for source: MenuBarItemSnapshot) async -> NativeVisibilityTarget? {
        if let key = await access.nativeSystemVisibilityKey(id: source.id) { return .system(key: key) }
        guard let bundle = source.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              !bundle.lowercased().hasPrefix("com.apple."), bundle.lowercased() != "com.apple" else { return nil }
        return .application(bundle: bundle)
    }

    func nativeTargetIsManaged(_ target: NativeVisibilityTarget) -> Bool {
        switch target {
        case .application(let bundle): nativeVisibilityStore.managedBundles.contains(bundle)
        case .system(let key): nativeSystemVisibilityStore.managedKeys.contains(key)
        }
    }
    func nativeTargetIsRevealed(_ target: NativeVisibilityTarget) -> Bool {
        switch target {
        case .application(let bundle): nativeVisibilityStore.isTemporarilyRevealed(bundle: bundle)
        case .system(let key): nativeSystemVisibilityStore.isTemporarilyRevealed(key: key)
        }
    }
    func nativeAllowed(_ target: NativeVisibilityTarget) throws -> Bool {
        switch target {
        case .application(let bundle): try nativeVisibilityStore.readAllowed(bundle: bundle)
        case .system(let key): try nativeSystemVisibilityStore.readAllowed(key: key)
        }
    }
    func hideNativeTarget(_ target: NativeVisibilityTarget) throws -> Bool {
        switch target {
        case .application(let bundle): try nativeVisibilityStore.hide(bundle: bundle)
        case .system(let key): try nativeSystemVisibilityStore.hide(key: key)
        }
    }
    func temporarilyRevealNativeTarget(_ target: NativeVisibilityTarget) throws {
        switch target {
        case .application(let bundle): try nativeVisibilityStore.temporarilyReveal(bundle: bundle)
        case .system(let key): try nativeSystemVisibilityStore.temporarilyReveal(key: key)
        }
    }
    func rehideNativeTarget(_ target: NativeVisibilityTarget) throws {
        switch target {
        case .application(let bundle): try nativeVisibilityStore.rehide(bundle: bundle)
        case .system(let key): try nativeSystemVisibilityStore.rehide(key: key)
        }
    }
    func restoreNativeTarget(_ target: NativeVisibilityTarget) throws {
        switch target {
        case .application(let bundle): try nativeVisibilityStore.restore(bundle: bundle)
        case .system(let key): try nativeSystemVisibilityStore.restore(key: key)
        }
    }
    func reloadNativeRecoveryJournalIfNeeded(for target: NativeVisibilityTarget) throws {
        switch target {
        case .application:
            if nativeVisibilityStore.pendingRecoveryIssue != nil { try nativeVisibilityStore.reloadForRecovery() }
        case .system:
            if nativeSystemVisibilityStore.pendingRecoveryIssue != nil { try nativeSystemVisibilityStore.reloadForRecovery() }
        }
    }
    func reloadAllNativeRecoveryJournalsIfNeeded() -> Bool {
        // Each store retains its own reload failure. Never let one unreadable
        // journal stop restoration of the other store's verified ownership.
        var succeeded = true
        do {
            if nativeVisibilityStore.pendingRecoveryIssue != nil { try nativeVisibilityStore.reloadForRecovery() }
        } catch { succeeded = false }
        do {
            if nativeSystemVisibilityStore.pendingRecoveryIssue != nil { try nativeSystemVisibilityStore.reloadForRecovery() }
        } catch { succeeded = false }
        return succeeded
    }
    func restoreAllNativeTargets() -> Bool {
        let reloadsSucceeded = reloadAllNativeRecoveryJournalsIfNeeded()
        let applications = nativeVisibilityStore.restoreAll()
        let systems = nativeSystemVisibilityStore.restoreAll()
        nativeOwnerRecoveries.retainManagedTargets(managedNativeTargets)
        if !systems.isEmpty { recheckNativeVisibilityAccess() }
        return reloadsSucceeded && applications.isEmpty && systems.isEmpty && nativeRecoveryIssue == nil
    }
    func latestNativeGroup(id: String, target: NativeVisibilityTarget) -> ItemVisibility {
        if case .application(let bundle) = target, let group = nativeTrayChoices.group(bundle: bundle) { return group }
        return items.first(where: { $0.id == id })?.group ?? rules.rule(for: id)?.visibility ?? .visible
    }
    func removeNativeEvidence(target: NativeVisibilityTarget) {
        for (id, evidence) in nativeVisibilityEvidence where evidence.target == target {
            nativeVisibilityEvidence.removeValue(forKey: id)
            actualGroups.removeValue(forKey: id)
        }
        if !nativeTargetIsManaged(target) { nativeOwnerRecoveries.complete(target: target) }
    }

    func reconcileNativeVisibilityEvidence() async {
        var confirmed: [String: NativeVisibilityEvidence] = [:]
        for (id, evidence) in nativeVisibilityEvidence {
            guard Self.observedOwnerIsCurrent(evidence.identity),
                  let snapshot = snapshots.first(where: { $0.id == id }),
                  observedItemIdentity(snapshot) == evidence.identity else { continue }
            // An unmanaged item's positive observation is not a durable
            // native preference proof. Refresh verifies it again when requested.
            guard let target = evidence.target else {
                if evidence.group == .visible, await inspectUnmanagedNativeVisibility(snapshot) == true {
                    confirmed[id] = evidence
                }
                continue
            }
            guard let allowed = try? nativeAllowed(target) else { continue }
            if nativeTargetIsRevealed(target) {
                if isActivatingPanelItem && evidence.group != .visible { confirmed[id] = evidence }
            } else if allowed == (evidence.group == .visible) { confirmed[id] = evidence }
        }
        // Positive-only checks above can suspend. Catch a departure during
        // those reads before replacing the last evidence for that owner epoch.
        registerDepartedNativeOwners()
        scheduleNativeOwnerRecoveryDiscoveryIfNeeded()
        nativeVisibilityEvidence = confirmed
    }

    func inspectUnmanagedNativeVisibility(_ source: MenuBarItemSnapshot) async -> Bool? {
        if source.bundleIdentifier?.hasPrefix("com.apple.") == true {
            return await access.inspectNativeVisibleSystemItem(id: source.id)
        }
        return await access.inspectNativeVisibility(id: source.id)
    }

    func applyNativeVisibilityRules(requestedIDs: [String], confirmedRules: [ItemRule]?) async throws -> Bool {
        recheckNativeVisibilityAccess()
        if let issue = nativeChoicesLoadIssue { throw MenuTidyManagementError.positionApplication(issue) }
        guard !needsLegacyPositionRecovery else {
            throw MenuTidyManagementError.positionApplication("旧版隐藏位置仍待恢复，请先完成排序恢复再启用原生隐藏。")
        }
        var appConflicts: Set<String> = []
        var systemConflicts: Set<String> = []
        // An empty unrelated backend owns nothing to recover and must not
        // require its separate file authorization before this target can run.
        if !nativeVisibilityStore.managedBundles.isEmpty || nativeVisibilityStore.pendingRecoveryIssue != nil {
            appConflicts = try nativeVisibilityStore.recoverPendingWrites()
        }
        if !nativeSystemVisibilityStore.managedKeys.isEmpty || nativeSystemVisibilityStore.pendingRecoveryIssue != nil {
            systemConflicts = try nativeSystemVisibilityStore.recoverPendingWrites()
        }
        guard appConflicts.isEmpty, systemConflicts.isEmpty else {
            positionRecoveryMessage = "上次图标显示设置已被其他操作改变，恢复记录已保留；请先重试恢复。"
            throw MenuBarAccessError.rejected
        }
        try await scanNow()
        let requested = Set(requestedIDs)
        let displayed = items.filter { requested.contains($0.id) && $0.canMove && $0.isAvailable }.map {
            ItemRule(id: $0.id, name: $0.name, bundleIdentifier: $0.bundleIdentifier, visibility: $0.group)
        }
        guard let targets = ManualArrangementRules.applicationRules(requestedIDs: requestedIDs,
            displayed: displayed, confirmed: confirmedRules) else { throw MenuBarAccessError.disappeared }
        var attempted = NativeVisibilityAttemptLedger<NativeVisibilityTarget>()
        for rule in targets {
            try checkOperationDeadline()
            let targetStarted = ProcessInfo.processInfo.systemUptime
            var cleanupTarget: NativeVisibilityTarget?
            var affectedIDs: Set<String> = [rule.id]
            do {
                guard let source = snapshots.first(where: { $0.id == rule.id }),
                      let identity = observedItemIdentity(source), Self.observedOwnerIsCurrent(identity) else {
                    throw MenuBarAccessError.disappeared
                }
                let discoveredTarget = await nativeTarget(for: source)
                if rule.visibility == .visible,
                   discoveredTarget.map({ !nativeTargetIsManaged($0) }) ?? true {
                    // Keeping an already unmanaged item visible needs no
                    // preference lookup, ownership, parent-bundle inference or
                    // authorization for a backend that will not be written.
                    guard items.first(where: { $0.id == rule.id })?.group == rule.visibility else { continue }
                    guard await inspectUnmanagedNativeVisibility(source) == true,
                          Self.observedOwnerIsCurrent(identity) else {
                        throw MenuTidyManagementError.positionApplication("尚未确认此图标当前可见，未改变系统设置。")
                    }
                    confirmNativeRule(rule, identity: identity, target: nil)
                    continue
                }
                guard let target = discoveredTarget else {
                    throw MenuTidyManagementError.positionApplication("此系统图标尚无经过验证的独立隐藏方式，当前保留在菜单栏。")
                }
                // A newer click already superseded this queued rule; its own
                // queued request owns the next mutation and draft consumption.
                guard latestNativeGroup(id: rule.id, target: target) == rule.visibility else { continue }
                // Failure owns this attempt too. Another sibling must not
                // silently repeat a rejected hide/restore within the same batch.
                guard attempted.claim(target) else { continue }
                let affected: [MenuBarItemSnapshot]
                switch target {
                case .application(let bundle):
                    affected = snapshots.filter { $0.canMove && $0.ownIdentifier == nil && $0.bundleIdentifier == bundle }
                    affectedIDs = Set(affected.map(\.id))
                    guard nativeVisibilityAccessAvailable else {
                        throw MenuTidyManagementError.positionApplication("请先授权菜单栏显示设置文件，之后即可收进托盘。当前选择已保存。")
                    }
                    let siblings = items.filter { $0.isAvailable && $0.canMove && $0.bundleIdentifier == bundle }
                    guard siblings.allSatisfy({ ($0.group == .visible) == (rule.visibility == .visible) }) else {
                        throw MenuTidyManagementError.positionApplication("同一应用的多个图标共用显示开关，请统一选择常驻或托盘。")
                    }
                case .system(let key):
                    guard nativeSystemVisibilityStore.accessAvailable(key: key) else {
                        nativeSystemVisibilityAccessNeeded = true
                        nativeSystemVisibilityAccessMessage = "需要允许访问 AirDrop 的菜单栏显示设置，当前选择已保留。"
                        throw MenuTidyManagementError.positionApplication("请先点击页面上的“授权 AirDrop 显示设置”，然后重试此图标。")
                    }
                    affected = [source]
                }
                affectedIDs = Set(affected.map(\.id))
                guard !affected.isEmpty, affectedIDs.count == affected.count else { throw MenuBarAccessError.disappeared }
                let identities = affected.compactMap { item -> (MenuBarItemSnapshot, ObservedItemGroupHistory.Identity)? in
                    guard let observed = observedItemIdentity(item), Self.observedOwnerIsCurrent(observed) else { return nil }
                    return (item, observed)
                }
                guard identities.count == affected.count else { throw MenuBarAccessError.disappeared }
                managementMessage = "正在更新「\(rule.name)」的显示位置…"
                if rule.visibility == .visible {
                    cleanupTarget = target
                    try restoreNativeTarget(target)
                    guard try nativeAllowed(target) else {
                        throw MenuTidyManagementError.positionApplication("此图标已在系统设置中被关闭。请先允许它显示在菜单栏，再连接托盘。")
                    }
                } else {
                    if !nativeTargetIsManaged(target) {
                        for item in affected { try await access.validateItemActionSupport(id: item.id) }
                    }
                    // Set cleanup before a store call that can throw after its
                    // preference write but before its receipt is committed.
                    cleanupTarget = target
                    guard try hideNativeTarget(target) else {
                        throw MenuTidyManagementError.positionApplication("此图标原本已被系统设置隐藏。请先允许它显示，再连接托盘。")
                    }
                }
                for (item, observed) in identities {
                    try await waitForNativeVisibility(id: item.id, target: target,
                        identity: observed, visible: rule.visibility == .visible)
                }
                guard identities.allSatisfy({ Self.observedOwnerIsCurrent($0.1) }) else { throw MenuBarAccessError.disappeared }
                for (item, observed) in identities {
                    confirmNativeRule(ItemRule(id: item.id, name: item.name, bundleIdentifier: item.bundleIdentifier,
                        visibility: rule.visibility), identity: observed, target: target)
                }
                cleanupTarget = nil
                let targetElapsed = ProcessInfo.processInfo.systemUptime - targetStarted
                Self.diagnosticLogger.notice("nativeVisibility classificationConfirmed=true hidden=\(rule.visibility != .visible) itemCount=\(identities.count) elapsedSeconds=\(targetElapsed)")
            } catch {
                if let target = cleanupTarget {
                    let recovery = Task { @MainActor in
                        do {
                            try self.reloadNativeRecoveryJournalIfNeeded(for: target)
                            try self.restoreNativeTarget(target)
                        } catch {
                            self.positionRecoveryMessage = "未完成的隐藏操作仍待恢复：\(error.localizedDescription)"
                        }
                    }
                    await recovery.value
                    removeNativeEvidence(target: target)
                }
                for id in affectedIDs {
                    nativeVisibilityEvidence.removeValue(forKey: id)
                    actualGroups.removeValue(forKey: id)
                    itemApplicationIssues[id] = error.localizedDescription
                }
                if Task.isCancelled || positionRecoveryMessage != nil { throw error }
            }
        }
        hasCompletedSetup = true
        defaults.set(true, forKey: "hasCompletedSetup")
        return true
    }

    func confirmNativeRule(_ rule: ItemRule, identity: ObservedItemGroupHistory.Identity, target: NativeVisibilityTarget?) {
        nativeVisibilityEvidence[rule.id] = NativeVisibilityEvidence(identity: identity, target: target, group: rule.visibility)
        actualGroups[rule.id] = rule.visibility
        rules.set(rule)
        persistRules()
        pendingDrafts.removeVerified(rule, sessionIdentity: identity)
        persistDrafts()
        if trayPlacementGroup(id: rule.id) == rule.visibility {
            itemApplicationIssues.removeValue(forKey: rule.id)
            trayPlacementErrors.removeValue(forKey: rule.id)
            trayItemErrors.removeValue(forKey: rule.id)
        }
    }

    func waitForNativeVisibility(id: String, target: NativeVisibilityTarget,
                                 identity: ObservedItemGroupHistory.Identity, visible: Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        var consecutive = 0
        var refreshed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard !stopping, AXIsProcessTrusted(), Self.observedOwnerIsCurrent(identity),
                  snapshots.first(where: { $0.id == id }).flatMap(observedItemIdentity) == identity else {
                throw MenuBarAccessError.disappeared
            }
            let allowed = try nativeAllowed(target)
            let observed: Bool?
            switch target {
            case .application: observed = await access.inspectNativeVisibility(id: id)
            case .system(let key): observed = await access.inspectNativeSystemVisibility(id: id, key: key)
            }
            let agrees = allowed == visible && observed == visible
            consecutive = agrees ? consecutive + 1 : 0
            if consecutive >= 2 { return }
            // Native showing may replace a source or host binding. Refresh at
            // most once; a transport failure never means the target is hidden.
            if visible && observed != true && !refreshed {
                try await scanNow()
                refreshed = true
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw MenuTidyManagementError.positionApplication(visible
            ? "图标尚未在菜单栏中可操作，已停止本次打开。"
            : "系统尚未完成隐藏，已恢复图标，可重试。")
    }

    func recoverNativeVisibilityAndRefresh(reconnect: Bool = true) {
        guard restoreAllNativeTargets() else {
            positionRecoveryMessage = "上次图标显示设置尚未恢复，请重试恢复。"
            return
        }
        nativeVisibilityEvidence.removeAll()
        actualGroups.removeAll()
        positionRecoveryMessage = nil
        if !reconnect {
            for item in snapshots {
                if let identity = observedItemIdentity(item) { trayConnectionAttempts[item.id] = identity }
            }
            managementMessage = "图标已恢复显示。关闭目标菜单后，可在对应图标旁重试连接。"
        }
        if accessibilityGranted { refreshMenuItems(collapseWhenFinished: startCollapsed && hasCompletedSetup) }
    }

    func restoreNativeAfterPermissionLoss() {
        guard !preparingToTerminate, !stopping else { return }
        cancelPassiveIconCapture()
        closeIconPanel()
        let previousWork = workTask
        let previousActivation = panelActivationTask
        let generation = beginPositionRecovery()
        workTask = Task {
            defer { finishPositionRecovery(generation) }
            await previousWork?.value
            await previousActivation?.value
            let restored = restoreAllNativeTargets()
            nativeVisibilityEvidence.removeAll()
            actualGroups.removeAll()
            rebuildRows()
            if restored {
                managementError = "辅助功能权限已关闭，已恢复本应用隐藏的图标。重新授权后可继续。"
            } else {
                positionRecoveryMessage = "权限变化后仍有图标显示设置待恢复，请重试恢复。"
            }
        }
    }
}

extension MenuTidyModel {
    func requestNativeSystemVisibilityAccess() {
        if isUIPreview { nativeSystemVisibilityAccessNeeded = false; return }
        guard !panelInteractionBusy, !preparingToTerminate, !stopping else { return }
        Task {
            do {
                guard try await nativeSystemVisibilityStore.requestAccess(key: "AirDrop") else { return }
                nativeSystemVisibilityAccessNeeded = !nativeSystemVisibilityStore.accessAvailable(key: "AirDrop")
                nativeSystemVisibilityAccessMessage = nativeSystemVisibilityAccessNeeded
                    ? "AirDrop 显示设置尚不可访问，请重新检测授权。"
                    : "AirDrop 显示设置已授权，可在图标旁重试连接。"
                if !nativeSystemVisibilityAccessNeeded { rebuildRows() }
            } catch {
                nativeSystemVisibilityAccessNeeded = true
                nativeSystemVisibilityAccessMessage = error.localizedDescription
            }
        }
    }

    func recheckNativeVisibilityAccess() {
        if isUIPreview { return }
        guard usesNativeVisibility else { return }
        nativeVisibilityAccessAvailable = nativeVisibilityStore.accessAvailable
        if nativeSystemVisibilityStore.managedKeys.contains("AirDrop"),
           !nativeSystemVisibilityStore.accessAvailable(key: "AirDrop") {
            nativeSystemVisibilityAccessNeeded = true
            nativeSystemVisibilityAccessMessage = "请先授权 AirDrop 显示设置，再点击恢复图标。恢复完成前保留现有记录。"
        }
        nativeVisibilityAccessMessage = nativeVisibilityAccessAvailable
            ? "菜单栏显示设置文件可访问。选择图标后即可连接托盘。"
            : "请在系统选择窗口中确认菜单栏显示设置文件，当前分类选择会保留。"
    }

    func requestNativeVisibilityAccess() {
        if isUIPreview { nativeVisibilityAccessAvailable = true; return }
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
        Task {
            do {
                guard try await nativeVisibilityStore.requestAccess() else { return }
                recheckNativeVisibilityAccess()
                if nativeVisibilityAccessAvailable {
                    managementError = nil
                    trayConnectionAttempts.removeAll()
                    recoverNativeVisibilityAndRefresh()
                }
            } catch { nativeVisibilityAccessMessage = error.localizedDescription }
        }
    }
}

// This fixture uses the real SettingsView and the same published row state,
// while every system-facing entry point above returns before its live backend.
@MainActor
private extension MenuTidyModel {
    func configureUIPreview() {
        let needsPermissions = CommandLine.arguments.contains("--preview-permissions")
        accessibilityGranted = !needsPermissions
        nativeVisibilityAccessAvailable = !needsPermissions
        menuBarPositionAccessAvailable = !needsPermissions
        screenCaptureGranted = false
        hasCompletedSetup = true
        shortcutEnabled = false
        items = [
            previewRow("chat", "Chat", "会话与通知", "bubble.left.and.bubble.right.fill", .visible),
            previewRow("cloud", "Cloud Drive", "文件同步", "icloud.fill", .collapsible),
            previewRow("timer", "Focus Timer", "专注计时", "timer", .alwaysHidden),
            previewRow("vpn", "Work VPN", "安全连接", "network", .collapsible, pending: true),
            previewRow("sync", "Sync Helper", "同步服务", "arrow.triangle.2.circlepath", .alwaysHidden, pending: true),
            previewRow("bluetooth", "蓝牙", "系统图标", "wave.3.right", .visible, canMove: false),
            previewRow("legacy", "Legacy Helper", "保留的应用规则", "archivebox.fill", .collapsible, available: false)
        ]
        itemApplicationIssues["item:preview.sync"] = "应用暂未响应，当前显示状态尚未确认。选择已保留，可以重试。"
        for row in items where !row.isPending {
            let rule = ItemRule(id: row.id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: row.group)
            rules.set(rule)
            actualGroups[row.id] = row.group
        }
        rowDraftIDs["item:preview.vpn"] = UUID()
        let offline = try? PendingDraftStore(unassociatedRules: [
            ItemRule(id: "item:preview.offline", name: "Archive Sync", bundleIdentifier: "preview.offline", visibility: .collapsible)
        ])
        offlineDrafts = offline?.records ?? []
        previewUpdateCounts()
    }

    func previewRow(_ key: String, _ name: String, _ owner: String, _ symbol: String,
                    _ group: ItemVisibility, pending: Bool = false, canMove: Bool = true,
                    available: Bool = true) -> ManagedItemRow {
        ManagedItemRow(id: "item:preview.\(key)", name: name, ownerName: owner,
            bundleIdentifier: "preview.\(key)", icon: NSImage(systemSymbolName: symbol, accessibilityDescription: name),
            group: group, isAvailable: available, canMove: canMove,
            detail: canMove ? "" : "由 macOS 管理，请在系统设置中调整。", isPending: pending)
    }

    func previewUpdateCounts() {
        actionablePendingCount = items.filter { $0.isPending && $0.isAvailable && $0.canMove }.count
        hasPendingChanges = actionablePendingCount > 0 || !offlineDrafts.isEmpty
    }

    func previewReplacing(_ row: ManagedItemRow, group: ItemVisibility, pending: Bool) -> ManagedItemRow {
        ManagedItemRow(id: row.id, name: row.name, ownerName: row.ownerName, bundleIdentifier: row.bundleIdentifier,
            icon: row.icon, group: group, isAvailable: row.isAvailable, canMove: row.canMove,
            detail: row.detail, isPending: pending)
    }
}

@MainActor
extension MenuTidyModel {
    func previewSetGroup(id: String, group: ItemVisibility) {
        guard isUIPreview, accessibilityGranted, nativeVisibilityAccessAvailable,
              let index = items.firstIndex(where: { $0.id == id && $0.canMove && $0.isAvailable }) else { return }
        let row = items[index]
        items[index] = previewReplacing(row, group: group, pending: false)
        rules.set(ItemRule(id: id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: group))
        actualGroups[id] = group
        itemApplicationIssues.removeValue(forKey: id)
        trayPlacementErrors.removeValue(forKey: id)
        rowDraftIDs.removeValue(forKey: id)
        previewUpdateCounts()
        managementMessage = "预览：已模拟确认「\(row.name)」的显示选择。"
    }

    func previewApplyPending(retryOnly: Bool) {
        guard isUIPreview, accessibilityGranted, nativeVisibilityAccessAvailable else { return }
        let targets = items.filter { $0.isPending && $0.canMove && $0.isAvailable &&
            (!retryOnly || itemApplicationIssues[$0.id] != nil || trayPlacementErrors[$0.id] != nil) }
        for row in targets { previewSetGroup(id: row.id, group: row.group) }
        managementMessage = "预览：已模拟确认 \(targets.count) 项；离线选择继续保留。"
    }
}
