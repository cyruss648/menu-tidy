// Explicit CLI-only experiments for CGPostMouseEvent and one build-checked
// private SLSPostEvent wrapper. Neither is used by ordinary application actions.
// It may affect global input state. Ordinary Menu Tidy actions never use it.
// Only one down/up pair at a verified, empty window owned by this process is
// permitted. There is no cursor warp, hide, suppression, retry or third-party UI.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MenuTidyCore
import MenuTidyDiagnosticInput

@MainActor
private final class LegacyNoCursorProbeView: NSView {
    weak var probe: LegacyNoCursorEventProbe?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        "无光标移动输入诊断：仅测试此空白窗口".draw(
            at: NSPoint(x: 16, y: bounds.height - 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
    }
    override func mouseDown(with event: NSEvent) { probe?.received(event, receiver: "view") }
    override func mouseUp(with event: NSEvent) { probe?.received(event, receiver: "view") }
    override func mouseDragged(with event: NSEvent) { probe?.received(event, receiver: "view") }
}

@MainActor
private final class LegacyNoCursorProbePanel: NSPanel {
    weak var probe: LegacyNoCursorEventProbe?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            probe?.received(event, receiver: "panel")
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class LegacyNoCursorEventProbe: NSObject, NSApplicationDelegate {
    enum Mode: String {
        case legacy
        case privateRecord
        // Retained to describe the failed experiment, never selectable. Its
        // Command down/up left combined-session Command set after process exit.
        case privateRecordCommand

        var apiName: String { self == .legacy ? "CGPostMouseEvent" : "SLSPostEvent" }
        var usesPrivateRecord: Bool { self != .legacy }
        var expectedFlags: CGEventFlags { self == .privateRecordCommand ? .maskCommand : [] }
    }

    private struct Observation {
        let cgPointer: CGPoint?
        let appKitPointer: CGPoint
        let hidButtons: UInt32
        let combinedButtons: UInt32
        let hidModifiers: UInt64
        let combinedModifiers: UInt64
        let activePID: pid_t?
        let ownAppActive: Bool
    }

    private let pid = getpid()
    private let nonce = UUID().uuidString
    private let eventNonce = Int64.random(in: 1...Int64.max)
    private let mode: Mode
    private var eventSource: CGEventSource?
    private let maximumDuration = 10.0
    private let preparationDuration = 1.0
    private let modifierMask: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
        .maskCommand, .maskHelp, .maskSecondaryFn,
    ]
    private var panel: LegacyNoCursorProbePanel?
    private var timer: Timer?
    private var appMonitor: Any?
    private var initial: Observation?
    private var previous: Observation?
    private var targetPoint: CGPoint?
    private var targetCocoaPoint: CGPoint?
    private var expectedFrame: CGRect?
    private var expectedWindowID: CGWindowID?
    private var started = 0.0
    private var downAt: Double?
    private var releasedAt: Double?
    private var stopReason: String?
    private var releasePending = false
    private var downAttempts = 0
    private var upAttempts = 0
    private var downResult: Int32?
    private var upResult: Int32?
    private var sampleCount = 0
    private var stateChangeCount = 0
    private var maximumCGPointerOffset: CGFloat = 0
    private var maximumAppKitPointerOffset: CGFloat = 0
    private var observedHIDButtons: UInt32 = 0
    private var observedCombinedButtons: UInt32 = 0
    private var observedHIDModifiers: UInt64 = 0
    private var observedCombinedModifiers: UInt64 = 0
    private var activeApplicationChanged = false
    private var ownApplicationBecameActive = false
    private var receiveCounts: [String: Int] = [:]
    private var candidateReceiveCounts: [String: Int] = [:]
    private var candidateFlagMatchCounts: [String: Int] = [:]
    private var candidateFlagMismatchCount = 0
    private var finished = false

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        started = ProcessInfo.processInfo.systemUptime
        let first = observation()
        initial = first
        previous = first
        let trusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        emit("start", [
            "pid": pid, "AXIsProcessTrusted": trusted, "CGPreflightPostEventAccess": postAccess,
            "API": mode.apiName, "mode": mode.rawValue, "updateMouseCursorPosition": false,
            "eventNonce": mode.usesPrivateRecord ? eventNonce : 0,
            "expectedEventFlags": mode.expectedFlags.rawValue,
            "keyboardEventsPermitted": false, "dragEventsPermitted": false,
            "maximumSeconds": maximumDuration, "preparationSeconds": preparationDuration,
            "initial": fields(first), "resultBoundary": "self-window experiment; global state isolation unverified",
        ])
        guard trusted, postAccess else { finish("permission-unavailable"); return }
        if mode.usesPrivateRecord {
            guard MenuTidyDiagnosticPrivateRecordAvailable() else {
                finish("private-record-abi-unavailable")
                return
            }
            guard let source = CGEventSource(stateID: .privateState) else {
                finish("private-event-source-unavailable")
                return
            }
            eventSource = source
        }
        guard first.cgPointer != nil, first.activePID != nil else { finish("initial-state-unavailable"); return }
        guard first.hidButtons == 0, first.combinedButtons == 0,
              first.hidModifiers == 0, first.combinedModifiers == 0 else {
            finish("initial-button-or-modifier-held")
            return
        }
        guard !first.ownAppActive, first.activePID != pid else { finish("probe-already-active"); return }
        guard createOwnWindow(awayFrom: first.appKitPointer) else { finish("no-safe-own-window"); return }
        appMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.received(event, receiver: "app") }
            return event
        }
        timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func createOwnWindow(awayFrom pointer: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let area = screen.visibleFrame.insetBy(dx: 32, dy: 32)
        guard area.width >= 360, area.height >= 200 else { return false }
        let size = CGSize(width: 340, height: 170)
        let choices = [
            CGPoint(x: area.minX, y: area.minY),
            CGPoint(x: area.maxX - size.width, y: area.minY),
            CGPoint(x: area.minX, y: area.maxY - size.height),
            CGPoint(x: area.maxX - size.width, y: area.maxY - size.height),
        ].map { CGRect(origin: $0, size: size) }
        guard let frame = choices.filter({ !$0.insetBy(dx: -160, dy: -160).contains(pointer) })
            .max(by: { distance(center($0), pointer) < distance(center($1), pointer) }) else { return false }
        let window = LegacyNoCursorProbePanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.probe = self
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        let view = LegacyNoCursorProbeView(frame: CGRect(origin: .zero, size: size))
        view.probe = self
        window.contentView = view
        panel = window
        window.orderFrontRegardless()
        guard window.windowNumber > 0, UInt64(window.windowNumber) <= UInt64(UInt32.max) else { return false }
        expectedWindowID = CGWindowID(window.windowNumber)
        let primaryTop = screen.frame.maxY
        expectedFrame = CGRect(x: window.frame.minX, y: primaryTop - window.frame.maxY,
            width: window.frame.width, height: window.frame.height)
        targetCocoaPoint = window.convertPoint(toScreen: CGPoint(x: size.width / 2, y: size.height / 2))
        if let targetCocoaPoint {
            targetPoint = CGPoint(x: targetCocoaPoint.x, y: primaryTop - targetCocoaPoint.y)
        }
        emit("windowReady", [
            "windowNumber": window.windowNumber, "targetPoint": targetPoint.map(point) ?? [],
            "frame": expectedFrame.map(rect) ?? [], "appActive": NSApp.isActive,
            "distanceFromInitialPointer": distance(center(frame), pointer),
        ])
        return true
    }

    private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let state = sample()
        if stopReason == nil, let reason = interruption(in: state) { stop(reason) }
        if now - started >= maximumDuration {
            if releasePending { releaseOnce(cleanup: true) }
            finish(stopReason ?? "deadline")
            return
        }
        if let stopReason {
            if releasePending { releaseOnce(cleanup: true) }
            if now - (releasedAt ?? now) >= 0.4 || downAt == nil {
                finish(stopReason)
            }
            return
        }
        if downAt == nil, now - started >= preparationDuration {
            guard validateOwnTarget() else { stop("own-target-validation-failed-before-down"); return }
            // Re-read input after the metadata query, immediately before posting.
            let immediatelyBefore = sample()
            guard interruption(in: immediatelyBefore) == nil else {
                stop(interruption(in: immediatelyBefore) ?? "input-changed-before-down")
                return
            }
            guard let targetPoint else { stop("target-unavailable"); return }
            downAt = now
            downAttempts = 1
            releasePending = true
            emit("send", ["phase": "down", "point": point(targetPoint),
                "windowNumber": expectedWindowID ?? 0, "state": fields(immediatelyBefore)])
            downResult = postButton(at: targetPoint, down: true)
            emit("sendResult", ["phase": "down", "CGError": downResult ?? -1])
            let after = sample()
            if downResult != 0 { stop("down-returned-error-delivery-unknown") }
            else if let reason = interruption(in: after) { stop(reason) }
            return
        }
        if releasePending, let downAt, now - downAt >= 0.06 { releaseOnce(cleanup: false) }
        if let releasedAt, now - releasedAt >= 0.5 { finish("completed-observation") }
    }

    private func stop(_ reason: String) {
        guard !finished else { return }
        if stopReason == nil {
            stopReason = reason
            emit("stopped", ["reason": reason])
        }
        if releasePending { releaseOnce(cleanup: true) }
    }

    private func releaseOnce(cleanup: Bool) {
        guard releasePending, upAttempts == 0 else { return }
        // A cleanup release is the sole additional action permitted after any
        // observed interference. Its destination must still be the exact own
        // window; a lost target never causes a release at another location.
        releasePending = false
        releasedAt = ProcessInfo.processInfo.systemUptime
        guard validateOwnTarget(), let targetPoint else {
            stopReason = stopReason ?? "own-target-lost-before-release"
            emit("releaseSkipped", ["reason": "own-target-no-longer-verified", "cleanup": cleanup,
                "deliveryMayRemainUnpaired": true])
            return
        }
        upAttempts = 1
        emit("send", ["phase": "up", "cleanup": cleanup, "point": point(targetPoint),
            "windowNumber": expectedWindowID ?? 0, "state": fields(sample())])
        upResult = postButton(at: targetPoint, down: false)
        emit("sendResult", ["phase": "up", "CGError": upResult ?? -1, "cleanup": cleanup])
        let after = sample()
        if upResult != 0 { stopReason = stopReason ?? "up-returned-error-delivery-unknown" }
        if let reason = interruption(in: after) { stopReason = stopReason ?? reason }
    }

    private func postButton(at point: CGPoint, down: Bool) -> Int32 {
        switch mode {
        case .legacy:
            return MenuTidyDiagnosticLegacyMouseButton(point.x, point.y, down)
        case .privateRecordCommand:
            // Defense in depth: even an accidental internal construction cannot
            // reach the removed Command transport wrapper.
            return CGError.invalidOperation.rawValue
        case .privateRecord:
            guard let eventSource,
                  let event = CGEvent(mouseEventSource: eventSource,
                      mouseType: down ? .leftMouseDown : .leftMouseUp,
                      mouseCursorPosition: point, mouseButton: .left) else {
                return CGError.failure.rawValue
            }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: eventNonce)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            return MenuTidyDiagnosticPrivateRecordPost(event)
        }
    }

    private func validateOwnTarget() -> Bool {
        guard let panel, panel.isVisible, !panel.isMiniaturized,
              let expectedWindowID, panel.windowNumber == Int(expectedWindowID),
              let targetPoint, let targetCocoaPoint, let expectedFrame,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let matches = windows.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == expectedWindowID
        }
        guard matches.count == 1, let record = matches.first,
              (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.99,
              let bounds = record[kCGWindowBounds as String] as? [String: Any],
              let current = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              abs(current.minX - expectedFrame.minX) < 0.5,
              abs(current.minY - expectedFrame.minY) < 0.5,
              abs(current.width - expectedFrame.width) < 0.5,
              abs(current.height - expectedFrame.height) < 0.5,
              current.insetBy(dx: 24, dy: 24).contains(targetPoint),
              NSWindow.windowNumber(at: targetCocoaPoint, belowWindowWithWindowNumber: 0) == Int(expectedWindowID)
        else { return false }
        return true
    }

    func received(_ event: NSEvent, receiver: String) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let geometryCandidate = downAt.map { now >= $0 && now - $0 < 2 } == true
            && event.windowNumber == panel?.windowNumber
            && targetPoint.map { target in
                event.cgEvent.map { distance($0.location, target) <= 1 } ?? false
            } == true
        let receivedNonce = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
        let nonceMatches = mode.usesPrivateRecord && receivedNonce == eventNonce
        let candidate = geometryCandidate && (mode == .legacy || nonceMatches)
        let cgFlags = event.cgEvent?.flags.rawValue
        let cgFlagsMatch = cgFlags == mode.expectedFlags.rawValue
        let modifierFlagsMatch = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            == mode.expectedFlags.rawValue
        let key = "\(receiver)-\(event.type.rawValue)"
        receiveCounts[key, default: 0] += 1
        if candidate {
            candidateReceiveCounts[key, default: 0] += 1
            if cgFlagsMatch && modifierFlagsMatch {
                candidateFlagMatchCounts[key, default: 0] += 1
            } else { candidateFlagMismatchCount += 1 }
        }
        emit("receive", [
            "receiver": receiver, "eventType": event.type.rawValue, "windowNumber": event.windowNumber,
            "eventNumber": event.eventNumber, "timestamp": event.timestamp,
            "locationInWindow": point(event.locationInWindow),
            "cgLocation": event.cgEvent.map { point($0.location) } ?? [],
            "candidateForProbe": candidate, "eventNonceMatches": nonceMatches,
            "receivedModifierFlags": event.modifierFlags.rawValue,
            "receivedCGFlags": cgFlags ?? 0, "receivedCGFlagsAvailable": cgFlags != nil,
            "expectedEventFlags": mode.expectedFlags.rawValue,
            "receivedModifierFlagsMatch": modifierFlagsMatch, "receivedCGFlagsMatch": cgFlagsMatch,
            "attribution": mode == .legacy
                ? "time-window-and-coordinate-only; legacy API cannot carry nonce"
                : "nonce-and-time-window-and-coordinate; nonce preservation is measured",
        ])
        // Reading state here supplements the timer while the event is delivered.
        // Stop at the next tick, avoiding a nested up post inside mouseDown.
        let state = sample()
        if stopReason == nil, let reason = interruption(in: state) {
            stopReason = reason
            emit("stopped", ["reason": reason])
        }
    }

    private func observation() -> Observation {
        Observation(cgPointer: CGEvent(source: nil)?.location, appKitPointer: NSEvent.mouseLocation,
            hidButtons: buttons(.hidSystemState), combinedButtons: buttons(.combinedSessionState),
            hidModifiers: CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).rawValue,
            combinedModifiers: CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).rawValue,
            activePID: NSWorkspace.shared.frontmostApplication?.processIdentifier, ownAppActive: NSApp.isActive)
    }

    private func sample() -> Observation {
        let state = observation()
        sampleCount += 1
        if let origin = initial?.cgPointer, let pointer = state.cgPointer {
            maximumCGPointerOffset = max(maximumCGPointerOffset, distance(origin, pointer))
        }
        if let initial { maximumAppKitPointerOffset = max(maximumAppKitPointerOffset, distance(initial.appKitPointer, state.appKitPointer)) }
        observedHIDButtons |= state.hidButtons
        observedCombinedButtons |= state.combinedButtons
        observedHIDModifiers |= state.hidModifiers
        observedCombinedModifiers |= state.combinedModifiers
        activeApplicationChanged = activeApplicationChanged || state.activePID != initial?.activePID
        ownApplicationBecameActive = ownApplicationBecameActive || state.ownAppActive
        if let previous, previous.hidButtons != state.hidButtons || previous.combinedButtons != state.combinedButtons
            || previous.hidModifiers != state.hidModifiers || previous.combinedModifiers != state.combinedModifiers
            || previous.activePID != state.activePID || previous.ownAppActive != state.ownAppActive {
            stateChangeCount += 1
            if stateChangeCount <= 20 { emit("stateChanged", fields(state)) }
        }
        previous = state
        return state
    }

    private func interruption(in state: Observation) -> String? {
        guard state.cgPointer != nil, state.activePID != nil else { return "state-unavailable" }
        if maximumCGPointerOffset > 0.01 || maximumAppKitPointerOffset > 0.01 { return "pointer-movement-observed" }
        if state.hidButtons != 0 || state.combinedButtons != 0 { return "global-button-state-observed" }
        if state.hidModifiers != 0 || state.combinedModifiers != 0 { return "global-modifier-state-observed" }
        if activeApplicationChanged || ownApplicationBecameActive { return "active-application-changed" }
        return nil
    }

    private func buttons(_ state: CGEventSourceStateID) -> UInt32 {
        var mask: UInt32 = 0
        for raw in UInt32(0)..<32 {
            if let button = CGMouseButton(rawValue: raw), CGEventSource.buttonState(state, button: button) {
                mask |= UInt32(1) << raw
            }
        }
        return mask
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        if releasePending { releaseOnce(cleanup: true) }
        let state = sample()
        finished = true
        timer?.invalidate()
        timer = nil
        if let appMonitor { NSEvent.removeMonitor(appMonitor) }
        appMonitor = nil
        emit("finish", [
            "reason": stopReason ?? reason, "downAttempts": downAttempts, "upAttempts": upAttempts,
            "downCGError": downResult ?? -1, "upCGError": upResult ?? -1,
            "receiveCounts": receiveCounts, "candidateReceiveCounts": candidateReceiveCounts,
            "candidateFlagMatchCounts": candidateFlagMatchCounts,
            "candidateFlagMismatchCount": candidateFlagMismatchCount,
            "pointerSamples": sampleCount, "maximumCGPointerOffset": maximumCGPointerOffset,
            "maximumAppKitPointerOffset": maximumAppKitPointerOffset,
            "observedHIDButtons": observedHIDButtons, "observedCombinedButtons": observedCombinedButtons,
            "observedHIDModifiers": observedHIDModifiers, "observedCombinedModifiers": observedCombinedModifiers,
            "activeApplicationChanged": activeApplicationChanged, "ownApplicationBecameActive": ownApplicationBecameActive,
            "final": fields(state), "runtimeSeconds": ProcessInfo.processInfo.systemUptime - started,
            "statusItemReorderingTested": false,
        ])
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        NSApp.terminate(nil)
    }

    private func fields(_ state: Observation) -> [String: Any] {
        ["cgPointer": state.cgPointer.map(point) ?? [], "appKitPointer": point(state.appKitPointer),
            "hidButtons": state.hidButtons, "combinedButtons": state.combinedButtons,
            "hidModifiers": state.hidModifiers, "combinedModifiers": state.combinedModifiers,
            "activePID": state.activePID ?? -1, "ownAppActive": state.ownAppActive]
    }

    private func emit(_ kind: String, _ fields: [String: Any]) {
        var record = fields
        record["kind"] = kind
        record["nonce"] = nonce
        record["mode"] = mode.rawValue
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private func point(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }
    private func rect(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
}

/// The parent CLI gate must select this before normal application setup. This
/// second guard keeps accidental direct calls from creating a diagnostic UI.
@MainActor
func runLegacyNoCursorEventProbe() {
    // This must precede NSApplication.shared, delegate creation and all input
    // setup. Do not try to repair an existing global modifier state here.
    if CommandLine.arguments.contains("--probe-private-record-command") {
        print("{\"kind\":\"disabled\",\"reason\":\"disabled-known-global-modifier-side-effect\",\"inputSent\":false}")
        fflush(stdout)
        return
    }
    let plan = MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst()))
    guard plan == .legacyNoCursor || plan == .privateRecord else { return }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let probe = LegacyNoCursorEventProbe(mode: plan == .privateRecord ? .privateRecord : .legacy)
    application.delegate = probe
    withExtendedLifetime(probe) { application.run() }
}
