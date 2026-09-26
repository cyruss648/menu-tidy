import AppKit
import SwiftUI

/// A transient row of original status-item images. The native hidden section stays closed.
@MainActor
final class HiddenItemsPanelController: NSObject, NSWindowDelegate {
    private weak var model: MenuTidyModel?
    private var panel: IconPanel?
    private var localMonitor: Any?
    private var presentationToken: UUID?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func show(model: MenuTidyModel, anchor: CGRect?) {
        close()
        self.model = model
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return }
        let token = UUID()
        presentationToken = token
        let itemCount = model.panelItems.count
        let contentWidth = CGFloat(itemCount) * 44 + CGFloat(max(0, itemCount - 1)) * 2 + 16
        let width = min(max(contentWidth, 300), screen.visibleFrame.width - 32)
        let panel = IconPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 92),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Menu Tidy · 隐藏图标栏"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HiddenItemsPanelView(model: model))
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

    func contains(_ point: NSPoint) -> Bool { panel?.frame.contains(point) == true }

    private func dismissForFocusChange(token: UUID) {
        guard presentationToken == token else { return }
        // The persistent control router retains the original press intent even
        // when this focus event arrives before its control mouse-up action.
        model?.closeIconPanel()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
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
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class IconPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct HiddenItemsPanelView: View {
    @ObservedObject var model: MenuTidyModel
    @Environment(\.colorScheme) private var colorScheme

    private var surface: Color {
        let white = colorScheme == .dark ? 0.16 : 0.97
        return Color(red: white, green: white, blue: white)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let count = model.panelItems.count
                let contentWidth = CGFloat(count) * 44 + CGFloat(max(0, count - 1)) * 2
                ScrollView(.horizontal, showsIndicators: contentWidth > geometry.size.width + 0.5) {
                    HStack(spacing: 2) {
                        ForEach(model.panelItems) { item in
                            HiddenPanelIconButton(name: item.name, image: model.panelImages[item.id]) {
                                model.activatePanelItem(id: item.id)
                            }
                        }
                    }
                    .frame(height: 44)
                }
                .frame(height: 48, alignment: .top)
            }
            .frame(height: 48)
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
            footer
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 14, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1))
    }

    @ViewBuilder private var footer: some View {
        if let error = model.panelActivationError ?? model.panelError {
            Label(error, systemImage: "info.circle")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(error)
        } else if model.panelItems.isEmpty {
            Text("暂无隐藏图标，可在管理界面设置分组。")
                .lineLimit(1)
        } else if model.panelImages.isEmpty {
            Text("正在载入原始图标…")
                .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Text(model.panelUsesCachedImages ? "快照 · 隐藏时不更新" : "原始图标")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("点击外部或 Esc 收起")
                    .fixedSize()
            }
        }
    }
}

private struct HiddenPanelIconButton: View {
    let name: String
    let image: NSImage?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .renderingMode(image.isTemplate ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(isHovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(image == nil ? "\(name) · 尚未取得图像，仍可请求打开菜单" : name)
        .accessibilityLabel(name)
    }
}
