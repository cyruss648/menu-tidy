import AppKit
import MenuTidyCore
import OSLog

/// Lives as long as the app: closing a panel must not remove the mouse-up
/// observer or the control press that will arrive after that passive dismissal.
@MainActor
final class PanelControlRouter {
    private let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "PanelGesture")
    private weak var model: MenuTidyModel?
    private var state = PanelControlGestureState()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start(model: MenuTidyModel) {
        guard localMonitor == nil, globalMonitor == nil else { return }
        self.model = model
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
    }

    func presentationChanged(isPresented: Bool) {
        state.presentationChanged(isPresented: isPresented, at: ProcessInfo.processInfo.systemUptime)
    }

    func controlClicked(event: NSEvent?) {
        if let event, let mouse = mouseEvent(event), mouse.phase == .down {
            // Remote-hosted down actions may arrive after the physical release.
            // Down only arms (or is rejected by the event ledger), never toggles.
            // An AXPress carrying stale down data therefore safely does nothing.
            let buttonIsPressed = NSEvent.pressedMouseButtons & (1 << mouse.button) != 0
            state.beginControlPress(mouse)
            logger.info("action=controlDown button=\(mouse.button) physicalButtonHeld=\(buttonIsPressed) timestamp=\(mouse.timestamp) eventNumber=\(mouse.eventNumber) generation=\(self.state.generation)")
            return
        }
        let mouse = event.flatMap(mouseEvent)
        let hasPress = mouse.map { state.hasControlPress(for: $0) } ?? false
        // A physical release without its control-down ticket must not borrow
        // the non-mouse toggle path: focus may already have closed the panel.
        // AX/keyboard actions with no mouse event remain independent actions.
        let decision = state.controlRelease(mouse)
        logger.info("action=controlRelease matchedPress=\(hasPress) close=\(decision == .close) show=\(decision == .show) timestamp=\(event?.timestamp ?? -1) generation=\(self.state.generation)")
        switch decision {
        case .close: model?.closeIconPanel()
        case .show:
            // A remote-hosted status item can report its primary-display
            // window even when activated on a secondary menu bar. Capture
            // the physical pointer before presentation changes window focus.
            model?.showIconPanelFromControl(at: NSEvent.mouseLocation)
        case .ignore: break
        }
    }

    private func observe(_ event: NSEvent) {
        guard let mouse = mouseEvent(event) else { return }
        state.observe(mouse)
        logger.debug("action=observedMouse button=\(mouse.button) down=\(mouse.phase == .down) timestamp=\(mouse.timestamp) shouldDismiss=\(self.state.shouldDismiss(for: mouse)) generation=\(self.state.generation)")
        guard state.shouldDismiss(for: mouse), let model,
              let point = screenPoint(for: event), !model.iconPanelContains(point) else { return }
        logger.debug("action=outsideDismiss button=\(mouse.button) generation=\(self.state.generation)")
        model.closeIconPanel()
    }

    private func mouseEvent(_ event: NSEvent) -> PanelControlGestureState.MouseEvent? {
        let phase: PanelControlGestureState.Phase
        switch event.type {
        case .leftMouseDown, .rightMouseDown: phase = .down
        case .leftMouseUp, .rightMouseUp: phase = .up
        default: return nil
        }
        return .init(button: event.buttonNumber, phase: phase, timestamp: event.timestamp, eventNumber: event.eventNumber)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        guard let point = event.cgEvent?.location, let primaryScreen = NSScreen.screens.first else { return nil }
        return NSPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        model = nil
        state = PanelControlGestureState()
    }
}
