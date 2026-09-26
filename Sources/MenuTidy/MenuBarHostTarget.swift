import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Read-only routing evidence for the two explicitly created diagnostic items.
/// No application label, item order, or nearby window is a routing identity.
@MainActor
enum MenuBarHostTarget {
    struct Target: Sendable {
        let sourcePID: pid_t
        let hostPID: pid_t
        let hostWindowID: CGWindowID
        let frame: CGRect
    }

    private final class OwnedRegistration {
        let token: UUID
        weak var item: NSStatusItem?
        weak var button: NSStatusBarButton?

        init(token: UUID, item: NSStatusItem, button: NSStatusBarButton) {
            self.token = token
            self.item = item
            self.button = button
        }
    }

    private static var ownedRegistrations: [String: OwnedRegistration] = [:]

    /// The probe registers its actual two local AppKit objects, not an accepted
    /// name prefix. A UUID identifier is valid only for these exact live items.
    static func registerOwnedItems(_ items: [(item: NSStatusItem, identifier: String)],
                                   expectedOwnerPID: pid_t) throws -> UUID {
        guard expectedOwnerPID == ProcessInfo.processInfo.processIdentifier, items.count == 2,
              ownedRegistrations.isEmpty, Set(items.map(\.identifier)).count == 2,
              items[0].item !== items[1].item else {
            throw ResolutionError.rejected("只能为本轮两个不同的自有图标注册一次。")
        }
        var buttons: [NSStatusBarButton] = []
        for entry in items {
            guard !entry.identifier.isEmpty, entry.item.statusBar === NSStatusBar.system,
                  let button = entry.item.button, button.accessibilityIdentifier() == entry.identifier,
                  !buttons.contains(where: { $0 === button }) else {
                throw ResolutionError.rejected("自有状态栏对象或其精确标识无法确认。")
            }
            buttons.append(button)
        }
        let token = UUID()
        for (entry, button) in zip(items, buttons) {
            ownedRegistrations[entry.identifier] = OwnedRegistration(token: token, item: entry.item, button: button)
        }
        return token
    }

    static func unregisterOwnedItems(token: UUID) {
        ownedRegistrations = ownedRegistrations.filter { $0.value.token != token }
    }

    private static func registeredItem(identifier: String, expectedOwnerPID: pid_t) -> OwnedRegistration? {
        guard expectedOwnerPID == ProcessInfo.processInfo.processIdentifier,
              let registration = ownedRegistrations[identifier], let item = registration.item,
              let button = registration.button, item.statusBar === NSStatusBar.system,
              item.button === button, button.accessibilityIdentifier() == identifier else { return nil }
        return registration
    }

    private enum ResolutionError: LocalizedError {
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let detail): "无法确认探针菜单栏接收目标：\(detail)"
            }
        }
    }

    private struct Match {
        let window: AXUIElement
        let container: AXUIElement
        let button: AXUIElement
        let windowFrame: CGRect
        let frame: CGRect
    }

    @MainActor
    private final class Reads {
        private let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        private var remaining = 512

        func value(_ element: AXUIElement, _ attribute: String, optional: Bool = false) throws -> CFTypeRef? {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else {
                throw ResolutionError.rejected("只读解析超过限定次数或时间。")
            }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.08)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if optional && (result == .noValue || result == .attributeUnsupported) { return nil }
            guard result == .success else {
                throw ResolutionError.rejected("AX 属性读取未完成（\(result.rawValue)）。")
            }
            return value
        }

        func children(_ element: AXUIElement, attribute: String = kAXChildrenAttribute,
                      optional: Bool = false) throws -> [AXUIElement] {
            guard let raw = try value(element, attribute, optional: optional) else { return [] }
            guard let values = raw as? [CFTypeRef], values.count <= 128 else {
                throw ResolutionError.rejected("AX 子节点列表不完整或超出限定数量。")
            }
            var result: [AXUIElement] = []
            for value in values {
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw ResolutionError.rejected("AX 子节点类型无法确认。")
                }
                result.append(unsafeDowncast(value, to: AXUIElement.self))
            }
            return result
        }

        func frame(_ element: AXUIElement) throws -> CGRect {
            guard let position = try value(element, kAXPositionAttribute),
                  let size = try value(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID() else {
                throw ResolutionError.rejected("AX 几何属性类型无法确认。")
            }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else {
                throw ResolutionError.rejected("AX 几何属性无法解码。")
            }
            let result = CGRect(origin: point, size: extent)
            guard valid(result) else { throw ResolutionError.rejected("AX 几何属性无效。") }
            return result
        }
    }

    static func resolveOwnedItem(identifier: String, expectedOwnerPID: pid_t) throws -> Target {
        guard let registration = registeredItem(identifier: identifier, expectedOwnerPID: expectedOwnerPID) else {
            throw ResolutionError.rejected("仅允许本进程明确创建的两个探针按钮。")
        }
        guard AXIsProcessTrusted() else { throw ResolutionError.rejected("辅助功能权限不可用。") }
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app" }
        guard hosts.count == 1, let host = hosts.first,
              let hostEpoch = MenuBarProcessIdentity.launchTime(for: host), host.processIdentifier > 0 else {
            throw ResolutionError.rejected("系统菜单栏宿主进程不能唯一确认。")
        }
        let hostPID = host.processIdentifier
        let application = AXUIElementCreateApplication(hostPID)
        let reads = Reads()
        let windows = try reads.children(application, attribute: kAXWindowsAttribute)
        guard windows.count <= 32 else { throw ResolutionError.rejected("宿主窗口数量超出限定范围。") }
        let bands = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard valid(bounds) else { return nil }
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                height: max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        }
        var matches: [Match] = []
        for window in windows {
            guard try pid(of: window) == hostPID,
                  try reads.value(window, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            let windowFrame = try reads.frame(window)
            guard bands.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(windowFrame) }) else { continue }
            for container in try reads.children(window) {
                guard try pid(of: container) == hostPID else { continue }
                let children = try reads.children(container, optional: true)
                var remoteChildren: [AXUIElement] = []
                for child in children where try pid(of: child) != hostPID { remoteChildren.append(child) }
                // One container must represent exactly one originating item;
                // the enclosing host window may contain many such containers.
                guard remoteChildren.count == 1, let button = remoteChildren.first,
                      try pid(of: button) == expectedOwnerPID,
                      try reads.value(button, kAXRoleAttribute) as? String == kAXButtonRole,
                      try reads.value(button, kAXIdentifierAttribute, optional: true) as? String == identifier else { continue }
                let containerFrame = try reads.frame(container)
                let widthAllowed = containerFrame.width <= 200
                let insideWindow = windowFrame.contains(containerFrame)
                let center = CGPoint(x: containerFrame.midX, y: containerFrame.midY)
                let centerInsideMenuBand = bands.contains(where: { $0.contains(center) })
                guard widthAllowed, insideWindow, centerInsideMenuBand else {
                    let geometry = "containerFrame=\(describe(containerFrame)) windowFrame=\(describe(windowFrame)) " +
                        "menuBands=[\(bands.map(describe).joined(separator: ";"))] " +
                        "widthAllowed=\(widthAllowed) insideWindow=\(insideWindow) centerInsideMenuBand=\(centerInsideMenuBand)"
                    throw ResolutionError.rejected("目标容器不在真实菜单栏区域内。\(geometry) \(windowDiagnostic(window))")
                }
                matches.append(Match(window: window, container: container, button: button,
                    windowFrame: windowFrame, frame: containerFrame))
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ResolutionError.rejected("实际宿主父子链未唯一匹配指定按钮（\(matches.count) 项）。")
        }
        let resolvedWindowID = try windowID(hostPID: hostPID, frame: match.windowFrame, axWindow: match.window)
        try validateEdges(match, application: application, identifier: identifier,
            expectedOwnerPID: expectedOwnerPID, hostPID: hostPID, reads: reads)
        let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
        var hitNodes: [AXUIElement] = []
        var hitError = AXError.success
        guard try centerHitMatches(match, point: center, reads: reads,
                                   visited: &hitNodes, hitError: &hitError) else {
            let context = "frame=\(describe(match.frame)) windowFrame=\(describe(match.windowFrame)) " +
                "cgWindowID=\(resolvedWindowID) sourcePID=\(expectedOwnerPID) hostPID=\(hostPID)"
            throw ResolutionError.rejected("目标中心未命中已确认的 AX 按钮或其独有容器。\(context) " +
                centerHitDiagnostic(match, nodes: hitNodes, hitError: hitError))
        }
        // Return only live evidence. Never carry an old host PID into a new epoch.
        guard !host.isTerminated, MenuBarProcessIdentity.launchTime(for: host) == hostEpoch,
              registeredItem(identifier: identifier, expectedOwnerPID: expectedOwnerPID) === registration,
              try reads.frame(match.window) == match.windowFrame,
              try reads.frame(match.container) == match.frame,
              try windowID(hostPID: hostPID, frame: match.windowFrame, axWindow: match.window) == resolvedWindowID else {
            throw ResolutionError.rejected("解析期间宿主进程、窗口或按钮几何发生变化。")
        }
        return Target(sourcePID: expectedOwnerPID, hostPID: hostPID, hostWindowID: resolvedWindowID, frame: match.frame)
    }

    private static func validateEdges(_ match: Match, application: AXUIElement, identifier: String,
                                      expectedOwnerPID: pid_t, hostPID: pid_t, reads: Reads) throws {
        let windows = try reads.children(application, attribute: kAXWindowsAttribute)
        let containers = try reads.children(match.window)
        let children = try reads.children(match.container)
        var remoteChildren: [AXUIElement] = []
        for child in children where try pid(of: child) != hostPID { remoteChildren.append(child) }
        guard windows.filter({ CFEqual($0, match.window) }).count == 1,
              containers.filter({ CFEqual($0, match.container) }).count == 1,
              remoteChildren.count == 1, let remote = remoteChildren.first,
              CFEqual(remote, match.button), try pid(of: match.container) == hostPID,
              try pid(of: match.button) == expectedOwnerPID,
              try reads.value(match.button, kAXRoleAttribute) as? String == kAXButtonRole,
              try reads.value(match.button, kAXIdentifierAttribute) as? String == identifier else {
            throw ResolutionError.rejected("再次读取的实际 AX 父子链或按钮身份不一致。")
        }
    }

    private static func centerHitMatches(_ match: Match, point: CGPoint, reads: Reads,
                                         visited: inout [AXUIElement], hitError: inout AXError) throws -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var hit: AXUIElement?
        hitError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard hitError == .success else { return false }
        for _ in 0..<6 {
            guard let node = hit, !visited.contains(where: { CFEqual($0, node) }) else { return false }
            visited.append(node)
            if CFEqual(node, match.button) || CFEqual(node, match.container) { return true }
            if try ownedMirrorMatches(node, button: match.button, reads: reads) { return true }
            // A shared host window alone does not identify which button was hit.
            if CFEqual(node, match.window) { return false }
            guard let parent = try reads.value(node, kAXParentAttribute, optional: true),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            hit = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func ownedMirrorMatches(_ node: AXUIElement, button: AXUIElement, reads: Reads) throws -> Bool {
        // macOS may expose our status button through a separate AXMenuBarItem
        // object at hit testing. Restrict this bridge to our two explicit probe
        // registered objects and exact live source geometry; never infer it
        // from a host frame or an identifier prefix.
        let ownerPID = try pid(of: button)
        guard ownerPID == ProcessInfo.processInfo.processIdentifier,
              try pid(of: node) == ownerPID,
              let identifier = try reads.value(button, kAXIdentifierAttribute, optional: true) as? String,
              registeredItem(identifier: identifier, expectedOwnerPID: ownerPID) != nil,
              try reads.value(node, kAXIdentifierAttribute, optional: true) as? String == identifier,
              let role = try reads.value(node, kAXRoleAttribute, optional: true) as? String,
              role == kAXMenuBarItemRole || role == kAXButtonRole else { return false }
        return try reads.frame(node) == reads.frame(button)
    }

    private static func centerHitDiagnostic(_ match: Match, nodes: [AXUIElement], hitError: AXError) -> String {
        // Read metadata only after the unchanged hit gate rejected the original
        // hit/parent objects. Do not perform a second hit test or query titles.
        let reads = Reads()
        var buttonFrame = "unavailable"
        if let frame = try? reads.frame(match.button) { buttonFrame = describe(frame) }
        var details: [String] = []
        for (depth, node) in nodes.prefix(6).enumerated() {
            var owner: pid_t = 0
            let ownerResult = AXUIElementGetPid(node, &owner)
            let role = diagnosticString(node, attribute: kAXRoleAttribute, reads: reads)
            let identifier = diagnosticString(node, attribute: kAXIdentifierAttribute, reads: reads)
            var frame = "unavailable"
            if let rectangle = try? reads.frame(node) { frame = describe(rectangle) }
            details.append("depth=\(depth),pid=\(owner),pidResult=\(ownerResult.rawValue),role=\(role)," +
                "identifier=\(identifier),frame=\(frame),cfButton=\(CFEqual(node, match.button))," +
                "cfContainer=\(CFEqual(node, match.container)),cfWindow=\(CFEqual(node, match.window))")
        }
        return "hitAXResult=\(hitError.rawValue) buttonOriginalFrame=\(buttonFrame) hitChain=[\(details.joined(separator: ";"))]"
    }

    private static func diagnosticString(_ element: AXUIElement, attribute: String, reads: Reads) -> String {
        do {
            guard let value = try reads.value(element, attribute, optional: true) as? String else { return "unavailable" }
            return String(reflecting: String(value.prefix(256)))
        } catch {
            return "unreadable"
        }
    }

    private static func windowID(hostPID: pid_t, frame: CGRect, axWindow: AXUIElement) throws -> CGWindowID {
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            throw ResolutionError.rejected("无法读取真实 CG 窗口清单。")
        }
        var matches: [CGWindowID] = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == hostPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary), rectangle == frame else { continue }
            guard let rawID = window[kCGWindowNumber as String] as? NSNumber,
                  rawID.doubleValue.isFinite, rawID.doubleValue >= 1,
                  rawID.doubleValue <= Double(UInt32.max), rawID.doubleValue.rounded(.down) == rawID.doubleValue else {
                throw ResolutionError.rejected("真实宿主窗口编号无效。")
            }
            matches.append(CGWindowID(rawID.uint32Value))
        }
        guard matches.count == 1, let windowID = matches.first else {
            let hostWindows = windows.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == hostPID
            }
            let details = hostWindows.prefix(12).map(describeCGWindow).joined(separator: ";")
            throw ResolutionError.rejected("宿主进程与 AX 窗口几何未唯一对应真实 CG 窗口。" +
                "hostPID=\(hostPID) axWindowFrame=\(describe(frame)) frameMatches=\(matches.count) " +
                "hostWindowCount=\(hostWindows.count) hostWindows=[\(details)] \(windowDiagnostic(axWindow))")
        }
        return windowID
    }

    private static func describeCGWindow(_ info: [String: Any]) -> String {
        let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.stringValue ?? "unavailable"
        let number = (info[kCGWindowNumber as String] as? NSNumber)?.stringValue ?? "unavailable"
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.stringValue ?? "unavailable"
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.stringValue ?? "unavailable"
        var boundsDescription = "unavailable"
        if let bounds = info[kCGWindowBounds as String] as? [String: Any],
           let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            boundsDescription = describe(rectangle)
        }
        return "ownerPID=\(owner),id=\(number),bounds=\(boundsDescription),layer=\(layer),onscreen=\(onScreen)"
    }

    /// Diagnostic only: a private read-only symbol cannot establish a routing
    /// target or bypass the public AX/CG geometry and identity checks above.
    private static func windowDiagnostic(_ window: AXUIElement) -> String {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return "axWindowSymbol=unavailable" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return "axWindowSymbol=unavailable" }
        typealias CopyWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let copyWindow = unsafeBitCast(symbol, to: CopyWindow.self)
        var windowID: CGWindowID = 0
        let result = copyWindow(window, &windowID)
        let summary = "axWindowResult=\(result.rawValue) axWindowID=\(windowID)"
        guard result == .success, windowID > 0 else { return summary }
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else {
            return "\(summary) cgWindowRead=false"
        }
        // Emit only the exact reported ID's owner and bounds, never window
        // names or data about any other menu-bar item.
        let matches = windows.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }
        let details = matches.map { info -> String in
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            var boundsDescription = "unavailable"
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                boundsDescription = describe(rectangle)
            }
            return "ownerPID=\(owner.map(String.init) ?? "unavailable") bounds=\(boundsDescription)"
        }.joined(separator: ";")
        return "\(summary) cgWindowMatches=\(matches.count) cgWindows=[\(details)]"
    }

    private static func describe(_ rectangle: CGRect) -> String {
        "(x:\(rectangle.origin.x),y:\(rectangle.origin.y),w:\(rectangle.width),h:\(rectangle.height))"
    }

    private static func pid(of element: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            throw ResolutionError.rejected("AX 节点所属进程无法确认。")
        }
        return pid
    }

    private static func valid(_ rectangle: CGRect) -> Bool {
        [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].allSatisfy(\.isFinite) &&
            rectangle.width > 0 && rectangle.height > 0
    }
}
