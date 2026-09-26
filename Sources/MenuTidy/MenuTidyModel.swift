import AppKit
import ApplicationServices
import Combine
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
}

private enum MenuTidyManagementError: LocalizedError {
    case anchorCount(identifier: String, count: Int)
    case positionApplication(String)

    var errorDescription: String? {
        switch self {
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
    @Published private(set) var iconImageWarning: String?
    @Published private(set) var iconImageWarningDetails: String?
    @Published private(set) var panelImages: [String: NSImage] = [:]
    @Published private(set) var panelUsesCachedImages = false
    @Published private(set) var panelLastCaptureDate: Date?
    @Published private(set) var permissionCheckMessage: String?
    @Published private(set) var menuBarPositionAccessAvailable = false
    @Published private(set) var menuBarPositionAccessMessage: String?
    @Published private(set) var positionRecoveryMessage: String?
    @Published private(set) var isRecoveringPositions = false
    @Published private(set) var isRefreshing = false { didSet { if isRefreshing { cancelPassiveIconCapture() } } }
    @Published private(set) var isApplying = false { didSet { if isApplying { cancelPassiveIconCapture() } } }
    @Published private(set) var managementMessage: String?
    @Published private(set) var managementError: String?
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
    private let positionStore = MenuBarPositionStore()
    private let positionAccess = MenuBarPositionAccess()
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
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && !demoMode
    }
    private let shortcut = GlobalShortcut()
    private var timer: Timer?
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var workspaceObservers: [NSObjectProtocol] = []
    private let demoMode = CommandLine.arguments.contains("--demo-items")
    private let access = MenuBarAccessibility()
    private var rules = ItemRuleBook()
    private var drafts = ItemRuleBook()
    private var pendingDrafts = PendingDraftStore()
    private var rowDraftIDs: [String: UUID] = [:]
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
    private var passiveIconCaptureTask: Task<Void, Never>?
    private var passiveIconCaptureID: UUID?
    private var lastPassiveIconCaptureAttempt = -Double.infinity
    private var passiveOverflowRebindAttempts = 0
    private var lastPassiveOverflowRebind = -Double.infinity
    private var passiveOverflowRebindNeedsRetry = false
    private var iconImagePreparationIssues: [String] = []
    private var preparingToTerminate = false
    var isPanelItemOperationRunning: Bool { panelActivationTask != nil }
    var panelItems: [ManagedItemRow] {
        items.filter { item in
            item.isAvailable && item.canMove && HiddenItemsPanelPolicy.includes(
                savedVisibility: rules.rule(for: item.id)?.visibility,
                observedVisibility: observedGroupForDisplay(id: item.id),
                includeAlwaysHidden: panelIncludesAlwaysHidden)
        }
    }
    var permissionSettingsName: String { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能" }
    var applicationPath: String { Bundle.main.bundleURL.path }
    var hasAlwaysHiddenItems: Bool { usesNativeAlwaysSection || rules.rules.values.contains { $0.visibility == .alwaysHidden } }

    init() {
        defaults = CommandLine.arguments.contains("--demo-items") ? UserDefaults(suiteName: "dev.hdh.MenuTidy.demo")! : .standard
        defaults.register(defaults: ["autoCollapse": false, "autoCollapseDelay": 15.0, "startCollapsed": false, "shortcutEnabled": true])
        autoCollapseEnabled = defaults.bool(forKey: "autoCollapse")
        autoCollapseDelay = AutoCollapsePolicy(delay: defaults.double(forKey: "autoCollapseDelay")).delay
        startCollapsed = defaults.bool(forKey: "startCollapsed")
        shortcutEnabled = defaults.bool(forKey: "shortcutEnabled")
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        usesNativeAlwaysSection = defaults.bool(forKey: "usesNativeAlwaysSection")
        if let data = defaults.data(forKey: "itemRules.v1") {
            do { rules = try JSONDecoder().decode(ItemRuleBook.self, from: data) }
            catch {
                defaults.set(data, forKey: "itemRules.unreadableBackup")
                managementError = "已保存的分类无法读取，原始设置已备份。请刷新图标后重新分类。"
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
        rebuildRows()
    }

    func start() {
        controlRouter.start(model: self)
        statusBar = StatusBarController(model: self, demoMode: demoMode)
        shortcut.onPress = { [weak self] in self?.toggleVisibility() }
        configureShortcut()
        refreshLoginStatus()
        refreshEnvironment()
        // Recover our own exact preference writes even if AX was revoked
        // while this application was stopped. Recovery never needs AX input.
        if usesPositionHiding && !positionStore.managedHiddenEntries.isEmpty {
            let recoveryGeneration = beginPositionRecovery()
            workTask = Task {
                defer { finishPositionRecovery(recoveryGeneration) }
                do {
                    let pending = try positionStore.recoverPendingHiddenWrites()
                    try await completeHiddenLayoutRefresh(pending.requiresLayoutRefresh)
                    let restored = try positionStore.restoreAllHidden()
                    try await completeHiddenLayoutRefresh(restored.requiresLayoutRefresh)
                    guard pending.isComplete && restored.isComplete else { throw MenuBarAccessError.rejected }
                    finishPositionRecovery(recoveryGeneration)
                    if accessibilityGranted { refreshMenuItems(collapseWhenFinished: startCollapsed && hasCompletedSetup) }
                } catch {
                    await refreshAfterHiddenFailure(error)
                    positionRecoveryMessage = "上次隐藏位置尚未恢复：\(error.localizedDescription)"
                }
            }
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
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pruneObservedGroupHistory()
                    self?.rebuildRows()
                    self?.refreshEnvironment()
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
        // This asks macOS to guide the user; it never edits the privacy database.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        managementMessage = "请在系统设置的「\(permissionSettingsName)」中开启 Menu Tidy。回到这里后会自动检测并读取图标。"
        openAccessibilitySettings()
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func recheckPermissions() {
        refreshPermissions()
        recheckMenuBarPositionAccess()
        permissionCheckMessage = accessibilityGranted
            ? "检测完成：macOS 已允许当前运行的 Menu Tidy 访问辅助功能。"
            : "检测完成：macOS 尚未允许当前版本访问。如果系统开关已经打开，请按下方「已开启仍未识别？」更新旧的授权记录。"
    }

    func recheckMenuBarPositionAccess() {
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
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
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
        guard !isApplying, !isRefreshing, !isActivatingPanelItem, !isRecoveringPositions else { return }
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
                managementMessage = "已恢复本应用仍在管理的隐藏位置，并保留外部改动；未确认的分类仍是草稿。"
            } catch {
                await refreshAfterHiddenFailure(error)
                positionRecoveryMessage = error.localizedDescription
            }
        }
    }

    func refreshPermissions() {
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !screenCaptureGranted && isPanelPresented { closeIconPanel() }
        if !accessibilityGranted && wasGranted {
            permissionCheckMessage = "macOS 已撤销当前应用的辅助功能访问，请重新授权。"
            workTask?.cancel()
            panelActivationTask?.cancel()
            Task { await access.cancel() }
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
        _ = CGRequestScreenCaptureAccess()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !screenCaptureGranted {
            panelError = "请在系统设置中允许 Menu Tidy 录制屏幕。授权后返回重新检测；若系统要求重新打开，请退出后重新打开应用。"
            openScreenCaptureSettings()
        } else { panelError = nil }
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshMenuItems(collapseWhenFinished: Bool = false, prepareOverflow: Bool = false) {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        guard accessibilityGranted else { managementError = "先在权限页开启辅助功能权限，再读取菜单栏图标。"; return }
        closeIconPanel()
        isRefreshing = true
        managementError = nil
        let preparesIconInventory = prepareOverflow && screenCaptureGranted
        let refreshesManagedIcons = preparesIconInventory && usesPositionHiding
        managementMessage = preparesIconInventory
            ? "正在读取原始图标；仅请求系统提供的后台接口，不移动鼠标。"
            : "正在读取菜单栏图标，保持当前分组的展开／收起状态。"
        applyState()
        workTask = Task { [weak self] in
            guard let self else { return }
            var scanSucceeded = false
            var inventoryIssues: [String] = []
            defer {
                self.isRefreshing = false
                self.applyState()
                if !prepareOverflow, self.usesPositionHiding, scanSucceeded, !Task.isCancelled, !self.preparingToTerminate,
                   self.items.contains(where: { $0.isPending && self.rowDraftIDs[$0.id] == nil && self.rules.rule(for: $0.id) != nil }) {
                    self.applyItemRules(onlySavedRules: true)
                }
                if collapseWhenFinished, scanSucceeded, !Task.isCancelled, !self.stopping,
                   !self.settingsVisible, !self.contextMenuVisible, !self.isPanelPresented {
                    self.collapseIfSafe()
                }
            }
            do {
                await self.passiveIconCaptureTask?.value
                try self.checkImageRefreshCancellation()
                try await Task.sleep(for: .milliseconds(350))
                if preparesIconInventory && !refreshesManagedIcons {
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
                try await self.scanNow()
                await self.access.inspectNonintrusiveCapabilities()
                if self.screenCaptureGranted {
                    if refreshesManagedIcons {
                        let issues = try await self.refreshManagedHiddenIconImages()
                        inventoryIssues.append(contentsOf: issues)
                        if !issues.isEmpty { self.managementError = issues.joined(separator: "\n") }
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
                try Task.checkCancellation()
                guard !self.stopping else { throw MenuBarAccessError.cancelled }
                scanSucceeded = true
                self.managementMessage = self.items.isEmpty
                    ? "没有读到菜单栏项目。请退出全屏、展开其他整理器后重试。"
                    : "主屏读取到 \(self.items.filter(\.isAvailable).count) 个项目。选择分类后点击「应用并收起」；空间不足时，请通过系统溢出入口查看图标。"
            } catch {
                do {
                    try self.checkImageRefreshCancellation(error)
                    self.managementError = error.localizedDescription
                } catch {
                    // Cancellation is handled once here, not converted into an
                    // unsupported capability or a failed classification.
                    self.managementMessage = nil
                }
            }
            if preparesIconInventory && !refreshesManagedIcons { await self.access.restoreSystemOverflowAfterManagement() }
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
        let deadline = ProcessInfo.processInfo.systemUptime + min(90, max(20, Double(targets.count) * 6))
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
                        // read-only wait has its own fixed five-second limit.
                        if AXIsProcessTrusted(), self.accessibilityGranted,
                           !self.stopping, !self.preparingToTerminate {
                            _ = try await self.waitForPositionVisibility(id: item.id, visible: false,
                                candidates: retainedCandidates, hadVerifiedReveal: hadVisibleProof)
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
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, let row = items.first(where: { $0.id == id }), row.canMove, row.isAvailable,
              snapshots.filter({ $0.id == id }).count == 1 else { return }
        cancelPassiveIconCapture()
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
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        cancelPassiveIconCapture()
        pendingDrafts.remove(id: id)
        persistDrafts()
        rebuildRows()
    }

    @discardableResult
    func reassociateDraft(id: UUID, to itemID: String) -> Bool {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging,
              offlineDrafts.contains(where: { $0.id == id }),
              let row = items.first(where: { $0.id == itemID && $0.isAvailable && $0.canMove }),
              snapshots.filter({ $0.id == itemID }).count == 1 else { return false }
        cancelPassiveIconCapture()
        do {
            try pendingDrafts.reassociate(id: id, to: ItemRule(id: row.id, name: row.name,
                bundleIdentifier: row.bundleIdentifier, visibility: row.group),
                sessionIdentity: draftSessionIdentity(for: row.id))
            persistDrafts()
            managementError = nil
            rebuildRows()
            return true
        } catch PendingDraftStore.StoreError.targetHasDraft {
            managementError = "此图标已有待应用草稿，未覆盖任何选择。请先撤销该图标的草稿，或选择其他图标。"
        } catch {
            managementError = "图标身份已变化，未关联草稿。请刷新列表后重新选择。"
        }
        return false
    }

    func forgetItem(id: String) {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, !items.contains(where: { $0.id == id && $0.isAvailable }) else { return }
        cancelPassiveIconCapture()
        rules.remove(id: id)
        drafts.remove(id: id)
        lastKnownObservedGroups.remove(id: id)
        persistRules()
        rebuildRows()
        applyState()
    }

    func applyItemRules(onlySavedRules: Bool = false) {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        closeIconPanel()
        guard accessibilityGranted else { requestAccessibility(); return }
        refreshEnvironment()
        guard environmentIssue == nil else { managementError = "请先退出其他菜单栏整理器，再应用分类，以免两个工具同时移动图标。"; return }
        let requestedIDs = items.filter {
            $0.isPending && $0.isAvailable && $0.canMove && (!onlySavedRules || rowDraftIDs[$0.id] == nil)
        }.map(\.id)
        let requestedIDSet = Set(requestedIDs)
        guard !requestedIDs.isEmpty else { return }
        let previousState = state
        let previousTemporaryReveal = temporarilyRevealingAll
        let previousBeforeTemporaryReveal = beforeTemporaryRevealCollapsed
        isApplying = true
        managementError = nil
        managementMessage = "正在检查后台分组能力，不移动鼠标。"
        workTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var stage = "检查后台分组能力"
            var failureMessage: String?
            defer {
                self.isApplying = false
                if !succeeded {
                    self.state = previousState
                    self.temporarilyRevealingAll = previousTemporaryReveal
                    self.beforeTemporaryRevealCollapsed = previousBeforeTemporaryReveal
                } else {
                    self.collapseIfSafe()
                    if self.isCollapsed {
                        self.managementMessage = "本次分类位置已确认并保存，已请求收起。点击菜单栏「···」可打开图标栏。" +
                            (self.offlineDrafts.isEmpty ? "" : "另有 \(self.offlineDrafts.count) 条离线草稿保留，未参与本次应用。")
                    }
                }
                self.rebuildRows()
                self.applyState()
            }
            do {
                await self.passiveIconCaptureTask?.value
                try Task.checkCancellation()
                stage = "应用后台排序"
                if !(try await self.applyStoredPositionRules(requestedIDs: requestedIDs)) {
                    try await self.access.validateBackgroundMoveSupport(ids: requestedIDs)
                    try Task.checkCancellation()
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
                    guard Set(pending.map(\.id)) == requestedIDSet else { throw MenuBarAccessError.invalidGeometry }
                    for (index, row) in pending.enumerated() {
                        stage = "移动「\(row.name)」至\(row.group.title)"
                        try Task.checkCancellation()
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
                        if self.items.contains(where: { requestedIDSet.contains($0.id) && $0.isPending }) {
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

            if let failureMessage {
                self.managementError = "\(failureMessage) 本次分类尚未全部生效：已确认的项目已保存，其余选择仍待应用。不支持后台调整的图标仍保留为待应用，不会回退到模拟拖动。"
                self.managementMessage = nil
            } else {
                if self.screenCaptureGranted {
                    do { try await self.prepareIconImages() }
                    catch { self.panelError = error.localizedDescription }
                }
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
    private func applyStoredPositionRules(requestedIDs: [String]) async throws -> Bool {
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
        if usesPositionHiding { return try await applyPositionHidingRules(requestedIDs: requestedIDs) }
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
            try Task.checkCancellation()
            guard let row = items.first(where: { $0.id == id && $0.isAvailable && $0.canMove }) else {
                failures.append("有一个待应用图标已退出或身份变化")
                continue
            }
            do {
                let result = try await access.prepareBackgroundPositionCandidates(
                    ids: [id], positions: initialPositions, owners: menuBarScanInputs().owners)
                guard let candidate = result.first else { throw MenuBarAccessError.disappeared }
                prepared.append((row, candidate))
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
            try Task.checkCancellation()
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
        statusBar.apply(collapsed: true, arranging: false)
        try await statusBar.refreshPreferredPositions()
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
            outcome = .success(try await applyStagedPositionHidingRules(requestedIDs: requestedIDs,
                controlID: controlID, statusBar: statusBar, scope: scope))
        } catch {
            invalidateHiddenPositionEvidence()
            for id in requestedIDs {
                verifiedPositionGroups.removeValue(forKey: id)
                verifiedPositionEvidence.removeValue(forKey: id)
                actualGroups.removeValue(forKey: id)
            }
            rebuildRows()
            outcome = .failure(error)
        }
        let layoutChanged = await restoreUnverifiedStagedHiddenPositions(scope)
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
        let requestedRules: [ItemRule]
        let bootstrap: Bool
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

    private func stageRequestedHiddenPositions(requestedIDs: [String], controlID: String,
        scope: HiddenStagingScope, failures: inout [String]) async throws -> [String: String] {
        // Capture exact identities before writing. Neither these weights nor
        // the intermediate captures are accepted rules until final batch proof.
        var stagedKeys: [String: String] = [:]
        for id in requestedIDs {
            try Task.checkCancellation()
            guard let rule = scope.requestedRules.first(where: { $0.id == id }),
                  rule.visibility != .visible else { continue }
            var candidates: [MenuBarPositionCandidate] = []
            do {
                do {
                    candidates = try await prepareStablePositionCandidates(ids: [id, controlID])
                } catch let error as MenuBarPositionBindingError where error.reason == .ambiguousKey {
                    try await resolvePositionKey(id: id, controlID: controlID)
                    candidates = try await prepareStablePositionCandidates(ids: [id, controlID])
                }
                guard let target = candidates.first(where: { $0.id == id }),
                      let identity = draftSessionIdentity(for: id),
                      !scope.stagedTargets.values.contains(where: { $0.key == target.key && $0.rule.id != id }) else {
                    throw MenuBarAccessError.disappeared
                }
                let expected = PositionHidingBatchTarget(rule: rule, identity: identity,
                    key: target.key, hadVerifiedReveal: false)
                guard expected.matches(target) else { throw MenuBarAccessError.disappeared }
                if !scope.bootstrap {
                    // An existing blocker can remove a newly hidden system
                    // item from the AX tree before per-item capture begins.
                    // Confirm recoverable original identity before writing.
                    try await access.ensureSystemModuleContinuityBeforeHiding(id: id)
                }
                scope.stagedTargets[id] = expected
                stagedKeys[id] = target.key
                if !scope.previouslyManagedKeys.contains(target.key) {
                    scope.newlyStagedKeysByID[id] = target.key
                }
                try Task.checkCancellation()
                let result = try positionStore.hide(key: target.key)
                guard result.isComplete else { throw MenuBarAccessError.rejected }
            } catch {
                await refreshAfterHiddenFailure(error)
                failures.append("「\(rule.name)」暂未准备好隐藏：\(error.localizedDescription)")
            }
            await access.discardBackgroundPositionCandidates(candidates)
            try Task.checkCancellation()
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
            if !scope.bootstrap { try await fitPositionHidingBlocker() }
        }
        var completedTargets: [String: PositionHidingBatchTarget] = [:]
        for rule in scope.requestedRules {
            let id = rule.id
            try Task.checkCancellation()
            var candidates: [MenuBarPositionCandidate] = []
            var managedKey: String? = stagedKeys[id]
            do {
                do {
                    candidates = try await prepareStablePositionCandidates(ids: [id, controlID])
                } catch let error as MenuBarPositionBindingError where error.reason == .ambiguousKey {
                    managementMessage = "正在确认「\(rule.name)」的位置记录；不会移动鼠标。"
                    try await resolvePositionKey(id: id, controlID: controlID)
                    candidates = try await prepareStablePositionCandidates(ids: [id, controlID])
                }
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
                    } else {
                        _ = try await waitForPositionVisibility(id: id, visible: true, candidates: candidates)
                    }
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
                    if screenCaptureGranted {
                        if let item = snapshots.first(where: { $0.id == id }), let visibleFrame {
                            try await iconCapture.refreshBindings(snapshots: snapshots)
                            let confirmed = snapshotForVerifiedIconCapture(item, frame: visibleFrame)
                            _ = try await captureAndVerifyIconImages([confirmed])
                        } else { throw MenuBarAccessError.disappeared }
                    }
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
            try Task.checkCancellation()
            guard !positionLayoutRecoveryNeeded else { throw MenuBarAccessError.rejected }
        }
        guard Set(completedTargets.keys) == Set(requestedIDs) else { throw MenuBarAccessError.disappeared }
        // No temporary preference writes follow this final fit. Earlier
        // successful captures did not commit a rule or remove a user draft.
        if !positionStore.managedHiddenEntries.isEmpty { try await fitPositionHidingBlocker() }
        try await scanNow()
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
        var evidence: [String: VerifiedPositionEvidence] = [:]
        for id in expected.keys.sorted() {
            try Task.checkCancellation()
            guard let target = expected[id] else { throw MenuBarAccessError.disappeared }
            evidence[id] = try await verifyPositionHidingBatchTarget(target, controlID: controlID, waitForStable: true)
        }
        // All preference mutations and the final fit precede these checks.
        // A read-only last pass also rejects a later item's layout obscuring
        // an earlier visible item, or bringing an earlier hidden item back.
        try await scanNow()
        for id in expected.keys.sorted() {
            try Task.checkCancellation()
            guard let target = expected[id], let previous = evidence[id] else { throw MenuBarAccessError.disappeared }
            let current = try await verifyPositionHidingBatchTarget(target, controlID: controlID, waitForStable: false)
            guard current.identity == previous.identity, current.key == previous.key,
                  current.value == previous.value else { throw MenuBarAccessError.rejected }
            evidence[id] = current
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
        guard required else { return }
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
    private func fitPositionHidingBlocker(reposition: Bool = true) async throws {
        guard let statusBar, usesPositionHiding, !positionStore.managedHiddenEntries.isEmpty else { return }
        var transaction: MenuBarPositionStore.Transaction?
        var candidates: [MenuBarPositionCandidate] = []
        do {
            try await scanNow()
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
                try await scanNow()
                let requested = statusBar.positionHidingBlockerRequestedWidth
                if let frame = await access.currentOwnDividerHostFrame(),
                   statusBar.setPositionHidingBlocker(verifiedFrame: frame, expectedRequestedWidth: requested) {
                    // Resizing this divider already invalidates its host.
                    // Nudging the control as well changes the budget while we
                    // measure it and can make an otherwise fitting item spill.
                    try await Task.sleep(for: .milliseconds(250))
                    if let actual = await access.currentOwnDividerHostFrame(),
                       actual.width >= statusBar.positionHidingBlockerRequestedWidth,
                       abs(actual.maxX - frame.maxX) <= 1 {
                        fitted = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(120))
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
                try Task.checkCancellation()
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
                        try Task.checkCancellation()
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
                                           hadVerifiedReveal: Bool = false) async throws -> CGRect? {
        guard let target = candidates.first(where: { $0.id == id }),
              let control = candidates.first(where: { $0.id != id }) else { throw MenuBarAccessError.disappeared }
        if usesPositionHiding, statusBar?.positionHidingBlockerWidth != nil {
            try await fitPositionHidingBlocker(reposition: false)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = min(started + 5, outerDeadline ?? .infinity)
        var refreshedAgain = false
        var matches = 0
        var matchedFrame: CGRect?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await scanNow()
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

    private func scanNow() async throws {
        anchorScanSequence += 1
        let scanID = anchorScanSequence
        let (owners, bands) = menuBarScanInputs()
        let newSnapshots: [MenuBarItemSnapshot]
        do {
            newSnapshots = try await access.scan(owners: owners, menuBands: bands, positions: (try? positionStore.readPositions()) ?? [:])
        } catch {
            logOwnAnchors(nil, scanID: scanID)
            throw error
        }
        logOwnAnchors(newSnapshots, scanID: scanID)
        guard !stopping, !Task.isCancelled, scanID == anchorScanSequence else { throw MenuBarAccessError.cancelled }
        snapshots = newSnapshots
        actualGroups.removeAll()
        if (!usesPositionHiding || isArranging), statusBar?.areGroupBoundariesExpanded == true,
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
                let currentPositions = try? positionStore.readPositions()
                verifiedPositionGroups = verifiedPositionGroups.filter { id, _ in
                    guard let evidence = verifiedPositionEvidence[id],
                          currentPositions?[evidence.key] == evidence.value,
                          Self.observedOwnerIsCurrent(evidence.identity),
                          let current = newSnapshots.first(where: { $0.id == id }),
                          observedItemIdentity(current) == evidence.identity else { return false }
                    return true
                }
                // A direct hit is positive evidence of reappearance even if
                // the preferred position and owner have not changed. Do not
                // keep presenting a historical success as current state.
                for (id, group) in verifiedPositionGroups where group != .visible {
                    let observed = await access.inspectVisibility(id: id)
                    if observed.centerHit {
                        verifiedPositionGroups.removeValue(forKey: id)
                        Self.diagnosticLogger.notice("positionHiding historicalProofRevoked=true reason=visible-again")
                    }
                }
                verifiedPositionEvidence = verifiedPositionEvidence.filter { verifiedPositionGroups[$0.key] != nil }
            }
            actualGroups = verifiedPositionGroups
        }
        rememberObservedGroups(scannedOwners: owners)
        rebuildRows()
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
            let group: ItemVisibility = item.canMove ? (draft?.visibility ?? rules.rule(for: item.id)?.visibility ?? observedGroupForDisplay(id: item.id) ?? .visible) : .visible
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
            let icon = item.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return ManagedItemRow(id: item.id, name: item.name, ownerName: item.ownerName, bundleIdentifier: item.bundleIdentifier,
                icon: icon, group: group, isAvailable: true, canMove: item.canMove, detail: details.joined(separator: " · "),
                isPending: item.canMove && counts[item.id] == 1 &&
                    (rowDraftIDs[item.id] != nil || (rules.rule(for: item.id) != nil &&
                        (observedMismatch || (usesPositionHiding && verifiedPositionGroups[item.id] == nil)))))
        }
        let boundDraftIDs = Set(rowDraftIDs.values)
        offlineDrafts = pendingDrafts.records.filter { !boundDraftIDs.contains($0.id) }
            .sorted { $0.rule.name.localizedStandardCompare($1.rule.name) == .orderedAscending }
        let offlineTargetIDs = Set(offlineDrafts.map(\.rule.id))
        for rule in rules.rules.values where !result.contains(where: { $0.id == rule.id }) && !offlineTargetIDs.contains(rule.id) {
            result.append(ManagedItemRow(id: rule.id, name: rule.name, ownerName: rule.bundleIdentifier ?? "尚未运行的应用",
                bundleIdentifier: rule.bundleIdentifier, icon: nil, group: rule.visibility, isAvailable: false, canMove: false,
                detail: "已应用规则；当前未读到此图标。启动对应应用后刷新。", isPending: false))
        }
        items = result.sorted { $0.isAvailable != $1.isAvailable ? $0.isAvailable : $0.ownerName.localizedStandardCompare($1.ownerName) == .orderedAscending }
        actionablePendingCount = items.filter { $0.isPending && $0.isAvailable && $0.canMove }.count
        hasPendingChanges = actionablePendingCount > 0 || !offlineDrafts.isEmpty
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
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        showIconPanel(includeAlwaysHidden: true)
    }

    func endTemporaryReveal() {
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
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
        closeIconPanel()
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        state.collapse()
        statusBar?.restoreControlVisibility()
        applyState()
        managementMessage = usesPositionHiding
            ? "已收起图标栏；未应用的分类选择仍保留。"
            : "已收起现有菜单栏分组；未应用的分类选择仍保留，不代表这些图标已移动。"
    }

    func toggleVisibility() {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing else { return }
        if isArranging { finishArrangement(); return }
        if isPanelPresented { closeIconPanel(); return }
        if temporarilyRevealingAll {
            temporarilyRevealingAll = false
            beforeTemporaryRevealCollapsed = nil
        }
        showIconPanel(includeAlwaysHidden: false)
    }

    func controlClicked(event: NSEvent?) {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing else { return }
        cancelPassiveIconCapture()
        if isArranging {
            if event?.type != .leftMouseDown && event?.type != .rightMouseDown { finishArrangement() }
            return
        }
        controlRouter.controlClicked(event: event)
    }

    func showIconPanelFromControl() {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging else { return }
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
        guard accessibilityGranted else { requestAccessibility(); onShowSettings?(); return }
        guard screenCaptureGranted else {
            panelError = "实时图标栏需要屏幕录制权限，请在「权限与设置」中授权。"
            onShowSettings?()
            return
        }
        closeIconPanel()
        panelIncludesAlwaysHidden = includeAlwaysHidden
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        collapseIfSafe()
        isPanelPresented = true
        resetIdleTime()
        controlRouter.presentationChanged(isPresented: true)
        panelError = nil
        statusBar?.apply(collapsed: true, arranging: false)
        let controller = iconPanel ?? HiddenItemsPanelController()
        iconPanel = controller
        let anchor = snapshots.first { $0.ownIdentifier == "menu-tidy-toggle" }?.frame
        controller.show(model: self, anchor: anchor)
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
                    let missing = ids.count - images.count
                    self.panelError = missing > 0 ? "有 \(missing) 个图标尚未取得图像。可先收起此图标栏，再展开系统溢出区并保持片刻；应用会在图标可见且身份确认后自动补采。" : nil
                    try await Task.sleep(for: .milliseconds(750))
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isPanelPresented && !Task.isCancelled else { return }
                self.panelImages = [:]
                self.panelError = error.localizedDescription
            }
        }
    }

    func closeIconPanel() {
        panelTask?.cancel()
        panelTask = nil
        isPanelPresented = false
        controlRouter.presentationChanged(isPresented: false)
        panelImages = [:]
        iconPanel?.close()
        statusBar?.apply(collapsed: isCollapsed, arranging: isArranging)
    }

    /// Use one native AX action. A managed item is temporarily placed beside
    /// our control, then returned to its hidden weight after its presentation closes.
    func activatePanelItem(id: String) {
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging,
              !preparingToTerminate, isPanelPresented,
              panelItems.contains(where: { $0.id == id }) else { return }
        refreshPermissions()
        guard accessibilityGranted else { requestAccessibility(); return }
        closeIconPanel()
        isActivatingPanelItem = true
        panelActivationError = nil
        panelError = nil
        panelItemProgress = "正在打开目标图标…"
        panelActivationTask = Task { [weak self] in
            guard let self else { return }
            var candidates: [MenuBarPositionCandidate] = []
            var revealedKey: String?
            var presentation: MenuBarItemPresentation?
            var revealVerified = false
            var pressAttempted = false
            var presentationClosed = false
            var canRestore = true
            defer {
                self.panelActivationTask = nil
                self.isActivatingPanelItem = false
                self.panelItemProgress = nil
                self.statusBar?.apply(collapsed: self.isCollapsed, arranging: self.isArranging)
            }
            do {
                await self.passiveIconCaptureTask?.value
                try Task.checkCancellation()
                try await self.scanNow()
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
                let baseline = try await self.access.prepareItemPresentation(id: id)
                pressAttempted = true
                presentation = try await self.access.pressItem(id: id, baseline: baseline)
                if let presentation {
                    Self.diagnosticLogger.notice("backgroundItemAction presentationConfirmed=true")
                    if revealedKey != nil {
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
                                self.positionLayoutRecoveryNeeded = true
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
            if canRestore, revealedKey != nil, pressAttempted, !presentationClosed,
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
                    self.positionLayoutRecoveryNeeded = true
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
                                candidates: verificationCandidates, hadVerifiedReveal: hadVisibleProof)
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
            await self.access.discardBackgroundPositionCandidates(candidates)
        }
    }

    func cancelPanelItemActivation() {
        panelActivationTask?.cancel()
    }

    func beginArrangement() {
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
        guard !isRecoveringPositions, !isActivatingPanelItem, !isApplying, !isRefreshing, !isArranging, (usesPositionHiding || statusBar?.validateOrder() != false) else { return }
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
        shortcutIssue = nil
        if shortcutEnabled { shortcutIssue = shortcut.register() } else { shortcut.unregister() }
    }
    private func refreshEnvironment() {
        let managerNames: Set<String> = ["Barbee", "Bartender", "Bartender 7", "Bartender 6", "Ice", "Hidden Bar", "Hidden", "Dozer"]
        let active = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName)).intersection(managerNames).sorted()
        environmentIssue = active.isEmpty ? nil : "检测到 \(active.joined(separator: "、")) 正在运行。应用分类前请先退出其他整理器，避免重复控制图标。"
    }
    func refreshLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        if loginIssue == "请在系统设置的登录项中允许 Menu Tidy。" { loginIssue = nil }
        if SMAppService.mainApp.status == .requiresApproval { loginIssue = "请在系统设置的登录项中允许 Menu Tidy。" }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        loginIssue = nil
        if demoMode { loginIssue = "演示模式不修改登录项。"; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginIssue = "登录项设置未生效：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func showSystemLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    var requiresTerminationCleanup: Bool {
        preparingToTerminate || isApplying || isRefreshing || isRecoveringPositions || panelActivationTask != nil || passiveIconCaptureTask != nil ||
            !positionStore.managedHiddenEntries.isEmpty || !positionStore.pendingTransactions.isEmpty ||
            positionLayoutRecoveryNeeded
    }

    func quit() { NSApp.terminate(nil) }

    func prepareForTermination() async -> Bool {
        preparingToTerminate = true
        // Hold the shared operation gate across every suspension in cleanup.
        // An older task's defer may clear its own busy flag, but its recovery
        // generation cannot unlock this newer one and admit another mutation.
        let recoveryGeneration = beginPositionRecovery()
        let previousWork = workTask
        let previousActivation = panelActivationTask
        let previousCapture = passiveIconCaptureTask
        visibilityDiagnosticsStopped = true
        cancelPassiveIconCapture()
        cancelVisibilityDiagnostics()
        closeIconPanel()
        previousWork?.cancel()
        previousActivation?.cancel()
        await access.cancel()
        await previousWork?.value
        await previousActivation?.value
        await previousCapture?.value
        do {
            for transaction in positionStore.pendingTransactions {
                let rollback = try positionStore.rollback(transaction)
                try await statusBar?.refreshPreferredPositions()
                guard rollback.isComplete else { throw MenuBarAccessError.rejected }
            }
            let result = try positionStore.restoreAllHidden()
            try await completeHiddenLayoutRefresh(result.requiresLayoutRefresh)
            guard result.isComplete else { throw MenuBarAccessError.rejected }
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
        closeIconPanel()
        controlRouter.stop()
        stopping = true
        cancelPassiveIconCapture()
        arrangementSequence += 1
        visibilityDiagnosticsStopped = true
        cancelVisibilityDiagnostics()
        workTask?.cancel()
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        shortcut.unregister()
        statusBar?.stop()
        statusBar = nil
    }
}
