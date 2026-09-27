import AppKit
import MenuTidyCore
import OSLog

/// Native status items define groups; boundaries become visible during Command-drag arrangement.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let blockerLogger = Logger(subsystem: "dev.hdh.MenuTidy", category: "PositionBlocker")
    private weak var model: MenuTidyModel?
    private let control: NSStatusItem
    private let divider: NSStatusItem
    private let alwaysDivider: NSStatusItem
    private var demoItems: [NSStatusItem] = []
    private var screenObserver: NSObjectProtocol?
    private var lastScreenLayout: MenuBarScreenLayout?
    private var isCollapsed = false
    private var isArranging = false
    private let modernMenuBar = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    init(model: MenuTidyModel, demoMode: Bool) {
        self.model = model
        // Items are inserted from right to left on first launch.
        control = NSStatusBar.system.statusItem(withLength: MenuBarLayout.controlWidth)
        control.autosaveName = demoMode ? "DemoControl" : "MenuTidyControl"
        divider = NSStatusBar.system.statusItem(withLength: MenuBarLayout.expandedLength)
        divider.autosaveName = demoMode ? "DemoDivider" : "MenuTidyDivider"
        alwaysDivider = NSStatusBar.system.statusItem(withLength: MenuBarLayout.expandedLength)
        alwaysDivider.autosaveName = demoMode ? "DemoAlwaysDivider" : "MenuTidyAlwaysDivider"
        super.init()
        control.behavior = []
        divider.behavior = []
        alwaysDivider.behavior = []
        restoreControlVisibility()
        if let button = control.button {
            button.target = self
            button.action = #selector(controlClicked)
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
            button.setAccessibilityIdentifier("menu-tidy-toggle")
        }
        if let button = divider.button {
            button.title = ""
            button.target = self
            button.action = #selector(dividerClicked)
            button.setAccessibilityLabel("Menu Tidy 收起区定位项")
            button.setAccessibilityIdentifier("menu-tidy-divider")
        }
        if let button = alwaysDivider.button {
            button.title = ""
            button.target = self
            button.action = #selector(dividerClicked)
            button.setAccessibilityLabel("Menu Tidy 常隐区定位项")
            button.setAccessibilityIdentifier("menu-tidy-always-divider")
        }
        if demoMode {
            for title in ["②", "①"] {
                let item = NSStatusBar.system.statusItem(withLength: 28)
                item.button?.title = title
                let menu = NSMenu()
                menu.addItem(withTitle: "Menu Tidy 测试图标 \(title)", action: nil, keyEquivalent: "")
                item.menu = menu
                demoItems.append(item)
            }
        }
        apply(collapsed: false, arranging: false)
        lastScreenLayout = currentScreenLayout()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        }
    }

    private func currentScreenLayout() -> MenuBarScreenLayout? {
        var screens: [MenuBarScreenLayout.Screen] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            screens.append(.init(displayID: number.uint32Value, frame: screen.frame,
                bounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)), scale: Double(screen.backingScaleFactor),
                safeAreaTop: Double(screen.safeAreaInsets.top), auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea))
        }
        return MenuBarScreenLayout(screens: screens, mainDisplayID: CGMainDisplayID(),
            menuBarThickness: Double(NSStatusBar.system.thickness))
    }

    private func screenParametersDidChange() {
        let current = currentScreenLayout()
        let reason = MenuBarScreenLayout.invalidationReason(from: lastScreenLayout, to: current)
        lastScreenLayout = current
        guard let reason else {
            Self.blockerLogger.notice("screenParameters invalidated=false reason=unchanged")
            return
        }
        Self.blockerLogger.notice("screenParameters invalidated=true reason=\(reason.rawValue, privacy: .public)")
        // Real or unreadable layout changes still invalidate the measured
        // budget and every active reservation before requesting revalidation.
        clearPositionHidingBlocker()
        model?.recoverVisibility()
    }

    func restoreControlVisibility() {
        control.isVisible = true
        divider.isVisible = true
        alwaysDivider.isVisible = true
    }

    func validateOrder() -> Bool {
        // On macOS 27 the status views can be remote-hosted and their local window
        // frames are zero. A collapsed spacer's midpoint also does not represent
        // its item order. Unknown geometry must not create or clear a warning.
        func isShortStatusFrame(_ frame: CGRect) -> Bool {
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) &&
                frame.width > 0 && frame.width <= 44 && frame.height > 0 && frame.height <= 64
        }
        guard let controlFrame = control.button?.window?.frame,
              let dividerFrame = divider.button?.window?.frame,
              isShortStatusFrame(controlFrame), isShortStatusFrame(dividerFrame),
              controlFrame.midY == dividerFrame.midY else { return true }
        if dividerFrame.midX >= controlFrame.midX {
            model?.layoutIssue = "菜单栏分组位置需要恢复。请右键点击 Menu Tidy「···」，打开「管理菜单栏图标」检查并应用分组。重新打开应用也可以恢复显示。"
            return false
        }
        model?.layoutIssue = nil
        return true
    }

    func apply(collapsed: Bool, arranging: Bool) {
        isCollapsed = collapsed
        isArranging = arranging
        if arranging || model?.usesPositionHiding != true {
            positionHidingBlockerWidth = nil
            positionHidingBlockerReservation = nil
        }
        // macOS 27 discards grossly oversized items. A boundary that fits within
        // the native right-hand region instead pushes left neighbours to overflow.
        let sections = MenuBarSectionPolicy.separatorVisibility(isCollapsed: collapsed,
            hasAlwaysHidden: model?.hasAlwaysHiddenItems ?? false,
            // Reading items does not grant permission to expose hidden groups.
            isManaging: arranging || (model?.isApplying ?? false),
            temporarilyRevealingAll: model?.temporarilyRevealingAll ?? false)
        areGroupBoundariesExpanded = !sections.collapseRegular && !sections.collapseAlways
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let regularTitle = "← 收起"
        let alwaysTitle = "← 常隐"
        func markerWidth(_ title: String) -> CGFloat {
            max(44, (title as NSString).size(withAttributes: [.font: font]).width + 12)
        }
        divider.length = arranging ? markerWidth(regularTitle) :
            (model?.usesPositionHiding == true ? (positionHidingBlockerWidth ?? MenuBarLayout.expandedLength) :
                (sections.collapseRegular ? collapsedLength() : MenuBarLayout.expandedLength))
        if !arranging && positionHidingBlockerWidth != nil { areGroupBoundariesExpanded = false }
        divider.button?.font = font
        divider.button?.title = arranging ? regularTitle : ""
        // Blank layout spacers are not undisclosed entry points. Only the
        // labelled markers in explicit arrangement mode accept clicks.
        divider.button?.isEnabled = arranging
        divider.button?.toolTip = arranging ? "收起区边界：按住 ⌘ 拖动图标；点击完成拖拽并收起。" : nil
        alwaysDivider.length = arranging ? markerWidth(alwaysTitle) :
            (sections.collapseAlways && model?.usesPositionHiding != true ? collapsedLength() : MenuBarLayout.expandedLength)
        alwaysDivider.button?.font = font
        alwaysDivider.button?.title = arranging ? alwaysTitle : ""
        alwaysDivider.button?.isEnabled = arranging
        alwaysDivider.button?.toolTip = arranging ? "常隐区边界：按住 ⌘ 拖动图标；点击完成拖拽并收起。" : nil

        let stateDescription: String
        if model?.isApplying == true {
            stateDescription = "正在应用分组"
        } else if model?.isRefreshing == true {
            stateDescription = "正在读取图标"

        } else if model?.isActivatingPanelItem == true {
            stateDescription = "正在请求图标操作"
        } else if arranging {
            stateDescription = model?.managementError == nil ? "正在拖拽分组" : "拖拽结果待确认，右键查看原因"
        } else if model?.usesPositionHiding == true {
            stateDescription = model?.isPanelPresented == true ? "图标栏已展开" : "图标栏已收起"
        } else if model?.isPanelPresented == true {
            stateDescription = "图标栏已展开"
        } else if model?.temporarilyRevealingAll == true {
            stateDescription = "临时显示全部图标"
        } else {
            stateDescription = collapsed ? "已收起" : "已展开"
        }
        let actionDescription = arranging ? "点击完成拖拽并收起" :
            (model?.isPanelPresented == true ? "点击收起托盘" : "点击展开托盘")
        let controlDescription = "Menu Tidy 托盘 · \(stateDescription)"
        let symbol = arranging ? "arrow.left.and.right" : (model?.isPanelPresented == true ? "chevron.up" : "chevron.down")
        control.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controlDescription)
        control.button?.image?.isTemplate = true
        control.button?.toolTip = "\(controlDescription) · \(actionDescription) · 右键打开管理菜单"
        control.button?.setAccessibilityLabel("\(controlDescription)；\(actionDescription)")
    }

    private(set) var areGroupBoundariesExpanded = false

    /// Requested width, not the hosted physical width. The model must pair it
    /// with a current strictly verified frame of this exact divider.
    var positionHidingBlockerRequestedWidth: CGFloat { divider.length }
    private(set) var positionHidingBlockerWidth: CGFloat?

    struct PositionHidingBlockerReservation: Equatable, Sendable {
        fileprivate let id: UUID
        let originalRequestedWidth: CGFloat
        let reservedRequestedWidth: CGFloat
    }
    private var positionHidingBlockerReservation: PositionHidingBlockerReservation?

    /// Changes only our divider. A successful plan does not establish hiding:
    /// the model must re-read the divider, control, and affected native items.
    /// Failed validation preserves an existing blocker; shrinking is explicit.
    /// Capture expectedRequestedWidth before awaiting the frame query to reject
    /// calibration against a length that changed while the query was pending.
    /// Preflight verifies the host and display, not the final free width. The
    /// divider moves after targets leave ordinary positions, so its current
    /// right edge cannot predict the available space in the resulting layout.
    func canPreparePositionHidingBlocker(verifiedFrame: CGRect,
                                         expectedRequestedWidth: CGFloat) -> Bool {
        modernMenuBar && model?.usesPositionHiding == true && !isArranging &&
            expectedRequestedWidth.isFinite && expectedRequestedWidth == divider.length &&
            divider.length >= MenuBarLayout.expandedLength && verifiedFrame.width >= divider.length &&
            positionHidingBlockerLeftEdge(for: verifiedFrame, allowLeadingOverflow: true) != nil
    }

    /// Fit only against the native layout after target positions are staged.
    /// A planned width remains a proposal until fresh layout evidence.
    func positionHidingBlockerPlan(verifiedFrame: CGRect,
                                  expectedRequestedWidth: CGFloat? = nil) -> CGFloat? {
        if let expectedRequestedWidth,
           !expectedRequestedWidth.isFinite || expectedRequestedWidth != divider.length { return nil }
        guard modernMenuBar, model?.usesPositionHiding == true, !isArranging,
              let leftEdge = positionHidingBlockerLeftEdge(for: verifiedFrame, allowLeadingOverflow: true),
              let width = MenuBarBlockerGeometry.fittedWidth(frameRight: Double(verifiedFrame.maxX),
                  leftEdge: Double(leftEdge), requested: Double(divider.length),
                  actual: Double(verifiedFrame.width)) else { return nil }
        return CGFloat(width)
    }

    @discardableResult
    func setPositionHidingBlocker(verifiedFrame: CGRect, expectedRequestedWidth: CGFloat? = nil) -> Bool {
        guard let width = positionHidingBlockerPlan(verifiedFrame: verifiedFrame,
                                                   expectedRequestedWidth: expectedRequestedWidth) else {
            Self.blockerLogger.notice("positionBlocker planned=false stage=unavailable-or-insufficient-geometry")
            return false
        }
        let requested = divider.length
        positionHidingBlockerWidth = width
        if requested != width { divider.length = width }
        areGroupBoundariesExpanded = false
        Self.blockerLogger.notice("positionBlocker planned=true requestedBefore=\(requested) actualBefore=\(verifiedFrame.width) frameRight=\(verifiedFrame.maxX) requestedAfter=\(width)")
        return true
    }

    /// Call synchronously immediately before the single preference reveal.
    /// targetHostWidth comes from that exact item's previously verified hosted
    /// frame, never an application icon size or guessed position placeholder.
    func beginPositionHidingBlockerReservation(targetHostWidth: CGFloat,
                                               verifiedDividerFrame: CGRect,
                                               expectedRequestedWidth: CGFloat) -> PositionHidingBlockerReservation? {
        guard modernMenuBar, model?.usesPositionHiding == true, !isArranging,
              positionHidingBlockerReservation == nil,
              let activeWidth = positionHidingBlockerWidth,
              activeWidth == divider.length, expectedRequestedWidth == divider.length,
              positionHidingBlockerLeftEdge(for: verifiedDividerFrame) != nil,
              let reserved = MenuBarBlockerGeometry.reservedWidth(requested: Double(activeWidth),
                  actual: Double(verifiedDividerFrame.width), targetHostWidth: Double(targetHostWidth)) else {
            Self.blockerLogger.notice("positionBlocker reservation=false stage=unconfirmed-or-insufficient-budget")
            return nil
        }
        let reservation = PositionHidingBlockerReservation(id: UUID(), originalRequestedWidth: activeWidth,
            reservedRequestedWidth: CGFloat(reserved))
        positionHidingBlockerReservation = reservation
        positionHidingBlockerWidth = CGFloat(reserved)
        divider.length = CGFloat(reserved)
        Self.blockerLogger.notice("positionBlocker reservation=true requestedBefore=\(activeWidth) requestedAfter=\(reserved) targetHostWidth=\(targetHostWidth)")
        return reservation
    }

    /// Call synchronously after the conditional preference restore. No stale
    /// token can reapply a width after arrangement or a display change cleared it.
    @discardableResult
    func endPositionHidingBlockerReservation(_ reservation: PositionHidingBlockerReservation) -> Bool {
        guard modernMenuBar, model?.usesPositionHiding == true, !isArranging,
              positionHidingBlockerReservation == reservation else { return false }
        positionHidingBlockerReservation = nil
        positionHidingBlockerWidth = reservation.originalRequestedWidth
        divider.length = reservation.originalRequestedWidth
        Self.blockerLogger.notice("positionBlocker reservationRestored=true requested=\(reservation.originalRequestedWidth)")
        return true
    }

    private func positionHidingBlockerLeftEdge(for frame: CGRect, allowLeadingOverflow: Bool = false) -> CGFloat? {
        guard let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let rightArea = screen.auxiliaryTopRightArea,
              [rightArea.minX, rightArea.maxX, rightArea.width,
               frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              rightArea.width > 0, rightArea.minX >= screen.frame.minX,
              rightArea.maxX <= screen.frame.maxX,
              frame.width > 0, frame.height > 0, frame.height <= 64 else { return nil }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        // Translate AppKit global screen coordinates to this CG display origin.
        let left = bounds.minX + rightArea.minX - screen.frame.minX
        let right = bounds.minX + rightArea.maxX - screen.frame.minX
        let height = min(64, max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, left, right].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0,
              frame.minX >= bounds.minX, frame.width <= bounds.width,
              frame.maxX > left, frame.maxX <= right,
              (allowLeadingOverflow || frame.minX >= left),
              frame.minY >= bounds.minY - 1, frame.maxY <= bounds.minY + height + 1 else { return nil }
        return left
    }

    func clearPositionHidingBlocker() {
        let hadPlan = positionHidingBlockerWidth != nil
        positionHidingBlockerWidth = nil
        positionHidingBlockerReservation = nil
        divider.length = MenuBarLayout.expandedLength
        if hadPlan { Self.blockerLogger.notice("positionBlocker cleared=true") }
    }

    private func collapsedLength() -> CGFloat {
        let screens = NSScreen.screens
        if modernMenuBar {
            // Use the smallest usable region across displays: an oversized boundary
            // is ignored by modern menu bars. Every display still needs acceptance.
            let widths = screens.map { screen in
                MenuBarLayout.collapsedLength(screenWidth: Double(screen.frame.width),
                    rightAreaWidth: screen.auxiliaryTopRightArea.map { Double($0.width) }, modernMenuBar: true)
            }
            return CGFloat(widths.min() ?? 500)
        }
        return MenuBarLayout.collapsedLength(screenWidth: Double(screens.map(\.frame.width).max() ?? 1440),
                                              rightAreaWidth: nil, modernMenuBar: false)
    }

    /// Ask the hosted menu bar to consume updated position preferences. This
    /// only changes our own item and never posts input or activates a window.
    func refreshPreferredPositions() async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(50))
        let original = control.length
        // Hosted status buttons can be wider than their requested length. A
        // +1 request below that minimum does not invalidate the host layout.
        let rendered = control.button?.frame.width ?? original
        control.length = max(44, rendered, original) + 1
        defer { control.length = original }
        // MenuBarAgent consumes this layout invalidation in another process.
        // Keep the changed size across several display frames so an immediate
        // restore is not coalesced with it into one unchanged layout request.
        try await Task.sleep(for: .milliseconds(100))
        control.length = original
        try await Task.sleep(for: .milliseconds(50))
        try Task.checkCancellation()
    }

    @objc private func controlClicked() {
        let event = NSApp.currentEvent
        guard event?.modifierFlags.contains(.command) != true else { return }
        if event?.type == .rightMouseDown || event?.type == .rightMouseUp || event?.modifierFlags.intersection([.option, .control]).isEmpty == false {
            guard event?.type != .leftMouseDown, event?.type != .rightMouseDown else { return }
            showMenu()
        } else { model?.controlClicked(event: event) }
    }
    @objc private func dividerClicked() {
        guard isArranging, NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        model?.finishArrangement()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let busy = model?.isApplying == true || model?.isRefreshing == true || model?.isActivatingPanelItem == true
        let usesPanelVisibility = model?.usesPositionHiding == true && !isArranging
        if isArranging {
            addItem(menu, title: "完成拖拽并收起", action: #selector(finishArrangement), enabled: !busy)
            addItem(menu, title: "退出拖拽，保持全部展开", action: #selector(leaveArrangement), enabled: !busy)
            let guide = NSMenuItem(title: "按住 ⌘ 拖动；左常隐、中收起、右常驻", action: nil, keyEquivalent: "")
            guide.isEnabled = false
            menu.addItem(guide)
            if let message = model?.managementError {
                let error = NSMenuItem(title: String(message.prefix(72)) + (message.count > 72 ? "…" : ""), action: nil, keyEquivalent: "")
                error.toolTip = message
                error.isEnabled = false
                menu.addItem(error)
            }
        } else {
            addItem(menu, title: model?.isPanelPresented == true ? "收起托盘" : "打开托盘", action: #selector(toggle))
        }
        if !usesPanelVisibility {
            addItem(menu, title: "收起现有菜单栏分组", action: #selector(collapseNativeGroups), enabled: !busy && !isArranging)
        }
        addItem(menu, title: "选择常驻与托盘图标…", action: #selector(settings))
        menu.addItem(.separator())
        addItem(menu, title: "设置…", action: #selector(settings), key: ",")
        addItem(menu, title: "检查更新…", action: #selector(checkForUpdates),
                enabled: (NSApp.delegate as? AppDelegate)?.updates?.canCheckForUpdates == true)
        addItem(menu, title: "退出 Menu Tidy", action: #selector(quit), key: "q")
        if let button = control.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    private func addItem(_ menu: NSMenu, title: String, action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.autoenablesItems = false
        menu.addItem(item)
    }
    @objc private func toggle() { model?.toggleVisibility() }
    @objc private func arrange() { model?.beginArrangement() }
    @objc private func finishArrangement() { model?.finishArrangement() }
    @objc private func leaveArrangement() { model?.leaveArrangementExpanded() }
    @objc private func collapseNativeGroups() { model?.collapseNativeGroups() }
    @objc private func revealAll() {
        if model?.usesPositionHiding == true && !isArranging { model?.revealAllTemporarily() }
        else if model?.temporarilyRevealingAll == true { model?.endTemporaryReveal() }
        else { model?.revealAllTemporarily() }
    }
    @objc private func settings() { model?.onShowSettings?() }
    @objc private func checkForUpdates() { (NSApp.delegate as? AppDelegate)?.updates?.checkForUpdates() }
    @objc private func quit() { model?.quit() }
    func menuWillOpen(_ menu: NSMenu) { model?.contextMenuVisible = true }
    func menuDidClose(_ menu: NSMenu) { model?.contextMenuVisible = false }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        clearPositionHidingBlocker()
        alwaysDivider.length = MenuBarLayout.expandedLength
        // Preserve only our own placement hints: removal can clear them on some OSes.
        let defaults = UserDefaults.standard
        let names = [control.autosaveName, divider.autosaveName, alwaysDivider.autosaveName].compactMap { $0 }
        let positions = names.compactMap { name -> (String, Any)? in
            let key = "NSStatusItem Preferred Position \(name)"
            return defaults.object(forKey: key).map { (key, $0) }
        }
        for item in demoItems { NSStatusBar.system.removeStatusItem(item) }
        demoItems.removeAll()
        NSStatusBar.system.removeStatusItem(alwaysDivider)
        NSStatusBar.system.removeStatusItem(divider)
        NSStatusBar.system.removeStatusItem(control)
        for (key, value) in positions { defaults.set(value, forKey: key) }
    }
}
