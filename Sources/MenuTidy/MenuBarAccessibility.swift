import AppKit
import ApplicationServices
import Darwin
import Foundation
import MenuTidyCore
import OSLog

struct MenuBarOwner: Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let launchTime: TimeInterval
}

struct MenuBarItemSnapshot: Identifiable, Sendable {
    let id: String
    let name: String
    let ownerName: String
    let bundleIdentifier: String?
    let frame: CGRect
    let hasReliableGeometry: Bool
    let canMove: Bool
    let detail: String
    let persistentIdentity: Bool
    let ownIdentifier: String?
}

/// Read-only evidence from an already known AX entry. A missing frame is
/// unknown visibility; an available frame alone does not prove clickability.
struct MenuBarVisibilityInspection: Sendable {
    let frame: CGRect?
    let centerHit: Bool
    let hasEntry: Bool
    var hasFrame: Bool { frame != nil }
}

enum MenuBarAccessError: LocalizedError, Sendable {
    case permission, eventPermission, disappeared, invalidGeometry, differentScreen, rejected, cancelled
    case geometryDetail(String)
    var errorDescription: String? {
        switch self {
        case .permission: return "需要辅助功能权限。请在权限页授权 Menu Tidy 后重试。"
        case .eventPermission: return "系统尚未允许控制事件。请在辅助功能中重新开启 Menu Tidy，重新打开应用后再试。"
        case .disappeared: return "图标已退出或位置不可读取，请刷新列表后重试。"
        case .invalidGeometry: return "菜单栏未提供有效位置。请先展开其他整理器、退出全屏，再刷新列表。"
        case .geometryDetail(let detail): return detail
        case .differentScreen: return "目标与分隔线不在同一块屏幕，无法安全移动。请在主屏菜单栏重试。"
        case .rejected: return "macOS 未接受图标移动。该图标可能被系统固定，或有其他菜单栏工具正在控制它。"
        case .cancelled: return "操作已取消，已释放鼠标并恢复展开。"
        }
    }
}

/// AX objects are confined to this actor; only value snapshots cross to the UI.
actor MenuBarAccessibility {
    private struct Entry {
        let element: AXUIElement
        let owner: MenuBarOwner
        let snapshot: MenuBarItemSnapshot
    }
    private struct Candidate {
        let element: AXUIElement
        let owner: MenuBarOwner
        let identifier: String?
        let name: String
        let frame: CGRect
        let role: String
        let source: CandidateSource
    }
    private enum CandidateSource {
        case applicationExtras
        case hostWindow
    }
    private enum SystemOverflowState {
        case collapsed
        case expanded
    }
    private struct OverflowPointerLease {
        let original: CGPoint
        var parked: CGPoint
        var valid = true
    }
    private struct InputCounterSnapshot {
        let hid: [UInt32]
        let combined: [UInt32]
    }
    private static let diagnosticEventTypes: [(String, CGEventType)] = [
        ("move", .mouseMoved), ("drag", .leftMouseDragged),
        ("leftDown", .leftMouseDown), ("leftUp", .leftMouseUp),
        ("rightDown", .rightMouseDown), ("rightUp", .rightMouseUp),
        ("flags", .flagsChanged), ("keyDown", .keyDown),
        ("keyUp", .keyUp), ("scroll", .scrollWheel)
    ]
    private var entries: [String: Entry] = [:]
    private var menuBands: [CGRect] = []
    private var cancellationRequested = false
    private var managementControlNeedsRecovery = false
    private var managementOverflowEntry: Entry?
    private var overflowPointerLease: OverflowPointerLease?
    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "MenuBarAccessibility")
    private static let allLocalEvents: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
    private static let anchorIdentifiers: Set<String> = ["menu-tidy-toggle", "menu-tidy-divider", "menu-tidy-always-divider"]
    private static let overflowAccessibilityLabels: (show: Set<String>, hide: Set<String>) = {
        let showKey = "menuBar.showOverflowItemsAccessibilityLabel"
        let hideKey = "menuBar.hideOverflowItemsAccessibilityLabel"
        var show: Set<String> = ["Show Hidden Menu Bar Items", "显示隐藏菜单栏项目"]
        var hide: Set<String> = ["Hide Menu Bar Items", "隐藏菜单栏项目"]
        // MenuBarAgent can use a different UI language from this application.
        // Match the system's translations of these two specific recovery actions.
        if let bundle = Bundle(path: "/System/Library/CoreServices/MenuBarAgent.app"),
           let resource = bundle.url(forResource: "MenuBarCore", withExtension: "loctable"),
           let data = try? Data(contentsOf: resource),
           let translations = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            for language in translations.values {
                guard let strings = language as? [String: String] else { continue }
                if let label = strings[showKey], !label.isEmpty { show.insert(label) }
                if let label = strings[hideKey], !label.isEmpty { hide.insert(label) }
            }
        }
        return (show, hide)
    }()

    func cancel() { cancellationRequested = true }

    func scan(owners: [MenuBarOwner], menuBands: [CGRect]) throws -> [MenuBarItemSnapshot] {
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        self.menuBands = menuBands
        // A MenuBarAgent subtree can contain remote AX elements whose PID belongs
        // to the originating application. Never attribute those to the host, and
        // require a launch timestamp so a reused PID cannot inherit old entries.
        let ownersByPID = Dictionary(owners.compactMap(resolvedOwner).map { ($0.pid, $0) },
                                     uniquingKeysWith: { first, _ in first })
        var candidates: [Candidate] = []
        var totalBudget = 2500
        for owner in owners {
            try Task.checkCancellation()
            guard totalBudget > 0 else { break }
            var ownerBudget = min(160, totalBudget)
            let initialBudget = ownerBudget
            let application = AXUIElementCreateApplication(owner.pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            var extrasValue: CFTypeRef?
            let extrasResult = AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &extrasValue)
            if owner.pid == ProcessInfo.processInfo.processIdentifier {
                let elementPresent = element(extrasValue) != nil
                Self.logger.notice("ownExtras pid=\(owner.pid) axError=\(extrasResult.rawValue) elementPresent=\(elementPresent)")
            }
            if extrasResult == .success, let extras = element(extrasValue) {
                if owner.pid == ProcessInfo.processInfo.processIdentifier {
                    var childrenValue: CFTypeRef?
                    let childrenResult = AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString, &childrenValue)
                    let ownChildren = elements(childrenValue)
                    Self.logger.notice("ownExtras directChildrenError=\(childrenResult.rawValue) directChildrenCount=\(ownChildren.count)")
                    for child in ownChildren.prefix(60) {
                        logOwnWalk(child, ownersByPID: ownersByPID, source: .applicationExtras,
                            depth: 1, stage: "own-extras-direct-child", includeOwnUnidentified: true)
                    }
                }
                walk(extras, ownersByPID: ownersByPID, source: .applicationExtras, depth: 0, remaining: &ownerBudget, into: &candidates)
            }
            // macOS 27 hosts system extras in a separate menu-bar process.
            if owner.bundleIdentifier == "com.apple.MenuBarAgent" || owner.name == "MenuBarAgent" {
                for window in elements(attribute(application, kAXWindowsAttribute)) {
                    walk(window, ownersByPID: ownersByPID, source: .hostWindow, depth: 0, remaining: &ownerBudget, into: &candidates)
                }
            }
            totalBudget -= initialBudget - ownerBudget
        }
        try Task.checkCancellation()
        // Preserve a stable identifier first, then prefer the originating app's
        // menu-bar item over the remote button projected through MenuBarAgent.
        candidates.sort {
            if ($0.identifier != nil) != ($1.identifier != nil) { return $0.identifier != nil }
            if $0.source != $1.source { return $0.source == .applicationExtras }
            return ($0.role == kAXMenuBarItemRole ? 1 : 0) > ($1.role == kAXMenuBarItemRole ? 1 : 0)
        }
        var unique: [Candidate] = []
        for candidate in candidates {
            var duplicate = false
            for existing in unique {
                if sameItem(existing, candidate) {
                    duplicate = true
                    break
                }
            }
            if !duplicate { unique.append(candidate) }
        }
        var identifierCounts: [String: Int] = [:]
        for candidate in unique {
            if let key = persistentKey(candidate) { identifierCounts[key, default: 0] += 1 }
        }
        var unreliableGeometry: Set<Int> = []
        for first in unique.indices {
            for second in unique.indices where second > first {
                let firstFrame = unique[first].frame
                let secondFrame = unique[second].frame
                let overlap = firstFrame.intersection(secondFrame)
                // Native overflow placeholders can give unrelated icons the
                // same position. Allow tiny borders, not substantial overlap.
                if !overlap.isNull,
                   overlap.width > max(2, min(firstFrame.width, secondFrame.width) * 0.25),
                   overlap.height > min(firstFrame.height, secondFrame.height) * 0.5 {
                    unreliableGeometry.insert(first)
                    unreliableGeometry.insert(second)
                }
            }
        }
        var updated: [String: Entry] = [:]
        for (candidateIndex, candidate) in unique.enumerated() {
            let hasReliableGeometry = !unreliableGeometry.contains(candidateIndex)
            let persistent = persistentKey(candidate).flatMap { identifierCounts[$0] == 1 ? $0 : nil }
            let existing = entries.values.first {
                $0.owner.pid == candidate.owner.pid && $0.owner.launchTime == candidate.owner.launchTime && CFEqual($0.element, candidate.element)
            }
            let reusableSessionID = existing?.snapshot.id.hasPrefix("session:") == true ? existing?.snapshot.id : nil
            let id = persistent ?? reusableSessionID ?? "session:\(candidate.owner.pid):\(UUID().uuidString)"
            let ownBundle = Bundle.main.bundleIdentifier
            let own = candidate.owner.pid == ProcessInfo.processInfo.processIdentifier && ownBundle != nil &&
                candidate.owner.bundleIdentifier == ownBundle ? candidate.identifier : nil
            if let identifier = candidate.identifier, Self.anchorIdentifiers.contains(identifier) {
                Self.logger.notice("anchorMapping id=\(identifier, privacy: .public) ownIdentifier=\(own ?? "nil", privacy: .public) ownerPID=\(candidate.owner.pid) ownPID=\(ProcessInfo.processInfo.processIdentifier) ownerBundle=\(candidate.owner.bundleIdentifier ?? "nil", privacy: .public) ownBundle=\(ownBundle ?? "nil", privacy: .public) role=\(candidate.role, privacy: .public) source=\(String(describing: candidate.source), privacy: .public) frame=\(String(describing: candidate.frame), privacy: .public)")
            }
            let systemOverflow = Self.isSystemOverflow(ownerBundleIdentifier: candidate.owner.bundleIdentifier,
                role: candidate.role, identifier: candidate.identifier, label: candidate.name)
            let protected = own != nil || systemOverflow || ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(candidate.identifier ?? "")
            let snapshot = MenuBarItemSnapshot(id: id, name: candidate.name, ownerName: candidate.owner.name,
                bundleIdentifier: candidate.owner.bundleIdentifier, frame: candidate.frame,
                hasReliableGeometry: hasReliableGeometry, canMove: !protected,
                detail: systemOverflow ? "系统菜单栏溢出入口，用于恢复隐藏图标，不参与分组" :
                    (protected ? "系统固定项目或 Menu Tidy 控制项，保持可见" : (persistent == nil ? "没有稳定标识，仅在本次运行中记住此图标的分类" : "")),
                persistentIdentity: persistent != nil, ownIdentifier: own)
            updated[id] = Entry(element: candidate.element, owner: candidate.owner, snapshot: snapshot)
        }
        // Retain off-screen items for recovery and rules; never reuse a stale PID.
        let alive = ownersByPID.mapValues(\.launchTime)
        for (id, old) in entries where updated[id] == nil && alive[old.owner.pid] == old.owner.launchTime && !updated.values.contains(where: { CFEqual($0.element, old.element) }) {
            updated[id] = old
        }
        entries = updated
        return unique.compactMap { candidate in
            updated.values.first { CFEqual($0.element, candidate.element) }?.snapshot
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    func currentFrame(id: String) -> CGRect? {
        guard let entry = entries[id] else { return nil }
        return frame(entry.element)
    }

    /// Does not rescan, open overflow, alter layout, or synthesize input.
    func inspectVisibility(id: String) -> MenuBarVisibilityInspection {
        guard let entry = entries[id] else {
            return MenuBarVisibilityInspection(frame: nil, centerHit: false, hasEntry: false)
        }
        guard AXIsProcessTrusted(), let rect = frame(entry.element) else {
            return MenuBarVisibilityInspection(frame: nil, centerHit: false, hasEntry: true)
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard rect.width > 0, rect.height > 0, center.x.isFinite, center.y.isFinite,
              menuBands.contains(where: { $0.contains(center) }) else {
            return MenuBarVisibilityInspection(frame: rect, centerHit: false, hasEntry: true)
        }
        return MenuBarVisibilityInspection(frame: rect,
            centerHit: sourceMatchesHitTest(entry.element, at: center, context: "visibility-inspection"),
            hasEntry: true)
    }

    /// Open the system's overflow from inside this application, only when our
    /// own anchors cannot currently be used for management. Moving still requires
    /// all of the existing geometry and hit-test checks after the caller rescans.
    func revealSystemOverflowForManagement() async throws -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return false }
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard !Task.isCancelled else { throw MenuBarAccessError.cancelled }
        guard managementOverflowEntry == nil else { return false }
        cancellationRequested = false
        var anchors: [Entry] = []
        for entry in entries.values {
            if let identifier = entry.snapshot.ownIdentifier,
               Self.anchorIdentifiers.contains(identifier),
               entry.owner.pid == ProcessInfo.processInfo.processIdentifier,
               entry.owner.bundleIdentifier == Bundle.main.bundleIdentifier {
                anchors.append(entry)
            }
        }
        guard anchors.count == Self.anchorIdentifiers.count,
              Set(anchors.compactMap(\.snapshot.ownIdentifier)) == Self.anchorIdentifiers else {
            throw MenuBarAccessError.geometryDetail("Menu Tidy 的三个定位项尚未完整读取，请刷新列表后重试。")
        }
        let frames = anchors.compactMap { frame($0.element) }
        var anchorsOverlap = false
        for first in frames.indices {
            for second in frames.indices where second > first {
                let overlap = frames[first].intersection(frames[second])
                // Ignore tiny borders; overflow placeholders substantially share
                // the same horizontal space instead of forming separate items.
                if !overlap.isNull, overlap.width >= min(frames[first].width, frames[second].width) / 2 {
                    anchorsOverlap = true
                }
            }
        }
        var anchorsClickable = frames.count == anchors.count
        if anchorsClickable {
            for entry in anchors {
                guard let rect = frame(entry.element), rect.width > 0, rect.height > 0,
                      sourceMatchesHitTest(entry.element, at: CGPoint(x: rect.midX, y: rect.midY), context: "management-anchor") else {
                    anchorsClickable = false
                    break
                }
            }
        }
        let needed = anchorsOverlap || !anchorsClickable
        managementControlNeedsRecovery = anchors.first(where: { $0.snapshot.ownIdentifier == "menu-tidy-toggle" }).map { entry in
            guard let rect = frame(entry.element) else { return true }
            return !sourceMatchesHitTest(entry.element, at: CGPoint(x: rect.midX, y: rect.midY), context: "management-control")
        } ?? false
        Self.logger.notice("managementOverflow prepareNeeded=\(needed) anchorsOverlap=\(anchorsOverlap) anchorsClickable=\(anchorsClickable)")
        var overflow: Entry?
        for entry in entries.values {
            guard currentSystemOverflowState(entry) != nil,
                  let rect = frame(entry.element), menuBands.contains(where: { $0.intersects(rect) }) else { continue }
            if let found = overflow, !CFEqual(found.element, entry.element) {
                throw MenuBarAccessError.geometryDetail("无法唯一识别主屏的系统菜单栏溢出入口，请刷新后重试。")
            }
            overflow = entry
        }
        guard let overflow, let initialState = currentSystemOverflowState(overflow) else {
            if !needed { return false }
            throw MenuBarAccessError.geometryDetail("定位项不可点击，且未找到可识别的系统菜单栏溢出入口，请检查主屏菜单栏后刷新。")
        }
        guard initialState == .collapsed else {
            try await validatedOverflowPark(overflow, expected: .expanded)
            Self.logger.notice("managementOverflow alreadyExpanded=true openedByManagement=false")
            return false
        }
        guard needed else { return false }
        // Keep the cursor at the recovery entry even when AXPress succeeds;
        // leaving it in the settings window can immediately dismiss overflow.
        try await validatedOverflowPark(overflow, expected: .collapsed)
        let pressResult = AXUIElementPerformAction(overflow.element, kAXPressAction as CFString)
        Self.logger.notice("managementOverflow openPressAccepted=\(pressResult == .success) axError=\(pressResult.rawValue)")
        if pressResult != .success {
            try await validatedOverflowClick(overflow, expected: .collapsed, restoring: false)
        }
        await waitForSystemOverflowTransition()
        let opened = currentSystemOverflowState(overflow) == .expanded
        if opened { managementOverflowEntry = overflow }
        Self.logger.notice("managementOverflow openedByManagement=\(opened)")
        guard opened else {
            throw MenuBarAccessError.geometryDetail("系统菜单栏溢出入口尚未确认展开，已停止整理，请重试。")
        }
        if overflowPointerLease != nil, !parkedPointerIsUntouched() { throw MenuBarAccessError.cancelled }
        guard !Task.isCancelled else { throw MenuBarAccessError.cancelled }
        return true
    }

    /// An overflowed control would remain unreachable after merely ordering the
    /// two boundaries. Recover only our own control beside the visible clock;
    /// the clock itself is never moved. All normal drag checks still apply.
    func recoverControlFromSystemOverflow() async throws {
        guard managementControlNeedsRecovery else { return }
        let controls = entries.values.filter { $0.snapshot.ownIdentifier == "menu-tidy-toggle" }
        let clocks = entries.values.filter {
            text($0.element, kAXIdentifierAttribute) == "com.apple.menuextra.clock"
                && $0.owner.bundleIdentifier?.hasPrefix("com.apple.") == true
        }
        guard controls.count == 1, clocks.count == 1,
              let control = controls.first, let clock = clocks.first else {
            throw MenuBarAccessError.geometryDetail("无法确认可见的系统时钟与 Menu Tidy 入口，已停止恢复入口。")
        }
        try await move(id: control.snapshot.id, before: clock.snapshot.id)
        // System-fixed extras can remain between our item and the clock. The
        // recovery contract is a hittable item to the right of overflow, not an
        // arbitrary maximum gap from the clock.
        let overflowFrames = entries.values.compactMap { entry -> CGRect? in
            guard currentSystemOverflowState(entry) != nil else { return nil }
            return frame(entry.element)
        }
        guard let result = frame(control.element), let clockFrame = frame(clock.element),
              result.maxX <= clockFrame.minX + 1,
              overflowFrames.allSatisfy({ result.minX >= $0.maxX }),
              sourceMatchesHitTest(control.element, at: CGPoint(x: result.midX, y: result.midY), context: "recovered-control") else {
            throw MenuBarAccessError.geometryDetail("Menu Tidy 入口尚未移到时钟旁的可见区域，请重试恢复。")
        }
        managementControlNeedsRecovery = false
    }

    /// Cleanup remains usable from a cancelled task. Never close overflow that
    /// the user had already opened before this management operation.
    func restoreSystemOverflowAfterManagement() async {
        managementControlNeedsRecovery = false
        let overflow = managementOverflowEntry
        managementOverflowEntry = nil
        defer { restoreOverflowPointerIfUntouched() }
        if overflowPointerLease != nil, !parkedPointerIsUntouched() {
            Self.logger.notice("managementOverflow restoreSkippedForUserInput=true")
            return
        }
        guard let overflow else { return }
        guard currentSystemOverflowState(overflow) == .expanded else {
            Self.logger.notice("managementOverflow restoreNeeded=false")
            return
        }
        let pressResult = AXUIElementPerformAction(overflow.element, kAXPressAction as CFString)
        Self.logger.notice("managementOverflow restorePressAccepted=\(pressResult == .success) axError=\(pressResult.rawValue)")
        if pressResult != .success {
            do { try await validatedOverflowClick(overflow, expected: .expanded, restoring: true) }
            catch { Self.logger.error("managementOverflow restorePhysicalClickAccepted=false"); return }
        }
        await waitForSystemOverflowTransition()
        let restored = currentSystemOverflowState(overflow) == .collapsed
        Self.logger.notice("managementOverflow restored=\(restored)")
    }

    private func currentSystemOverflowState(_ entry: Entry) -> SystemOverflowState? {
        guard entry.owner.bundleIdentifier == "com.apple.MenuBarAgent" else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(entry.element, &pid) == .success, pid == entry.owner.pid,
              text(entry.element, kAXRoleAttribute) == kAXButtonRole,
              let liveOwner = resolvedOwner(MenuBarOwner(pid: pid, bundleIdentifier: entry.owner.bundleIdentifier,
                  name: entry.owner.name, launchTime: 0)), liveOwner.launchTime == entry.owner.launchTime,
              let label = text(entry.element, kAXDescriptionAttribute) ?? text(entry.element, kAXTitleAttribute) else { return nil }
        if Self.overflowAccessibilityLabels.show.contains(label) { return .collapsed }
        if Self.overflowAccessibilityLabels.hide.contains(label) { return .expanded }
        return nil
    }

    private func waitForSystemOverflowTransition(milliseconds: Int = 200) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    private func physicalInputIsIdle() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty &&
            !CGEventSource.buttonState(.combinedSessionState, button: .left) &&
            !CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    private func invalidateOverflowPointerLease() {
        overflowPointerLease?.valid = false
    }

    private func parkedPointerIsUntouched() -> Bool {
        guard let lease = overflowPointerLease else { return true }
        let flags = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
        let point = CGEvent(source: nil)?.location
        let delta = point.map { hypot($0.x - lease.parked.x, $0.y - lease.parked.y) } ?? .infinity
        guard lease.valid, flags.isEmpty, !left, !right, delta <= 12 else {
            Self.logger.error("pointerLease rejected=true valid=\(lease.valid) delta=\(delta) flags=\(flags.rawValue) left=\(left) right=\(right)")
            invalidateOverflowPointerLease()
            return false
        }
        return true
    }

    private func restoreOverflowPointerIfUntouched() {
        defer { overflowPointerLease = nil }
        guard parkedPointerIsUntouched(), let lease = overflowPointerLease,
              let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                  mouseCursorPosition: lease.original, mouseButton: .left) else { return }
        event.flags = []
        let warpResult = CGWarpMouseCursorPosition(lease.original)
        Self.logger.notice("pointerLease restoreWarpAccepted=\(warpResult == .success) warpError=\(warpResult.rawValue)")
        guard warpResult == .success else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Parking is independent of ownership: user-opened overflow is never
    /// acquired by management and therefore never receives a cleanup click.
    private func validatedOverflowPark(_ entry: Entry, expected: SystemOverflowState) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard CGPreflightPostEventAccess() else { throw MenuBarAccessError.eventPermission }
        guard !Task.isCancelled, !cancellationRequested,
              physicalInputIsIdle(), parkedPointerIsUntouched() else { throw MenuBarAccessError.cancelled }
        guard currentSystemOverflowState(entry) == expected,
              let rect = frame(entry.element), rect.width > 0, rect.height > 0,
              menuBands.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口的状态或主屏位置无法确认，未停驻鼠标。")
        }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard sourceMatchesHitTest(entry.element, at: point, context: "overflow-park") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口不在可点击位置，未停驻鼠标。")
        }
        guard let originalPointer = CGEvent(source: nil)?.location,
              let eventSource = CGEventSource(stateID: .combinedSessionState),
              let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                  mouseCursorPosition: point, mouseButton: .left) else { throw MenuBarAccessError.eventPermission }
        eventSource.localEventsSuppressionInterval = 0
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateSuppressionInterval)
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateRemoteMouseDrag)
        moveEvent.flags = []
        await waitForSystemOverflowTransition(milliseconds: 50)
        guard !Task.isCancelled, !cancellationRequested,
              physicalInputIsIdle(), parkedPointerIsUntouched() else { throw MenuBarAccessError.cancelled }
        guard frame(entry.element) == rect, currentSystemOverflowState(entry) == expected,
              sourceMatchesHitTest(entry.element, at: point, context: "overflow-park-settled") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口的位置或状态发生变化，未停驻鼠标。")
        }
        var completed = false
        var pointerWarped = false
        defer {
            if !completed {
                if overflowPointerLease != nil { restoreOverflowPointerIfUntouched() }
                else if pointerWarped, physicalInputIsIdle(), let actual = CGEvent(source: nil)?.location,
                        hypot(actual.x - point.x, actual.y - point.y) <= 12 {
                    _ = CGWarpMouseCursorPosition(originalPointer)
                }
            }
        }
        let warpResult = CGWarpMouseCursorPosition(point)
        Self.logger.notice("managementOverflow parkWarpAccepted=\(warpResult == .success) warpError=\(warpResult.rawValue)")
        guard warpResult == .success else { throw MenuBarAccessError.geometryDetail("无法将鼠标停驻在系统溢出入口，已停止整理。") }
        pointerWarped = true
        moveEvent.post(tap: .cghidEventTap)
        await waitForSystemOverflowTransition(milliseconds: 50)
        guard !Task.isCancelled, !cancellationRequested else { throw MenuBarAccessError.cancelled }
        let actual = CGEvent(source: nil)?.location
        let delta = actual.map { hypot($0.x - point.x, $0.y - point.y) } ?? .infinity
        Self.logger.notice("managementOverflow parkReadbackDelta=\(delta)")
        guard physicalInputIsIdle(), delta <= 12 else {
            invalidateOverflowPointerLease()
            throw MenuBarAccessError.cancelled
        }
        if overflowPointerLease == nil { overflowPointerLease = OverflowPointerLease(original: originalPointer, parked: point) }
        else { overflowPointerLease?.parked = point }
        guard frame(entry.element) == rect, currentSystemOverflowState(entry) == expected,
              sourceMatchesHitTest(entry.element, at: point, context: "overflow-park-ready") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口在停驻时发生变化，已停止整理。")
        }
        completed = true
        Self.logger.notice("managementOverflow parkedForManagement=true")
    }

    private func validatedOverflowClick(_ entry: Entry, expected: SystemOverflowState, restoring: Bool) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard CGPreflightPostEventAccess() else { throw MenuBarAccessError.eventPermission }
        guard restoring || (!Task.isCancelled && !cancellationRequested) else { throw MenuBarAccessError.cancelled }
        guard currentSystemOverflowState(entry) == expected,
              let rect = frame(entry.element), rect.width > 0, rect.height > 0,
              menuBands.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口的状态或主屏位置无法确认，未执行鼠标点击。")
        }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard physicalInputIsIdle(), parkedPointerIsUntouched() else { throw MenuBarAccessError.cancelled }
        guard sourceMatchesHitTest(entry.element, at: point, context: "overflow-click") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口不在可点击位置，未执行鼠标点击。")
        }
        guard let originalPointer = CGEvent(source: nil)?.location,
              let eventSource = CGEventSource(stateID: .combinedSessionState),
              let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left),
              let emergencyUp = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw MenuBarAccessError.eventPermission
        }
        eventSource.localEventsSuppressionInterval = 0
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateSuppressionInterval)
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateRemoteMouseDrag)
        for event in [moveEvent, downEvent, upEvent, emergencyUp] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        await waitForSystemOverflowTransition(milliseconds: 50)
        guard restoring || (!Task.isCancelled && !cancellationRequested) else { throw MenuBarAccessError.cancelled }
        guard physicalInputIsIdle(), parkedPointerIsUntouched(), frame(entry.element) == rect,
              currentSystemOverflowState(entry) == expected,
              sourceMatchesHitTest(entry.element, at: point, context: "overflow-click-settled") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口或输入状态发生变化，未执行鼠标点击。")
        }
        var mouseHeld = false
        var completed = false
        var pointerWarped = false
        defer {
            if mouseHeld { emergencyUp.post(tap: .cghidEventTap) }
            if !completed {
                if overflowPointerLease != nil { restoreOverflowPointerIfUntouched() }
                else if pointerWarped, physicalInputIsIdle(), let actual = CGEvent(source: nil)?.location,
                        hypot(actual.x - point.x, actual.y - point.y) <= 12 {
                    _ = CGWarpMouseCursorPosition(originalPointer)
                }
            }
        }
        let warpResult = CGWarpMouseCursorPosition(point)
        Self.logger.notice("managementOverflow clickWarpAccepted=\(warpResult == .success) warpError=\(warpResult.rawValue)")
        guard warpResult == .success else { throw MenuBarAccessError.geometryDetail("无法定位鼠标到系统溢出入口，未执行点击。") }
        pointerWarped = true
        moveEvent.post(tap: .cghidEventTap)
        await waitForSystemOverflowTransition(milliseconds: 50)
        guard restoring || (!Task.isCancelled && !cancellationRequested) else { throw MenuBarAccessError.cancelled }
        let actualPointer = CGEvent(source: nil)?.location
        let parkedDelta = actualPointer.map { hypot($0.x - point.x, $0.y - point.y) } ?? .infinity
        Self.logger.notice("managementOverflow clickWarpReadbackDelta=\(parkedDelta)")
        guard physicalInputIsIdle(), parkedDelta <= 12 else {
            invalidateOverflowPointerLease()
            throw MenuBarAccessError.cancelled
        }
        // Establish the lease only after the physical cursor reached the target.
        if overflowPointerLease == nil { overflowPointerLease = OverflowPointerLease(original: originalPointer, parked: point) }
        else { overflowPointerLease?.parked = point }
        guard parkedPointerIsUntouched(), frame(entry.element) == rect,
              currentSystemOverflowState(entry) == expected,
              sourceMatchesHitTest(entry.element, at: point, context: "overflow-click-before-down") else {
            throw MenuBarAccessError.geometryDetail("系统溢出入口或鼠标位置发生变化，已停止点击。")
        }
        downEvent.post(tap: .cghidEventTap)
        mouseHeld = true
        // Complete our mouse-up even when the task is cancelled during the click.
        await waitForSystemOverflowTransition(milliseconds: 50)
        upEvent.post(tap: .cghidEventTap)
        mouseHeld = false
        completed = true
        Self.logger.notice("managementOverflow physicalClickCompleted=true restoring=\(restoring)")
    }

    func move(id: String, before anchorID: String) async throws {
        cancellationRequested = false
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard CGPreflightPostEventAccess() else { throw MenuBarAccessError.eventPermission }
        guard parkedPointerIsUntouched() else { throw MenuBarAccessError.cancelled }
        guard let entry = entries[id], let anchor = entries[anchorID] else { throw MenuBarAccessError.disappeared }
        guard let sourceRect = frame(entry.element) else {
            throw geometryFailure("源图标位置不可读取，请刷新列表后重试。", stage: "source-frame-missing", source: nil, anchor: nil)
        }
        guard let anchorRect = frame(anchor.element) else {
            throw geometryFailure("目标定位项位置不可读取，请临时显示全部并刷新后重试。", stage: "anchor-frame-missing", source: sourceRect, anchor: nil)
        }
        guard sourceRect.width > 0, sourceRect.height > 0, menuBands.contains(where: { $0.intersects(sourceRect) }) else {
            throw geometryFailure("源图标不在可点击的主屏菜单栏内，请先让图标显示在主菜单栏再试。", stage: "source-outside-menu-band", source: sourceRect, anchor: anchorRect)
        }
        guard anchorRect.width > 0, anchorRect.height > 0, menuBands.contains(where: { $0.intersects(anchorRect) }) else {
            throw geometryFailure("目标定位项不在可点击的主屏菜单栏内，请临时显示全部并检查 Menu Tidy 入口。", stage: "anchor-outside-menu-band", source: sourceRect, anchor: anchorRect)
        }
        guard let band = menuBands.first(where: { $0.contains(CGPoint(x: sourceRect.midX, y: sourceRect.midY)) && $0.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) }),
              abs(sourceRect.midY - anchorRect.midY) < 8 else { throw MenuBarAccessError.differentScreen }
        let physicalModifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard physicalModifiers.isEmpty, !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right) else {
            invalidateOverflowPointerLease()
            throw MenuBarAccessError.cancelled
        }
        let source = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let destination = CGPoint(x: anchorRect.minX - 3, y: anchorRect.midY)
        guard band.contains(destination) else { throw MenuBarAccessError.differentScreen }
        try await pause(0.15)
        let checkedSource = frame(entry.element)
        let checkedAnchor = frame(anchor.element)
        guard checkedSource == sourceRect else {
            throw geometryFailure("准备移动时源图标位置发生变化，请刷新后重试。", stage: "source-moved-before-hit-test", source: checkedSource, anchor: checkedAnchor)
        }
        guard checkedAnchor == anchorRect else {
            throw geometryFailure("准备移动时目标定位项位置发生变化，请刷新后重试。", stage: "anchor-moved-before-hit-test", source: checkedSource, anchor: checkedAnchor)
        }
        guard sourceMatchesHitTest(entry.element, at: source, context: "source") else {
            throw geometryFailure("源图标不在可点击的菜单栏位置，可能位于系统溢出区或被遮挡。请先让图标显示在主菜单栏再试。", stage: "source-hit-test-failed", source: sourceRect, anchor: anchorRect)
        }
        guard sourceMatchesHitTest(anchor.element, at: CGPoint(x: anchorRect.midX, y: anchorRect.midY), context: "anchor") else {
            throw geometryFailure("目标定位项不在可点击的菜单栏位置，可能位于系统溢出区或被遮挡。请检查 Menu Tidy 入口并刷新。", stage: "anchor-hit-test-failed", source: sourceRect, anchor: anchorRect)
        }
        let originalPointer = CGEvent(source: nil)?.location
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else { throw MenuBarAccessError.eventPermission }
        eventSource.localEventsSuppressionInterval = 0
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateSuppressionInterval)
        eventSource.setLocalEventsFilterDuringSuppressionState(Self.allLocalEvents, state: .eventSuppressionStateRemoteMouseDrag)
        guard let commandDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x37, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x37, keyDown: false),
              let emergencyMouseUp = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: source, mouseButton: .left) else { throw MenuBarAccessError.eventPermission }
        guard let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: source, mouseButton: .left),
              let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: source, mouseButton: .left),
              let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: destination, mouseButton: .left) else { throw MenuBarAccessError.eventPermission }
        var dragEvents: [(CGPoint, CGEvent)] = []
        for step in 1...30 {
            let progress = Double(step) / 30
            let point = CGPoint(x: source.x + (destination.x - source.x) * progress, y: source.y)
            guard let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { throw MenuBarAccessError.eventPermission }
            dragEvents.append((point, event))
        }
        for event in [moveEvent, downEvent, upEvent] + dragEvents.map({ $0.1 }) {
            event.flags = [.maskCommand, .maskNonCoalesced]
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        commandDown.flags = .maskCommand
        commandUp.flags = []
        var pointer = source
        var mouseHeld = false
        var commandHeld = false
        var restorePointer = true
        let inputBaseline = inputCounterSnapshot()
        logDragInput(stage: "before-warp", baseline: inputBaseline, source: source, expected: pointer)
        defer {
            if let actualPointer = CGEvent(source: nil)?.location,
               hypot(actualPointer.x - pointer.x, actualPointer.y - pointer.y) > 12 {
                logDragInput(stage: "defer-position-rejected", baseline: inputBaseline, source: source, expected: pointer)
                restorePointer = false
                invalidateOverflowPointerLease()
            }
            if !CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskShift, .maskControl]).isEmpty ||
                CGEventSource.buttonState(.combinedSessionState, button: .right) {
                logDragInput(stage: "defer-input-rejected", baseline: inputBaseline, source: source, expected: pointer)
                restorePointer = false
                invalidateOverflowPointerLease()
            }
            if mouseHeld {
                emergencyMouseUp.location = pointer
                emergencyMouseUp.flags = commandHeld ? .maskCommand : []
                emergencyMouseUp.post(tap: .cghidEventTap)
            }
            if commandHeld { commandUp.post(tap: .cghidEventTap) }
            if restorePointer, let originalPointer {
                let restored = CGWarpMouseCursorPosition(originalPointer) == .success
                Self.logger.notice("dragPointer restoreWarpAccepted=\(restored)")
                if restored { post(.mouseMoved, at: originalPointer, source: eventSource, command: false) }
                else { invalidateOverflowPointerLease() }
            }
        }
        let warpResult = CGWarpMouseCursorPosition(source)
        Self.logger.notice("dragPointer sourceWarpAccepted=\(warpResult == .success) warpError=\(warpResult.rawValue)")
        guard warpResult == .success else { throw MenuBarAccessError.geometryDetail("无法定位鼠标到源图标，未开始拖动。") }
        try await pause(0.02)
        logDragInput(stage: "after-warp", baseline: inputBaseline, source: source, expected: pointer)
        guard let actualSource = CGEvent(source: nil)?.location,
              hypot(actualSource.x - source.x, actualSource.y - source.y) <= 12,
              physicalInputIsIdle() else {
            restorePointer = false
            invalidateOverflowPointerLease()
            throw MenuBarAccessError.cancelled
        }
        commandDown.post(tap: .cghidEventTap)
        commandHeld = true
        moveEvent.post(tap: .cghidEventTap)
        try await pause(0.05)
        logDragInput(stage: "after-command-and-move", baseline: inputBaseline, source: source, expected: pointer)
        let pressedSource = frame(entry.element)
        let pressedAnchor = frame(anchor.element)
        guard pressedSource == sourceRect else {
            throw geometryFailure("按下修饰键后源图标位置发生变化，已停止移动。请刷新后重试。", stage: "source-moved-before-mouse-down", source: pressedSource, anchor: pressedAnchor)
        }
        guard pressedAnchor == anchorRect else {
            throw geometryFailure("按下修饰键后目标定位项位置发生变化，已停止移动。请刷新后重试。", stage: "anchor-moved-before-mouse-down", source: pressedSource, anchor: pressedAnchor)
        }
        downEvent.post(tap: .cghidEventTap)
        mouseHeld = true
        try await pause(0.10)
        logDragInput(stage: "after-mouse-down", baseline: inputBaseline, source: source, expected: pointer)
        let dragDeadline = ProcessInfo.processInfo.systemUptime + 2
        var dragStep = 0
        for (point, event) in dragEvents {
            guard !cancellationRequested, ProcessInfo.processInfo.systemUptime < dragDeadline else { throw MenuBarAccessError.cancelled }
            dragStep += 1
            pointer = point
            event.post(tap: .cghidEventTap)
            try await pause(0.014)
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.intersection([.maskAlternate, .maskShift, .maskControl]).isEmpty {
                logDragInput(stage: "drag-flags-rejected-step-\(dragStep)", baseline: inputBaseline, source: source, expected: pointer)
                restorePointer = false
                invalidateOverflowPointerLease()
                throw MenuBarAccessError.cancelled
            }
            if let actualPointer = CGEvent(source: nil)?.location,
               hypot(actualPointer.x - pointer.x, actualPointer.y - pointer.y) > 12 {
                logDragInput(stage: "drag-position-rejected-step-\(dragStep)", baseline: inputBaseline, source: source, expected: pointer)
                restorePointer = false
                invalidateOverflowPointerLease()
                throw MenuBarAccessError.cancelled
            }
        }
        upEvent.post(tap: .cghidEventTap)
        mouseHeld = false
        commandUp.post(tap: .cghidEventTap)
        commandHeld = false
        let settleDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        var previousValidFrames: (source: CGRect, anchor: CGRect)?
        var resultFrame: CGRect?
        var finalAnchorFrame: CGRect?
        var didLogRelease = false
        while ProcessInfo.processInfo.systemUptime < settleDeadline {
            try await pause(min(0.1, max(0, settleDeadline - ProcessInfo.processInfo.systemUptime)))
            guard !cancellationRequested, !Task.isCancelled else { throw MenuBarAccessError.cancelled }
            if !didLogRelease {
                logDragInput(stage: "after-release", baseline: inputBaseline, source: source, expected: pointer)
                didLogRelease = true
            }
            resultFrame = frame(entry.element)
            finalAnchorFrame = frame(anchor.element)
            if let result = resultFrame, let finalAnchor = finalAnchorFrame,
               result.width > 0, result.height > 0, finalAnchor.width > 0, finalAnchor.height > 0,
               result.minX < finalAnchor.minX, abs(result.midY - finalAnchor.midY) < 8 {
                if let previous = previousValidFrames,
                   previous.source == result, previous.anchor == finalAnchor { return }
                previousValidFrames = (result, finalAnchor)
            } else {
                previousValidFrames = nil
            }
        }
        Self.logger.error("moveFinalValidation rejected=true sourceBefore=\(String(describing: sourceRect), privacy: .public) anchorBefore=\(String(describing: anchorRect), privacy: .public) sourceAfter=\(String(describing: resultFrame), privacy: .public) anchorAfter=\(String(describing: finalAnchorFrame), privacy: .public) destination=\(String(describing: destination), privacy: .public)")
        throw MenuBarAccessError.rejected
    }

    private func inputCounterSnapshot() -> InputCounterSnapshot {
        InputCounterSnapshot(
            hid: Self.diagnosticEventTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0.1) },
            combined: Self.diagnosticEventTypes.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0.1) })
    }

    private func logDragInput(stage: String, baseline: InputCounterSnapshot, source: CGPoint, expected: CGPoint) {
        // Event counts and distances only; never log key values or application content.
        let current = inputCounterSnapshot()
        let hidDelta = Self.diagnosticEventTypes.indices.map {
            "\(Self.diagnosticEventTypes[$0].0):\(current.hid[$0] &- baseline.hid[$0])"
        }.joined(separator: ",")
        let combinedDelta = Self.diagnosticEventTypes.indices.map {
            "\(Self.diagnosticEventTypes[$0].0):\(current.combined[$0] &- baseline.combined[$0])"
        }.joined(separator: ",")
        let actual = CGEvent(source: nil)?.location
        let sourceDelta = actual.map { hypot($0.x - source.x, $0.y - source.y) } ?? .infinity
        let expectedDelta = actual.map { hypot($0.x - expected.x, $0.y - expected.y) } ?? .infinity
        let hidFlags = CGEventSource.flagsState(.hidSystemState).rawValue
        let combinedFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let hidLeft = CGEventSource.buttonState(.hidSystemState, button: .left)
        let combinedLeft = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let hidRight = CGEventSource.buttonState(.hidSystemState, button: .right)
        let combinedRight = CGEventSource.buttonState(.combinedSessionState, button: .right)
        Self.logger.notice("dragInput stage=\(stage, privacy: .public) sourceDelta=\(sourceDelta) expectedDelta=\(expectedDelta) hidFlags=\(hidFlags) combinedFlags=\(combinedFlags) hidLeft=\(hidLeft) combinedLeft=\(combinedLeft) hidRight=\(hidRight) combinedRight=\(combinedRight) hidCounts=\(hidDelta, privacy: .public) combinedCounts=\(combinedDelta, privacy: .public)")
    }

    private func pause(_ seconds: Double) async throws {
        do { try await Task.sleep(for: .seconds(seconds)) }
        catch { throw MenuBarAccessError.cancelled }
    }
    private func post(_ type: CGEventType, at point: CGPoint, source: CGEventSource, command: Bool) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = command ? [.maskCommand, .maskNonCoalesced] : []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }
    private func geometryFailure(_ detail: String, stage: String, source: CGRect?, anchor: CGRect?) -> MenuBarAccessError {
        // Geometry only: never record another application's labels or menu content.
        Self.logger.error("moveGeometry stage=\(stage, privacy: .public) sourceFrame=\(String(describing: source), privacy: .public) anchorFrame=\(String(describing: anchor), privacy: .public)")
        return .geometryDetail(detail)
    }
    private func sourceMatchesHitTest(_ source: AXUIElement, at point: CGPoint, context: String) -> Bool {
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        guard result == .success else {
            Self.logger.error("hitTest context=\(context, privacy: .public) stage=query-failed axError=\(result.rawValue) point=\(String(describing: point), privacy: .public)")
            return false
        }
        var sourcePID: pid_t = 0
        AXUIElementGetPid(source, &sourcePID)
        for _ in 0..<6 {
            guard let node = hit else {
                Self.logger.error("hitTest context=\(context, privacy: .public) stage=no-matching-ancestor point=\(String(describing: point), privacy: .public)")
                return false
            }
            if CFEqual(node, source) { return true }
            var nodePID: pid_t = 0
            AXUIElementGetPid(node, &nodePID)
            if let identifier = text(source, kAXIdentifierAttribute), identifier == text(node, kAXIdentifierAttribute),
               nodePID == sourcePID, frame(node) == frame(source) { return true }
            hit = element(attribute(node, kAXParentAttribute))
        }
        Self.logger.error("hitTest context=\(context, privacy: .public) stage=ancestor-limit-no-match point=\(String(describing: point), privacy: .public)")
        return false
    }
    private func persistentKey(_ candidate: Candidate) -> String? {
        MenuItemIdentity.persistentID(bundleIdentifier: candidate.owner.bundleIdentifier,
            accessibilityIdentifier: candidate.identifier, occurrenceCount: 1)
    }
    private static func isSystemOverflow(ownerBundleIdentifier: String?, role: String, identifier: String?, label: String) -> Bool {
        guard ownerBundleIdentifier == "com.apple.MenuBarAgent", role == kAXButtonRole else { return false }
        return identifier?.lowercased().contains("overflow") == true ||
            overflowAccessibilityLabels.show.contains(label) || overflowAccessibilityLabels.hide.contains(label)
    }
    private func sameItem(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        guard lhs.owner.pid == rhs.owner.pid, lhs.owner.launchTime == rhs.owner.launchTime else { return false }
        if CFEqual(lhs.element, rhs.element) { return true }
        guard lhs.frame == rhs.frame, lhs.source != rhs.source,
              (lhs.role == kAXMenuBarItemRole && rhs.role == kAXButtonRole) ||
              (lhs.role == kAXButtonRole && rhs.role == kAXMenuBarItemRole) else { return false }
        if let leftID = lhs.identifier, let rightID = rhs.identifier, leftID != rightID { return false }
        return true
    }
    private func resolvedOwner(_ owner: MenuBarOwner) -> MenuBarOwner? {
        guard owner.pid > 0 else { return nil }
        if owner.launchTime.isFinite && owner.launchTime > 0 { return owner }
        // Background system applications such as MenuBarAgent may have no
        // NSRunningApplication.launchDate. Read their real process start time
        // rather than using zero as a reusable process identity.
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize,
              info.pbi_pid == UInt32(owner.pid), info.pbi_start_tvsec > 0 else { return nil }
        let launchTime = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return MenuBarOwner(pid: owner.pid, bundleIdentifier: owner.bundleIdentifier,
                            name: owner.name, launchTime: launchTime)
    }
    private func walk(_ node: AXUIElement, ownersByPID: [pid_t: MenuBarOwner], source: CandidateSource, depth: Int, remaining: inout Int, into output: inout [Candidate]) {
        guard depth < 7, remaining > 0, !Task.isCancelled else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth,
                stage: depth >= 7 ? "filtered:depth-limit" : (remaining <= 0 ? "filtered:node-budget" : "filtered:cancelled"))
            return
        }
        remaining -= 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        if role == kAXMenuRole || role == kAXMenuItemRole {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:menu-content-role")
            return
        }
        let children = elements(attribute(node, kAXChildrenAttribute))
        if role != kAXMenuBarItemRole {
            let count = output.count
            for child in children.prefix(60) {
                walk(child, ownersByPID: ownersByPID, source: source, depth: depth + 1, remaining: &remaining, into: &output)
            }
            if output.count > count {
                logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:descendant-preferred")
                return
            }
        }
        let identifier = text(node, kAXIdentifierAttribute) ?? children.prefix(2).compactMap { text($0, kAXIdentifierAttribute) }.first
        let label = text(node, kAXDescriptionAttribute) ?? text(node, kAXTitleAttribute) ??
            children.prefix(2).compactMap { text($0, kAXDescriptionAttribute) ?? text($0, kAXTitleAttribute) }.first
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, let owner = ownersByPID[pid] else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:pid-or-owner-unavailable")
            return
        }
        if owner.name == "MenuBarAgent", let identifier, ["overflow", "sectionplaceholder"].contains(where: { identifier.lowercased().contains($0) }) { return }
        guard let rect = frame(node) else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:frame-unavailable")
            return
        }
        guard rect.width > 0, rect.height > 0, rect.height <= 64 else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:invalid-size-or-height")
            return
        }
        guard rect.width <= 500 || identifier?.hasPrefix("menu-tidy-") == true else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:width-limit")
            return
        }
        guard menuBands.contains(where: { $0.intersects(rect) }) else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:outside-menu-band")
            return
        }
        guard role == kAXMenuBarItemRole || role == kAXButtonRole || (identifier != nil && label != nil) else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:role-or-metadata")
            return
        }
        output.append(Candidate(element: node, owner: owner, identifier: identifier,
                                name: String((label ?? owner.name).prefix(100)), frame: rect, role: role, source: source))
        logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "candidate-accepted")
    }
    private func logOwnWalk(_ node: AXUIElement, ownersByPID: [pid_t: MenuBarOwner], source: CandidateSource,
                            depth: Int, stage: String, includeOwnUnidentified: Bool = false) {
        let nodeIdentifier = text(node, kAXIdentifierAttribute)
        let children = elements(attribute(node, kAXChildrenAttribute))
        let childIdentifiers = children.prefix(60).compactMap { text($0, kAXIdentifierAttribute) }
            .filter { Self.anchorIdentifiers.contains($0) }
        let ownNodeIdentifier = nodeIdentifier.flatMap { Self.anchorIdentifiers.contains($0) ? $0 : nil }
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(node, &pid)
        guard ownNodeIdentifier != nil || !childIdentifiers.isEmpty ||
            (includeOwnUnidentified && pidResult == .success && pid == ProcessInfo.processInfo.processIdentifier) else { return }
        var position: CFTypeRef?
        var size: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &position)
        let sizeResult = AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &size)
        let role = attribute(node, kAXRoleAttribute) as? String ?? "nil"
        let frameDescription = String(describing: frame(node))
        Self.logger.notice("anchorWalk stage=\(stage, privacy: .public) id=\(ownNodeIdentifier ?? "nil", privacy: .public) childIDs=\(childIdentifiers.joined(separator: ","), privacy: .public) nodePID=\(pid) pidError=\(pidResult.rawValue) ownerBundle=\(ownersByPID[pid]?.bundleIdentifier ?? "nil", privacy: .public) role=\(role, privacy: .public) source=\(String(describing: source), privacy: .public) depth=\(depth) frame=\(frameDescription, privacy: .public) positionError=\(positionResult.rawValue) sizeError=\(sizeResult.rawValue)")
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private func text(_ node: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(node, name) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let values = value as? [CFTypeRef] else { return [] }
        return values.compactMap(element)
    }
    private func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, kAXPositionAttribute), let size = attribute(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
