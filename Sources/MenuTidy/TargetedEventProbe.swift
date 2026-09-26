// Explicit CLI-only controlled experiment; ordinary app startup never calls it.
// Only CGEvent.postToPid(getpid()) is used. No global event posting, cursor warp,
// input suppression, AX permission request, capture, or third-party target exists.
import AppKit
#if canImport(MenuTidyCore)
import MenuTidyCore
#endif
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
private final class ProbeView: NSView {
    weak var probe: TargetedEventProbe?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let title = "后台输入实验"
        title.draw(at: NSPoint(x: 18, y: bounds.height - 42), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let detail = "仅向本进程发送定向事件\n不移动鼠标，不激活其他应用\n最多 15 秒自动退出；结果输出到标准输出"
        detail.draw(in: NSRect(x: 18, y: 18, width: bounds.width - 36, height: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
    override func mouseDown(with event: NSEvent) { probe?.received(event, receiver: "view") }
    override func mouseDragged(with event: NSEvent) { probe?.received(event, receiver: "view") }
    override func mouseUp(with event: NSEvent) { probe?.received(event, receiver: "view") }
}

@MainActor
private final class ProbePanel: NSPanel {
    weak var probe: TargetedEventProbe?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            probe?.received(event, receiver: "panel")
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class TargetedEventProbe: NSObject, NSApplicationDelegate {
    private enum Routing: String, CaseIterable {
        case defaults
        case window91
        case handling92
        case both91and92
        case targetPIDand91and92
        case diagnosticPrivateWindow
    }
    private struct PlannedEvent {
        let routing: Routing
        let gesture: String
        let type: CGEventType
        let point: CGPoint
        let command: Bool
    }
    private let pid = getpid()
    private let nonce = UUID().uuidString
    private let tagBase = Int64.random(in: 1_000_000...Int64.max / 4)
    private var panel: ProbePanel?
    private var source: CGEventSource?
    private var plan: [PlannedEvent] = []
    private var sent: [Int64: PlannedEvent] = [:]
    private var timer: Timer?
    private var appEventMonitor: Any?
    private let privateWindowFieldEnabled = CommandLine.arguments.contains("--probe-private-window-field")
    private var startTime = 0.0
    private var firstPointer: CGPoint?
    private var pointerAtFirstSend: CGPoint?
    private var maximumPointerOffset: CGFloat = 0
    private var maximumPointerOffsetDuringPosting: CGFloat = 0
    private var sampleCount = 0
    private var buttonObserved = false
    private var preparationButtonObserved = false
    private let preparationDuration = 2.0
    private var receiveOrdinal = 0
    private var nextIndex = 0
    private var nextSendTime = 0.0
    private var lastSentTime = 0.0
    private var heldSyntheticEvent: PlannedEvent?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        startTime = ProcessInfo.processInfo.systemUptime
        firstPointer = CGEvent(source: nil)?.location
        let accessibilityGranted = AXIsProcessTrusted()
        let postEventGranted = CGPreflightPostEventAccess()
        emit("start", ["pid": pid, "sourceState": "privateState",
            "AXIsProcessTrusted": accessibilityGranted, "CGPreflightPostEventAccess": postEventGranted,
            "privateWindowFieldEnabled": privateWindowFieldEnabled,
            "preparationSeconds": preparationDuration, "pointerBefore": firstPointer.map(coordinate) ?? [],
            "appActive": NSApp.isActive])
        guard accessibilityGranted, postEventGranted else {
            finish(reason: "permission-unavailable")
            return
        }
        appEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.received(event, receiver: "app") }
            return event
        }
        guard let screen = NSScreen.screens.first, firstPointer != nil,
              let privateSource = CGEventSource(stateID: .privateState) else {
            finish(reason: "setup-unavailable")
            return
        }
        source = privateSource
        let pointer = NSEvent.mouseLocation
        let area = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let size = NSSize(width: min(380, area.width), height: min(190, area.height))
        let choices = [
            NSPoint(x: area.minX, y: area.minY),
            NSPoint(x: area.maxX - size.width, y: area.minY),
            NSPoint(x: area.minX, y: area.maxY - size.height),
            NSPoint(x: area.maxX - size.width, y: area.maxY - size.height),
        ].map { NSRect(origin: $0, size: size) }
        guard let frame = choices.filter({ !$0.insetBy(dx: -32, dy: -32).contains(pointer) })
            .max(by: { distance($0.center, pointer) < distance($1.center, pointer) }) else {
            finish(reason: "no-window-location-away-from-pointer")
            return
        }
        let panel = ProbePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.probe = self
        panel.title = "后台输入实验"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        let view = ProbeView(frame: NSRect(origin: .zero, size: frame.size))
        view.probe = self
        panel.contentView = view
        self.panel = panel
        panel.orderFrontRegardless()
        guard panel.windowNumber > 0 else { finish(reason: "own-window-unavailable"); return }

        let base = panel.convertPoint(toScreen: NSPoint(x: frame.width * 0.45, y: frame.height * 0.4))
        // AppKit screen coordinates are bottom-up; CGEvent coordinates use the
        // primary display's top-left origin, including secondary display offsets.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: base.x, y: primaryTop - base.y)
        for routing in Routing.allCases where routing != .diagnosticPrivateWindow || privateWindowFieldEnabled {
            plan.append(PlannedEvent(routing: routing, gesture: "click", type: .leftMouseDown, point: point, command: false))
            plan.append(PlannedEvent(routing: routing, gesture: "click", type: .leftMouseUp, point: point, command: false))
            plan.append(PlannedEvent(routing: routing, gesture: "command-drag", type: .leftMouseDown, point: point, command: true))
            plan.append(PlannedEvent(routing: routing, gesture: "command-drag", type: .leftMouseDragged,
                point: CGPoint(x: point.x + 36, y: point.y), command: true))
            plan.append(PlannedEvent(routing: routing, gesture: "command-drag", type: .leftMouseUp,
                point: CGPoint(x: point.x + 36, y: point.y), command: true))
        }
        emit("windowReady", ["windowNumber": panel.windowNumber, "plannedEvents": plan.count,
            "windowContainsInitialPointer": frame.contains(pointer), "appActive": NSApp.isActive])
        nextSendTime = startTime + preparationDuration
        timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        guard !finished else { return }
        samplePointer()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - startTime < 14 else { finish(reason: "deadline"); return }
        // Do not attribute a launch click's trailing button state to a post.
        guard now - startTime >= preparationDuration else { return }
        // Physical user input or a surprising combined-session state ends the
        // experiment; it is recorded, never suppressed or counteracted globally.
        if combinedButtons() != 0 { finish(reason: "combined-session-button-observed"); return }
        guard nextIndex < plan.count else {
            if now - lastSentTime >= 1 { finish(reason: "completed") }
            return
        }
        guard now >= nextSendTime else { return }
        if nextIndex == 0 { pointerAtFirstSend = CGEvent(source: nil)?.location }
        let planned = plan[nextIndex]
        nextIndex += 1
        dispatch(planned, ordinal: nextIndex, cleanup: false)
        lastSentTime = now
        nextSendTime = now + (planned.type == .leftMouseUp ? 0.25 : 0.12)
    }

    private func dispatch(_ planned: PlannedEvent, ordinal: Int, cleanup: Bool) {
        guard let panel, let source,
              let event = CGEvent(mouseEventSource: source, mouseType: planned.type,
                  mouseCursorPosition: planned.point, mouseButton: .left) else {
            emit("eventCreationFailed", ["ordinal": ordinal])
            return
        }
        let tag = tagBase + Int64(ordinal)
        event.flags = planned.command ? .maskCommand : []
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.setIntegerValueField(.mouseEventNumber, value: Int64(ordinal))
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        let explicitTarget = planned.routing == .targetPIDand91and92 || planned.routing == .diagnosticPrivateWindow
        if planned.routing == .window91 || planned.routing == .both91and92 || explicitTarget {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        }
        if planned.routing == .handling92 || planned.routing == .both91and92 || explicitTarget {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(panel.windowNumber))
        }
        if explicitTarget {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        }
        // Undocumented window-routing field, isolated to this explicit CLI
        // experiment. Never used for normal app actions or another process.
        if planned.routing == .diagnosticPrivateWindow, privateWindowFieldEnabled,
           let privateField = CGEventField(rawValue: 0x33) {
            event.setIntegerValueField(privateField, value: Int64(panel.windowNumber))
        }
        sent[tag] = planned
        if planned.type == .leftMouseDown { heldSyntheticEvent = planned }
        if planned.type == .leftMouseUp { heldSyntheticEvent = nil }
        samplePointer()
        emit("send", ["tag": tag, "ordinal": ordinal, "routing": planned.routing.rawValue,
            "gesture": planned.gesture, "eventType": planned.type.rawValue, "command": planned.command,
            "targetPID": pid, "targetWindow": panel.windowNumber, "point": coordinate(planned.point),
            "eventTargetPIDField": event.getIntegerValueField(.eventTargetUnixProcessID),
            "window91": event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            "window92": event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
            "privateWindowField": planned.routing == .diagnosticPrivateWindow,
            "pointerObserved": CGEvent(source: nil).map { coordinate($0.location) } ?? [],
            "combinedButtons": combinedButtons(), "cleanup": cleanup])
        event.postToPid(pid)
        samplePointer()
    }

    func received(_ event: NSEvent, receiver: String) {
        receiveOrdinal += 1
        let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        let planned = sent[tag]
        samplePointer()
        emit("receive", ["receiveOrdinal": receiveOrdinal, "receiver": receiver, "tag": tag,
            "matchedNonce": planned != nil, "routing": planned?.routing.rawValue ?? "unmatched",
            "gesture": planned?.gesture ?? "unmatched", "eventType": event.type.rawValue,
            "eventNumber": event.eventNumber,
            "windowNumber": event.windowNumber, "expectedWindow": panel?.windowNumber ?? -1,
            "locationInWindow": coordinate(event.locationInWindow),
            "cgLocation": event.cgEvent.map { coordinate($0.location) } ?? [],
            "pointerObserved": CGEvent(source: nil).map { coordinate($0.location) } ?? [],
            "command": event.modifierFlags.contains(.command), "timestamp": event.timestamp,
            "combinedButtons": combinedButtons()])
    }

    private func samplePointer() {
        sampleCount += 1
        if let firstPointer, let current = CGEvent(source: nil)?.location {
            maximumPointerOffset = max(maximumPointerOffset, distance(firstPointer, current))
            if let pointerAtFirstSend {
                maximumPointerOffsetDuringPosting = max(maximumPointerOffsetDuringPosting, distance(pointerAtFirstSend, current))
            }
        }
        if ProcessInfo.processInfo.systemUptime - startTime < preparationDuration {
            preparationButtonObserved = preparationButtonObserved || combinedButtons() != 0
        } else {
            buttonObserved = buttonObserved || combinedButtons() != 0
        }
    }

    private func combinedButtons() -> Int {
        var mask = 0
        for (button, bit) in [(CGMouseButton.left, 1), (.right, 2), (.center, 4)] {
            if CGEventSource.buttonState(.combinedSessionState, button: button) { mask |= bit }
        }
        return mask
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if let appEventMonitor { NSEvent.removeMonitor(appEventMonitor) }
        appEventMonitor = nil
        if let heldSyntheticEvent {
            let release = PlannedEvent(routing: heldSyntheticEvent.routing, gesture: "cleanup",
                type: .leftMouseUp, point: heldSyntheticEvent.point, command: heldSyntheticEvent.command)
            dispatch(release, ordinal: plan.count + 1, cleanup: true)
        }
        samplePointer()
        emit("finish", ["reason": reason, "sentPlannedEvents": nextIndex, "receivedEvents": receiveOrdinal,
            "pointerSamples": sampleCount, "pointerBefore": firstPointer.map(coordinate) ?? [],
            "pointerAtFirstSend": pointerAtFirstSend.map(coordinate) ?? [],
            "pointerAfter": CGEvent(source: nil).map { coordinate($0.location) } ?? [],
            "maximumPointerOffset": maximumPointerOffset, "combinedButtonEverObserved": buttonObserved,
            "maximumPointerOffsetDuringPosting": maximumPointerOffsetDuringPosting,
            "preparationButtonObserved": preparationButtonObserved,
            "combinedButtonsAfter": combinedButtons(), "appActive": NSApp.isActive,
            "runtimeSeconds": ProcessInfo.processInfo.systemUptime - startTime])
        panel?.close()
        NSApp.terminate(nil)
    }

    private func emit(_ kind: String, _ fields: [String: Any]) {
        var record = fields
        record["kind"] = kind
        record["nonce"] = nonce
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    private func coordinate(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }
    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Called only by an explicit diagnostic CLI branch before normal app setup.
/// Reusing the installed application's executable lets TCC evaluate its actual
/// signing identity. Neither this entry nor the delegate requests permission.
@MainActor
func runTargetedEventProbe() {
    guard MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) == .targetedEvents else { return }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let probe = TargetedEventProbe()
    application.delegate = probe
    withExtendedLifetime(probe) { application.run() }
}
