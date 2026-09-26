// Explicit diagnostic mode only. These two temporary items belong to this
// process. Host routing requires an explicit flag and a resolver binding to
// these exact two source buttons. The explicit weights mode changes only its
// UUID keys in MenuBarAgent's dictionary; external layout effects are unverified.
// The undocumented 0x33 event field is an experiment, not normal app behavior.
import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
import Darwin
import Foundation
import MenuTidyCore
import ObjectiveC
@preconcurrency import ScreenCaptureKit

@MainActor
private final class TargetedStatusItemProbe: NSObject, NSApplicationDelegate {
    private struct SavedPreference {
        let key: String
        let existed: Bool
        let value: Any?
    }
    private struct OwnItemGeometry {
        let windowNumber: Int
        let frame: CGRect
        let sourcePID: pid_t
        let targetPID: pid_t
    }
    private struct SentEvent {
        let command: Bool
        let sourceWindowNumber: Int
        var sendCount: Int
    }
    private struct SentEventKey: Hashable {
        let number: Int
        let type: UInt32
    }
    private struct WeightsInputSample {
        let cgPointer: CGPoint?
        let appKitPointer: CGPoint?
        let hidButtons: UInt32?
        let combinedButtons: UInt32?
        let hidFlags: UInt64
        let combinedFlags: UInt64
    }
    private enum Phase: String {
        case preparation, observation, axPending, axConfirm, preferredConfirm, weightsNudge, weightsFirst, weightsSecond, hidingBaseline, hidingRaised, hidingRestored, clickDown, clickUp, confirmClick, dragDown, dragMove, dragUp, confirmOrder
    }
    private let pid = getpid()
    private let hostMode = CommandLine.arguments.contains("--probe-status-host")
    private let hostDragOptIn = CommandLine.arguments.contains("--probe-status-host-drag")
    private let preferredPositionOptIn = CommandLine.arguments.contains("--probe-preferred-position")
    private let preferredReorderOptIn = CommandLine.arguments.contains("--probe-preferred-reorder")
    private let menuAgentWeightsOptIn = CommandLine.arguments.contains("--probe-menu-agent-weights")
    private let positionHidingOptIn = CommandLine.arguments.contains("--probe-position-hiding")
    private let menuAgentContainerOptIn = CommandLine.arguments.contains("--probe-menu-agent-container")
    private let observeOnly = CommandLine.arguments.contains("--probe-observe-only")
    private let sourceAXOptIn = CommandLine.arguments.contains("--probe-ax-source") || CommandLine.arguments.contains("--probe-source-ax")
    private let hostAXOptIn = CommandLine.arguments.contains("--probe-ax-host")
    private let showMenuAXOptIn = CommandLine.arguments.contains("--probe-ax-showmenu")
    private var identifierA: String { menuAgentWeightsOptIn ? "MenuTidyProbe-\(nonce)-A" : "menu-tidy-probe-a" }
    private var identifierB: String { menuAgentWeightsOptIn ? "MenuTidyProbe-\(nonce)-B" : "menu-tidy-probe-b" }
    private let nonce = UUID().uuidString
    private let tagBase = Int64.random(in: 1_000_000...Int64.max / 4)
    private let eventNumberBase = Int.random(in: 1_000_000...(Int(Int32.max) - 1_024))
    private var itemA: NSStatusItem?
    private var itemB: NSStatusItem?
    private var hostRegistrationToken: UUID?
    private var preferredPositionNames: (a: String, b: String)?
    private var preferenceDomain: String?
    private var savedPreferences: [SavedPreference] = []
    private var source: CGEventSource?
    private var timer: Timer?
    private var appMonitor: Any?
    private var axTask: Task<Void, Never>?
    private var axWorker: Task<StatusItemAXProbe.Report, Never>?
    private var axActionCountBeforeA = 0
    private var axActionCountBeforeB = 0
    private var axActionWasDispatched = false
    private var phase: Phase = .preparation
    private var phaseDeadline = 0.0
    private var nextObservation = 0.0
    private var startTime = 0.0
    private var originalA: OwnItemGeometry?
    private var originalB: OwnItemGeometry?
    private var dragStart: CGPoint?
    private var dragDestination: CGPoint?
    private var dragStep = 0
    private var sentCount = 0
    private var sentTags: Set<Int64> = []
    private var sentEvents: [SentEventKey: SentEvent] = [:]
    private var gestureCount = 0
    private var activeGestureNumber: Int?
    private var actionCountA = 0
    private var actionCountB = 0
    private var confirmedClickActionCountA = 0
    private var sceneCorrelatedClickActionCountA = 0
    private var pointerBefore: CGPoint?
    private var pointerAtFirstSend: CGPoint?
    private var maxPointerOffset: CGFloat = 0
    private var maxPostingOffset: CGFloat = 0
    private var pointerSamples = 0
    private var preparationButtonObserved = false
    private var buttonObserved = false
    private var held = false
    private var lastPostedPoint: CGPoint?
    private var finished = false
    private var preferredStableObservations = 0
    private var menuAgentContainerDomainURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar")
    }
    private var menuAgentDomain: CFString {
        (menuAgentContainerOptIn ? menuAgentContainerDomainURL.path : "com.apple.MenuBarAgent") as CFString
    }
    private var menuAgentStorageScope: String {
        menuAgentContainerOptIn ? "actual-container-absolute-path-public-CFPreferences" : "legacy-menu-bar-agent-domain-public-CFPreferences"
    }
    private let menuAgentWeightsKey = "TrailingItemPreferredPositions" as CFString
    private var menuAgentOriginalEntries: [String: NSNumber]?
    private var menuAgentKeyExisted = false
    private var menuAgentOwnedKeys: (a: String, b: String)?
    private var menuAgentWrittenWeights: [String: Int] = [:]
    private var weightsNudgeTask: Task<Void, Never>?
    private var weightsNudgeBaseline: CGFloat?
    private var weightsNudgeItem: NSStatusItem?
    private var weightsObservationDeadline = 0.0
    private var weightsLastOrder: Bool?
    private var weightsFirstOrder: Bool?
    private var weightsStableObservations = 0
    private var weightsCleanupVerified = false
    private var weightsInputInitial: WeightsInputSample?
    private var weightsInputLatest: WeightsInputSample?
    private var weightsInputFailure: String?
    private var weightsInputSamples = 0
    private var weightsMaxCGOffset: CGFloat = 0
    private var weightsMaxAppKitOffset: CGFloat = 0
    private var weightsObservedHIDButtons: UInt32 = 0
    private var weightsObservedCombinedButtons: UInt32 = 0
    private var weightsObservedHIDFlags: UInt64 = 0
    private var weightsObservedCombinedFlags: UInt64 = 0
    private var weightsObservedReversal: Bool?
    private var positionSourceElements: [String: AXUIElement] = [:]
    private var hidingBaselineA: OwnItemGeometry?
    private var hidingBaselineB: OwnItemGeometry?
    private var hidingLastAFrame: CGRect?
    private var hidingLastBFrame: CGRect?
    private var hidingStageSamples = 0
    private var hidingRaisedSamples = 0
    private var hidingRaisedVisibleSamples = 0
    private var hidingRaisedUnknownSamples = 0
    private var hidingRestoredGeometry = false
    private var hidingCaptureTask: Task<Void, Never>?
    private var hidingCaptureTimeout: Task<Void, Never>?
    private var hidingCaptureToken: UUID?
    private var hidingCaptureAttemptedStages: Set<String> = []
    private struct HidingCaptureContext: Equatable {
        let displayID: CGDirectDisplayID
        let displayBounds: CGRect
        let hostPID: pid_t
        let hostEpoch: TimeInterval
        let windowID: Int
        let windowFrame: CGRect
        let captureRect: CGRect
        let safeAreaTop: CGFloat
        let statusThickness: CGFloat
        let expectedA: Int
    }
    private var diagnosticLifetime: Double { observeOnly ? 45 : (positionHidingOptIn ? 24 : 14) }
    private var usesAX: Bool { sourceAXOptIn || hostAXOptIn }
    private var usesSyntheticEvents: Bool { !usesAX && !observeOnly && !preferredReorderOptIn && !menuAgentWeightsOptIn && !positionHidingOptIn }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startTime = ProcessInfo.processInfo.systemUptime
        pointerBefore = CGEvent(source: nil)?.location
        let trusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        emit("start", ["pid": pid, "AXIsProcessTrusted": trusted,
            "CGPreflightPostEventAccess": postAccess, "sourceState": usesSyntheticEvents ? "privateState" : "none",
            "privateWindowField": usesSyntheticEvents ? "0x33" : "unused", "appActive": NSApp.isActive,
            "hostMode": hostMode, "hostDragOptIn": hostDragOptIn,
            "preferredPositionOptIn": preferredPositionOptIn,
            "preferredReorderOptIn": preferredReorderOptIn,
            "menuAgentWeightsOptIn": menuAgentWeightsOptIn, "usesSyntheticEvents": usesSyntheticEvents,
            "menuAgentContainerOptIn": menuAgentContainerOptIn, "weightsStorageScope": menuAgentStorageScope,
            "positionHidingOptIn": positionHidingOptIn,
            "observeOnly": observeOnly, "maximumLifetimeSeconds": diagnosticLifetime,
            "eventNumberBase": eventNumberBase,
            "axSource": sourceAXOptIn, "axHost": hostAXOptIn, "axShowMenu": showMenuAXOptIn,
            "pointerBefore": pointerBefore.map(coordinate) ?? []])
        guard !positionHidingOptIn || (menuAgentWeightsOptIn && menuAgentContainerOptIn) else {
            finish("position-hiding-requires-container-weights-mode")
            return
        }
        guard !menuAgentContainerOptIn || menuAgentWeightsOptIn else { finish("container-requires-weights-mode"); return }
        if menuAgentWeightsOptIn {
            var allowed = Set(["--probe-status-items", "--probe-menu-agent-weights", "--probe-preferred-position", "--probe-status-host"])
            if menuAgentContainerOptIn { allowed.insert("--probe-menu-agent-container") }
            if positionHidingOptIn { allowed.insert("--probe-position-hiding") }
            guard preferredPositionOptIn, hostMode, CommandLine.arguments.contains("--probe-status-items"),
                  !CommandLine.arguments.contains(where: { $0.hasPrefix("--probe-") && !allowed.contains($0) }),
                  Bundle.main.bundleIdentifier == "dev.hdh.MenuTidy" else {
                finish("menu-agent-weights-incompatible-options")
                return
            }
        }
        guard !(sourceAXOptIn && hostAXOptIn), !(usesAX && hostDragOptIn),
              !showMenuAXOptIn || usesAX else { finish("incompatible-ax-options"); return }
        guard !preferredReorderOptIn || (preferredPositionOptIn && hostMode && !usesAX && !hostDragOptIn) else {
            finish("preferred-reorder-requires-only-owned-host-and-preferences")
            return
        }
        // Observation creates no synthetic event source and never requires or
        // requests event-post permission. Failed AX reads remain diagnostic.
        if !observeOnly {
            guard trusted, !usesSyntheticEvents || postAccess else { finish("permission-unavailable"); return }
            if usesSyntheticEvents {
                guard !hostDragOptIn || hostMode else { finish("host-drag-requires-host-mode"); return }
                guard let source = CGEventSource(stateID: .privateState) else { finish("source-unavailable"); return }
                self.source = source
            }
        }
        if menuAgentWeightsOptIn && !sampleWeightsInput() { finish("menu-agent-weights-input-rejected"); return }
        if preferredPositionOptIn && !preparePreferredPositions() {
            finish("temporary-preference-setup-unavailable")
            return
        }
        let a = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        itemA = a
        if let names = preferredPositionNames { a.autosaveName = names.a }
        let b = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        itemB = b
        if let names = preferredPositionNames { b.autosaveName = names.b }
        guard let buttonA = a.button, let buttonB = b.button else { finish("own-button-unavailable"); return }
        for button in [buttonA, buttonB] {
            button.target = self
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = observeOnly
                ? "菜单栏观察实验：不发送输入，最多 45 秒自动移除"
                : (menuAgentWeightsOptIn ? "菜单栏权重实验：不发送输入，最多 \(Int(diagnosticLifetime)) 秒自动移除" : "后台输入实验：临时菜单栏项，最多 15 秒自动移除")
        }
        buttonA.title = "MT-A"
        buttonB.title = "MT-B"
        buttonA.setAccessibilityIdentifier(identifierA)
        buttonB.setAccessibilityIdentifier(identifierB)
        if hostMode {
            do {
                hostRegistrationToken = try MenuBarHostTarget.registerOwnedItems(
                    [(item: a, identifier: identifierA), (item: b, identifier: identifierB)], expectedOwnerPID: pid)
                emit("ownHostRegistration", ["registered": true, "ownedItemCount": 2, "exactLocalObjects": true])
            } catch {
                emit("ownHostRegistration", ["registered": false, "reason": error.localizedDescription])
                finish("own-host-registration-failed")
                return
            }
        }
        buttonA.action = #selector(actionA)
        buttonB.action = #selector(actionB)
        appMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.received(event) }
            return event
        }
        phaseDeadline = startTime + 2
        if observeOnly {
            phase = .observation
            nextObservation = startTime + 5
            emit("observationReady", ["sendsEvents": false, "intervalSeconds": 5,
                "deadlineUptime": startTime + 45])
        }
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func actionA() {
        actionCountA += 1
        let event = NSApp.currentEvent
        let tag = event?.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        if sentTags.contains(tag), event?.modifierFlags.contains(.command) == false,
           phase == .clickDown || phase == .clickUp || phase == .confirmClick {
            confirmedClickActionCountA += 1
        }
        if sceneMatches(event), event?.type == .leftMouseUp,
           event?.modifierFlags.contains(.command) == false,
           phase == .clickDown || phase == .clickUp || phase == .confirmClick {
            sceneCorrelatedClickActionCountA += 1
        }
        logAction("MT-A", count: actionCountA)
    }

    func applicationWillTerminate(_ notification: Notification) {
        axWorker?.cancel()
        axTask?.cancel()
        removeProbeItemsAndRestorePreferences()
    }

    @objc private func actionB() {
        actionCountB += 1
        logAction("MT-B", count: actionCountB)
    }

    private func logAction(_ item: String, count: Int) {
        let event = NSApp.currentEvent
        let tag = event?.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        emit("action", ["item": item, "count": count, "phase": phase.rawValue,
            "tag": tag, "matchedNonce": sentTags.contains(tag), "windowNumber": event?.windowNumber ?? -1,
            "timestamp": event?.timestamp ?? -1, "eventNumber": event?.eventNumber ?? -1,
            "sceneCorrelated": item == "MT-A" && sceneMatches(event),
            "command": event?.modifierFlags.contains(.command) ?? false])
    }

    private func received(_ event: NSEvent) {
        let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        emit("receive", ["receiver": "app", "tag": tag, "matchedNonce": sentTags.contains(tag),
            "eventType": event.type.rawValue, "eventNumber": event.eventNumber,
            "timestamp": event.timestamp, "sceneCorrelated": sceneMatches(event),
            "windowNumber": event.windowNumber, "locationInWindow": coordinate(event.locationInWindow),
            "cgLocation": event.cgEvent.map { coordinate($0.location) } ?? [],
            "command": event.modifierFlags.contains(.command), "combinedButtons": combinedButtons()])
    }

    /// Scene hosting can rebuild an event without its user-data tag. Accept a
    /// separate correlation only when the per-gesture event number, event kind,
    /// modifiers and A's exact source window all agree. Time proximity alone
    /// never establishes this link; B's action never counts as A's delivery.
    private func sceneMatches(_ event: NSEvent?) -> Bool {
        guard hostMode, let event else { return false }
        let type: CGEventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseUp: type = .leftMouseUp
        case .leftMouseDragged: type = .leftMouseDragged
        default: return false
        }
        let key = SentEventKey(number: event.eventNumber, type: type.rawValue)
        guard let sent = sentEvents[key],
              // Repeated drag samples belong to one gesture. A click action
              // must instead correlate with exactly one posted mouse-up.
              type == .leftMouseDragged || sent.sendCount == 1,
              sent.sourceWindowNumber > 0,
              event.windowNumber == sent.sourceWindowNumber,
              itemA?.button?.window?.windowNumber == sent.sourceWindowNumber,
              event.modifierFlags.contains(.command) == sent.command,
              event.buttonNumber == 0 else { return false }
        return true
    }

    private func tick() {
        guard !finished else { return }
        samplePointer()
        if menuAgentWeightsOptIn && weightsInputFailure != nil { finish("menu-agent-weights-input-rejected"); return }
        let now = ProcessInfo.processInfo.systemUptime
        if observeOnly {
            guard now - startTime < 45 else { finish("observation-deadline"); return }
            guard now >= nextObservation else { return }
            nextObservation += 5
            logReadOnlyStatusItemMetadata()
            emitGeometry("observationGeometry")
            return
        }
        guard now - startTime < diagnosticLifetime else { finish("deadline"); return }
        guard now - startTime >= 2 else { return }
        guard maxPostingOffset == 0 else { finish("pointer-observation-changed"); return }
        guard combinedButtons() == 0 else { finish("combined-session-button-observed"); return }
        guard now >= phaseDeadline else { return }
        switch phase {
        case .observation:
            // The early observation branch never enters the action machine.
            return
        case .axPending:
            return
        case .weightsNudge:
            return
        case .weightsFirst, .weightsSecond:
            observeMenuAgentWeights()
            return
        case .hidingBaseline, .hidingRaised, .hidingRestored:
            observePositionHiding()
            return
        case .preferredConfirm:
            guard let a = geometry(itemA), let b = geometry(itemB), reliableClickPair(a, b),
                  let originalA, let originalB else {
                preferredStableObservations = 0
                phaseDeadline = now + 0.2
                return
            }
            guard a.targetPID == originalA.targetPID, b.targetPID == originalB.targetPID,
                  a.windowNumber == originalA.windowNumber, b.windowNumber == originalB.windowNumber else {
                finish("preferred-host-replaced")
                return
            }
            // AX reads above may block. Reconcile input again before assigning
            // a successful observation to the defaults update.
            samplePointer()
            guard maxPostingOffset == 0 else { finish("pointer-observation-changed"); return }
            guard combinedButtons() == 0 else { finish("combined-session-button-observed"); return }
            let changed = (a.frame.midX < b.frame.midX) != (originalA.frame.midX < originalB.frame.midX)
            preferredStableObservations = changed ? preferredStableObservations + 1 : 0
            if preferredStableObservations >= 3 {
                emitGeometry("preferredAfterGeometry")
                emit("preferredOrderResult", ["ownOrderChanged": true, "consecutiveObservations": preferredStableObservations,
                    "cgEventSends": sentCount, "method": "public-autosaveName-reload"])
                finish("preferred-order-changed")
            } else if now - startTime > 6 {
                emit("preferredOrderResult", ["ownOrderChanged": false, "cgEventSends": sentCount,
                    "method": "public-autosaveName-reload"])
                finish("preferred-order-unchanged")
            } else { phaseDeadline = now + 0.2 }
        case .axConfirm:
            let observed = axActionWasDispatched && actionCountA - axActionCountBeforeA == 1 &&
                actionCountB == axActionCountBeforeB && !buttonObserved && maxPostingOffset == 0
            emit("axResult", ["evidence": observed ? "AX-observed-only" : "unconfirmed",
                "sourceActionObserved": observed, "nonceConfirmed": false,
                "actionCountDeltaA": actionCountA - axActionCountBeforeA,
                "actionCountDeltaB": actionCountB - axActionCountBeforeB, "cgEventSends": sentCount])
            finish(observed ? "ax-observed-only" : "ax-unconfirmed")
        case .preparation:
            logReadOnlyStatusItemMetadata()
            if usesAX { startAXProbe(); return }
            guard let a = geometry(itemA), let b = geometry(itemB),
                  hostMode && !hostDragOptIn ? reliableClickPair(a, b) : reliablePair(a, b) else {
                emitGeometry("invalidInitialGeometry")
                finish("own-window-or-adjacency-unavailable")
                return
            }
            originalA = a
            originalB = b
            emitGeometry("originalGeometry")
            if menuAgentWeightsOptIn {
                pointerAtFirstSend = CGEvent(source: nil)?.location
                do {
                    try prepareMenuAgentWeights()
                    try writeMenuAgentWeights(a: positionHidingOptIn ? 200 : 100, b: positionHidingOptIn ? 100 : 200)
                    requestMenuAgentNudge(nextPhase: positionHidingOptIn ? .hidingBaseline : .weightsFirst)
                } catch {
                    emit("menuAgentWeightsRejected", ["reason": error.localizedDescription])
                    finish("menu-agent-weights-preparation-failed")
                }
                return
            }
            if preferredReorderOptIn {
                guard let names = preferredPositionNames, let itemA, let itemB else {
                    finish("preferred-items-unavailable")
                    return
                }
                pointerAtFirstSend = CGEvent(source: nil)?.location
                UserDefaults.standard.set(108, forKey: "NSStatusItem Preferred Position \(names.a)")
                UserDefaults.standard.set(54, forKey: "NSStatusItem Preferred Position \(names.b)")
                // Only these two UUID-named owned items reload their saved
                // settings. No external defaults, private setter or input event.
                itemA.autosaveName = names.a
                itemB.autosaveName = names.b
                emit("preferredOrderRequested", ["aPreferred": 108, "bPreferred": 54,
                    "onlyOwnedItems": true, "cgEventSends": 0, "method": "public-autosaveName-reload"])
                phase = .preferredConfirm
                phaseDeadline = now + 0.4
                return
            }
            if hostMode && hostDragOptIn {
                pointerAtFirstSend = CGEvent(source: nil)?.location
                emit("dragOptIn", ["independentExperiment": true, "clickPrerequisite": false])
                prepareDrag(a: a, b: b, now: now)
                return
            }
            let point = CGPoint(x: a.frame.midX, y: a.frame.midY)
            pointerAtFirstSend = CGEvent(source: nil)?.location
            phase = .clickDown
            guard post(.leftMouseDown, point: point, command: false, target: a) else { return }
            phase = .clickUp
            phaseDeadline = now + 0.15
        case .clickDown:
            finish("invalid-phase")
        case .clickUp:
            guard let a = sameOwnWindowA(), let lastPostedPoint,
                  post(.leftMouseUp, point: lastPostedPoint, command: false, target: a) else {
                finish("own-window-changed")
                return
            }
            phase = .confirmClick
            phaseDeadline = now + 0.6
        case .confirmClick:
            if hostMode {
                let observed = sentCount == 2 && actionCountA == 1 && actionCountB == 0 && !buttonObserved && maxPostingOffset == 0
                let confirmed = observed && confirmedClickActionCountA == 1
                let sceneCorrelated = observed && sceneCorrelatedClickActionCountA == 1
                let evidence = confirmed ? "nonce-confirmed" : (sceneCorrelated ? "scene-correlated" : (observed ? "observed-only" : "unconfirmed"))
                emit("clickResult", ["sourceActionObserved": observed, "nonceConfirmed": confirmed,
                    "sceneCorrelated": sceneCorrelated, "evidence": evidence,
                    "automaticDrag": false])
                finish("host-click-\(evidence)")
                return
            }
            guard actionCountA == 1, confirmedClickActionCountA == 1, actionCountB == 0 else {
                finish("own-click-action-unconfirmed")
                return
            }
            guard let a = sameOwnWindowA(), let b = geometry(itemB), b.windowNumber == originalB?.windowNumber,
                  reliablePair(a, b), let originalA, let originalB,
                  (a.frame.midX < b.frame.midX) == (originalA.frame.midX < originalB.frame.midX) else {
                finish("own-order-changed-before-drag")
                return
            }
            prepareDrag(a: a, b: b, now: now)
        case .dragDown:
            guard let a = sameOwnWindowA(), let dragStart,
                  post(.leftMouseDown, point: dragStart, command: true, target: a) else {
                finish("own-window-changed")
                return
            }
            phase = .dragMove
            phaseDeadline = now + 0.2
        case .dragMove:
            guard let a = sameOwnWindowA(), let dragStart, let dragDestination else {
                finish("own-window-changed")
                return
            }
            dragStep += 1
            let amount = CGFloat(dragStep) / 5
            let point = CGPoint(x: dragStart.x + (dragDestination.x - dragStart.x) * amount,
                y: dragStart.y + (dragDestination.y - dragStart.y) * amount)
            guard post(.leftMouseDragged, point: point, command: true, target: a) else { return }
            phase = dragStep == 5 ? .dragUp : .dragMove
            phaseDeadline = now + 0.12
        case .dragUp:
            guard let a = sameOwnWindowA(), let dragDestination,
                  post(.leftMouseUp, point: dragDestination, command: true, target: a) else {
                finish("own-window-changed")
                return
            }
            phase = .confirmOrder
            phaseDeadline = now + 0.6
        case .confirmOrder:
            emitGeometry("afterGeometry")
            guard let a = geometry(itemA), let b = geometry(itemB), reliablePair(a, b),
                  let originalA, let originalB else { finish("own-final-order-unavailable"); return }
            let changed = (a.frame.midX < b.frame.midX) != (originalA.frame.midX < originalB.frame.midX)
            emit("orderResult", ["ownOrderChanged": changed, "originalABeforeB": originalA.frame.midX < originalB.frame.midX,
                "finalABeforeB": a.frame.midX < b.frame.midX])
            finish(changed ? "own-order-changed" : "own-order-unchanged")
        }
    }

    private func startAXProbe() {
        guard !observeOnly, usesAX, axWorker == nil, !axActionWasDispatched else { return }
        // Record native visibility separately from whether an object offers an
        // AX action. Failed geometry is diagnostic only for this object action.
        emitGeometry("axBeforeGeometry")
        phase = .axPending
        axActionCountBeforeA = actionCountA
        axActionCountBeforeB = actionCountB
        pointerAtFirstSend = CGEvent(source: nil)?.location
        let ownerPID = pid
        let identifier = identifierA
        let hostRoute = hostAXOptIn
        let action = showMenuAXOptIn ? kAXShowMenuAction : kAXPressAction
        emit("axRequest", ["route": hostRoute ? "host-remote-button" : "source-menu-bar-item",
            "requestedAction": action, "oneActionOnly": true, "cgEventSends": 0])
        // The worker never blocks the main run loop while awaiting completion.
        // Its own-process AX calls use a synchronous main-thread bridge because
        // AX can directly invoke AppKit. No AX object crosses this task boundary.
        let worker = Task.detached {
            StatusItemAXProbe.perform(ownerPID: ownerPID, identifier: identifier, hostRoute: hostRoute, action: action)
        }
        axWorker = worker
        axTask = Task { [weak self] in
            let report = await worker.value
            guard let self, !self.finished, !Task.isCancelled else { return }
            self.axActionWasDispatched = report.dispatched
            self.emit("axDispatch", ["route": hostRoute ? "host-remote-button" : "source-menu-bar-item",
                "requestedAction": action, "advertisedStandardActions": report.actions,
                "dispatched": report.dispatched, "axResult": report.result ?? -1,
                "sourcePID": ownerPID, "hostPID": report.hostPID ?? -1,
                "readCount": report.readCount, "targetMatches": report.matches,
                "reason": report.error ?? "", "requestUptime": report.requestUptime ?? -1,
                "returnUptime": report.returnUptime ?? -1, "messagingTimeoutSeconds": 0.2])
            self.axTask = nil
            guard report.dispatched else { self.finish("ax-not-dispatched"); return }
            self.phase = .axConfirm
            self.phaseDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        }
    }

    private func prepareDrag(a: OwnItemGeometry, b: OwnItemGeometry, now: Double) {
        dragStart = CGPoint(x: a.frame.midX, y: a.frame.midY)
        // End within B's far half, never beyond our two owned items.
        dragDestination = CGPoint(x: a.frame.midX < b.frame.midX ? b.frame.maxX - 4 : b.frame.minX + 4,
            y: b.frame.midY)
        phase = .dragDown
        phaseDeadline = now + 0.3
    }

    private func geometry(_ item: NSStatusItem?) -> OwnItemGeometry? {
        guard let item else { return nil }
        if hostMode {
            let identifier: String
            if item === itemA { identifier = identifierA }
            else if item === itemB { identifier = identifierB }
            else { return nil }
            do {
                let target = try MenuBarHostTarget.resolveOwnedItem(identifier: identifier, expectedOwnerPID: pid)
                guard target.sourcePID == pid, target.hostPID > 0, target.hostWindowID > 0,
                      validFrame(target.frame) else { return nil }
                return OwnItemGeometry(windowNumber: Int(target.hostWindowID), frame: target.frame,
                    sourcePID: target.sourcePID, targetPID: target.hostPID)
            } catch {
                emit("hostBindingUnavailable", ["ownItem": identifier == identifierA ? "MT-A" : "MT-B",
                    "reason": error.localizedDescription])
                return nil
            }
        }
        guard let button = item.button, let window = button.window, window.windowNumber > 0,
              window.isVisible, let primary = NSScreen.screens.first else { return nil }
        let screenFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = CGRect(x: screenFrame.minX, y: primary.frame.maxY - screenFrame.maxY,
            width: screenFrame.width, height: screenFrame.height)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= 12, frame.height >= 12,
              NSScreen.screens.contains(where: { $0.frame.contains(screenFrame) }) else { return nil }
        return OwnItemGeometry(windowNumber: window.windowNumber, frame: frame, sourcePID: pid, targetPID: pid)
    }

    private func validFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width >= 12 && frame.height >= 12
    }

    private func reliablePair(_ a: OwnItemGeometry, _ b: OwnItemGeometry) -> Bool {
        guard a.sourcePID == pid, b.sourcePID == pid, a.targetPID == b.targetPID else { return false }
        let left = a.frame.minX < b.frame.minX ? a.frame : b.frame
        let right = a.frame.minX < b.frame.minX ? b.frame : a.frame
        return abs(left.midY - right.midY) < 2 && left.maxX <= right.minX + 1 &&
            right.minX - left.maxX <= 2
    }

    private func reliableClickPair(_ a: OwnItemGeometry, _ b: OwnItemGeometry) -> Bool {
        guard a.sourcePID == pid, b.sourcePID == pid, a.targetPID == b.targetPID else { return false }
        let left = a.frame.minX < b.frame.minX ? a.frame : b.frame
        let right = a.frame.minX < b.frame.minX ? b.frame : a.frame
        return abs(left.midY - right.midY) < 2 && left.maxX <= right.minX
    }

    private func sameOwnWindowA() -> OwnItemGeometry? {
        guard let a = geometry(itemA), a.windowNumber == originalA?.windowNumber,
              a.sourcePID == pid, a.targetPID == originalA?.targetPID else { return nil }
        return a
    }

    @discardableResult
    private func post(_ type: CGEventType, point: CGPoint, command: Bool, target: OwnItemGeometry, cleanup: Bool = false) -> Bool {
        // Defense in depth: even cleanup must not dispatch in observe-only mode.
        guard usesSyntheticEvents else { return false }
        let windowNumber = target.windowNumber
        guard ProcessInfo.processInfo.systemUptime - startTime < 14 || cleanup,
              target.sourcePID == pid, target.targetPID == originalA?.targetPID,
              target.windowNumber == originalA?.windowNumber,
              let b = geometry(itemB), b.sourcePID == pid, b.targetPID == target.targetPID,
              b.windowNumber == originalB?.windowNumber,
              ProcessInfo.processInfo.systemUptime - startTime < 14 || cleanup,
              windowNumber > 0, let source, let privateWindow = CGEventField(rawValue: 0x33),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            if !cleanup { finish("event-or-own-window-unavailable") }
            return false
        }
        samplePointer()
        guard cleanup || maxPostingOffset == 0 else {
            finish("pointer-observation-changed")
            return false
        }
        guard cleanup || combinedButtons() == 0 else {
            finish("combined-session-button-observed")
            return false
        }
        // AppKit pairs a down and its drag/up sequence by mouseEventNumber.
        // Allocate once for the whole gesture; per-send tags stay unique.
        if type == .leftMouseDown {
            guard activeGestureNumber == nil else {
                if !cleanup { finish("overlapping-synthetic-gesture") }
                return false
            }
            gestureCount += 1
            activeGestureNumber = eventNumberBase + gestureCount
        }
        guard let eventNumber = activeGestureNumber else {
            if !cleanup { finish("unpaired-synthetic-event") }
            return false
        }
        sentCount += 1
        let tag = tagBase + Int64(sentCount)
        let sourceWindowNumber = itemA?.button?.window?.windowNumber ?? -1
        sentTags.insert(tag)
        let key = SentEventKey(number: eventNumber, type: type.rawValue)
        if var previous = sentEvents[key] {
            // Preserve the first source identity for repeated drag records.
            // A changed window or modifier cannot acquire a new correlation.
            if previous.sourceWindowNumber == sourceWindowNumber && previous.command == command {
                previous.sendCount += 1
                sentEvents[key] = previous
            }
        } else {
            sentEvents[key] = SentEvent(command: command, sourceWindowNumber: sourceWindowNumber, sendCount: 1)
        }
        event.flags = command ? .maskCommand : []
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.targetPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        event.setIntegerValueField(privateWindow, value: Int64(windowNumber))
        if type == .leftMouseDown { held = true }
        if type == .leftMouseUp {
            held = false
            activeGestureNumber = nil
        }
        lastPostedPoint = point
        samplePointer()
        emit("send", ["tag": tag, "ordinal": sentCount, "phase": phase.rawValue, "eventType": type.rawValue,
            "eventNumber": eventNumber, "timestamp": Double(event.timestamp) / 1_000_000_000,
            "sourceWindowNumber": sourceWindowNumber,
            "sourcePID": pid, "targetPID": target.targetPID, "boundWindowNumber": windowNumber,
            "hostMode": hostMode, "point": coordinate(point),
            "command": command, "cleanup": cleanup, "combinedButtons": combinedButtons(),
            "pointerObserved": CGEvent(source: nil).map { coordinate($0.location) } ?? []])
        event.postToPid(target.targetPID)
        emit("postReturned", ["tag": tag, "ordinal": sentCount, "eventNumber": eventNumber, "targetPID": target.targetPID,
            "boundWindowNumber": windowNumber, "deliveryAcknowledged": false])
        samplePointer()
        if !cleanup && maxPostingOffset > 0 {
            finish("pointer-observation-changed")
            return false
        }
        return true
    }

    private func emitGeometry(_ kind: String) {
        let a = geometry(itemA), b = geometry(itemB)
        emit(kind, ["aWindowNumber": a?.windowNumber ?? -1, "bWindowNumber": b?.windowNumber ?? -1,
            "aSourcePID": a?.sourcePID ?? -1, "bSourcePID": b?.sourcePID ?? -1,
            "aTargetPID": a?.targetPID ?? -1, "bTargetPID": b?.targetPID ?? -1, "hostMode": hostMode,
            "aRawWindowNumber": itemA?.button?.window?.windowNumber ?? -1,
            "bRawWindowNumber": itemB?.button?.window?.windowNumber ?? -1,
            "aWindowVisible": itemA?.button?.window?.isVisible ?? false,
            "bWindowVisible": itemB?.button?.window?.isVisible ?? false,
            "aFrame": a.map { rectangle($0.frame) } ?? [], "bFrame": b.map { rectangle($0.frame) } ?? []])
    }

    private struct WeightsFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func readMenuAgentWeightsRaw() throws -> CFPropertyList? {
        guard CFPreferencesSynchronize(menuAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw WeightsFailure(reason: "menu-agent-preferences-synchronize-failed")
        }
        return CFPreferencesCopyValue(menuAgentWeightsKey, menuAgentDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func decodeMenuAgentWeights(_ raw: CFPropertyList?) throws -> [String: NSNumber] {
        guard let raw else { return [:] }
        guard CFGetTypeID(raw) == CFDictionaryGetTypeID(), let dictionary = raw as? NSDictionary else {
            throw WeightsFailure(reason: "menu-agent-weights-not-a-dictionary")
        }
        var result: [String: NSNumber] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String, let number = value as? NSNumber,
                  CFGetTypeID(number) == CFNumberGetTypeID(),
                  number.doubleValue.isFinite else {
                throw WeightsFailure(reason: "menu-agent-weights-require-string-finite-number-values")
            }
            // Keep the original NSNumber, including fractional values and
            // representation; only our two experimental values are replaced.
            result[key] = number
        }
        return result
    }

    private func prepareMenuAgentWeights() throws {
        guard menuAgentWeightsOptIn, !usesSyntheticEvents, let names = preferredPositionNames,
              names.a == identifierA, names.b == identifierB else {
            throw WeightsFailure(reason: "menu-agent-owned-identity-unavailable")
        }
        if menuAgentContainerOptIn {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: menuAgentContainerDomainURL.appendingPathExtension("plist").path,
                isDirectory: &directory), !directory.boolValue else {
                throw WeightsFailure(reason: "actual-menu-bar-container-preference-file-missing")
            }
        }
        let raw = try readMenuAgentWeightsRaw()
        // Preserve the full original property-list value and its absence before
        // any experimental write. Do not print its contents or external keys.
        do {
            let manager = FileManager.default
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Menu Tidy/Diagnostics/\(nonce)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var payload: [String: Any] = ["domain": menuAgentDomain as String, "key": "TrailingItemPreferredPositions",
                "storageScope": menuAgentStorageScope, "existed": raw != nil, "nonce": nonce]
            if let raw { payload["value"] = raw }
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            let filename = menuAgentContainerOptIn ? "MenuBar-container-before.plist" : "MenuBarAgent-before.plist"
            let file = directory.appendingPathComponent(filename)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw WeightsFailure(reason: "backup-open-failed") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw WeightsFailure(reason: "backup-mode-failed") }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            let mode = (try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            guard mode == 0o600 else { throw WeightsFailure(reason: "backup-mode-unconfirmed") }
            emit("menuAgentWeightsBackup", ["created": true, "mode": "0600", "originalKeyExisted": raw != nil,
                "backupIdentifier": "\(nonce)/\(filename)", "contentsLogged": false, "storageScope": menuAgentStorageScope])
        } catch {
            throw WeightsFailure(reason: "private-menu-agent-backup-unavailable")
        }
        let entries = try decodeMenuAgentWeights(raw)
        guard !menuAgentContainerOptIn || (raw != nil && !entries.isEmpty) else {
            throw WeightsFailure(reason: "actual-menu-bar-container-dictionary-missing-or-empty")
        }
        // This is an explicitly unverified candidate convention, not an Apple
        // API contract. Only names belonging to this run are ever considered.
        let keys = (a: "status:dev.hdh.MenuTidy::\(names.a)", b: "status:dev.hdh.MenuTidy::\(names.b)")
        guard entries[keys.a] == nil, entries[keys.b] == nil else {
            throw WeightsFailure(reason: "menu-agent-test-key-already-present")
        }
        menuAgentOriginalEntries = entries
        menuAgentKeyExisted = raw != nil
        menuAgentOwnedKeys = keys
        emit("menuAgentWeightsCandidate", ["keyA": keys.a, "keyB": keys.b, "mappingIsOSContract": false,
            "preferenceScope": "currentUser/anyHost", "storageScope": menuAgentStorageScope,
            "scopeIsOSContract": false, "sameConsumerCacheProven": false,
            "initialNonProbeEntryCount": entries.count, "emptyDictionarySeedUnverified": entries.isEmpty])
    }

    private func writeMenuAgentWeights(a: Int, b: Int) throws {
        guard menuAgentWeightsOptIn, !usesSyntheticEvents, let keys = menuAgentOwnedKeys else {
            throw WeightsFailure(reason: "menu-agent-weights-not-prepared")
        }
        let raw = try readMenuAgentWeightsRaw()
        var current = try decodeMenuAgentWeights(raw)
        guard !menuAgentContainerOptIn || (raw != nil && !current.isEmpty) else {
            throw WeightsFailure(reason: "actual-menu-bar-container-dictionary-disappeared")
        }
        for key in [keys.a, keys.b] {
            if let expected = menuAgentWrittenWeights[key] {
                guard current[key] == NSNumber(value: expected) else {
                    throw WeightsFailure(reason: "menu-agent-own-weight-changed-externally")
                }
            } else if current[key] != nil {
                throw WeightsFailure(reason: "menu-agent-test-key-appeared-externally")
            }
        }
        samplePointer()
        guard weightsInputFailure == nil, maxPostingOffset == 0, combinedButtons() == 0, !buttonObserved else {
            throw WeightsFailure(reason: "input-observed-before-weight-write")
        }
        current[keys.a] = NSNumber(value: a)
        current[keys.b] = NSNumber(value: b)
        menuAgentWrittenWeights = [keys.a: a, keys.b: b]
        CFPreferencesSetValue(menuAgentWeightsKey, current as CFDictionary, menuAgentDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let readback = try decodeMenuAgentWeights(readMenuAgentWeightsRaw())
        guard readback[keys.a] == NSNumber(value: a), readback[keys.b] == NSNumber(value: b) else {
            throw WeightsFailure(reason: "menu-agent-weight-write-unconfirmed")
        }
        emit("menuAgentWeightsWritten", ["aWeight": a, "bWeight": b, "readbackMatched": true,
            "synchronizeAndReadbackConfirmed": true, "freshMerge": true,
            "nonProbeEntryCount": current.count - 2, "cgEventSends": sentCount])
    }

    private func requestMenuAgentNudge(nextPhase: Phase) {
        phase = .weightsNudge
        // Upstream Thaw 528b9503 ControlItem.swift:700-749 waits 50 ms for
        // preferences, changes only its own length, then restores after 16 ms.
        // That source is an experimental precedent, not proof for this OS.
        weightsNudgeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self, !self.finished, !Task.isCancelled else { return }
            let item: NSStatusItem
            let frame: CGRect
            if self.positionHidingOptIn {
                // A may no longer have a visible host binding after its weight
                // changes. B remains at 100; only this exact owned item nudges.
                guard let b = self.geometry(self.itemB), let originalB = self.originalB,
                      b.sourcePID == self.pid, b.targetPID == originalB.targetPID,
                      b.windowNumber == originalB.windowNumber, let ownedB = self.itemB,
                      ownedB.button?.accessibilityIdentifier() == self.identifierB,
                      self.itemA?.button?.accessibilityIdentifier() == self.identifierA,
                      self.hostRegistrationToken != nil else {
                    self.finish("position-hiding-nudge-identity-unavailable")
                    return
                }
                item = ownedB
                frame = b.frame
            } else {
                guard let a = self.geometry(self.itemA), let b = self.geometry(self.itemB),
                      self.reliableClickPair(a, b), let originalA = self.originalA, let originalB = self.originalB,
                      a.targetPID == originalA.targetPID, b.targetPID == originalB.targetPID,
                      a.windowNumber == originalA.windowNumber, b.windowNumber == originalB.windowNumber,
                      let ownedA = self.itemA else { self.finish("menu-agent-nudge-identity-unavailable"); return }
                item = ownedA
                frame = a.frame
            }
            self.samplePointer()
            guard self.weightsInputFailure == nil, self.maxPostingOffset == 0, self.combinedButtons() == 0, !self.buttonObserved,
                  ProcessInfo.processInfo.systemUptime - self.startTime < self.diagnosticLifetime else {
                self.finish("menu-agent-nudge-input-or-deadline")
                return
            }
            let baseline = item.length
            let temporary = max(24, frame.width) + 1
            self.weightsNudgeItem = item
            self.weightsNudgeBaseline = baseline
            item.length = temporary
            self.emit("menuAgentLengthNudge", ["originalRequestedLength": baseline, "temporaryLength": temporary,
                "restoreDelayMilliseconds": 16, "preferenceDelayMilliseconds": 50, "onlyOwnedItem": true,
                "ownItem": self.positionHidingOptIn ? "MT-B" : "MT-A"])
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !self.finished, !Task.isCancelled else { return }
            self.restoreMenuAgentNudgeLength()
            self.samplePointer()
            guard self.weightsInputFailure == nil else { self.finish("menu-agent-weights-input-rejected"); return }
            self.phase = nextPhase
            self.weightsObservationDeadline = ProcessInfo.processInfo.systemUptime + 4
            self.weightsLastOrder = nil
            self.weightsStableObservations = 0
            self.hidingStageSamples = 0
            self.hidingLastAFrame = nil
            self.hidingLastBFrame = nil
            self.phaseDeadline = ProcessInfo.processInfo.systemUptime + 0.2
            self.weightsNudgeTask = nil
        }
    }

    private func restoreMenuAgentNudgeLength() {
        guard let baseline = weightsNudgeBaseline else { return }
        weightsNudgeItem?.length = baseline
        let present = weightsNudgeItem != nil
        weightsNudgeItem = nil
        weightsNudgeBaseline = nil
        emit("menuAgentLengthRestored", ["requestedLength": baseline, "ownItemPresent": present])
    }

    private func observeMenuAgentWeights() {
        let observingFirst = phase == .weightsFirst
        let a = geometry(itemA), b = geometry(itemB)
        samplePointer()
        guard weightsInputFailure == nil, maxPostingOffset == 0, combinedButtons() == 0, !buttonObserved else {
            finish("pointer-or-button-observed-during-weights")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - startTime < diagnosticLifetime else { finish("deadline"); return }
        if let a, let b, reliableClickPair(a, b), let originalA, let originalB,
           a.targetPID == originalA.targetPID, b.targetPID == originalB.targetPID,
           a.windowNumber == originalA.windowNumber, b.windowNumber == originalB.windowNumber {
            let order = a.frame.midX < b.frame.midX
            weightsStableObservations = weightsLastOrder == order ? weightsStableObservations + 1 : 1
            weightsLastOrder = order
            emit("menuAgentWeightOrderObservation", ["stage": observingFirst ? 1 : 2,
                "aBeforeB": order, "consecutiveObservations": weightsStableObservations,
                "aFrame": rectangle(a.frame), "bFrame": rectangle(b.frame),
                "aHostWindowID": a.windowNumber, "bHostWindowID": b.windowNumber])
        } else {
            weightsLastOrder = nil
            weightsStableObservations = 0
        }
        guard now >= weightsObservationDeadline else { phaseDeadline = now + 0.2; return }
        guard weightsStableObservations >= 2, let order = weightsLastOrder else {
            finish("menu-agent-weights-stable-order-unavailable")
            return
        }
        if observingFirst {
            weightsFirstOrder = order
            do {
                try writeMenuAgentWeights(a: 200, b: 100)
                requestMenuAgentNudge(nextPhase: .weightsSecond)
            } catch {
                emit("menuAgentWeightsRejected", ["reason": error.localizedDescription])
                finish("menu-agent-weights-second-write-failed")
            }
        } else {
            let reversed = weightsFirstOrder.map { $0 != order } ?? false
            weightsObservedReversal = reversed
            finish(reversed ? "menu-agent-weights-order-reversed" : "menu-agent-weights-order-unchanged")
        }
    }

    /// Evidence-only source census, confined to this process and this run's
    /// exact identifiers. Missing/partial trees remain unknown, never hidden.
    private func positionHidingSourceEvidence() -> (fields: [String: Any], identityConfirmed: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var remaining = 128
        var complete = true
        var lastError: Int32 = 0
        func value(_ node: AXUIElement, _ name: String, optional: Bool = false) -> CFTypeRef? {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                return nil
            }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.08)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(node, name as CFString, &result)
            if optional && (error == .noValue || error == .attributeUnsupported) { return nil }
            guard error == .success else { complete = false; lastError = error.rawValue; return nil }
            return result
        }
        func element(_ raw: CFTypeRef?) -> AXUIElement? {
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let p = value(node, kAXPositionAttribute, optional: true),
                  let z = value(node, kAXSizeAttribute, optional: true),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(z) == AXValueGetTypeID() else { return nil }
            let position = unsafeDowncast(p, to: AXValue.self), size = unsafeDowncast(z, to: AXValue.self)
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
                  AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
            let result = CGRect(origin: point, size: dimensions)
            return validFrame(result) ? result : nil
        }
        let app = AXUIElementCreateApplication(pid)
        guard AXIsProcessTrusted(), let root = element(value(app, kAXExtrasMenuBarAttribute)) else {
            var fields: [String: Any] = ["sourceCensusComplete": false, "sourceReadError": lastError]
            for (label, identifier) in [("a", identifierA), ("b", identifierB)] {
                if let retained = positionSourceElements[identifier] {
                    fields[label + "OriginalObjectFrame"] = frame(retained).map(rectangle) ?? []
                }
            }
            return (fields, false)
        }
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var matches: [String: [AXUIElement]] = [:]
        while let (node, depth) = pending.popLast() {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline,
                  seen.count < 64, depth <= 4 else { complete = false; break }
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            seen.append(node)
            var owner: pid_t = 0
            guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { complete = false; continue }
            let role = value(node, kAXRoleAttribute) as? String
            let identifier = value(node, kAXIdentifierAttribute, optional: true) as? String
            if let identifier, identifier == identifierA || identifier == identifierB,
               role == kAXMenuBarItemRole || role == kAXButtonRole {
                matches[identifier, default: []].append(node)
                continue
            }
            if let raw = value(node, kAXChildrenAttribute, optional: true) {
                guard let children = raw as? [CFTypeRef], children.count <= 64 else { complete = false; continue }
                for child in children {
                    guard let next = element(child) else { complete = false; continue }
                    pending.append((next, depth + 1))
                }
            }
        }
        if let fresh = element(value(app, kAXExtrasMenuBarAttribute)) {
            if !CFEqual(root, fresh) { complete = false }
        } else { complete = false }
        var fields: [String: Any] = ["sourcePID": pid]
        var identities = complete
        for (label, identifier) in [("a", identifierA), ("b", identifierB)] {
            let nodes = matches[identifier] ?? []
            fields[label + "SourceMatches"] = nodes.count
            if let retained = positionSourceElements[identifier] {
                fields[label + "OriginalObjectFrame"] = frame(retained).map(rectangle) ?? []
            }
            guard nodes.count == 1, let node = nodes.first else { identities = false; continue }
            if complete && positionSourceElements[identifier] == nil { positionSourceElements[identifier] = node }
            let same = positionSourceElements[identifier].map { CFEqual($0, node) } ?? false
            identities = identities && same
            fields[label + "SourceIdentitySame"] = same
            fields[label + "SourceFrame"] = frame(node).map(rectangle) ?? []
            if let hidden = value(node, kAXHiddenAttribute, optional: true) as? NSNumber {
                fields[label + "AXHiddenHint"] = hidden.boolValue
            }
        }
        fields["sourceCensusComplete"] = complete
        fields["sourceReadError"] = lastError
        fields["sourceGeometryIsVisibilityProof"] = false
        return (fields, identities && complete)
    }

    private func observePositionHiding() {
        guard hidingCaptureToken == nil else { return }
        let stage = phase
        let sources = positionHidingSourceEvidence()
        let a = geometry(itemA), b = geometry(itemB)
        let sameHostA = a.map { $0.sourcePID == pid && $0.targetPID == originalA?.targetPID && $0.windowNumber == originalA?.windowNumber } ?? false
        let sameHostB = b.map { $0.sourcePID == pid && $0.targetPID == originalB?.targetPID && $0.windowNumber == originalB?.windowNumber } ?? false
        let pairReliable: Bool
        if let a, let b { pairReliable = sameHostA && sameHostB && reliableClickPair(a, b) }
        else { pairReliable = false }
        let overlapping = a.flatMap { first in b.map { second in
            min(first.frame.maxX, second.frame.maxX) > max(first.frame.minX, second.frame.minX) &&
                min(first.frame.maxY, second.frame.maxY) > max(first.frame.minY, second.frame.minY)
        } } ?? false
        let aVisible = sameHostA && !overlapping
        let bVisible = sameHostB && !overlapping
        var fields = sources.fields
        fields["stage"] = stage.rawValue
        fields["aHostFrame"] = a.map { rectangle($0.frame) } ?? []
        fields["bHostFrame"] = b.map { rectangle($0.frame) } ?? []
        fields["aHostPID"] = a?.targetPID ?? -1
        fields["bHostPID"] = b?.targetPID ?? -1
        fields["aHostWindowID"] = a?.windowNumber ?? -1
        fields["bHostWindowID"] = b?.windowNumber ?? -1
        fields["aCenterHitVisibility"] = aVisible ? "verified-visible" : "unknown"
        fields["bCenterHitVisibility"] = bVisible ? "verified-visible" : "unknown"
        fields["overlappingHostFrames"] = overlapping
        fields["overflowExpandedOrConcealed"] = "not-tested"
        fields["weightReadbackIsVisibilityProof"] = false
        // Shared host-window presence cannot prove visibility of either item.
        if let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            let expected = [originalA, originalB].compactMap { $0 }
            fields["sharedHostWindows"] = windows.filter { window in
                expected.contains { target in
                    (window[kCGWindowNumber as String] as? NSNumber)?.intValue == target.windowNumber &&
                    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.targetPID
                }
            }.prefix(2).map { window -> [String: Any] in
                ["windowID": (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
                 "ownerPID": (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1,
                 "onscreen": (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                 "perItemVisibilityProof": false]
            }
        }
        samplePointer()
        guard weightsInputFailure == nil, maxPostingOffset == 0, combinedButtons() == 0, !buttonObserved else {
            finish("position-hiding-input-rejected")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - startTime < diagnosticLifetime else { finish("position-hiding-deadline"); return }
        hidingStageSamples += 1
        if pairReliable && sources.identityConfirmed, let a, let b {
            weightsStableObservations = hidingLastAFrame == a.frame && hidingLastBFrame == b.frame ? weightsStableObservations + 1 : 1
            hidingLastAFrame = a.frame
            hidingLastBFrame = b.frame
        } else { weightsStableObservations = 0; hidingLastAFrame = nil; hidingLastBFrame = nil }
        if stage == .hidingRaised {
            hidingRaisedSamples += 1
            if aVisible { hidingRaisedVisibleSamples += 1 } else { hidingRaisedUnknownSamples += 1 }
        }
        fields["consecutiveReliablePairObservations"] = weightsStableObservations
        emit("positionHidingObservation", fields)
        guard now >= weightsObservationDeadline else { phaseDeadline = now + 0.3; return }
        if !hidingCaptureAttemptedStages.contains(stage.rawValue) {
            beginPositionHidingCapture(stage: stage)
            return
        }
        switch stage {
        case .hidingBaseline:
            guard weightsStableObservations >= 2, let a, let b else {
                finish("position-hiding-visible-baseline-unavailable")
                return
            }
            hidingBaselineA = a
            hidingBaselineB = b
            emit("positionHidingBaseline", ["aWeight": 200, "bWeight": 100,
                "aFrame": rectangle(a.frame), "bFrame": rectangle(b.frame), "sourceIdentityConfirmed": true])
            do {
                // Only A's value changes. The documented upstream constant is
                // a hypothesis; its own weight predicate is not physical proof.
                try writeMenuAgentWeights(a: 50_000, b: 100)
                requestMenuAgentNudge(nextPhase: .hidingRaised)
            } catch {
                emit("positionHidingRejected", ["reason": error.localizedDescription])
                finish("position-hiding-weight-write-failed")
            }
        case .hidingRaised:
            emit("positionHidingRaisedEvidence", ["samples": hidingStageSamples,
                "aVerifiedVisibleSamples": hidingRaisedVisibleSamples, "aUnknownSamples": hidingRaisedUnknownSamples,
                "physicalConcealConfirmed": false, "overflowExpansionPerformed": false])
            do {
                try writeMenuAgentWeights(a: 200, b: 100)
                requestMenuAgentNudge(nextPhase: .hidingRestored)
            } catch {
                emit("positionHidingRejected", ["reason": error.localizedDescription])
                finish("position-hiding-baseline-restore-failed")
            }
        case .hidingRestored:
            hidingRestoredGeometry = weightsStableObservations >= 2 && a?.frame == hidingBaselineA?.frame &&
                b?.frame == hidingBaselineB?.frame && hidingBaselineA != nil && hidingBaselineB != nil
            emit("positionHidingBaselineRestored", ["exactVisibleGeometryRestored": hidingRestoredGeometry,
                "consecutiveReliablePairObservations": weightsStableObservations,
                "preferenceReadbackIsLayoutProof": false])
            finish(hidingRestoredGeometry ? "position-hiding-evidence-collected-baseline-restored" : "position-hiding-baseline-geometry-unconfirmed")
        default:
            finish("position-hiding-invalid-phase")
        }
    }

    /// Verify this exact diagnostic's phase, retained source identities, weight
    /// values, and a bounded main-display menu strip containing the verified
    /// owned host items. A host window's extent never sets the capture extent.
    private func positionHidingCaptureContext(stage: Phase) throws -> HidingCaptureContext {
        guard positionHidingOptIn, phase == stage, !finished, weightsInputFailure == nil,
              [Phase.hidingBaseline, .hidingRaised, .hidingRestored].contains(stage),
              let a = originalA, let b = originalB, a.targetPID == b.targetPID,
              a.windowNumber == b.windowNumber,
              let host = NSRunningApplication(processIdentifier: b.targetPID), !host.isTerminated,
              host.bundleIdentifier == "com.apple.MenuBarAgent",
              let epoch = MenuBarProcessIdentity.launchTime(for: host),
              let liveB = geometry(itemB), liveB.sourcePID == pid,
              liveB.targetPID == b.targetPID, liveB.windowNumber == b.windowNumber,
              positionHidingSourceEvidence().identityConfirmed,
              let keys = menuAgentOwnedKeys else { throw WeightsFailure(reason: "capture-identity-or-phase-unavailable") }
        let expectedA = stage == .hidingRaised ? 50_000 : 200
        let current = try decodeMenuAgentWeights(readMenuAgentWeightsRaw())
        guard current[keys.a] == NSNumber(value: expectedA), current[keys.b] == NSNumber(value: 100),
              menuAgentWrittenWeights[keys.a] == expectedA, menuAgentWrittenWeights[keys.b] == 100 else {
            throw WeightsFailure(reason: "capture-expected-weights-changed")
        }
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)
        let screens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        var diagnostics: [String: Any] = ["stage": stage.rawValue, "displayID": displayID,
            "displayBounds": rectangle(displayBounds), "matchingScreens": screens.count,
            "hostPID": b.targetPID, "hostWindowID": b.windowNumber,
            "originalAFrame": rectangle(a.frame), "originalBFrame": rectangle(b.frame),
            "liveBFrame": rectangle(liveB.frame)]
        func reject(_ reason: String) throws -> Never {
            diagnostics["accepted"] = false
            diagnostics["reason"] = reason
            emit("positionHidingCaptureGeometry", diagnostics)
            throw WeightsFailure(reason: reason)
        }
        guard CGDisplayIsActive(displayID) != 0, validFrame(displayBounds), screens.count == 1,
              let screen = screens.first,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            try reject("capture-display-or-host-window-unavailable")
        }
        let safeTop = screen.safeAreaInsets.top
        let thickness = NSStatusBar.system.thickness
        diagnostics["safeAreaTop"] = safeTop
        diagnostics["statusThickness"] = thickness
        guard safeTop.isFinite, thickness.isFinite, safeTop >= 0, thickness > 0,
              safeTop <= 64, thickness <= 64 else { try reject("capture-invalid-menu-height") }
        let matching = windows.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == b.windowNumber &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == b.targetPID
        }
        diagnostics["matchingCGWindows"] = matching.count
        guard matching.count == 1, let raw = matching[0][kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: raw as CFDictionary), validFrame(frame) else {
            try reject("capture-host-window-geometry-unavailable")
        }
        diagnostics["hostCGWindowFrame"] = rectangle(frame)
        diagnostics["hostCGWindowOnscreenHint"] = (matching[0][kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let baseHeight = max(28, safeTop, thickness)
        let baseBand = CGRect(x: displayBounds.minX, y: displayBounds.minY,
            width: displayBounds.width, height: baseHeight)
        let liveCenter = CGPoint(x: liveB.frame.midX, y: liveB.frame.midY)
        let verifiedFrames = [a.frame, b.frame, liveB.frame]
        let insidePrimary = verifiedFrames.allSatisfy { displayBounds.contains($0) }
        let insideMenuBand = verifiedFrames.allSatisfy { baseBand.insetBy(dx: 0, dy: -1).contains($0) }
        let hostContainsLiveB = frame.contains(liveCenter)
        // macOS 27 can expose a 33pt host item against a 32pt safe top
        // area. Only an already verified item's <=1pt edge can add height;
        // an oversized/shared CG window can never enlarge this strip.
        let observedBottom = verifiedFrames.map(\.maxY).max() ?? displayBounds.minY
        let height = max(baseHeight, observedBottom - displayBounds.minY)
        let rect = CGRect(x: displayBounds.minX, y: displayBounds.minY,
            width: displayBounds.width, height: height).integral
        diagnostics["baseMenuBand"] = rectangle(baseBand)
        diagnostics["captureRect"] = rectangle(rect)
        diagnostics["itemsInsideMainDisplay"] = insidePrimary
        diagnostics["itemsInsideMenuBandWithOnePointEdge"] = insideMenuBand
        diagnostics["hostWindowContainsLiveBCenter"] = hostContainsLiveB
        diagnostics["captureHeightWithin64"] = rect.height <= 64
        diagnostics["captureInsideDisplay"] = displayBounds.contains(rect)
        guard insidePrimary, insideMenuBand, hostContainsLiveB,
              height <= baseHeight + 1, rect.height <= 64, displayBounds.contains(rect) else {
            try reject("capture-not-bounded-main-menu-strip")
        }
        diagnostics["accepted"] = true
        emit("positionHidingCaptureGeometry", diagnostics)
        samplePointer()
        guard weightsInputFailure == nil else { throw WeightsFailure(reason: "capture-input-observed") }
        return HidingCaptureContext(displayID: displayID, displayBounds: displayBounds,
            hostPID: b.targetPID, hostEpoch: epoch, windowID: b.windowNumber,
            windowFrame: frame, captureRect: rect, safeAreaTop: safeTop,
            statusThickness: thickness, expectedA: expectedA)
    }

    /// Exactly one raw, unprocessed image attempt per existing stage. The
    /// timeout releases the state machine; a late SCK result is never saved.
    private func beginPositionHidingCapture(stage: Phase) {
        hidingCaptureAttemptedStages.insert(stage.rawValue)
        guard #available(macOS 15.2, *), CGPreflightScreenCaptureAccess() else {
            emit("positionHidingScreenshot", ["stage": stage.rawValue, "saved": false,
                "reason": "screen-capture-permission-or-api-unavailable", "permissionRequested": false])
            return
        }
        let context: HidingCaptureContext
        do { context = try positionHidingCaptureContext(stage: stage) }
        catch {
            emit("positionHidingScreenshot", ["stage": stage.rawValue, "saved": false,
                "reason": error.localizedDescription])
            return
        }
        let token = UUID()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        hidingCaptureToken = token
        hidingCaptureTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, self.hidingCaptureToken == token else { return }
            self.hidingCaptureToken = nil
            self.hidingCaptureTask?.cancel()
            self.hidingCaptureTask = nil
            self.hidingCaptureTimeout = nil
            self.emit("positionHidingScreenshot", ["stage": stage.rawValue, "saved": false,
                "reason": "capture-timeout-late-result-discarded"])
        }
        hidingCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await SCScreenshotManager.captureImage(in: context.captureRect)
                guard !Task.isCancelled, !self.finished, self.hidingCaptureToken == token,
                      ProcessInfo.processInfo.systemUptime < deadline,
                      CGPreflightScreenCaptureAccess(),
                      try self.positionHidingCaptureContext(stage: stage) == context,
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    throw WeightsFailure(reason: "capture-completion-state-changed-or-expired")
                }
                guard image.width >= Int(context.captureRect.width), image.width <= Int(context.captureRect.width * 4),
                      image.height >= Int(context.captureRect.height), image.height <= Int(context.captureRect.height * 4),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw WeightsFailure(reason: "capture-invalid-image-or-png")
                }
                let manager = FileManager.default
                let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent("Menu Tidy/Diagnostics/\(self.nonce)", isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let attributes = try manager.attributesOfItem(atPath: directory.path)
                guard (attributes[.type] as? FileAttributeType) == .typeDirectory,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                    throw WeightsFailure(reason: "capture-private-directory-unconfirmed")
                }
                let file = directory.appendingPathComponent("position-hiding-\(stage.rawValue).png")
                let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw WeightsFailure(reason: "capture-private-file-open-failed") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw WeightsFailure(reason: "capture-private-file-mode-failed") }
                try handle.write(contentsOf: png)
                try handle.synchronize()
                self.emit("positionHidingScreenshot", ["stage": stage.rawValue, "saved": true,
                    "path": file.path, "mode": "0600", "directoryMode": "0700",
                    "frame": self.rectangle(context.captureRect), "pixelWidth": image.width, "pixelHeight": image.height,
                    "rawUnprocessed": true, "cacheUsed": false, "physicalConcealConfirmed": false])
            } catch {
                if self.hidingCaptureToken == token {
                    self.emit("positionHidingScreenshot", ["stage": stage.rawValue, "saved": false,
                        "reason": error.localizedDescription])
                }
            }
            if self.hidingCaptureToken == token {
                self.hidingCaptureToken = nil
                self.hidingCaptureTimeout?.cancel()
                self.hidingCaptureTimeout = nil
                self.hidingCaptureTask = nil
            }
        }
    }

    private func restoreMenuAgentWeights() {
        guard let keys = menuAgentOwnedKeys else { return }
        defer {
            menuAgentOwnedKeys = nil
            menuAgentWrittenWeights.removeAll()
        }
        guard !menuAgentWrittenWeights.isEmpty else { return }
        do {
            let currentRaw = try readMenuAgentWeightsRaw()
            var current = try decodeMenuAgentWeights(currentRaw)
            var conflicts = 0
            var removed = 0
            for key in [keys.a, keys.b] {
                guard let value = current[key] else { continue }
                if let expected = menuAgentWrittenWeights[key], value == NSNumber(value: expected) {
                    current.removeValue(forKey: key)
                    removed += 1
                } else { conflicts += 1 }
            }
            // Fresh merge: only delete our still-owned values. A changed own
            // value or external entry is never replaced with the old backup.
            let removeContainer = !menuAgentKeyExisted && current.isEmpty
            // Do not recreate a container that another writer removed, or
            // rewrite unrelated values when our keys are already absent.
            if removed > 0 || (removeContainer && currentRaw != nil) {
                CFPreferencesSetValue(menuAgentWeightsKey, removeContainer ? nil : current as CFDictionary,
                    menuAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            let raw = try readMenuAgentWeightsRaw()
            let restored = try decodeMenuAgentWeights(raw)
            var nonProbe = restored
            nonProbe.removeValue(forKey: keys.a)
            nonProbe.removeValue(forKey: keys.b)
            let othersEqual = NSDictionary(dictionary: nonProbe).isEqual(NSDictionary(dictionary: menuAgentOriginalEntries ?? [:]))
            let ownKeysAbsent = restored[keys.a] == nil && restored[keys.b] == nil
            let presenceRestored = (raw != nil) == menuAgentKeyExisted
            weightsCleanupVerified = ownKeysAbsent && othersEqual && presenceRestored && conflicts == 0
            emit("menuAgentWeightsCleanup", ["readbackComplete": true, "ownKeysRemoved": ownKeysAbsent,
                "synchronizeAndReadbackConfirmed": true,
                "ownValueConflictsPreserved": conflicts, "nonProbeEntriesEqualToBackup": othersEqual,
                "keyPresenceRestored": presenceRestored, "dictionaryRestored": weightsCleanupVerified,
                "thirdPartyLayoutRestored": "unverified", "backupRetained": true])
        } catch {
            emit("menuAgentWeightsCleanup", ["readbackComplete": false, "dictionaryRestored": false,
                "synchronizeAndReadbackConfirmed": false,
                "reason": error.localizedDescription, "thirdPartyLayoutRestored": "unverified", "backupRetained": true])
        }
    }

    /// Mirror AppKit's existing preferred-position key convention, but only for
    /// these UUID-named diagnostic objects. Both keys are seeded before either
    /// item is created or receives its autosaveName. Normal mode never writes.
    private func preparePreferredPositions() -> Bool {
        guard preferredPositionOptIn, let domain = Bundle.main.bundleIdentifier, !domain.isEmpty else { return false }
        if menuAgentWeightsOptIn && !sampleWeightsInput() { return false }
        let names = (a: "MenuTidyProbe-\(nonce)-A", b: "MenuTidyProbe-\(nonce)-B")
        let defaults = UserDefaults.standard
        let original = defaults.persistentDomain(forName: domain) ?? [:]
        let entries = [(name: names.a, position: 54), (name: names.b, position: 108)]
        // Retain presence separately from value; a missing key must be removed,
        // not replaced by a guessed default when this experiment ends.
        savedPreferences = entries.map { entry in
            let key = "NSStatusItem Preferred Position \(entry.name)"
            return SavedPreference(key: key, existed: original.keys.contains(key), value: original[key])
        }
        preferenceDomain = domain
        preferredPositionNames = names
        for (entry, saved) in zip(entries, savedPreferences) {
            if menuAgentWeightsOptIn && !sampleWeightsInput() { return false }
            defaults.set(entry.position, forKey: saved.key)
            emit("temporaryPreferredPosition", ["key": saved.key, "position": entry.position,
                "existedBefore": saved.existed, "onlyOwnDiagnosticItem": true])
        }
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        return zip(entries, savedPreferences).allSatisfy { entry, saved in
            (current[saved.key] as? NSNumber)?.intValue == entry.position
        }
    }

    private func restorePreferredPositions() {
        guard let preferenceDomain, !savedPreferences.isEmpty else { return }
        let defaults = UserDefaults.standard
        // Removal can change AppKit's position hints, so restore only after
        // both temporary status items have been removed.
        for saved in savedPreferences {
            if saved.existed, let value = saved.value { defaults.set(value, forKey: saved.key) }
            else { defaults.removeObject(forKey: saved.key) }
        }
        let synchronized = defaults.synchronize()
        let restoredDomain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        var allRestored = true
        for saved in savedPreferences {
            let current = restoredDomain[saved.key]
            let matches: Bool
            if saved.existed, let value = saved.value, let current {
                matches = NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": current])
            } else {
                matches = !saved.existed && current == nil
            }
            allRestored = allRestored && matches
            emit("temporaryPreferenceCleanup", ["key": saved.key, "existedBefore": saved.existed,
                "existsAfter": current != nil, "restored": matches])
        }
        emit("temporaryPreferenceCleanupSummary", ["keys": savedPreferences.count,
            "allRestored": allRestored, "synchronizeAccepted": synchronized])
        savedPreferences.removeAll()
        preferredPositionNames = nil
        self.preferenceDomain = nil
    }

    /// These exact private getters are diagnostic reads on our two objects (or
    /// the fixed NSStatusItem class). Their results never enter routing logic.
    /// No method enumeration, setter, KVC write or speculative selector is used.
    private func logReadOnlyStatusItemMetadata() {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        for (label, optionalItem) in [("MT-A", itemA), ("MT-B", itemB)] {
            guard let item = optionalItem else { continue }
            let actualClass = NSStringFromClass(type(of: item))
            let selector = NSSelectorFromString("hostWindowID")
            var fields: [String: Any] = ["ownItem": label, "actualClass": actualClass,
                "getter": "hostWindowID", "invoked": false, "routingEvidence": false]
            guard actualClass == "NSSceneStatusItem", item.responds(to: selector),
                  let method = class_getInstanceMethod(type(of: item), selector),
                  let encodedType = method_getTypeEncoding(method) else {
                emit("ownItemRuntimeMetadata", fields)
                continue
            }
            let encoding = String(cString: encodedType)
            fields["methodEncoding"] = encoding
            guard encoding == "q16@0:8", method_getNumberOfArguments(method) == 2 else {
                emit("ownItemRuntimeMetadata", fields)
                continue
            }
            // q is a signed 64-bit NSInteger on this ABI. Preserve the full
            // result as a decimal string before any CGWindowID range check.
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSInteger
            let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let rawWindowID = getter(item, selector)
            fields["invoked"] = true
            fields["rawSigned64WindowID"] = String(rawWindowID)
            fields["cgWindowListAvailable"] = windows != nil
            let inRange = rawWindowID > 0 && UInt64(rawWindowID) <= UInt64(UInt32.max)
            fields["withinCGWindowIDRange"] = inRange
            if inRange {
                let matches = (windows ?? []).filter { info in
                    (info[kCGWindowNumber as String] as? NSNumber)?.uint64Value == UInt64(rawWindowID)
                }
                fields["exactCGWindowMatches"] = matches.count
                fields["cgWindows"] = matches.map { info -> [String: Any] in
                    var record: [String: Any] = [
                        "ownerPID": (info[kCGWindowOwnerPID as String] as? NSNumber)?.int64Value ?? -1,
                        "layer": (info[kCGWindowLayer as String] as? NSNumber)?.int64Value ?? -1,
                        "onscreen": (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                    ]
                    if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                       let frame = CGRect(dictionaryRepresentation: bounds) {
                        record["frame"] = rectangle(frame)
                    }
                    return record
                }
            }
            emit("ownItemRuntimeMetadata", fields)
        }

        let selector = NSSelectorFromString("_activeItem")
        var fields: [String: Any] = ["receiverClass": "NSStatusItem", "getter": "_activeItem",
            "invoked": false, "routingEvidence": false]
        guard let method = class_getClassMethod(NSStatusItem.self, selector),
              let encodedType = method_getTypeEncoding(method) else {
            emit("activeItemRuntimeMetadata", fields)
            return
        }
        let encoding = String(cString: encodedType)
        fields["methodEncoding"] = encoding
        guard encoding == "@16@0:8", method_getNumberOfArguments(method) == 2 else {
            emit("activeItemRuntimeMetadata", fields)
            return
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let active = getter(NSStatusItem.self as AnyObject, selector)?.takeUnretainedValue()
        fields["invoked"] = true
        fields["returnedNil"] = active == nil
        if let active, let actualClass = object_getClass(active) {
            fields["actualClass"] = NSStringFromClass(actualClass)
        }
        emit("activeItemRuntimeMetadata", fields)
    }

    private func samplePointer() {
        if menuAgentWeightsOptIn { _ = sampleWeightsInput() }
        pointerSamples += 1
        if let current = CGEvent(source: nil)?.location {
            if let pointerBefore { maxPointerOffset = max(maxPointerOffset, distance(current, pointerBefore)) }
            if let pointerAtFirstSend { maxPostingOffset = max(maxPostingOffset, distance(current, pointerAtFirstSend)) }
        }
        if ProcessInfo.processInfo.systemUptime - startTime < 2 {
            preparationButtonObserved = preparationButtonObserved || combinedButtons() != 0
        } else {
            buttonObserved = buttonObserved || combinedButtons() != 0
        }
    }

    /// Weights-only, read-only guard. CG and AppKit use different coordinate
    /// spaces, so each pointer is compared with its own initial reading. An
    /// unavailable reading or any nonzero input latches failure until exit.
    @discardableResult
    private func sampleWeightsInput() -> Bool {
        guard menuAgentWeightsOptIn else { return true }
        let mask: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
            .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn]
        func finite(_ point: CGPoint?) -> CGPoint? {
            guard let point, point.x.isFinite, point.y.isFinite else { return nil }
            return point
        }
        func buttons(_ state: CGEventSourceStateID) -> UInt32? {
            var result: UInt32 = 0
            for raw in UInt32(0)..<32 {
                guard let button = CGMouseButton(rawValue: raw) else { return nil }
                if CGEventSource.buttonState(state, button: button) { result |= UInt32(1) << raw }
            }
            return result
        }
        let current = WeightsInputSample(cgPointer: finite(CGEvent(source: nil)?.location),
            appKitPointer: finite(NSEvent.mouseLocation), hidButtons: buttons(.hidSystemState),
            combinedButtons: buttons(.combinedSessionState),
            hidFlags: CGEventSource.flagsState(.hidSystemState).intersection(mask).rawValue,
            combinedFlags: CGEventSource.flagsState(.combinedSessionState).intersection(mask).rawValue)
        weightsInputSamples += 1
        weightsInputLatest = current
        if weightsInputInitial == nil { weightsInputInitial = current }
        if let origin = weightsInputInitial?.cgPointer, let point = current.cgPointer {
            weightsMaxCGOffset = max(weightsMaxCGOffset, distance(origin, point))
        }
        if let origin = weightsInputInitial?.appKitPointer, let point = current.appKitPointer {
            weightsMaxAppKitOffset = max(weightsMaxAppKitOffset, distance(origin, point))
        }
        weightsObservedHIDButtons |= current.hidButtons ?? 0
        weightsObservedCombinedButtons |= current.combinedButtons ?? 0
        weightsObservedHIDFlags |= current.hidFlags
        weightsObservedCombinedFlags |= current.combinedFlags
        let failure: String?
        if current.cgPointer == nil || current.appKitPointer == nil || current.hidButtons == nil || current.combinedButtons == nil {
            failure = "weights-input-state-unavailable"
        } else if weightsMaxCGOffset > 0 || weightsMaxAppKitOffset > 0 {
            failure = "weights-pointer-movement-observed"
        } else if weightsObservedHIDButtons != 0 || weightsObservedCombinedButtons != 0 {
            failure = "weights-global-button-observed"
        } else if weightsObservedHIDFlags != 0 || weightsObservedCombinedFlags != 0 {
            failure = "weights-global-modifier-observed"
        } else { failure = nil }
        if weightsInputFailure == nil, let failure {
            weightsInputFailure = failure
            emit("menuAgentWeightsInputRejected", weightsInputFields())
        } else if weightsInputSamples == 1 {
            emit("menuAgentWeightsInputBaseline", weightsInputFields())
        }
        return weightsInputFailure == nil
    }

    private func weightsInputFields() -> [String: Any] {
        let current = weightsInputLatest
        return ["fault": weightsInputFailure ?? "", "sampleCount": weightsInputSamples,
            "cgPointerAvailable": current?.cgPointer != nil, "appKitPointerAvailable": current?.appKitPointer != nil,
            "cgPointer": current?.cgPointer.map(coordinate) ?? [], "appKitPointer": current?.appKitPointer.map(coordinate) ?? [],
            "maximumCGPointerOffset": weightsMaxCGOffset, "maximumAppKitPointerOffset": weightsMaxAppKitOffset,
            "observedHIDButtons": weightsObservedHIDButtons, "observedCombinedButtons": weightsObservedCombinedButtons,
            "observedHIDFlags": weightsObservedHIDFlags, "observedCombinedFlags": weightsObservedCombinedFlags,
            "finalHIDButtonsKnown": current?.hidButtons != nil, "finalCombinedButtonsKnown": current?.combinedButtons != nil,
            "finalHIDButtons": current?.hidButtons ?? 0, "finalCombinedButtons": current?.combinedButtons ?? 0,
            "finalHIDFlags": current?.hidFlags ?? 0, "finalCombinedFlags": current?.combinedFlags ?? 0]
    }

    private func combinedButtons() -> Int {
        var result = 0
        for (button, bit) in [(CGMouseButton.left, 1), (.right, 2), (.center, 4)] {
            if CGEventSource.buttonState(.combinedSessionState, button: button) { result |= bit }
        }
        return result
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        axWorker?.cancel()
        axTask?.cancel()
        axTask = nil
        timer?.invalidate()
        timer = nil
        if !observeOnly, held, let a = sameOwnWindowA(), let point = lastPostedPoint {
            post(.leftMouseUp, point: point, command: phase == .dragMove || phase == .dragUp,
                target: a, cleanup: true)
        }
        samplePointer()
        // Remove before any final host read at the observation deadline. AX
        // timeouts must not extend the temporary items' visible lifetime.
        if observeOnly || menuAgentWeightsOptIn { removeProbeItemsAndRestorePreferences() }
        emitGeometry("finalGeometry")
        if menuAgentWeightsOptIn {
            _ = sampleWeightsInput()
            emit("menuAgentWeightsInputFinal", weightsInputFields())
            if positionHidingOptIn {
                emit("positionHidingResult", ["baselineVisibleVerified": hidingBaselineA != nil && hidingBaselineB != nil,
                    "raisedWeightSamples": hidingRaisedSamples, "raisedWeightVisibleSamples": hidingRaisedVisibleSamples,
                    "raisedWeightUnknownSamples": hidingRaisedUnknownSamples,
                    "baselineGeometryRestored": hidingRestoredGeometry, "dictionaryRestored": weightsCleanupVerified,
                    "inputGuardPassed": weightsInputFailure == nil, "cgEventSends": sentCount,
                    "physicalConcealConfirmed": false, "overflowExpansionTested": false,
                    "conclusion": hidingRaisedVisibleSamples > 0 ? "visible-at-hidden-weight-observed" : "hidden-state-unconfirmed",
                    "thirdPartyLayoutRestored": "unverified"])
            }
            if let reversed = weightsObservedReversal {
                emit("menuAgentWeightsResult", ["ownOrderReversed": reversed,
                    "inputGuardPassed": weightsInputFailure == nil, "passed": reversed && weightsInputFailure == nil,
                    "consecutiveObservations": weightsStableObservations, "cgEventSends": sentCount,
                    "thirdPartyLayoutRestored": "unverified", "method": "candidate-weights-and-owned-length-nudge"])
            }
        }
        let finalReason = menuAgentWeightsOptIn && weightsInputFailure != nil ? "menu-agent-weights-input-rejected" : reason
        emit("finish", ["reason": finalReason, "sentCount": sentCount,
            "actionCountA": actionCountA, "actionCountB": actionCountB,
            "confirmedClickActionCountA": confirmedClickActionCountA,
            "sceneCorrelatedClickActionCountA": sceneCorrelatedClickActionCountA,
            "syntheticButtonPending": held,
            "pointerSamples": pointerSamples, "pointerBefore": pointerBefore.map(coordinate) ?? [],
            "pointerAtFirstSend": pointerAtFirstSend.map(coordinate) ?? [],
            "pointerAfter": CGEvent(source: nil).map { coordinate($0.location) } ?? [],
            "maximumPointerOffset": maxPointerOffset, "maximumPointerOffsetDuringPosting": maxPostingOffset,
            "preparationButtonObserved": preparationButtonObserved, "combinedButtonEverObserved": buttonObserved,
            "combinedButtonsAfter": combinedButtons(), "appActive": NSApp.isActive,
            "observeOnly": observeOnly,
            "menuAgentWeightsOptIn": menuAgentWeightsOptIn,
            "weightsDictionaryRestored": weightsCleanupVerified,
            "thirdPartyLayoutRestored": "unverified",
            "runtimeSeconds": ProcessInfo.processInfo.systemUptime - startTime])
        if let appMonitor { NSEvent.removeMonitor(appMonitor) }
        appMonitor = nil
        removeProbeItemsAndRestorePreferences()
        NSApp.terminate(nil)
    }

    private func removeProbeItemsAndRestorePreferences() {
        hidingCaptureToken = nil
        hidingCaptureTask?.cancel()
        hidingCaptureTask = nil
        hidingCaptureTimeout?.cancel()
        hidingCaptureTimeout = nil
        weightsNudgeTask?.cancel()
        weightsNudgeTask = nil
        restoreMenuAgentNudgeLength()
        if let token = hostRegistrationToken {
            MenuBarHostTarget.unregisterOwnedItems(token: token)
            hostRegistrationToken = nil
            emit("ownHostRegistrationCleanup", ["removed": true])
        }
        if let itemA { NSStatusBar.system.removeStatusItem(itemA) }
        if let itemB { NSStatusBar.system.removeStatusItem(itemB) }
        itemA = nil
        itemB = nil
        restoreMenuAgentWeights()
        restorePreferredPositions()
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
    private func rectangle(_ frame: CGRect) -> [Double] { [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)] }
    private func distance(_ left: CGPoint, _ right: CGPoint) -> CGFloat { hypot(left.x - right.x, left.y - right.y) }
}

/// Only explicit diagnostic flags enter this helper. It never addresses a
/// third-party item, does not use screen coordinates, and invokes one action.
private enum StatusItemAXProbe {
    struct Report: Sendable {
        var actions: [String] = []
        var dispatched = false
        var result: Int32?
        var hostPID: pid_t?
        var readCount = 0
        var matches = 0
        var error: String?
        var requestUptime: Double?
        var returnUptime: Double?
    }
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
    private struct Match {
        let target: AXUIElement
        let path: [AXUIElement]
    }
    private final class Reads {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var count = 0

        func check() throws {
            try Task.checkCancellation()
            guard count < 512, ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure(detail: "bounded-read-budget-exceeded")
            }
            count += 1
        }
        func value(_ node: AXUIElement, _ attribute: String, optional: Bool = false) throws -> CFTypeRef? {
            try check()
            let result: (AXError, CFTypeRef?) = try onOwnerThread(node) {
                AXUIElementSetMessagingTimeout(node, 0.2)
                var value: CFTypeRef?
                return (AXUIElementCopyAttributeValue(node, attribute as CFString, &value), value)
            }
            if optional && (result.0 == .noValue || result.0 == .attributeUnsupported) { return nil }
            guard result.0 == .success else { throw Failure(detail: "AX-read-error-\(result.0.rawValue)") }
            return result.1
        }
        func children(_ node: AXUIElement, attribute: String = kAXChildrenAttribute,
                      optional: Bool = false) throws -> [AXUIElement] {
            guard let raw = try value(node, attribute, optional: optional) else { return [] }
            guard let array = raw as? [CFTypeRef], array.count <= 128 else {
                throw Failure(detail: "invalid-or-excessive-child-array")
            }
            return try array.map { value in
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw Failure(detail: "invalid-child-element")
                }
                return unsafeDowncast(value, to: AXUIElement.self)
            }
        }
        func actionNames(_ node: AXUIElement) throws -> [String] {
            try check()
            let result: (AXError, CFArray?) = try onOwnerThread(node) {
                AXUIElementSetMessagingTimeout(node, 0.2)
                var names: CFArray?
                return (AXUIElementCopyActionNames(node, &names), names)
            }
            guard result.0 == .success, let names = result.1 as? [String], names.count <= 64 else {
                throw Failure(detail: "AX-action-list-error-\(result.0.rawValue)")
            }
            return names
        }
    }

    static func perform(ownerPID: pid_t, identifier: String, hostRoute: Bool, action: String) -> Report {
        var report = Report()
        let reads = Reads()
        do {
            guard ownerPID == getpid(), identifier == "menu-tidy-probe-a",
                  action == kAXPressAction || action == kAXShowMenuAction,
                  AXIsProcessTrusted(), let ownerEpoch = MenuBarProcessIdentity.kernelLaunchTime(pid: ownerPID) else {
                throw Failure(detail: "own-target-or-permission-unavailable")
            }
            let application: AXUIElement
            let root: AXUIElement?
            let host: NSRunningApplication?
            let hostEpoch: TimeInterval?
            var matches: [Match] = []
            if hostRoute {
                let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
                    .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app" }
                guard hosts.count == 1, let foundHost = hosts.first,
                      let epoch = MenuBarProcessIdentity.launchTime(for: foundHost) else {
                    throw Failure(detail: "unique-system-host-unavailable")
                }
                host = foundHost
                hostEpoch = epoch
                root = nil
                report.hostPID = foundHost.processIdentifier
                application = AXUIElementCreateApplication(foundHost.processIdentifier)
                let windows = try reads.children(application, attribute: kAXWindowsAttribute)
                guard windows.count <= 32 else { throw Failure(detail: "excessive-host-windows") }
                for window in windows {
                    guard try pid(of: window) == foundHost.processIdentifier,
                          try reads.value(window, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
                    for container in try reads.children(window, optional: true) {
                        guard try pid(of: container) == foundHost.processIdentifier else { continue }
                        let children = try reads.children(container, optional: true)
                        let remote = try children.filter { try pid(of: $0) != foundHost.processIdentifier }
                        guard remote.count == 1, let target = remote.first,
                              try pid(of: target) == ownerPID,
                              try reads.value(target, kAXRoleAttribute) as? String == kAXButtonRole,
                              try reads.value(target, kAXIdentifierAttribute, optional: true) as? String == identifier else { continue }
                        matches.append(Match(target: target, path: [window, container, target]))
                    }
                }
            } else {
                host = nil
                hostEpoch = nil
                application = AXUIElementCreateApplication(ownerPID)
                guard let raw = try reads.value(application, kAXExtrasMenuBarAttribute),
                      CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                    throw Failure(detail: "source-extras-menu-bar-unavailable")
                }
                let extras = unsafeDowncast(raw, to: AXUIElement.self)
                root = extras
                var visited: [AXUIElement] = []
                try findSource(extras, path: [extras], ownerPID: ownerPID, identifier: identifier,
                    reads: reads, visited: &visited, matches: &matches)
            }
            report.matches = matches.count
            guard matches.count == 1, let match = matches.first else {
                throw Failure(detail: "target-not-unique-\(matches.count)")
            }
            // Re-read every actual edge immediately before the one action.
            if let root {
                guard let current = try reads.value(application, kAXExtrasMenuBarAttribute), CFEqual(current, root) else {
                    throw Failure(detail: "source-root-changed")
                }
            } else {
                guard let window = match.path.first,
                      try reads.children(application, attribute: kAXWindowsAttribute).filter({ CFEqual($0, window) }).count == 1 else {
                    throw Failure(detail: "host-window-changed")
                }
            }
            for (parent, child) in zip(match.path, match.path.dropFirst()) {
                let children = try reads.children(parent)
                guard children.filter({ CFEqual($0, child) }).count == 1 else {
                    throw Failure(detail: "target-lineage-changed")
                }
                if hostRoute && CFEqual(child, match.target) {
                    let remote = try children.filter { try pid(of: $0) != report.hostPID }
                    guard remote.count == 1 else { throw Failure(detail: "host-container-no-longer-unique") }
                }
            }
            guard try pid(of: match.target) == ownerPID,
                  try reads.value(match.target, kAXIdentifierAttribute) as? String == identifier,
                  try reads.value(match.target, kAXRoleAttribute) as? String == (hostRoute ? kAXButtonRole : kAXMenuBarItemRole),
                  MenuBarProcessIdentity.kernelLaunchTime(pid: ownerPID) == ownerEpoch else {
                throw Failure(detail: "own-target-identity-changed")
            }
            if let host {
                guard !host.isTerminated, MenuBarProcessIdentity.launchTime(for: host) == hostEpoch else {
                    throw Failure(detail: "host-epoch-changed")
                }
            }
            let names = try reads.actionNames(match.target)
            let standard = [kAXPressAction, kAXShowMenuAction, kAXRaiseAction, kAXCancelAction,
                kAXConfirmAction, kAXPickAction, kAXIncrementAction, kAXDecrementAction]
            report.actions = standard.filter(names.contains)
            guard names.contains(action) else { throw Failure(detail: "requested-action-not-advertised") }
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  !CGEventSource.buttonState(.combinedSessionState, button: .right),
                  !CGEventSource.buttonState(.combinedSessionState, button: .center) else {
                throw Failure(detail: "permission-or-input-changed")
            }
            report.requestUptime = ProcessInfo.processInfo.systemUptime
            report.result = try onOwnerThread(match.target) {
                AXUIElementSetMessagingTimeout(match.target, 0.2)
                return AXUIElementPerformAction(match.target, action as CFString).rawValue
            }
            report.dispatched = true
            report.returnUptime = ProcessInfo.processInfo.systemUptime
        } catch { report.error = error.localizedDescription }
        report.readCount = reads.count
        return report
    }

    private static func findSource(_ node: AXUIElement, path: [AXUIElement], ownerPID: pid_t,
                                   identifier: String, reads: Reads, visited: inout [AXUIElement],
                                   matches: inout [Match]) throws {
        guard !visited.contains(where: { CFEqual($0, node) }) else { return }
        guard visited.count < 128, path.count <= 5 else { throw Failure(detail: "source-tree-budget-exceeded") }
        visited.append(node)
        guard try pid(of: node) == ownerPID else { return }
        if try reads.value(node, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
           try reads.value(node, kAXIdentifierAttribute, optional: true) as? String == identifier {
            matches.append(Match(target: node, path: path))
            return
        }
        for child in try reads.children(node, optional: true) {
            try findSource(child, path: path + [child], ownerPID: ownerPID, identifier: identifier,
                reads: reads, visited: &visited, matches: &matches)
        }
    }

    private static func pid(of node: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(node, &pid)
        guard result == .success, pid > 0 else { throw Failure(detail: "AX-owner-unavailable") }
        return pid
    }

    private static func onOwnerThread<T>(_ node: AXUIElement, _ operation: () -> T) throws -> T {
        if try pid(of: node) == getpid(), !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: operation)
        }
        return operation()
    }
}

/// Call only before normal app initialization from --probe-status-items.
@MainActor
func runTargetedStatusItemProbe() {
    guard MenuTidyLaunchPlan.parse(Array(CommandLine.arguments.dropFirst())) == .statusItems else { return }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let probe = TargetedStatusItemProbe()
    application.delegate = probe
    withExtendedLifetime(probe) { application.run() }
}
