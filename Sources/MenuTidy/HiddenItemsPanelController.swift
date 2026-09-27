import AppKit
import SwiftUI

/// An independent tray whose contents are available before optional image capture.
@MainActor
final class HiddenItemsPanelController: NSObject, NSWindowDelegate {
    private weak var model: MenuTidyModel?
    private var panel: IconPanel?
    private var localMonitor: Any?
    private var presentationToken: UUID?
    private var isSuspendedForNativePresentation = false
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func show(model: MenuTidyModel, anchor: CGRect?) {
        close()
        self.model = model
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let token = UUID()
        presentationToken = token
        let width = min(TrayPanelLayout.width, screen.visibleFrame.width - 16)
        let maxGridHeight = min(TrayPanelLayout.maximumGridHeight, max(44, screen.visibleFrame.height - 160))
        let height = TrayPanelLayout.gridHeight(itemCount: model.panelItems.count, limit: maxGridHeight) + 59
        let panel = IconPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Menu Tidy · 托盘"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HiddenItemsPanelView(model: model,
            width: width, maximumGridHeight: maxGridHeight) { [weak self] height in
                self?.resize(height: height, token: token, screen: screen)
            })
        let midpoint = anchor?.midX ?? (screen.visibleFrame.maxX - width / 2)
        let x = max(screen.visibleFrame.minX + 8, min(midpoint - width / 2, screen.visibleFrame.maxX - width - 8))
        let menuHeight = max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        panel.setFrameOrigin(NSPoint(x: x, y: screen.frame.maxY - menuHeight - 8 - panel.frame.height))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.keyCode == 53, self?.presentationToken == token {
                    self?.model?.closeIconPanel()
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissForFocusChange(token: token) }
            })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismissForFocusChange(token: token) }
                })
        }
    }

    func contains(_ point: NSPoint) -> Bool {
        panel?.isVisible == true && panel?.frame.contains(point) == true
    }

    /// Keep this presentation's view and local state while removing its window
    /// from native hit testing. The returned token cannot restore a newer tray.
    @discardableResult
    func suspendForNativePresentation() -> UUID? {
        guard let panel, let token = presentationToken else { return nil }
        isSuspendedForNativePresentation = true
        panel.orderOut(nil)
        return token
    }

    func restoreAfterNativePresentationFailure(token: UUID) {
        guard presentationToken == token, isSuspendedForNativePresentation,
              let panel else { return }
        isSuspendedForNativePresentation = false
        panel.makeKeyAndOrderFront(nil)
    }

    private func resize(height: CGFloat, token: UUID, screen: NSScreen) {
        guard presentationToken == token, let panel, height.isFinite else { return }
        let height = min(max(height.rounded(.up), 90), screen.visibleFrame.height - 16)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = max(screen.visibleFrame.minY + 8, frame.maxY - height)
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func dismissForFocusChange(token: UUID) {
        guard presentationToken == token else { return }
        // Native menus can change focus while an activation is being verified.
        // The model decides when that presentation is safe to dismiss.
        model?.dismissIconPanelForFocusChange()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isSuspendedForNativePresentation,
              let window = notification.object as? NSWindow, window === panel,
              let token = presentationToken else { return }
        dismissForFocusChange(token: token)
    }

    func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        applicationObservers.removeAll()
        workspaceObservers.removeAll()
        presentationToken = nil
        isSuspendedForNativePresentation = false
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private enum TrayPanelLayout {
    static let columns = 6
    static let cellSize: CGFloat = 44
    static let spacing: CGFloat = 6
    static let width = CGFloat(columns) * cellSize + CGFloat(columns - 1) * spacing + 24
    static let maximumGridHeight = cellSize * 4 + spacing * 3

    static func gridHeight(itemCount: Int, limit: CGFloat) -> CGFloat {
        let rows = max(1, (itemCount + columns - 1) / columns)
        return min(CGFloat(rows) * cellSize + CGFloat(rows - 1) * spacing, limit)
    }
}

private final class IconPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct TrayPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum TrayPanelAction: Equatable {
    case activation
    case placement
}

private struct TrayPanelError {
    let itemID: String?
    let message: String
    let retryAction: TrayPanelAction?
}

private struct HiddenItemsPanelView: View {
    @ObservedObject var model: MenuTidyModel
    let width: CGFloat
    let maximumGridHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredItemID: String?
    @State private var lastInteractedItemID: String?
    @State private var lastInteraction: TrayPanelAction?

    private var surface: Color {
        let white = colorScheme == .dark ? 0.16 : 0.97
        return Color(red: white, green: white, blue: white)
    }

    private var displayedError: TrayPanelError? {
        if let id = lastInteractedItemID {
            // Pending placement may have removed its tile optimistically.
            // Keep the operation's result tied to its identity and action.
            if model.trayPlacementIsPending(id: id) { return nil }
            if model.trayPlacementNeedsIdentification(id: id), let message = model.trayPlacementMessage(id: id) {
                return TrayPanelError(itemID: id, message: message, retryAction: .placement)
            }
            if lastInteraction == .placement, let message = model.trayPlacementMessage(id: id) {
                return TrayPanelError(itemID: id, message: message, retryAction: .placement)
            }
            if lastInteraction == .activation,
               let message = model.trayItemErrors[id] ?? model.panelActivationError {
                return TrayPanelError(itemID: id, message: message, retryAction: .activation)
            }
        }
        for item in model.panelItems {
            if model.trayPlacementNeedsIdentification(id: item.id),
               !model.trayPlacementIsPending(id: item.id), let message = model.trayPlacementMessage(id: item.id) {
                return TrayPanelError(itemID: item.id, message: message, retryAction: .placement)
            }
            if let message = model.trayItemErrors[item.id] {
                return TrayPanelError(itemID: item.id, message: message, retryAction: .activation)
            }
            if !model.trayPlacementIsPending(id: item.id),
               let message = model.trayPlacementMessage(id: item.id) {
                return TrayPanelError(itemID: item.id, message: message, retryAction: .placement)
            }
        }
        if let message = model.panelError {
            return TrayPanelError(itemID: nil, message: message, retryAction: nil)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.panelItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("托盘中还没有图标")
                        .font(.system(size: 12, weight: .medium))
                    Text("在设置中选择要收进托盘的图标。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                iconGrid
            }
            if let error = displayedError {
                errorNotice(error)
            } else if let id = lastInteractedItemID, model.trayPlacementIsPending(id: id) {
                let message = model.trayPlacementMessage(id: id) ?? "正在调整图标位置…"
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(message)
            }
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
            footer
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: TrayPanelHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(TrayPanelHeightKey.self, perform: onHeightChange)
    }

    private var iconGrid: some View {
        let totalRows = (model.panelItems.count + TrayPanelLayout.columns - 1) / TrayPanelLayout.columns
        let totalHeight = CGFloat(totalRows) * TrayPanelLayout.cellSize
            + CGFloat(max(0, totalRows - 1)) * TrayPanelLayout.spacing
        return ScrollView(.vertical, showsIndicators: totalHeight > maximumGridHeight) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(TrayPanelLayout.cellSize),
                spacing: TrayPanelLayout.spacing), count: TrayPanelLayout.columns),
                alignment: .leading, spacing: TrayPanelLayout.spacing) {
                ForEach(model.panelItems) { item in
                    HiddenPanelIconButton(name: item.name, image: model.panelImages[item.id],
                        fallbackImage: item.icon,
                        isWorking: model.activePanelItemID == item.id || model.trayPlacementIsPending(id: item.id),
                        hasError: model.trayItemErrors[item.id] != nil ||
                            (!model.trayPlacementIsPending(id: item.id) && model.trayPlacementMessage(id: item.id) != nil),
                        isDisabled: model.panelInteractionBusy,
                        placementMessage: model.trayPlacementMessage(id: item.id),
                        onHover: { hoveredItemID = $0 ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID) }) {
                            openItem(id: item.id)
                        }
                        .contextMenu {
                            Button("打开菜单") { openItem(id: item.id) }
                                .disabled(model.panelInteractionBusy)
                            Divider()
                            Button("常驻菜单栏") {
                                lastInteractedItemID = item.id
                                lastInteraction = .placement
                                model.requestTrayPlacement(id: item.id, inTray: false)
                            }
                            .disabled(model.panelInteractionBusy)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TrayPanelLayout.gridHeight(itemCount: model.panelItems.count, limit: maximumGridHeight))
    }

    private func openItem(id: String) {
        lastInteractedItemID = id
        lastInteraction = .activation
        model.activatePanelItem(id: id)
    }

    private func errorNotice(_ error: TrayPanelError) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if let id = error.itemID, let item = model.items.first(where: { $0.id == id }) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Text(error.message)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let id = error.itemID, let action = error.retryAction {
                Button(action == .placement ? model.trayPlacementRetryTitle(id: id) : "重试") {
                    switch action {
                    case .placement:
                        lastInteractedItemID = id
                        lastInteraction = .placement
                        model.retryTrayPlacement(id: id)
                    case .activation:
                        openItem(id: id)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(model.panelInteractionBusy)
                .accessibilityLabel("重试此图标的操作")
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(error.message)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(hoveredItemID.flatMap { id in model.panelItems.first(where: { $0.id == id })?.name }
                ?? "\(model.panelItems.count) 个图标")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("Esc 收起")
                .fixedSize()
                .accessibilityHidden(true)
            Button { model.openTraySettings() } label: {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("托盘设置")
            .accessibilityLabel("托盘设置")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }
}

private struct HiddenPanelIconButton: View {
    let name: String
    let image: NSImage?
    let fallbackImage: NSImage?
    let isWorking: Bool
    let hasError: Bool
    let isDisabled: Bool
    let placementMessage: String?
    let onHover: (Bool) -> Void
    let action: () -> Void
    @State private var isHovered = false

    private var help: String {
        let source = image != nil ? "图标快照" : (fallbackImage != nil ? "应用图标" : "名称标识")
        return "\(name) · \(source)\n\(placementMessage ?? "点击打开菜单，右键可设为常驻菜单栏")"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Group {
                    if let displayedImage = image ?? fallbackImage {
                        Image(nsImage: displayedImage)
                            .renderingMode(displayedImage.isTemplate ? .template : .original)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.primary)
                    } else {
                        Group {
                            let initial = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
                            if initial.isEmpty {
                                Image(systemName: "app.fill")
                            } else {
                                Text(initial.uppercased())
                            }
                        }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(width: image == nil ? 26 : 22, height: image == nil ? 26 : 22)
                .opacity(isWorking ? 0.22 : 1)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理 \(name)")
                }
            }
            .frame(width: TrayPanelLayout.cellSize, height: TrayPanelLayout.cellSize)
            .background(Color.primary.opacity(isHovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if hasError, !isWorking {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0; onHover($0) }
        .help(help)
        .accessibilityLabel(name)
        .accessibilityValue(isWorking ? "正在处理" : (hasError ? "上次操作未完成，可重试" : "托盘图标"))
    }
}
