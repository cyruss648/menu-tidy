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

    var errorDescription: String? {
        switch self {
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
    @Published private(set) var isCollapsed = false
    @Published private(set) var isArranging = false
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
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var permissionCheckMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isApplying = false
    @Published private(set) var managementMessage: String?
    @Published private(set) var managementError: String?
    @Published private(set) var temporarilyRevealingAll = false
    @Published private(set) var hasPendingChanges = false
    var settingsVisible = false { didSet { resetIdleTime() } }
    var contextMenuVisible = false { didSet { resetIdleTime() } }
    var onShowSettings: (() -> Void)?

    private let defaults: UserDefaults
    private var state = VisibilityState()
    private var statusBar: StatusBarController?
    private let shortcut = GlobalShortcut()
    private var timer: Timer?
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var workspaceObservers: [NSObjectProtocol] = []
    private let demoMode = CommandLine.arguments.contains("--demo-items")
    private let access = MenuBarAccessibility()
    private var rules = ItemRuleBook()
    private var drafts = ItemRuleBook()
    private var snapshots: [MenuBarItemSnapshot] = []
    private var actualGroups: [String: ItemVisibility] = [:]
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
        accessibilityGranted = AXIsProcessTrusted()
        rebuildRows()
    }

    func start() {
        statusBar = StatusBarController(model: self, demoMode: demoMode)
        shortcut.onPress = { [weak self] in self?.toggleVisibility() }
        configureShortcut()
        refreshLoginStatus()
        refreshEnvironment()
        if accessibilityGranted && rules.rules.isEmpty { refreshMenuItems() }
        if startCollapsed && hasCompletedSetup && !demoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.settingsVisible, !self.contextMenuVisible else { return }
                self.collapseIfSafe()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkAutoCollapse()
                guard let self else { return }
                if (self.settingsVisible || self.isArranging) && ProcessInfo.processInfo.systemUptime - self.lastPermissionCheck > 2 {
                    self.refreshPermissions()
                }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEnvironment() }
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
        permissionCheckMessage = accessibilityGranted
            ? "检测完成：macOS 已允许当前运行的 Menu Tidy 访问辅助功能。"
            : "检测完成：macOS 尚未允许当前版本访问。如果系统开关已经打开，请按下方「已开启仍未识别？」更新旧的授权记录。"
    }

    func refreshPermissions() {
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        if !accessibilityGranted && wasGranted {
            permissionCheckMessage = "macOS 已撤销当前应用的辅助功能访问，请重新授权。"
            workTask?.cancel()
            Task { await access.cancel() }
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

    func refreshMenuItems() {
        guard !isApplying, !isRefreshing, !isArranging else { return }
        guard accessibilityGranted else { managementError = "先在权限页开启辅助功能权限，再读取菜单栏图标。"; return }
        isRefreshing = true
        managementError = nil
        managementMessage = "正在展开本应用的分组并读取图标；空间不足时，部分图标仍可能位于系统溢出区。"
        applyState()
        workTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false; self.applyState() }
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await self.scanNow()
                guard !Task.isCancelled, !self.stopping else { return }
                self.managementMessage = self.items.isEmpty
                    ? "没有读到菜单栏项目。请退出全屏、展开其他整理器后重试。"
                    : "主屏读取到 \(self.items.filter(\.isAvailable).count) 个项目。选择分类后点击「应用并收起」；空间不足时，请通过系统溢出入口查看图标。"
            } catch { self.managementError = error.localizedDescription }
        }
    }

    func setGroup(id: String, group: ItemVisibility) {
        guard !isApplying, !isRefreshing, !isArranging, let row = items.first(where: { $0.id == id }), row.canMove, row.isAvailable else { return }
        drafts.set(ItemRule(id: id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: group))
        managementError = nil
        rebuildRows()
    }

    func forgetItem(id: String) {
        guard !isApplying, !isRefreshing, !isArranging, !items.contains(where: { $0.id == id && $0.isAvailable }) else { return }
        rules.remove(id: id)
        drafts.remove(id: id)
        persistRules()
        rebuildRows()
        applyState()
    }

    func applyItemRules() {
        guard !isApplying, !isRefreshing, !isArranging else { return }
        guard accessibilityGranted else { requestAccessibility(); return }
        refreshEnvironment()
        guard environmentIssue == nil else { managementError = "请先退出其他菜单栏整理器，再应用分类，以免两个工具同时移动图标。"; return }
        guard NSEvent.pressedMouseButtons == 0 else { managementError = "请先松开鼠标，再应用更改。"; return }
        isApplying = true
        managementError = nil
        managementMessage = "正在整理图标，请暂时不要操作鼠标或键盘。"
        applyState()
        workTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var stage = "等待菜单栏展开"
            var failureMessage: String?
            defer {
                self.isApplying = false
                if !succeeded {
                    self.beforeTemporaryRevealCollapsed = false
                    self.temporarilyRevealingAll = true
                    self.state.expand()
                } else {
                    self.collapseIfSafe()
                    if self.isCollapsed {
                        self.managementMessage = "分类已保存并收起。点击菜单栏「···」可展开「收起后隐藏」的图标。"
                    }
                }
                self.rebuildRows()
                self.applyState()
            }
            do {
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
                let pending = self.items.filter { $0.isAvailable && $0.canMove && $0.isPending }
                for (index, row) in pending.enumerated() {
                    stage = "移动「\(row.name)」至\(row.group.title)"
                    try Task.checkCancellation()
                    self.managementMessage = "正在整理 \(index + 1)/\(pending.count)：将「\(row.name)」设为\(row.group.title)。请暂时不要操作鼠标或键盘。"
                    let anchor = row.group == .alwaysHidden ? anchors.always : (row.group == .collapsible ? anchors.regular : anchors.control)
                    try await self.access.move(id: row.id, before: anchor)
                    stage = "连续两次验证「\(row.name)」的\(row.group.title)分类"
                    try await self.verify(id: row.id, group: row.group, anchors: anchors)
                    // Save a rule only after the actual AX order agrees twice.
                    self.rules.set(ItemRule(id: row.id, name: row.name, bundleIdentifier: row.bundleIdentifier, visibility: row.group))
                    self.persistRules()
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
                        if self.items.contains(where: { $0.isAvailable && $0.canMove && $0.isPending }) {
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
                self.managementError = "\(failureMessage) 本次分类尚未全部生效：已确认的项目已保存，其余选择仍待应用。请松开鼠标和键盘后重试「应用并收起」。当前已临时展开全部分组。"
                self.managementMessage = nil
            } else {
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
        // Retry reads before acquiring the pointer; never guess a missing anchor.
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
        let deadline = ProcessInfo.processInfo.systemUptime + 2
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
               always.frame.minX < regular.frame.minX,
               abs(always.frame.midY - regular.frame.midY) < 8, sameDisplay(always.frame, regular.frame),
               abs(item.frame.midY - regular.frame.midY) < 8, sameDisplay(item.frame, regular.frame) {
                let observed: ItemVisibility = item.frame.minX < always.frame.minX ? .alwaysHidden :
                    (item.frame.minX < regular.frame.minX ? .collapsible : .visible)
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

    private func scanNow() async throws {
        anchorScanSequence += 1
        let scanID = anchorScanSequence
        let owners = NSWorkspace.shared.runningApplications.map {
            MenuBarOwner(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                         name: $0.localizedName ?? "应用 \($0.processIdentifier)", launchTime: $0.launchDate?.timeIntervalSince1970 ?? 0)
        }
        let bands = NSScreen.screens.prefix(1).compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        }
        let newSnapshots: [MenuBarItemSnapshot]
        do {
            newSnapshots = try await access.scan(owners: owners, menuBands: bands)
        } catch {
            logOwnAnchors(nil, scanID: scanID)
            throw error
        }
        logOwnAnchors(newSnapshots, scanID: scanID)
        guard !stopping, !Task.isCancelled, scanID == anchorScanSequence else { throw MenuBarAccessError.cancelled }
        snapshots = newSnapshots
        actualGroups.removeAll()
        if let always = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-always-divider" }),
           let regular = snapshots.first(where: { $0.ownIdentifier == "menu-tidy-divider" }),
           always.hasReliableGeometry, regular.hasReliableGeometry,
           always.frame.minX < regular.frame.minX,
           abs(always.frame.midY - regular.frame.midY) < 8, sameDisplay(always.frame, regular.frame) {
            for item in snapshots where item.hasReliableGeometry && abs(item.frame.midY - regular.frame.midY) < 8 && sameDisplay(item.frame, regular.frame) {
                actualGroups[item.id] = item.frame.minX < always.frame.minX ? .alwaysHidden : (item.frame.minX < regular.frame.minX ? .collapsible : .visible)
            }
        }
        rebuildRows()
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
        let external = snapshots.filter { $0.ownIdentifier == nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        var result: [ManagedItemRow] = external.map { item in
            let draft = drafts.rule(for: item.id)
            let group = draft?.visibility ?? actualGroups[item.id] ?? .visible
            // Concealed overflow items may have no usable AX order. An unknown
            // observation is not evidence that an already verified rule moved.
            let observedMismatch = actualGroups[item.id].map { $0 != group } ?? false
            let savedMismatch = rules.rule(for: item.id)?.visibility != group
            var details = item.detail.isEmpty ? [] : [item.detail]
            if item.canMove && actualGroups[item.id] == nil {
                details.append(draft == nil
                    ? "当前实际分组位置未确认；选择显示方式后应用。"
                    : "当前实际分组位置未确认；保留已保存或待应用的选择。")
            }
            let icon = item.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return ManagedItemRow(id: item.id, name: item.name, ownerName: item.ownerName, bundleIdentifier: item.bundleIdentifier,
                icon: icon, group: group, isAvailable: true, canMove: item.canMove, detail: details.joined(separator: " · "),
                isPending: item.canMove && draft != nil && (observedMismatch || savedMismatch))
        }
        for rule in drafts.rules.values where !result.contains(where: { $0.id == rule.id }) {
            result.append(ManagedItemRow(id: rule.id, name: rule.name, ownerName: rule.bundleIdentifier ?? "尚未运行的应用",
                bundleIdentifier: rule.bundleIdentifier, icon: nil, group: rule.visibility, isAvailable: false, canMove: false,
                detail: "已保存；当前未读到此图标。启动对应应用后刷新。", isPending: false))
        }
        items = result.sorted { $0.isAvailable != $1.isAvailable ? $0.isAvailable : $0.ownerName.localizedStandardCompare($1.ownerName) == .orderedAscending }
        hasPendingChanges = items.contains(where: \.isPending)
    }

    private func persistRules() {
        let persistent = ItemRuleBook(rules: rules.rules.filter { !$0.key.hasPrefix("session:") })
        if let data = try? JSONEncoder().encode(persistent) { defaults.set(data, forKey: "itemRules.v1") }
    }

    func revealAllTemporarily() {
        guard !isApplying, !isRefreshing, !isArranging else { return }
        if !temporarilyRevealingAll { beforeTemporaryRevealCollapsed = isCollapsed }
        temporarilyRevealingAll = true
        state.expand()
        applyState()
        managementMessage = "已临时展开全部分组，包含「始终隐藏」。系统空间不足时，请通过系统溢出入口查看图标；点击「···」或「结束临时显示」恢复之前的状态。"
    }

    func endTemporaryReveal() {
        guard !isApplying, !isRefreshing, !isArranging, temporarilyRevealingAll else { return }
        let shouldCollapse = beforeTemporaryRevealCollapsed == true
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        state.expand()
        applyState()
        if shouldCollapse { collapseIfSafe() }
    }

    func toggleVisibility() {
        guard !isApplying, !isRefreshing else { return }
        if isArranging { finishArrangement(); return }
        if temporarilyRevealingAll { endTemporaryReveal(); return }
        if isCollapsed { state.expand(); applyState() } else { collapseIfSafe() }
    }

    func beginArrangement() {
        guard !isApplying, !isRefreshing, !isArranging else { return }
        refreshPermissions()
        guard accessibilityGranted else { requestAccessibility(); onShowSettings?(); return }
        guard !isRefreshing else { return }
        refreshEnvironment()
        guard environmentIssue == nil else {
            managementError = "请先退出其他菜单栏整理器，再使用菜单栏拖拽分组。"
            onShowSettings?()
            return
        }
        arrangementSequence += 1
        temporarilyRevealingAll = false
        beforeTemporaryRevealCollapsed = nil
        managementError = nil
        managementMessage = "按住 ⌘ 拖动图标：「常隐」左侧始终隐藏；「常隐」与「收起」之间收起后隐藏；「收起」右侧常驻。拖好后点击「···」完成并收起。"
        state.beginArrangement()
        applyState()
    }

    /// Native dragging belongs to macOS. We only read the settled positions;
    /// never run synthetic moves or acquire the automated overflow pointer lease.
    func finishArrangement() {
        guard isArranging, !isApplying, !isRefreshing else { return }
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
                // Native placement remains authoritative for the always-hidden
                // boundary, even for unidentifiable/session-only overflow items.
                self.usesNativeAlwaysSection = true
                self.defaults.set(true, forKey: "usesNativeAlwaysSection")
                self.hasCompletedSetup = true
                self.defaults.set(true, forKey: "hasCompletedSetup")
                self.temporarilyRevealingAll = false
                self.state.finishArrangement(collapse: true)
                self.rebuildRows()
                let available = self.items.filter { $0.isAvailable && $0.canMove }.count
                let unknown = max(0, available - confirmed.count)
                self.managementMessage = "已按菜单栏位置收起；\(confirmed.count) 个图标分类已确认并同步。" +
                    (unknown > 0 ? "另有 \(unknown) 个图标位置未确认，保留原有记录；原生分组仍按边界位置隐藏。" : "") +
                    (self.hasPendingChanges ? "界面中尚未应用的选择已保留。" : "")
            } catch {
                guard !Task.isCancelled, !self.stopping, self.arrangementSequence == sequence else { return }
                self.managementError = "暂时无法确认拖拽结果：\(error.localizedDescription) 请确认从左到右为「常隐」「收起」「···」，空间不足时打开系统溢出区，再重试完成；也可保持全部展开退出。"
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
        guard isArranging else { return }
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
        guard !isApplying else { return }
        if isArranging { leaveArrangementExpanded() }
        beforeTemporaryRevealCollapsed = false
        temporarilyRevealingAll = true
        state.expand()
        statusBar?.restoreControlVisibility()
        applyState()
    }
    private func collapseIfSafe() {
        guard !isApplying, !isRefreshing, !isArranging, statusBar?.validateOrder() != false else { return }
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
            !isApplying && !isRefreshing && !isArranging && visibilityDiagnosticSequence == sequence
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
        let paused = settingsVisible || contextMenuVisible || isApplying || isRefreshing || temporarilyRevealingAll || !hasCompletedSetup
        if pointerInMenuBar || buttonDown || paused { resetIdleTime() }
        if AutoCollapsePolicy(delay: autoCollapseDelay).shouldCollapse(elapsed: ProcessInfo.processInfo.systemUptime - lastInteraction,
            isExpanded: !isCollapsed, isArranging: isArranging, isPaused: paused, pointerInMenuBar: pointerInMenuBar,
            mouseButtonDown: buttonDown, enabled: autoCollapseEnabled) { collapseIfSafe() }
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
    func quit() {
        visibilityDiagnosticsStopped = true
        cancelVisibilityDiagnostics()
        workTask?.cancel()
        Task {
            await access.cancel()
            await workTask?.value
            NSApp.terminate(nil)
        }
    }
    func stop() {
        stopping = true
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
