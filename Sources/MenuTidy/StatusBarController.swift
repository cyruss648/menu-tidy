import AppKit
import MenuTidyCore

/// Native status items define groups; boundaries become visible during Command-drag arrangement.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private weak var model: MenuTidyModel?
    private let control: NSStatusItem
    private let divider: NSStatusItem
    private let alwaysDivider: NSStatusItem
    private var demoItems: [NSStatusItem] = []
    private var screenObserver: NSObjectProtocol?
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("menu-tidy-toggle")
        }
        if let button = divider.button {
            button.title = ""
            button.target = self
            button.action = #selector(dividerClicked)
            button.toolTip = "收起区边界：拖拽分组时，按住 ⌘ 将图标拖到此项左侧，收起后隐藏。"
            button.setAccessibilityLabel("Menu Tidy 收起区定位项")
            button.setAccessibilityIdentifier("menu-tidy-divider")
        }
        if let button = alwaysDivider.button {
            button.title = ""
            button.target = self
            button.action = #selector(dividerClicked)
            button.toolTip = "常隐区边界：拖拽分组时，按住 ⌘ 将图标拖到此项左侧，普通展开时也隐藏。"
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
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A changed display topology must never strand hidden items.
                self?.model?.recoverVisibility()
            }
        }
    }

    func restoreControlVisibility() {
        control.isVisible = true
        divider.isVisible = true
        alwaysDivider.isVisible = true
    }

    func validateOrder() -> Bool {
        // On macOS 27 the status views can be remote-hosted and their local window
        // frames are zero. Only reject an order when real geometry is available.
        if let controlFrame = control.button?.window?.frame,
           let dividerFrame = divider.button?.window?.frame,
           controlFrame.height > 0, dividerFrame.height > 0,
           controlFrame.midY == dividerFrame.midY, dividerFrame.midX >= controlFrame.midX {
            model?.layoutIssue = "菜单栏分组位置需要恢复。请右键点击 Menu Tidy「···」，打开「管理菜单栏图标」检查并应用分组。重新打开应用也可以恢复显示。"
            return false
        }
        model?.layoutIssue = nil
        return true
    }

    func apply(collapsed: Bool, arranging: Bool) {
        isCollapsed = collapsed
        isArranging = arranging
        // macOS 27 discards grossly oversized items. A boundary that fits within
        // the native right-hand region instead pushes left neighbours to overflow.
        let sections = MenuBarSectionPolicy.separatorVisibility(isCollapsed: collapsed,
            hasAlwaysHidden: model?.hasAlwaysHiddenItems ?? false,
            isManaging: arranging || (model?.isApplying ?? false) || (model?.isRefreshing ?? false),
            temporarilyRevealingAll: model?.temporarilyRevealingAll ?? false)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let regularTitle = "← 收起"
        let alwaysTitle = "← 常隐"
        func markerWidth(_ title: String) -> CGFloat {
            max(44, (title as NSString).size(withAttributes: [.font: font]).width + 12)
        }
        divider.length = arranging ? markerWidth(regularTitle) :
            (sections.collapseRegular ? collapsedLength() : MenuBarLayout.expandedLength)
        divider.button?.font = font
        divider.button?.title = arranging ? regularTitle : ""
        divider.button?.isEnabled = !sections.collapseRegular
        alwaysDivider.length = arranging ? markerWidth(alwaysTitle) :
            (sections.collapseAlways ? collapsedLength() : MenuBarLayout.expandedLength)
        alwaysDivider.button?.font = font
        alwaysDivider.button?.title = arranging ? alwaysTitle : ""
        alwaysDivider.button?.isEnabled = !sections.collapseAlways

        let stateDescription: String
        if model?.isApplying == true {
            stateDescription = "正在应用分组"
        } else if model?.isRefreshing == true {
            stateDescription = "正在读取图标"
        } else if arranging {
            stateDescription = model?.managementError == nil ? "正在拖拽分组" : "拖拽结果待确认，右键查看原因"
        } else if model?.temporarilyRevealingAll == true {
            stateDescription = "临时显示全部图标"
        } else {
            stateDescription = collapsed ? "已收起" : "已展开"
        }
        let actionDescription: String
        if model?.isApplying == true || model?.isRefreshing == true {
            actionDescription = "请稍候"
        } else {
            actionDescription = arranging ? "点击完成拖拽并收起" :
                (model?.temporarilyRevealingAll == true ? "点击结束临时显示" : "点击\(collapsed ? "展开" : "收起")")
        }
        let controlDescription = "Menu Tidy「···」 · \(stateDescription)"
        control.button?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: controlDescription)
        control.button?.image?.isTemplate = true
        control.button?.toolTip = "\(controlDescription) · \(actionDescription) · 右键打开管理菜单"
        control.button?.setAccessibilityLabel("\(controlDescription)；\(actionDescription)")
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

    @objc private func controlClicked() {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.intersection([.option, .control]).isEmpty == false {
            showMenu()
        } else { model?.toggleVisibility() }
    }
    @objc private func dividerClicked() {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        if isArranging { model?.finishArrangement() } else { model?.beginArrangement() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let busy = model?.isApplying == true || model?.isRefreshing == true
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
            addItem(menu, title: isCollapsed ? "展开隐藏图标" : "收起隐藏图标", action: #selector(toggle),
                    enabled: !busy && model?.temporarilyRevealingAll != true)
            addItem(menu, title: "在菜单栏拖拽分组", action: #selector(arrange), enabled: !busy)
        }
        addItem(menu, title: model?.temporarilyRevealingAll == true ? "结束临时显示" : "临时显示全部（含始终隐藏）",
                action: #selector(revealAll), enabled: !busy && !isArranging)
        addItem(menu, title: "管理菜单栏图标…", action: #selector(settings))
        menu.addItem(.separator())
        addItem(menu, title: "设置…", action: #selector(settings), key: ",")
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
    @objc private func revealAll() {
        if model?.temporarilyRevealingAll == true { model?.endTemporaryReveal() }
        else { model?.revealAllTemporarily() }
    }
    @objc private func settings() { model?.onShowSettings?() }
    @objc private func quit() { model?.quit() }
    func menuWillOpen(_ menu: NSMenu) { model?.contextMenuVisible = true }
    func menuDidClose(_ menu: NSMenu) { model?.contextMenuVisible = false }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        divider.length = MenuBarLayout.expandedLength
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
