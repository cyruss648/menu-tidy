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
    let processIdentifier: pid_t
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

/// A live AX identity's candidate existing preference key, not a new item ID.
/// A caller must still verify the resulting native order after a preference write.
struct MenuBarPositionCandidate: Sendable {
    let id: String
    let key: String
    let processIdentifier: pid_t
    let launchTime: TimeInterval
    let bundleIdentifier: String
    fileprivate let token: UUID
}

/// A bounded read-only AX challenge session. Preference transactions remain
/// the caller's responsibility; discarding this handle never restores them.
struct MenuBarPositionKeyChallenge: Sendable {
    let id: String
    let controlID: String
    let candidateKeys: [String]
    let controlKey: String
    let deadline: TimeInterval
    fileprivate let token: UUID
}

struct MenuBarPositionBindingError: LocalizedError, Sendable {
    enum Reason: String, Sendable {
        case permission, cancelled, invalidRequest, missingEntry, protectedItem
        case ownerChanged, ambiguousOwner, missingKey, ambiguousKey
        case incompleteSource, unsupportedSource, ambiguousSource, identityChanged, expired
        case visibilityUnconfirmed
    }
    let id: String
    let reason: Reason

    var errorDescription: String? {
        let detail: String
        switch reason {
        case .permission: detail = "需要辅助功能权限才能确认图标身份"
        case .cancelled: detail = "后台排序身份检查已取消"
        case .invalidRequest: detail = "后台排序请求或排序数据不完整"
        case .missingEntry: detail = "尚未读取到这个图标"
        case .protectedItem: detail = "此系统项目不参与后台分组"
        case .ownerChanged: detail = "图标所属进程已经变化，请刷新后重试"
        case .ambiguousOwner: detail = "同一应用存在多个进程实例，无法唯一确认排序归属"
        case .missingKey: detail = "这个图标没有可精确匹配的现有排序键"
        case .ambiguousKey: detail = "这个应用存在多个排序键，无法唯一匹配图标"
        case .incompleteSource: detail = "未能完整读取这个应用的菜单栏项目，尚不能确认唯一身份"
        case .unsupportedSource: detail = "这个应用的菜单栏结构暂不支持严格的后台排序绑定"
        case .ambiguousSource: detail = "这个应用提供多个菜单栏项目，无法唯一匹配排序键"
        case .identityChanged: detail = "无法继续确认图标的原始菜单栏身份，未继续排序"
        case .expired: detail = "后台排序身份凭据已过期，请重新检查"
        case .visibilityUnconfirmed: detail = "尚未确认该系统图标的原始可见身份；请先使该系统图标在原生菜单栏中可见后重试"
        }
        return detail + "；未发送鼠标或键盘事件。"
    }
}

/// Read-only evidence from an already known AX entry. A missing frame is
/// unknown visibility; an available frame alone does not prove clickability.
struct MenuBarVisibilityInspection: Sendable {
    let frame: CGRect?
    let centerHit: Bool
    let hasEntry: Bool
    var hasFrame: Bool { frame != nil }
}

struct MenuBarPresentationBaseline: Sendable { fileprivate let token: UUID }
struct MenuBarItemPresentation: Sendable {
    enum Kind: Sendable { case menu, window }
    fileprivate let token: UUID
    let kind: Kind
}
enum MenuBarPresentationStatus: Sendable { case open, closed, unavailable }

enum MenuBarOverflowError: LocalizedError, Sendable {
    case entryNotFound, entryAmbiguous, actionUnsupported, cancelled
    case actionUnconfirmed(axError: Int32?)

    var errorDescription: String? {
        switch self {
        case .entryNotFound:
            return "未找到当前菜单栏中的系统溢出入口，请检查菜单栏后刷新。"
        case .entryAmbiguous:
            return "系统溢出入口无法唯一确认，已停止后台展开。"
        case .actionUnsupported:
            return "系统溢出入口未提供可用的后台展开操作。可手动展开并保持片刻，待图标可见时自动补采。"
        case .actionUnconfirmed(let code):
            let suffix = code.map { "（AX 返回码 \($0)）" } ?? ""
            return "尚未确认系统溢出区域已展开\(suffix)；未重复发送操作，也未移动鼠标。"
        case .cancelled:
            return "系统溢出区域准备已取消；未发送鼠标或键盘事件。"
        }
    }
}

enum MenuBarAccessError: LocalizedError, Sendable {
    case permission, eventPermission, disappeared, invalidGeometry, differentScreen, rejected, cancelled
    case dragEventTimedOut, inputStateChanged, scanTimedOut
    case actionUnavailable, actionRejected
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
        case .actionUnavailable: return "该图标暂不支持后台打开菜单，需在原生菜单栏手动打开。没有模拟鼠标点击。"
        case .actionRejected: return "目标应用未接受本次菜单操作。没有补发点击；请稍后重试，或在原生菜单栏手动打开。"
        case .cancelled: return "操作已取消；未发送鼠标或键盘事件。"
        case .scanTimedOut: return "菜单栏读取未及时完成，已停止本次扫描并保留原列表。请关闭正在展开的菜单后刷新列表。"
        case .dragEventTimedOut: return "系统未及时处理拖动事件，已停止本次移动并释放鼠标。请稍后重试。"
        case .inputStateChanged: return "检测到输入状态发生变化，已停止本次操作；未接管鼠标。"
        }
    }
}

/// AX objects are confined to this actor; only value snapshots cross to the UI.
actor MenuBarAccessibility {
    private struct PositionCandidateBinding {
        let candidate: MenuBarPositionCandidate
        let element: AXUIElement
        let owner: MenuBarOwner
        let ownIdentifier: String?
        let expiresAt: TimeInterval
    }
    /// A visible, fully enumerated original object supplies an identity seed,
    /// never reusable geometry. Every later use rechecks its live attributes,
    /// owner epoch and complete current census; operation tokens still expire.
    private struct SystemModuleContinuitySeed {
        let element: AXUIElement
        let owner: MenuBarOwner
        let identifier: String
        let role: String?
        var policy: SystemModuleContinuityPolicy
    }
    /// AirDrop is recreated when its native visibility preference changes.
    /// This protects its system identity, never the identity of an old AX object.
    private struct NativeSystemVisibilityIdentity {
        let owner: MenuBarOwner
        let identifier: String?
        let key: String
    }
    private struct PositionReadBudget {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var remaining = 512
    }
    private struct PositionKeyChallengeBinding {
        let handle: MenuBarPositionKeyChallenge
        let source: Entry
        let control: Entry
        let identifierElement: AXUIElement
        let originalValues: [String: Double]
        var resolution: MenuBarPositionKeyResolution
        var activeKey: String?
        var attempt: UUID?
        var lastPlan: MenuBarPositionPlan?
        var invalidated = false
    }
    private struct ValidatedPositionKey {
        let source: Entry
        let identifierElement: AXUIElement
        let accessibilityIdentifier: String
        let key: String
        let candidateKeys: Set<String>
    }
    private struct Entry {
        let element: AXUIElement
        let owner: MenuBarOwner
        let accessibilityIdentifier: String?
        let snapshot: MenuBarItemSnapshot
        let hostPresentation: HostPresentation?
        let hostGeometryUnresolved: Bool
    }
    /// The identity remains the originating app's AX element. A host container
    /// supplies geometry only while every observed child edge still agrees.
    private struct HostPresentation {
        let hostOwner: MenuBarOwner
        let window: AXUIElement
        let path: [AXUIElement]
        let snapshotFrame: CGRect
        let mirrorIdentity: MirrorIdentity?
    }
    /// A separate host AXButton can represent the original AXMenuBarItem.
    /// Keep the original path as well as the host path; neither is an action
    /// fallback, and live validation must still prove both identities agree.
    private struct MirrorIdentity {
        let identifier: String?
        let originPath: [AXUIElement]
        // A CFEqual direct child is stronger evidence than matching metadata.
        // This retained edge is re-read whenever host geometry is consumed.
        var directChild: AXUIElement? = nil
    }
    private struct MirrorReadBudget {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var remaining = 512

        var isValid: Bool {
            remaining > 0 && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
        }
    }
    private struct Candidate {
        let element: AXUIElement
        let owner: MenuBarOwner
        let identifier: String?
        let name: String
        let sourceFrame: CGRect
        let requiresHostPresentation: Bool
        var hostPresentation: HostPresentation?
        var hostGeometryUnresolved = false
        var frame: CGRect { hostPresentation?.snapshotFrame ?? sourceFrame }
        let role: String
        let source: CandidateSource
        let enumerationRootPID: pid_t
        let ancestors: [AXUIElement]
    }
    private enum CandidateSource {
        case applicationExtras
        case hostWindow
    }
    private enum SystemOverflowState {
        case collapsed
        case expanded
    }
    private struct SystemOverflowControl {
        let element: AXUIElement
        let owner: MenuBarOwner
        let state: SystemOverflowState
    }
    private struct OverflowReadBudget {
        let deadline: TimeInterval
        let allowsCancellation: Bool
        var remaining = 180
    }
    private enum HitTestFailure {
        case unconfirmed
        case coveredByWindow(applicationName: String?)

        func explanation(for target: String, fallback: String) -> String {
            switch self {
            case .unconfirmed:
                return fallback
            case .coveredByWindow(let applicationName):
                let owner = applicationName.map { "「\($0)」的窗口" } ?? "另一应用的窗口"
                return "\(target)所在位置被\(owner)遮挡，已停止移动。请收起或关闭该浮动窗口后重试，无需反复展开系统溢出入口。"
            }
        }
    }
    private struct PresentationOwner {
        let identity: MenuBarOwner
        let requiredBundlePath: String?
    }
    private struct PresentationNode {
        let element: AXUIElement
        let owner: PresentationOwner
        let kind: MenuBarItemPresentation.Kind
        let originalRole: String
        let frame: CGRect
        let visible: Bool
        let validationPoint: CGPoint?
        let validationElement: AXUIElement?
        let backingWindowID: CGWindowID?
    }
    private struct PresentationValidation {
        let point: CGPoint
        let element: AXUIElement
    }
    private struct PresentationWindowCandidate {
        let id: CGWindowID
        let layer: Int
        let frame: CGRect
        let alpha: Double
    }
    private struct PresentationBaseline {
        let token: UUID
        let entry: Entry
        let owners: [PresentationOwner]
        let nodes: [PresentationNode]
        let visible: [PresentationNode]
        let ownerWindowIDs: Set<CGWindowID>?
        let authoritativeRoots: Bool
        let expiresAt: TimeInterval
    }
    private struct Presentation {
        let token: UUID
        let entry: Entry
        let owners: [PresentationOwner]
        let node: PresentationNode
        var cancelActionResult: AXError? = nil
    }
    private struct PresentationReadBudget {
        var remaining = 96
        var diagnosticRemaining = 4
        var geometryDiagnosticRemaining = 4
        var incompleteDiagnosticRemaining = 4
        var source = "core"
        var complete = true
        var authoritativeRoots = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    }
    private var entries: [String: Entry] = [:]
    private var scanReadBudget: AccessibilityScanBudget?
    private var scanApplicationMenuBarRoots: [pid_t: AXUIElement] = [:]
    private var scanApplicationMenuBarQueries: Set<pid_t> = []
    private var scanCanContinue: Bool {
        scanReadBudget?.canPublish(at: ProcessInfo.processInfo.systemUptime, cancelled: Task.isCancelled) ?? true
    }
    private var positionCandidateBindings: [UUID: PositionCandidateBinding] = [:]
    private var systemModuleContinuity: [String: SystemModuleContinuitySeed] = [:]
    private var nativeSystemVisibilityIdentities: [String: NativeSystemVisibilityIdentity] = [:]
    private var positionKeyChallenges: [UUID: PositionKeyChallengeBinding] = [:]
    private var validatedPositionKeys: [String: ValidatedPositionKey] = [:]
    private var menuBands: [CGRect] = []
    private var cancellationRequested = false
    private var managementControlNeedsRecovery = false
    private var managementOverflowEntry: SystemOverflowControl?
    private var managementOverflowInputCounts: [UInt32]?
    private static let overflowOwnershipEventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .keyDown, .keyUp, .flagsChanged, .scrollWheel
    ]
    private var presentationBaseline: PresentationBaseline?
    private var lastPresentationBaseline: PresentationBaseline?
    private var presentation: Presentation?
    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "MenuBarAccessibility")
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

    func cancel() {
        cancellationRequested = true
        if !AXIsProcessTrusted() {
            systemModuleContinuity.removeAll()
            nativeSystemVisibilityIdentities.removeAll()
        }
    }

    func scan(owners: [MenuBarOwner], menuBands: [CGRect],
              positions: [String: Double] = [:],
              retainHiddenIDs: Set<String> = []) throws -> [MenuBarItemSnapshot] {
        guard AXIsProcessTrusted() else {
            systemModuleContinuity.removeAll()
            nativeSystemVisibilityIdentities.removeAll()
            throw MenuBarAccessError.permission
        }
        self.menuBands = menuBands
        scanReadBudget = AccessibilityScanBudget(startedAt: ProcessInfo.processInfo.systemUptime)
        scanApplicationMenuBarRoots.removeAll(keepingCapacity: true)
        scanApplicationMenuBarQueries.removeAll(keepingCapacity: true)
        let previousContinuity = systemModuleContinuity
        var published = false
        defer {
            scanReadBudget = nil
            scanApplicationMenuBarRoots.removeAll(keepingCapacity: true)
            scanApplicationMenuBarQueries.removeAll(keepingCapacity: true)
            if !published { systemModuleContinuity = previousContinuity }
        }
        // A MenuBarAgent subtree can contain remote AX elements whose PID belongs
        // to the originating application. Never attribute those to the host, and
        // require a launch timestamp so a reused PID cannot inherit old entries.
        let ownersByPID = Dictionary(owners.compactMap(resolvedOwner).map { ($0.pid, $0) },
                                     uniquingKeysWith: { first, _ in first })
        var candidates: [Candidate] = []
        var totalBudget = 2500
        for owner in owners {
            try Task.checkCancellation()
            guard scanCanContinue else { throw MenuBarAccessError.scanTimedOut }
            guard totalBudget > 0 else { break }
            var ownerBudget = min(160, totalBudget)
            let initialBudget = ownerBudget
            let application = AXUIElementCreateApplication(owner.pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            let (extrasResult, extrasValue) = copyAttribute(application, kAXExtrasMenuBarAttribute)
            if owner.pid == ProcessInfo.processInfo.processIdentifier {
                let elementPresent = element(extrasValue) != nil
                Self.logger.notice("ownExtras pid=\(owner.pid) axError=\(extrasResult.rawValue) elementPresent=\(elementPresent)")
            }
            if extrasResult == .success, let extras = element(extrasValue) {
                if owner.pid == ProcessInfo.processInfo.processIdentifier {
                    let (childrenResult, childrenValue) = copyAttribute(extras, kAXChildrenAttribute)
                    let ownChildren = elements(childrenValue)
                    Self.logger.notice("ownExtras directChildrenError=\(childrenResult.rawValue) directChildrenCount=\(ownChildren.count)")
                    for child in ownChildren.prefix(60) {
                        logOwnWalk(child, ownersByPID: ownersByPID, source: .applicationExtras,
                            depth: 1, stage: "own-extras-direct-child", includeOwnUnidentified: true)
                    }
                }
                walk(extras, ownersByPID: ownersByPID, source: .applicationExtras, enumerationRootPID: owner.pid,
                    depth: 0, remaining: &ownerBudget, into: &candidates)
            }
            // macOS 27 hosts system extras in a separate menu-bar process.
            if owner.bundleIdentifier == "com.apple.MenuBarAgent" || owner.name == "MenuBarAgent" {
                for window in elements(attribute(application, kAXWindowsAttribute)) {
                    walk(window, ownersByPID: ownersByPID, source: .hostWindow, enumerationRootPID: owner.pid,
                        depth: 0, remaining: &ownerBudget, into: &candidates)
                }
            }
            totalBudget -= initialBudget - ownerBudget
        }
        let provisionalCount = candidates.count
        let identityCandidates = candidates
        candidates.removeAll { $0.requiresHostPresentation && $0.hostPresentation == nil }
        Self.logger.notice("hostPresentation scannedBindings=\(candidates.filter { $0.hostPresentation != nil }.count) rejectedUnbound=\(provisionalCount - candidates.count)")
        try Task.checkCancellation()
        // Prefer the originating app's menu-bar item, then preserve its stable
        // identifier. A host AXButton mirror need not match system hit testing.
        candidates.sort {
            if $0.source != $1.source { return $0.source == .applicationExtras }
            if ($0.identifier != nil) != ($1.identifier != nil) { return $0.identifier != nil }
            if ($0.hostPresentation != nil) != ($1.hostPresentation != nil) { return $0.hostPresentation != nil }
            return ($0.role == kAXMenuBarItemRole ? 1 : 0) > ($1.role == kAXMenuBarItemRole ? 1 : 0)
        }
        var unique: [Candidate] = []
        for candidate in candidates {
            var duplicate = false
            for index in unique.indices {
                let existing = unique[index]
                let childBridge = existing.hostPresentation == nil
                    ? sourceChildBinding(origin: existing, projection: candidate, candidates: identityCandidates) : nil
                // Keep non-Sendable AX entries on this actor instead of
                // capturing them in a short-circuit autoclosure (Swift 6.2).
                var isSameItem = childBridge != nil
                if !isSameItem { isSameItem = sameItem(existing, candidate) }
                if isSameItem {
                    if let childBridge {
                        unique[index].hostPresentation = childBridge
                        unique[index].hostGeometryUnresolved = false
                    } else if existing.hostPresentation == nil, let binding = candidate.hostPresentation {
                        if let identity = binding.path.last, CFEqual(identity, existing.element) {
                            // Identifier-rich and host projections are the same
                            // AX object: retain identity metadata and real geometry.
                            unique[index].hostPresentation = binding
                        } else if let mirror = mirrorBinding(origin: existing, projection: candidate,
                                                             candidates: identityCandidates) {
                            unique[index].hostPresentation = mirror
                        } else {
                            // The older frame-based mirror rule is insufficient
                            // evidence to transfer a host geometry binding.
                            unique[index].hostGeometryUnresolved = true
                        }
                    }
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
        logDuplicateCandidateBuckets(candidates: candidates, unique: unique, identifierCounts: identifierCounts)
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
        var positionInventories: [pid_t: [AXUIElement]] = [:]
        for (candidateIndex, candidate) in unique.enumerated() {
            let accessibilityPersistent = persistentKey(candidate).flatMap { identifierCounts[$0] == 1 ? $0 : nil }
            let existing = entries.values.first {
                $0.owner.pid == candidate.owner.pid && $0.owner.launchTime == candidate.owner.launchTime && CFEqual($0.element, candidate.element)
            }
            let ownBundle = Bundle.main.bundleIdentifier
            let own = candidate.owner.pid == ProcessInfo.processInfo.processIdentifier && ownBundle != nil &&
                candidate.owner.bundleIdentifier == ownBundle ? candidate.identifier : nil
            let systemOverflow = Self.isSystemOverflow(ownerBundleIdentifier: candidate.owner.bundleIdentifier,
                role: candidate.role, identifier: candidate.identifier, label: candidate.name)
            let protected = own != nil || systemOverflow || ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"].contains(candidate.identifier ?? "")
            // Preserve all existing AX-based IDs. The preference identity is
            // only a strictly proven fallback for otherwise session-only items.
            let positionPersistent: String?
            if accessibilityPersistent == nil && !protected {
                positionPersistent = try? persistentPositionIdentity(candidate, existing: existing, positions: positions,
                    owners: owners, inventories: &positionInventories)
            } else {
                positionPersistent = nil
            }
            try Task.checkCancellation()
            var systemPersistent: String?
            if candidate.owner.bundleIdentifier == "com.apple.MenuBarAgent",
               candidate.identifier == "com.apple.menuextra.airdrop",
               let systemID = MenuItemIdentity.persistentID(bundleIdentifier: candidate.owner.bundleIdentifier,
                   accessibilityIdentifier: candidate.identifier, occurrenceCount: 1) {
                let identity = NativeSystemVisibilityIdentity(owner: candidate.owner, identifier: candidate.identifier, key: "AirDrop")
                if let sources = try? nativeSystemSources(identity, id: systemID), let source = sources.first {
                    guard CFEqual(source, candidate.element) else { continue }
                    systemPersistent = systemID
                }
            }
            let inputPersistent = verifiedInputMenuPersistentID(owner: candidate.owner, element: candidate.element)
            let persistent = systemPersistent ?? inputPersistent ?? accessibilityPersistent ?? positionPersistent
            let reusableSessionID = existing?.snapshot.id.hasPrefix("session:") == true ? existing?.snapshot.id : nil
            let id = persistent ?? reusableSessionID ?? "session:\(candidate.owner.pid):\(UUID().uuidString)"
            if let identity = nativeSystemVisibilityIdentities[id], let previous = entries[id],
               !CFEqual(previous.element, candidate.element),
               sameNativeSystemOwner(identity.owner, candidate.owner) {
                // Native AirDrop showing creates a new source. Its protected
                // system identifier permits rebinding only after a complete,
                // unique current census; the ordinary scan is not that proof.
                guard candidate.identifier == identity.identifier,
                      let matches = try? nativeSystemSources(identity, id: id),
                      matches.count == 1, let source = matches.first,
                      CFEqual(source, candidate.element) else { continue }
            }
            if persistent == nil {
                // These IDs contain only a process ID and a locally generated
                // UUID. Record continuity without logging app names, source
                // identifiers, preference keys, or the user's chosen group.
                let previousOwnerEntries = entries.values.filter {
                    $0.owner.pid == candidate.owner.pid && $0.owner.launchTime == candidate.owner.launchTime
                }.count
                Self.logger.notice("scanSessionIdentity token=\(id, privacy: .public) reused=\(reusableSessionID != nil) previousOwnerEntries=\(previousOwnerEntries) source=\(String(describing: candidate.source), privacy: .public) identifierPresent=\(candidate.identifier != nil) hasHostBinding=\(candidate.hostPresentation != nil)")
            }
            if let existing, existing.snapshot.id != id {
                let formerKind = existing.snapshot.id.hasPrefix("session:") ? "session" : "persistent"
                let currentKind = persistent == nil ? "session" : "persistent"
                let formerSession = formerKind == "session" ? existing.snapshot.id : "none"
                Self.logger.notice("scanIdentityTransition pid=\(candidate.owner.pid) originCFEqual=true formerKind=\(formerKind, privacy: .public) currentKind=\(currentKind, privacy: .public) formerSession=\(formerSession, privacy: .public) source=\(String(describing: candidate.source), privacy: .public)")
            }
            let previous = existing ?? entries[id]
            let lostHostBinding = candidate.hostPresentation == nil && previous.map {
                $0.owner.pid == candidate.owner.pid && $0.owner.launchTime == candidate.owner.launchTime &&
                    ($0.hostPresentation != nil || $0.hostGeometryUnresolved)
            } == true
            // macOS may expose an AXButton mirror in the host while system hit
            // testing returns the originating AXMenuBarItem. They need not be
            // CFEqual. Without a strictly validated dual-identity binding, a
            // fresh system hit on the original independently proves only its
            // own position. This is not a PID/frame-only host association.
            var verifiedOrigin = false
            if candidate.source == .applicationExtras, !candidate.requiresHostPresentation {
                verifiedOrigin = sourceMatchesHitTest(candidate.element,
                    at: CGPoint(x: candidate.sourceFrame.midX, y: candidate.sourceFrame.midY), context: "origin-position")
            }
            let hostGeometryUnresolved = (candidate.hostGeometryUnresolved || lostHostBinding) && !verifiedOrigin
            let hasReliableGeometry = !unreliableGeometry.contains(candidateIndex) && !hostGeometryUnresolved
            if let identifier = candidate.identifier, Self.anchorIdentifiers.contains(identifier) {
                Self.logger.notice("anchorMapping id=\(identifier, privacy: .public) ownIdentifier=\(own ?? "nil", privacy: .public) ownerPID=\(candidate.owner.pid) ownPID=\(ProcessInfo.processInfo.processIdentifier) ownerBundle=\(candidate.owner.bundleIdentifier ?? "nil", privacy: .public) ownBundle=\(ownBundle ?? "nil", privacy: .public) role=\(candidate.role, privacy: .public) source=\(String(describing: candidate.source), privacy: .public) frame=\(String(describing: candidate.frame), privacy: .public)")
            }
            let snapshot = MenuBarItemSnapshot(id: id, processIdentifier: candidate.owner.pid, name: inputPersistent != nil ? "输入法切换" : candidate.name, ownerName: candidate.owner.name,
                bundleIdentifier: candidate.owner.bundleIdentifier, frame: candidate.frame,
                hasReliableGeometry: hasReliableGeometry, canMove: !protected,
                detail: systemOverflow ? "系统菜单栏溢出入口，用于恢复隐藏图标，不参与分组" :
                    (protected ? "系统固定项目或 Menu Tidy 控制项，保持可见" : (persistent == nil ? "没有稳定标识，仅在本次运行中记住此图标的分类" : "")),
                persistentIdentity: persistent != nil, ownIdentifier: own)
            updated[id] = Entry(element: candidate.element, owner: candidate.owner,
                                accessibilityIdentifier: candidate.identifier, snapshot: snapshot,
                                hostPresentation: candidate.hostPresentation, hostGeometryUnresolved: hostGeometryUnresolved)
            if let host = candidate.hostPresentation {
                Self.logger.notice("hostPresentation candidateOrdinal=\(candidateIndex) bound=true dualIdentity=\(host.mirrorIdentity != nil) pathDepth=\(host.path.count) sourceFrame=\(NSStringFromRect(candidate.sourceFrame), privacy: .public) sourceFrameUsable=\(!candidate.requiresHostPresentation) presentationFrame=\(NSStringFromRect(candidate.frame), privacy: .public) frameChanged=\(candidate.sourceFrame != candidate.frame) reliable=\(hasReliableGeometry)")
            }
            if hostGeometryUnresolved {
                Self.logger.notice("hostPresentation candidateOrdinal=\(candidateIndex) bound=false canonicalIdentityNotProven=\(candidate.hostGeometryUnresolved) lostBinding=\(lostHostBinding) reliable=false")
            }
        }
        // Retain off-screen items for recovery and rules; never reuse a stale PID.
        for (id, old) in entries {
            guard updated[id] == nil,
                  ownersByPID[old.owner.pid]?.launchTime == old.owner.launchTime,
                  ownersByPID[old.owner.pid]?.bundleIdentifier == old.owner.bundleIdentifier else { continue }
            // Keep non-Sendable AX entries within this actor, including on Swift 6.2.
            if belongsToScannedApplicationMenu(old) { continue }
            var alreadyEnumerated = false
            for current in updated.values {
                if CFEqual(current.element, old.element) {
                    alreadyEnumerated = true
                    break
                }
            }
            if !alreadyEnumerated { updated[id] = old }
        }
        // Native hiding can remove an item from both enumerated roots while its
        // owner keeps the original AX object alive. Preserve only caller-owned
        // hidden inventory with an unchanged process identity, never its old
        // geometry or host binding. Revealing must obtain fresh evidence again.
        var retainedSnapshots: [String: MenuBarItemSnapshot] = [:]
        for id in retainHiddenIDs {
            guard let old = entries[id], let current = updated[id],
                  old.snapshot.ownIdentifier == nil,
                  CFEqual(old.element, current.element),
                  let owner = ownersByPID[old.owner.pid],
                  owner.bundleIdentifier == old.owner.bundleIdentifier,
                  owner.launchTime == old.owner.launchTime,
                  current.owner.pid == owner.pid,
                  current.owner.bundleIdentifier == owner.bundleIdentifier,
                  current.owner.launchTime == owner.launchTime,
                  !unique.contains(where: { CFEqual($0.element, old.element) }) else { continue }
            let previous = old.snapshot
            let snapshot = MenuBarItemSnapshot(id: previous.id, processIdentifier: previous.processIdentifier,
                name: previous.name, ownerName: previous.ownerName, bundleIdentifier: previous.bundleIdentifier,
                frame: previous.frame, hasReliableGeometry: false, canMove: previous.canMove, detail: previous.detail,
                persistentIdentity: previous.persistentIdentity, ownIdentifier: previous.ownIdentifier)
            updated[id] = Entry(element: old.element, owner: old.owner,
                accessibilityIdentifier: old.accessibilityIdentifier, snapshot: snapshot,
                hostPresentation: nil, hostGeometryUnresolved: true)
            retainedSnapshots[id] = snapshot
        }
        if !retainedSnapshots.isEmpty {
            Self.logger.notice("nativeHiddenInventory retainedSnapshots=\(retainedSnapshots.count) reliableGeometry=false")
        }
        // The host omits some hidden system modules from both public roots.
        // Preserve their row only after a fresh continuity check, and explicitly
        // discard geometric trust. Neither absence nor this row proves hiding.
        var systemInventory: [AXUIElement]?
        var systemInventoryFailed = false
        for (id, seed) in Array(systemModuleContinuity) {
            guard let currentOwner = ownersByPID[seed.owner.pid],
                  currentOwner.launchTime == seed.owner.launchTime,
                  currentOwner.bundleIdentifier == seed.owner.bundleIdentifier,
                  let current = updated[id], CFEqual(current.element, seed.element) else {
                systemModuleContinuity.removeValue(forKey: id)
                continue
            }
            if unique.contains(where: { CFEqual($0.element, current.element) }) { continue }
            if retainedSnapshots[id] != nil { continue }
            do {
                guard !systemInventoryFailed else { continue }
                if systemInventory == nil {
                    do { systemInventory = try systemPositionSourceItems(owner: current.owner, id: id) }
                    catch { systemInventoryFailed = true; throw error }
                }
                guard let systemInventory,
                      try checkSystemModuleContinuity(current, sourceItems: systemInventory) == .retained else { continue }
                let old = current.snapshot
                let snapshot = MenuBarItemSnapshot(id: old.id, processIdentifier: old.processIdentifier,
                    name: old.name, ownerName: old.ownerName, bundleIdentifier: old.bundleIdentifier,
                    frame: old.frame, hasReliableGeometry: false, canMove: old.canMove, detail: old.detail,
                    persistentIdentity: old.persistentIdentity, ownIdentifier: old.ownIdentifier)
                updated[id] = Entry(element: current.element, owner: current.owner,
                    accessibilityIdentifier: current.accessibilityIdentifier, snapshot: snapshot,
                    hostPresentation: nil, hostGeometryUnresolved: true)
                retainedSnapshots[id] = snapshot
            } catch {
                // A transport failure is unknown for this scan. It does not
                // convert the last successful check into a current row/proof.
                Self.logger.notice("systemModuleContinuity retainedSnapshot=false stage=read-unconfirmed")
            }
        }
        try Task.checkCancellation()
        guard scanCanContinue else { throw MenuBarAccessError.scanTimedOut }
        entries = updated
        for (id, identity) in nativeSystemVisibilityIdentities {
            guard let entry = updated[id], sameNativeSystemOwner(identity.owner, entry.owner),
                  entry.accessibilityIdentifier == identity.identifier else {
                nativeSystemVisibilityIdentities.removeValue(forKey: id)
                continue
            }
        }
        published = true
        var observed: [MenuBarItemSnapshot] = []
        for candidate in unique {
            for entry in updated.values {
                if CFEqual(entry.element, candidate.element) {
                    observed.append(entry.snapshot)
                    break
                }
            }
        }
        var result = retainedSnapshots
        for snapshot in observed { result[snapshot.id] = snapshot }
        return result.values.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Diagnose stable-key collisions using only already-read structural data.
    /// Bucket ordinals are local to this scan: never log names, real identifiers,
    /// their hashes, or the persistent keys used internally to form the buckets.
    private func logDuplicateCandidateBuckets(candidates: [Candidate], unique: [Candidate], identifierCounts: [String: Int]) {
        let duplicateBucketCount = identifierCounts.values.filter { $0 > 1 }.count
        Self.logger.notice("scanIdentity candidateCount=\(candidates.count) uniqueCount=\(unique.count) duplicateBucketCount=\(duplicateBucketCount)")
        guard duplicateBucketCount > 0 else { return }
        var reportedKeys: Set<String> = []
        var bucketOrdinal = 0
        let diagnosticRoles: Set<String> = [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole,
            kAXImageRole, kAXStaticTextRole, kAXMenuBarRole, kAXWindowRole, kAXUnknownRole]
        for candidate in unique {
            guard bucketOrdinal < 16, let key = persistentKey(candidate), identifierCounts[key, default: 0] > 1,
                  reportedKeys.insert(key).inserted else { continue }
            bucketOrdinal += 1
            let members = unique.filter { persistentKey($0) == key }
            let rawCount = candidates.filter { persistentKey($0) == key }.count
            Self.logger.notice("scanDuplicate bucketOrdinal=\(bucketOrdinal) count=\(members.count) rawCount=\(rawCount) loggedCount=\(min(members.count, 8))")
            guard let first = members.first else { continue }
            for (index, member) in members.prefix(8).enumerated() {
                let role = diagnosticRoles.contains(member.role) ? member.role : "other"
                let source = member.source == .applicationExtras ? "applicationExtras" : "hostWindow"
                let geometry = NSStringFromRect(member.frame)
                let pidEqual = member.owner.pid == first.owner.pid
                let launchEqual = member.owner.launchTime == first.owner.launchTime
                let identifierEqual = member.identifier == first.identifier
                let bundleEqual = member.owner.bundleIdentifier == first.owner.bundleIdentifier
                let frameEqual = member.frame == first.frame
                let cfEqual = CFEqual(member.element, first.element)
                Self.logger.notice("scanDuplicateMember bucketOrdinal=\(bucketOrdinal) memberOrdinal=\(index + 1) pid=\(member.owner.pid) rootPID=\(member.enumerationRootPID) role=\(role, privacy: .public) source=\(source, privacy: .public) frame=\(geometry, privacy: .public) pidEqualFirst=\(pidEqual) launchEqualFirst=\(launchEqual) identifierEqualFirst=\(identifierEqual) bundleEqualFirst=\(bundleEqual) frameEqualFirst=\(frameEqual) cfEqualFirst=\(cfEqual)")
            }
        }
    }

    func currentFrame(id: String) -> CGRect? {
        guard let entry = entries[id] else { return nil }
        return entryFrame(entry)
    }

    /// Physical MenuBarAgent container of our exact regular divider. This is
    /// deliberately not entryFrame: a source's inner 22-point button does not
    /// describe the actual width consumed by its hosted menu-bar container.
    func currentOwnDividerHostFrame() -> CGRect? {
        let identifier = "menu-tidy-divider"
        var stage = "availability"
        var budget = MirrorReadBudget()
        func failed(_ value: String) -> CGRect? {
            Self.logger.notice("ownDividerHostFrame verified=false stage=\(value, privacy: .public)")
            return nil
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              AXIsProcessTrusted(), !Task.isCancelled, !menuBands.isEmpty,
              let bundle = Bundle.main.bundleIdentifier else { return failed(stage) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let matching = entries.values.filter {
            $0.snapshot.ownIdentifier == identifier && $0.accessibilityIdentifier == identifier &&
                $0.owner.pid == ownPID && $0.owner.bundleIdentifier == bundle
        }
        stage = "source-identity"
        guard matching.count == 1, let entry = matching.first, liveOwnerMatches(entry),
              mirrorText(entry.element, kAXRoleAttribute, budget: &budget) == kAXMenuBarItemRole,
              mirrorText(entry.element, kAXIdentifierAttribute, budget: &budget) == identifier else { return failed(stage) }
        let application = AXUIElementCreateApplication(ownPID)
        let rootRead = mirrorAttribute(application, kAXExtrasMenuBarAttribute, budget: &budget)
        stage = "source-root"
        guard rootRead.error == .success, let root = element(rootRead.value),
              mirrorText(root, kAXRoleAttribute, budget: &budget) == kAXMenuBarRole,
              liveOwnerMatches(element: root, owner: entry.owner),
              let originChildren = completeMirrorChildren(root, budget: &budget),
              originChildren.filter({ CFEqual($0, entry.element) }).count == 1 else { return failed(stage) }
        var originalMatches: [AXUIElement] = []
        for child in originChildren {
            guard budget.isValid, liveOwnerMatches(element: child, owner: entry.owner) else { return failed(stage) }
            let read = mirrorOptionalIdentifier(child, budget: &budget)
            guard read.complete else { return failed(stage) }
            if read.identifier == identifier { originalMatches.append(child) }
        }
        guard originalMatches.count == 1, let original = originalMatches.first,
              CFEqual(original, entry.element) else { return failed(stage) }
        stage = "host-owner"
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app" }
        guard hosts.count == 1, let host = hosts.first,
              let hostOwner = resolvedOwner(MenuBarOwner(pid: host.processIdentifier,
                  bundleIdentifier: host.bundleIdentifier, name: "",
                  launchTime: host.launchDate?.timeIntervalSince1970 ?? 0)) else { return failed(stage) }
        let hostApplication = AXUIElementCreateApplication(hostOwner.pid)
        stage = "host-census"
        guard let windows = completeMirrorChildren(hostApplication, attribute: kAXWindowsAttribute, budget: &budget),
              windows.count <= 32 else { return failed(stage) }
        var bindings: [HostPresentation] = []
        for window in windows {
            guard budget.isValid, liveOwnerMatches(element: window, owner: hostOwner),
                  mirrorText(window, kAXRoleAttribute, budget: &budget) == kAXWindowRole,
                  let windowFrame = mirrorFrame(window, budget: &budget) else { return failed(stage) }
            // Popup windows cannot provide a menu-bar item's physical footprint.
            guard validHostWindowFrame(windowFrame, containing: windowFrame) else { continue }
            guard let containers = completeMirrorChildren(window, budget: &budget) else { return failed(stage) }
            for container in containers {
                guard budget.isValid, liveOwnerMatches(element: container, owner: hostOwner),
                      let children = completeMirrorChildren(container, allowMissing: true, budget: &budget) else { return failed(stage) }
                var remoteChildren: [AXUIElement] = []
                for child in children {
                    var pid: pid_t = 0
                    guard budget.isValid, AXUIElementGetPid(child, &pid) == .success, pid > 0 else { return failed(stage) }
                    if pid != hostOwner.pid { remoteChildren.append(child) }
                    guard pid == ownPID else { continue }
                    // This fallback supports the observed direct own-button
                    // shape only. It does not search unrelated remote apps or
                    // infer a target from container order or nearby geometry.
                    guard liveOwnerMatches(element: child, owner: entry.owner),
                          mirrorText(child, kAXRoleAttribute, budget: &budget) == kAXButtonRole else { return failed(stage) }
                    let read = mirrorOptionalIdentifier(child, budget: &budget)
                    guard read.complete else { return failed(stage) }
                    if read.identifier == identifier {
                        guard let rect = mirrorFrame(container, budget: &budget),
                              validHostFrame(rect, identifier: identifier),
                              validHostWindowFrame(windowFrame, containing: rect) else { return failed(stage) }
                        let identity = MirrorIdentity(identifier: identifier, originPath: [root, entry.element])
                        bindings.append(HostPresentation(hostOwner: hostOwner, window: window,
                            path: [container, child], snapshotFrame: rect, mirrorIdentity: identity))
                    }
                }
                if bindings.contains(where: { binding in
                    binding.path.first.map { CFEqual($0, container) } == true
                }), remoteChildren.count != 1 { return failed(stage) }
            }
        }
        stage = "host-uniqueness"
        guard bindings.count == 1, let binding = bindings.first else { return failed(stage) }
        stage = "host-live-frame"
        guard let rect = currentHostFrame(binding, original: entry.element, owner: entry.owner,
                identifier: identifier, budget: &budget), rect == binding.snapshotFrame else { return failed(stage) }
        // This own blank/disabled spacer may legitimately not be hit-testable.
        // A hit is diagnostic only: its exact live AX host chain and stable
        // physical frame establish geometry, never third-party concealment.
        let centerHit = ownDividerCenterHits(entry: entry, binding: binding, frame: rect, budget: &budget)
        stage = "final-recheck"
        guard currentHostFrame(binding, original: entry.element, owner: entry.owner,
                identifier: identifier, budget: &budget) == rect,
              !Task.isCancelled, budget.isValid, liveOwnerMatches(entry) else { return failed(stage) }
        Self.logger.notice("ownDividerHostFrame verified=true centerHit=\(centerHit) frame=\(NSStringFromRect(rect), privacy: .public)")
        return rect
    }

    /// Returns the physical footprint of an already-visible, strictly bound
    /// host item. The origin's inner frame and overflow placeholders are never
    /// substitutes. A caller retaining this measurement must also retain and
    /// revalidate the source identity; this is not a promise of constant width.
    func verifiedVisibleHostFrame(id: String) -> CGRect? {
        func failed(_ stage: String) -> CGRect? {
            Self.logger.notice("visibleHostFootprint verified=false stage=\(stage, privacy: .public)")
            return nil
        }
        func fitsPrimaryMenuBand(_ rect: CGRect) -> Bool {
            guard let band = menuBands.first,
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.width <= 120, rect.height > 0, rect.height <= 64 else { return false }
            return rect.minX >= band.minX && rect.maxX <= band.maxX &&
                rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              AXIsProcessTrusted(), !Task.isCancelled,
              let entry = entries[id], liveOwnerMatches(entry) else { return failed("source-unavailable") }
        if let binding = entry.hostPresentation {
            var budget = MirrorReadBudget()
            guard let rect = currentHostFrame(binding, original: entry.element, owner: entry.owner,
                    identifier: entry.accessibilityIdentifier, budget: &budget),
                  fitsPrimaryMenuBand(rect) else { return failed("host-geometry") }
            // The helper accepts only this original object or its proven host
            // path. The shared host window cannot establish a visible item.
            guard ownDividerCenterHits(entry: entry, binding: binding, frame: rect, budget: &budget),
                  currentHostFrame(binding, original: entry.element, owner: entry.owner,
                    identifier: entry.accessibilityIdentifier, budget: &budget) == rect,
                  ownDividerCenterHits(entry: entry, binding: binding, frame: rect, budget: &budget),
                  currentHostFrame(binding, original: entry.element, owner: entry.owner,
                    identifier: entry.accessibilityIdentifier, budget: &budget) == rect,
                  budget.isValid, liveOwnerMatches(entry) else { return failed("host-not-stably-visible") }
            Self.logger.notice("visibleHostFootprint verified=true systemModule=false frame=\(NSStringFromRect(rect), privacy: .public)")
            return rect
        }
        if let rect = verifiedSingletonVisibleHostFrame(entry), fitsPrimaryMenuBand(rect) {
            Self.logger.notice("visibleHostFootprint verified=true singletonSource=true frame=\(NSStringFromRect(rect), privacy: .public)")
            return rect
        }
        // This helper obtains a unique container-to-original-object path for a
        // system module and repeats both exact path hits and structural reads.
        // It has no raw-origin geometry fallback.
        guard let inspection = verifiedSystemModuleVisibility(entry), inspection.centerHit,
              let rect = inspection.frame, fitsPrimaryMenuBand(rect),
              liveOwnerMatches(entry), !Task.isCancelled else { return failed("no-verified-host-presentation") }
        Self.logger.notice("visibleHostFootprint verified=true systemModule=true frame=\(NSStringFromRect(rect), privacy: .public)")
        return rect
    }

    /// Geometry-only proof for an app with exactly one originating menu item.
    /// Host mirrors need not be CFEqual to that item, but both visible points
    /// must hit the original object. This never installs an action binding.
    private func verifiedSingletonVisibleHostFrame(_ entry: Entry) -> CGRect? {
        var stage = "source-census"
        var windowIndex = -1
        var containerIndex = -1
        var nodeCount = -1
        var remoteCount = -1
        var targetCount = -1
        defer {
            Self.logger.notice("visibleHostSingleton stage=\(stage, privacy: .public) windowIndex=\(windowIndex) containerIndex=\(containerIndex) nodeCount=\(nodeCount) remoteCount=\(remoteCount) targetCount=\(targetCount)")
        }
        guard entry.owner.bundleIdentifier != "com.apple.MenuBarAgent", liveOwnerMatches(entry),
              let originals = try? positionSourceItems(owner: entry.owner, id: entry.snapshot.id),
              originals.count == 1, let original = originals.first, CFEqual(original, entry.element) else { return nil }
        var budget = MirrorReadBudget()
        guard let sourceFrame = mirrorFrame(original, budget: &budget),
              validHostFrame(sourceFrame, identifier: nil), sourceFrame.width <= 120 else { return nil }
        let sourcePoint = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        stage = "original-positive-hit"
        guard exactOriginalVisiblePoint(original, point: sourcePoint, owner: entry.owner, budget: &budget) else { return nil }
        stage = "host-owner"
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app" }
        guard hosts.count == 1, let app = hosts.first,
              let hostOwner = resolvedOwner(MenuBarOwner(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                  name: "", launchTime: app.launchDate?.timeIntervalSince1970 ?? 0)) else { return nil }
        let application = AXUIElementCreateApplication(hostOwner.pid)
        stage = "host-census-windows-read"
        guard let windows = completeMirrorChildren(application, attribute: kAXWindowsAttribute, budget: &budget) else { return nil }
        nodeCount = windows.count
        stage = "host-census-windows-count"
        guard windows.count <= 32 else { return nil }
        var branches: [(parent: AXUIElement, children: [AXUIElement])] = []
        var matches: [HostPresentation] = []
        var ownerContainers = 0
        for (windowOrdinal, window) in windows.enumerated() {
            windowIndex = windowOrdinal
            containerIndex = -1
            stage = "host-census-window-budget"
            guard budget.isValid else { return nil }
            stage = "host-census-window-owner"
            guard liveOwnerMatches(element: window, owner: hostOwner) else { return nil }
            stage = "host-census-window-role"
            guard mirrorText(window, kAXRoleAttribute, budget: &budget) == kAXWindowRole else { return nil }
            stage = "host-census-window-frame"
            guard let windowFrame = mirrorFrame(window, budget: &budget) else { return nil }
            guard validHostWindowFrame(windowFrame, containing: windowFrame) else { continue }
            stage = "host-census-window-children"
            guard let containers = completeMirrorChildren(window, budget: &budget) else { return nil }
            nodeCount = containers.count
            branches.append((window, containers))
            for (containerOrdinal, container) in containers.enumerated() {
                containerIndex = containerOrdinal
                remoteCount = -1
                targetCount = -1
                stage = "host-census-container-owner"
                guard liveOwnerMatches(element: container, owner: hostOwner) else { return nil }
                stage = "host-census-container-children"
                guard let children = completeMirrorChildren(container, allowMissing: true, budget: &budget) else { return nil }
                nodeCount = children.count
                branches.append((container, children))
                var remote: [AXUIElement] = []
                var targetChildren: [AXUIElement] = []
                var targetIsDirect = true
                var pending = children.map { (element: $0, depth: 0) }
                var visited: [AXUIElement] = [container]
                while let next = pending.popLast() {
                    let child = next.element
                    var pid: pid_t = 0
                    stage = "host-census-child-budget"
                    guard budget.isValid, next.depth < 6, visited.count < 120,
                          !visited.contains(where: { CFEqual($0, child) }) else { return nil }
                    visited.append(child)
                    stage = "host-census-child-pid"
                    guard AXUIElementGetPid(child, &pid) == .success, pid > 0 else { return nil }
                    if pid != hostOwner.pid {
                        // Foreign applications are boundaries, never roots to
                        // walk. Count them under their actual host container.
                        remote.append(child)
                        if pid == entry.owner.pid {
                            targetChildren.append(child)
                            targetIsDirect = targetIsDirect && next.depth == 0
                        }
                        continue
                    }
                    stage = "host-census-host-child-owner"
                    guard liveOwnerMatches(element: child, owner: hostOwner) else { return nil }
                    stage = "host-census-host-child-role"
                    guard let role = mirrorText(child, kAXRoleAttribute, budget: &budget) else { return nil }
                    stage = "host-census-host-child-read"
                    guard let nested = completeMirrorChildren(child, allowMissing: true, budget: &budget) else { return nil }
                    nodeCount = nested.count
                    // Observed system-owned AXGroup -> AXMenuBarItem leaves
                    // must not make every third-party census fail. Enumerate
                    // groups completely and retain every edge for re-reading.
                    stage = "host-census-host-child-container-role"
                    guard nested.isEmpty || role == kAXGroupRole else { return nil }
                    branches.append((child, nested))
                    pending.append(contentsOf: nested.map { (element: $0, depth: next.depth + 1) })
                }
                remoteCount = remote.count
                targetCount = targetChildren.count
                guard !targetChildren.isEmpty else { continue }
                ownerContainers += 1
                stage = "host-census-target-container-unique"
                guard ownerContainers == 1, targetChildren.count == 1, remote.count == 1,
                      let item = targetChildren.first else { return nil }
                stage = "host-census-target-direct-path"
                guard targetIsDirect else { return nil }
                stage = "host-census-target-owner"
                guard liveOwnerMatches(element: item, owner: entry.owner) else { return nil }
                stage = "host-census-target-role-read"
                guard let role = mirrorText(item, kAXRoleAttribute, budget: &budget) else { return nil }
                stage = "host-census-target-role-kind"
                guard role == kAXButtonRole || role == kAXMenuBarItemRole else { return nil }
                stage = "host-census-target-container-frame-read"
                guard let rect = mirrorFrame(container, budget: &budget) else { return nil }
                stage = "host-census-target-container-frame-bounds"
                guard validHostFrame(rect, identifier: nil), rect.width <= 120,
                      validHostWindowFrame(windowFrame, containing: rect) else { return nil }
                matches.append(HostPresentation(hostOwner: hostOwner, window: window,
                    path: [container, item], snapshotFrame: rect, mirrorIdentity: nil))
            }
        }
        stage = "unique-container-and-live-path"
        guard ownerContainers == 1, matches.count == 1, let binding = matches.first,
              let remote = binding.path.last,
              let rect = currentHostFrame(binding, original: remote, owner: entry.owner,
                  identifier: nil, budget: &budget), rect == binding.snapshotFrame,
              rect.contains(sourcePoint) else { return nil }
        let hostPoint = CGPoint(x: rect.midX, y: rect.midY)
        // This is positive identity evidence at two points, not PID/nearest-frame
        // inference. The host supplies width only while this original is hit.
        stage = "both-positive-original-hits"
        guard exactOriginalVisiblePoint(original, point: sourcePoint, owner: entry.owner, budget: &budget),
              exactOriginalVisiblePoint(original, point: hostPoint, owner: entry.owner, budget: &budget),
              mirrorFrame(original, budget: &budget) == sourceFrame else { return nil }
        stage = "complete-census-recheck"
        for branch in branches {
            guard let current = completeMirrorChildren(branch.parent, allowMissing: true, budget: &budget),
                  current.count == branch.children.count,
                  branch.children.allSatisfy({ child in current.filter { CFEqual($0, child) }.count == 1 }) else { return nil }
        }
        guard let currentWindows = completeMirrorChildren(application, attribute: kAXWindowsAttribute, budget: &budget),
              currentWindows.count == windows.count,
              windows.allSatisfy({ window in currentWindows.filter { CFEqual($0, window) }.count == 1 }),
              currentHostFrame(binding, original: remote, owner: entry.owner, identifier: nil, budget: &budget) == rect,
              exactOriginalVisiblePoint(original, point: sourcePoint, owner: entry.owner, budget: &budget),
              exactOriginalVisiblePoint(original, point: hostPoint, owner: entry.owner, budget: &budget),
              mirrorFrame(original, budget: &budget) == sourceFrame,
              budget.isValid, liveOwnerMatches(entry) else { return nil }
        stage = "source-census-recheck"
        guard let finalOriginals = try? positionSourceItems(owner: entry.owner, id: entry.snapshot.id),
              finalOriginals.count == 1, let finalOriginal = finalOriginals.first,
              CFEqual(finalOriginal, original), liveOwnerMatches(entry), budget.isValid,
              currentHostFrame(binding, original: remote, owner: entry.owner, identifier: nil, budget: &budget) == rect else { return nil }
        stage = "verified"
        return rect
    }

    private func exactOriginalVisiblePoint(_ original: AXUIElement, point: CGPoint, owner: MenuBarOwner,
                                           budget: inout MirrorReadBudget) -> Bool {
        guard budget.isValid, liveOwnerMatches(element: original, owner: owner) else { return false }
        let hit = Self.copyElementAtPositionOnMainThread(point)
        guard budget.isValid, hit.error == .success else { return false }
        var current = hit.element
        var visited: [AXUIElement] = []
        for _ in 0..<6 {
            guard let node = current, budget.isValid,
                  !visited.contains(where: { CFEqual($0, node) }),
                  liveOwnerMatches(element: node, owner: owner) else { return false }
            if CFEqual(node, original) { return true }
            visited.append(node)
            current = element(mirrorAttribute(node, kAXParentAttribute, budget: &budget).value)
        }
        return false
    }

    /// A disabled divider may hit its host container rather than its button.
    /// Accept only the exact bound identities; the shared window never suffices.
    private func ownDividerCenterHits(entry: Entry, binding: HostPresentation, frame: CGRect,
                                     budget: inout MirrorReadBudget) -> Bool {
        let hit = Self.copyElementAtPositionOnMainThread(CGPoint(x: frame.midX, y: frame.midY))
        guard budget.isValid, hit.error == .success else { return false }
        var current = hit.element
        var visited: [AXUIElement] = []
        for _ in 0..<6 {
            guard budget.isValid, let node = current,
                  !visited.contains(where: { CFEqual($0, node) }) else { return false }
            visited.append(node)
            if CFEqual(node, entry.element) || binding.path.contains(where: { CFEqual($0, node) }) { return true }
            if CFEqual(node, binding.window) { return false }
            let parent = mirrorAttribute(node, kAXParentAttribute, budget: &budget)
            guard parent.error == .success else { return false }
            current = element(parent.value)
        }
        return false
    }

    /// Invoke the original item's accessible action without opening the native
    /// hidden section or sending a click to an unverified screen coordinate.
    func validateItemActionSupport(id: String) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), let entry = entries[id], entry.snapshot.canMove,
              liveOwnerMatches(entry) else { throw MenuBarAccessError.disappeared }
        let actions = copyAXActions(entry.element)
        guard actions.error == .success else { throw MenuBarAccessError.actionRejected }
        guard actions.names.contains(kAXPressAction) || actions.names.contains(kAXShowMenuAction) else {
            throw MenuBarAccessError.actionUnavailable
        }
        guard liveOwnerMatches(entry) else { throw MenuBarAccessError.disappeared }
    }

    @discardableResult
    func pressItem(id: String, baseline suppliedBaseline: MenuBarPresentationBaseline? = nil) async throws -> MenuBarItemPresentation? {
        let baseline = try suppliedBaseline ?? prepareItemPresentation(id: id)
        guard let prepared = presentationBaseline, prepared.token == baseline.token,
              prepared.entry.snapshot.id == id, prepared.expiresAt > ProcessInfo.processInfo.systemUptime,
              let entry = entries[id], CFEqual(entry.element, prepared.entry.element), livePresentationScopeMatches(entry, owners: prepared.owners) else {
            throw MenuBarAccessError.disappeared
        }
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        lastPresentationBaseline = prepared
        let available = copyAXActions(entry.element)
        guard available.error == .success else { throw MenuBarAccessError.actionRejected }
        let names = available.names
        let action = names.contains(kAXPressAction) ? kAXPressAction : (names.contains(kAXShowMenuAction) ? kAXShowMenuAction : nil)
        guard let action else {
            throw MenuBarAccessError.actionUnavailable
        }
        // The action-list query can block in another process. Recheck after it
        // returns so cancellation or an owner restart cannot dispatch a stale action.
        try Task.checkCancellation()
        guard prepared.expiresAt > ProcessInfo.processInfo.systemUptime,
              livePresentationScopeMatches(entry, owners: prepared.owners) else {
            throw MenuBarAccessError.disappeared
        }
        let pointerBefore = CGEvent(source: nil)?.location
        defer { logPointerObservation(pointerBefore, context: "item-action") }
        let result = performAXAction(entry.element, action)
        Self.logger.notice("itemAction dispatched=true axResult=\(result.rawValue)")
        // A menu tracking loop can outlive the AX message timeout even when it
        // opened successfully. Observe the result before calling it rejected.
        if result == .actionUnsupported { throw MenuBarAccessError.actionUnavailable }
        guard result == .success || result == .cannotComplete else { throw MenuBarAccessError.actionRejected }
        return try await observeItemPresentation(since: baseline)
    }

    /// Compatibility entry point: actions are addressed only to the original AX
    /// item. An unconfirmed action never falls back to synthetic pointer input.
    func pressVisibleItem(id: String, baseline: MenuBarPresentationBaseline) async throws -> MenuBarItemPresentation? {
        try await pressItem(id: id, baseline: baseline)
    }

    /// Read the current native presentation before invoking the original item;
    /// no temporary placement or pointer movement is required.
    /// Only one pending baseline/presentation is retained by this actor.
    func prepareItemPresentation(id: String) throws -> MenuBarPresentationBaseline {
        lastPresentationBaseline = nil
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard let entry = entries[id], entry.snapshot.canMove,
              entry.owner.pid != ProcessInfo.processInfo.processIdentifier,
              liveOwnerMatches(entry) else { throw MenuBarAccessError.disappeared }
        try Task.checkCancellation()
        let owners = try presentationOwners(for: entry)
        let probe = probePresentations(for: entry, owners: owners)
        Self.logger.notice("itemPresentation baselineComplete=\(probe.complete) roots=\(probe.authoritativeRoots) nodes=\(probe.nodes.count)")
        guard probe.complete, livePresentationScopeMatches(entry, owners: owners) else {
            throw MenuBarAccessError.geometryDetail("无法完整确认目标应用当前的菜单状态，尚未点击图标，请稍后重试。")
        }
        let token = UUID()
        presentation = nil
        presentationBaseline = PresentationBaseline(token: token, entry: entry, owners: owners,
            nodes: probe.nodes, visible: probe.nodes.filter(\.visible),
            ownerWindowIDs: ownerWindowIDs(owners), authoritativeRoots: probe.authoritativeRoots,
            expiresAt: ProcessInfo.processInfo.systemUptime + 10)
        return MenuBarPresentationBaseline(token: token)
    }

    /// Success means an actual new visible root menu/window was hit, not merely
    /// that AXPress accepted the request. A nil result is unconfirmed.
    func observeItemPresentation(since baseline: MenuBarPresentationBaseline) async throws -> MenuBarItemPresentation? {
        guard let prepared = presentationBaseline, prepared.token == baseline.token,
              prepared.expiresAt > ProcessInfo.processInfo.systemUptime else { throw MenuBarAccessError.disappeared }
        lastPresentationBaseline = prepared
        defer { if presentationBaseline?.token == baseline.token { presentationBaseline = nil } }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
            guard presentationBaseline?.token == baseline.token,
                  livePresentationScopeMatches(prepared.entry, owners: prepared.owners) else {
                throw MenuBarAccessError.disappeared
            }
            let probe = probePresentations(for: prepared.entry, owners: prepared.owners)
            guard livePresentationScopeMatches(prepared.entry, owners: prepared.owners) else {
                throw MenuBarAccessError.disappeared
            }
            var appeared: [PresentationNode] = []
            for node in probe.nodes {
                guard node.visible else { continue }
                var previouslyVisible = false
                for previous in prepared.visible {
                    if CFEqual(previous.element, node.element) { previouslyVisible = true; break }
                }
                if !previouslyVisible { appeared.append(node) }
            }
            var matched: [PresentationNode] = []
            for node in appeared {
                if presentationMatchesSystemModule(node, entry: prepared.entry) { matched.append(node) }
            }
            var menus: [PresentationNode] = []
            for node in matched {
                if node.kind == .menu { menus.append(node) }
            }
            let preferred = menus.isEmpty ? matched : menus
            Self.logger.debug("itemPresentation observationComplete=\(probe.complete) nodes=\(probe.nodes.count) visible=\(probe.nodes.filter(\.visible).count) appeared=\(preferred.count)")
            // A verified new root is positive evidence even when a separate
            // supplemental path could not be read completely.
            if preferred.count == 1, let node = preferred.first {
                let token = UUID()
                presentation = Presentation(token: token, entry: prepared.entry, owners: prepared.owners, node: node)
                Self.logger.notice("itemPresentation confirmed=true isMenu=\(node.kind == .menu)")
                return MenuBarItemPresentation(token: token, kind: node.kind)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(min(0.1, remaining))) }
        }
        Self.logger.notice("itemPresentation confirmed=false")
        logUnconfirmedPresentationWindows(owners: prepared.owners)
        return nil
    }

    /// A reopen request can bring forward an existing window. Verify an actual
    /// visible in-scope window; activation or a successful launch callback alone
    /// is not proof. This path never dispatches an AX action to the tray item.
    func applicationWindowIsPresented(id: String) throws -> Bool {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), let entry = entries[id], liveOwnerMatches(entry) else {
            throw MenuBarAccessError.disappeared
        }
        let owners = try presentationOwners(for: entry)
        let probe = probePresentations(for: entry, owners: owners)
        guard livePresentationScopeMatches(entry, owners: owners) else { throw MenuBarAccessError.disappeared }
        for node in probe.nodes {
            if node.kind == .window && node.visible && node.owner.identity.pid == entry.owner.pid { return true }
        }
        return false
    }

    /// Queries the same retained AX object. An IPC failure or occlusion is not
    /// evidence of closure. The caller may require consecutive closed samples.
    func presentationStatus(_ token: MenuBarItemPresentation) -> MenuBarPresentationStatus {
        guard AXIsProcessTrusted(), let current = presentation, current.token == token.token,
              livePresentationScopeMatches(current.entry, owners: current.owners) else { return .unavailable }
        let role = copyAttribute(current.node.element, kAXRoleAttribute)
        guard livePresentationScopeMatches(current.entry, owners: current.owners) else { return .unavailable }
        if role.error == .invalidUIElement { return .closed }
        guard role.error == .success, role.value as? String == current.node.originalRole else { return .unavailable }
        var nodePID: pid_t = 0
        guard AXUIElementGetPid(current.node.element, &nodePID) == .success,
              nodePID == current.node.owner.identity.pid else { return .unavailable }
        guard let rect = frame(current.node.element) else { return .unavailable }
        if rect.width <= 0 || rect.height <= 0 || !presentationFrameIsOnscreen(rect) {
            return livePresentationScopeMatches(current.entry, owners: current.owners) ? .closed : .unavailable
        }
        var budget = PresentationReadBudget()
        let previousValidation = current.node.validationPoint.flatMap { point in
            current.node.validationElement.map { PresentationValidation(point: point, element: $0) }
        }
        if presentationValidation(root: current.node.element, owner: current.node.owner, frame: rect,
            preferred: previousValidation, budget: &budget) != nil {
            return livePresentationScopeMatches(current.entry, owners: current.owners) ? .open : .unavailable
        }
        // This is the one window correlated to the confirmed AX object when it
        // opened, never a window-count heuristic or an unrelated owner's window.
        // Covering a real popup does not close it: preserve its observation while
        // the retained window ID, owner epoch and exact live AX/CG frame agree.
        if let windowID = current.node.backingWindowID, let windows = onscreenWindowInfo() {
            let matches = windows.filter {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
            }
            if matches.isEmpty {
                return livePresentationScopeMatches(current.entry, owners: current.owners) ? .closed : .unavailable
            }
            guard matches.count == 1, let window = matches.first,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == current.node.owner.identity.pid,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha.isFinite, alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let windowFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary), windowFrame == rect,
                  frame(current.node.element) == rect,
                  text(current.node.element, kAXRoleAttribute) == current.node.originalRole,
                  livePresentationScopeMatches(current.entry, owners: current.owners) else { return .unavailable }
            return .open
        }
        return .unavailable
    }

    /// Request cancellation of only the retained, confirmed native menu.
    /// true means AX accepted the action, never that the menu has closed.
    /// Keep observing presentationStatus before restoring temporary placement.
    @discardableResult
    func cancelCurrentMenuPresentation() -> Bool {
        guard AXIsProcessTrusted(), let current = presentation, current.node.kind == .menu,
              livePresentationScopeMatches(current.entry, owners: current.owners) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(current.node.element, &pid) == .success, pid == current.node.owner.identity.pid,
              text(current.node.element, kAXRoleAttribute) == kAXMenuRole else { return false }
        if current.cancelActionResult != nil { return false }
        let actions = copyAXActions(current.node.element)
        guard actions.error == .success, actions.names.contains(kAXCancelAction) else {
            Self.logger.debug("itemPresentation cancelSupported=false axError=\(actions.error.rawValue)")
            return false
        }
        guard livePresentationScopeMatches(current.entry, owners: current.owners) else { return false }
        // Record the attempt before dispatch. Even an IPC timeout can mean the
        // action ran, so never automatically send a second cancel for this root.
        presentation?.cancelActionResult = .cannotComplete
        let result = performAXAction(current.node.element, kAXCancelAction)
        presentation?.cancelActionResult = result
        Self.logger.notice("itemPresentation cancelDispatched=true accepted=\(result == .success) axError=\(result.rawValue)")
        return result == .success
    }

    func discardPresentation(_ token: MenuBarItemPresentation) {
        if presentation?.token == token.token {
            presentation = nil
            lastPresentationBaseline = nil
        }
    }

    /// Post-action evidence relative to that item's own retained baseline.
    /// false is a complete unchanged observation; absence of a baseline, an
    /// unsupported tree, occlusion of a new candidate, or IPC failure is unknown.
    func hasVisiblePresentation(id: String) -> Bool? {
        guard AXIsProcessTrusted(), let baseline = lastPresentationBaseline,
              baseline.entry.snapshot.id == id, livePresentationScopeMatches(baseline.entry, owners: baseline.owners),
              let current = entries[id], CFEqual(current.element, baseline.entry.element),
              livePresentationScopeMatches(current, owners: baseline.owners) else { return nil }
        let probe = probePresentations(for: current, owners: baseline.owners)
        guard livePresentationScopeMatches(current, owners: baseline.owners) else { return nil }
        var uncertain = false
        for node in probe.nodes {
            let old = baseline.nodes.first { CFEqual($0.element, node.element) }
            let changed = old == nil || old?.frame != node.frame || old?.backingWindowID != node.backingWindowID ||
                (node.visible && old?.visible != true)
            guard changed else { continue }
            if node.visible { return true }
            uncertain = true
        }
        guard probe.complete, probe.authoritativeRoots, baseline.authoritativeRoots else { return nil }
        guard !uncertain, let before = baseline.ownerWindowIDs,
              let now = ownerWindowIDs(baseline.owners) else { return nil }
        // A new in-scope on-screen window without an AX counterpart may be a
        // custom popup. Window counts/IDs do not prove its role, so stay unknown.
        guard now.isSubset(of: before), livePresentationScopeMatches(current, owners: baseline.owners) else { return nil }
        return false
    }

    private func ownerWindowIDs(_ owners: [PresentationOwner]) -> Set<CGWindowID>? {
        guard owners.allSatisfy({ livePresentationOwnerMatches($0) }), let windows = onscreenWindowInfo() else { return nil }
        let pids = Set(owners.map { $0.identity.pid })
        return Set(windows.compactMap { info -> CGWindowID? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pids.contains(pid) else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    /// These exact system extras keep their original identity in MenuBarAgent
    /// while the fixed ControlCenter process presents their native panels.
    /// Unknown modules and arbitrary com.apple processes gain no delegation.
    private func presentationOwners(for entry: Entry) throws -> [PresentationOwner] {
        var owners = [PresentationOwner(identity: entry.owner, requiredBundlePath: nil)]
        guard let delegate = SystemModulePresentationIdentity.delegate(
            ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) else { return owners }
        guard text(entry.element, kAXIdentifierAttribute) == entry.accessibilityIdentifier else {
            throw MenuBarAccessError.disappeared
        }
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: delegate.bundleIdentifier)
            .filter { !$0.isTerminated && $0.bundleIdentifier == delegate.bundleIdentifier &&
                $0.bundleURL?.standardizedFileURL.path == delegate.bundlePath }
        guard matches.count == 1, let running = matches.first,
              running.processIdentifier != entry.owner.pid,
              let owner = resolvedOwner(MenuBarOwner(pid: running.processIdentifier,
                  bundleIdentifier: running.bundleIdentifier, name: "",
                  launchTime: running.launchDate?.timeIntervalSince1970 ?? 0)) else {
            throw MenuBarAccessError.geometryDetail("无法确认该系统图标的展示进程，尚未点击图标。请关闭系统面板后重试。")
        }
        owners.append(PresentationOwner(identity: owner, requiredBundlePath: delegate.bundlePath))
        Self.logger.notice("itemPresentation systemModuleOwnerBound=true ownerCount=\(owners.count)")
        return owners
    }

    private func livePresentationOwnerMatches(_ owner: PresentationOwner) -> Bool {
        let expected = owner.identity
        guard let running = NSRunningApplication(processIdentifier: expected.pid), !running.isTerminated,
              running.bundleIdentifier == expected.bundleIdentifier,
              owner.requiredBundlePath == nil || running.bundleURL?.standardizedFileURL.path == owner.requiredBundlePath,
              let current = resolvedOwner(MenuBarOwner(pid: expected.pid, bundleIdentifier: running.bundleIdentifier,
                  name: "", launchTime: running.launchDate?.timeIntervalSince1970 ?? 0)) else { return false }
        return current.launchTime == expected.launchTime
    }

    private func livePresentationScopeMatches(_ entry: Entry, owners: [PresentationOwner]) -> Bool {
        guard liveOwnerMatches(entry), !owners.isEmpty, owners.allSatisfy({ livePresentationOwnerMatches($0) }),
              owners[0].identity.pid == entry.owner.pid,
              owners[0].identity.bundleIdentifier == entry.owner.bundleIdentifier,
              owners[0].identity.launchTime == entry.owner.launchTime else { return false }
        guard let delegate = SystemModulePresentationIdentity.delegate(
            ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) else { return owners.count == 1 }
        return owners.count == 2 && owners[1].identity.pid != entry.owner.pid &&
            text(entry.element, kAXIdentifierAttribute) == entry.accessibilityIdentifier &&
            owners[1].identity.bundleIdentifier == delegate.bundleIdentifier &&
            owners[1].requiredBundlePath == delegate.bundlePath
    }

    /// Positive attribution only: this new, independently visible native root
    /// must contain the exact module header observed in the system UI. Header
    /// absence never means closed; later status tracks the retained root itself.
    private func presentationMatchesSystemModule(_ node: PresentationNode, entry: Entry) -> Bool {
        guard let delegate = SystemModulePresentationIdentity.delegate(
            ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) else { return true }
        guard node.owner.identity.bundleIdentifier == delegate.bundleIdentifier,
              node.owner.requiredBundlePath == delegate.bundlePath,
              livePresentationOwnerMatches(node.owner), liveOwnerMatches(entry),
              AXUIElementSetMessagingTimeout(node.element, 0.08) == .success,
              frame(node.element) == node.frame else { return false }
        var budget = PresentationReadBudget()
        var pending: [(element: AXUIElement, path: [AXUIElement])] = [(node.element, [node.element])]
        var visited: [AXUIElement] = []
        while !pending.isEmpty, visited.count < 48,
              budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline {
            let current = pending.removeFirst()
            if visited.contains(where: { CFEqual($0, current.element) }) { continue }
            visited.append(current.element)
            var pid: pid_t = 0
            guard AXUIElementGetPid(current.element, &pid) == .success,
                  pid == node.owner.identity.pid else { continue }
            let remaining = budget.deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  AXUIElementSetMessagingTimeout(current.element, Float(min(0.08, remaining))) == .success else { return false }
            let identifier = presentationAttribute(current.element, kAXIdentifierAttribute, budget: &budget) as? String
            if identifier == delegate.headerIdentifier {
                // Text and switch may intentionally share this header ID.
                // One positively linked instance suffices; neither names nor
                // the number of windows establishes module attribution.
                var linked = true
                for (parent, child) in zip(current.path, current.path.dropFirst()) {
                    let children = elements(presentationAttribute(parent, kAXChildrenAttribute, budget: &budget))
                    if children.filter({ CFEqual($0, child) }).count != 1 { linked = false; break }
                }
                guard linked, budget.complete, budget.remaining > 0,
                      presentationAttribute(current.element, kAXIdentifierAttribute, budget: &budget) as? String == delegate.headerIdentifier,
                      frame(node.element) == node.frame,
                      livePresentationOwnerMatches(node.owner), liveOwnerMatches(entry),
                      text(entry.element, kAXIdentifierAttribute) == entry.accessibilityIdentifier,
                      ProcessInfo.processInfo.systemUptime < budget.deadline else { return false }
                Self.logger.notice("itemPresentation systemModuleHeaderConfirmed=true depth=\(current.path.count - 1)")
                return true
            }
            guard current.path.count < 7 else { continue }
            let children = elements(presentationAttribute(current.element, kAXChildrenAttribute, budget: &budget))
            guard children.count <= 48, pending.count + children.count <= 96 else { return false }
            pending.append(contentsOf: children.map { ($0, current.path + [$0]) })
        }
        Self.logger.notice("itemPresentation systemModuleHeaderConfirmed=false visited=\(visited.count)")
        return false
    }

    private func liveOwnerMatches(_ entry: Entry) -> Bool {
        liveOwnerMatches(element: entry.element, owner: entry.owner)
    }

    private func liveOwnerMatches(element: AXUIElement, owner: MenuBarOwner) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == owner.pid,
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              running.bundleIdentifier == owner.bundleIdentifier,
              let current = resolvedOwner(MenuBarOwner(pid: pid, bundleIdentifier: running.bundleIdentifier,
                  name: "", launchTime: running.launchDate?.timeIntervalSince1970 ?? 0)) else { return false }
        return current.launchTime == owner.launchTime
    }

    private func presentationAttribute(_ node: AXUIElement, _ name: String,
                                       budget: inout PresentationReadBudget) -> CFTypeRef? {
        guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
            markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
            return nil
        }
        budget.remaining -= 1
        let result = copyAttribute(node, name)
        if result.error != .success && result.error != .attributeUnsupported && result.error != .noValue {
            markPresentationIncomplete("attribute-error", error: result.error, budget: &budget)
        }
        return result.error == .success ? result.value : nil
    }

    private func probePresentations(for entry: Entry, owners: [PresentationOwner]) -> (nodes: [PresentationNode], complete: Bool, authoritativeRoots: Bool) {
        guard !owners.isEmpty else { return ([], false, false) }
        var nodes: [PresentationNode] = []
        var complete = true
        var authoritativeRoots = true
        for owner in owners {
            guard livePresentationOwnerMatches(owner) else { return ([], false, false) }
            let result = probePresentations(for: entry, owner: owner)
            nodes += result.nodes.filter { candidate in
                !nodes.contains(where: { CFEqual($0.element, candidate.element) })
            }
            complete = complete && result.complete
            authoritativeRoots = authoritativeRoots && result.authoritativeRoots
        }
        return (nodes, complete, authoritativeRoots)
    }

    private func probePresentations(for entry: Entry, owner: PresentationOwner) -> (nodes: [PresentationNode], complete: Bool, authoritativeRoots: Bool) {
        var budget = PresentationReadBudget()
        let application = AXUIElementCreateApplication(owner.identity.pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let windowInfo = onscreenWindowInfo()
        var roots: [(AXUIElement, Int)] = []
        if owner.identity.pid == entry.owner.pid {
            for name in [kAXChildrenAttribute, kAXVisibleChildrenAttribute] {
                roots += elements(presentationAttribute(entry.element, name, budget: &budget)).map { ($0, 0) }
            }
        }
        for name in [kAXWindowsAttribute, kAXChildrenAttribute] {
            let value = presentationAttribute(application, name, budget: &budget)
            if let value, CFGetTypeID(value) == CFArrayGetTypeID() { budget.authoritativeRoots = true }
            roots += elements(value).map { ($0, 3) }
        }
        var visited: [AXUIElement] = []
        var nodes: [PresentationNode] = []
        // Core item/application roots always get the budget first. Optional
        // discovery can add evidence but cannot erase already verified roots.
        appendPresentationNodes(from: roots, owner: owner, windowInfo: windowInfo,
            budget: &budget, visited: &visited, nodes: &nodes)
        let coreWindows = nodes.filter { $0.kind == .window }.map(\.element)
        roots.removeAll(keepingCapacity: true)
        // Transient NSMenu trees are not always children of AXApplication or
        // members of AXWindows. Only an actual same-owner AX ancestor becomes
        // a supplemental root; a CG window alone is never menu-open evidence.
        for name in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] {
            budget.source = name == kAXFocusedWindowAttribute ? "focused-window" : "focused-element"
            if let focused = element(presentationAttribute(application, name, budget: &budget)),
               let root = presentationAncestor(from: focused, ownerPID: owner.identity.pid,
                   coreWindows: coreWindows, budget: &budget) {
                roots.append((root, 3))
            }
        }
        budget.source = "system-focused"
        if budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline {
            budget.remaining -= 1
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.08)
            // A system query can resolve to this application's AppKit tree.
            let focused = Self.copyOwnAttributeOnMainThread(system, kAXFocusedUIElementAttribute)
            if focused.error != .success && focused.error != .attributeUnsupported && focused.error != .noValue {
                markPresentationIncomplete("attribute-error", error: focused.error, budget: &budget)
            }
            if let node = element(focused.value),
               let root = presentationAncestor(from: node, ownerPID: owner.identity.pid,
                   coreWindows: coreWindows, budget: &budget) {
                roots.append((root, 3))
            }
        } else {
            markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
        }
        budget.source = "cg-hit"
        let candidates = presentationWindowCandidates(in: windowInfo, ownerPID: owner.identity.pid)
        if candidates.count > 8 { markPresentationIncomplete("candidate-limit", budget: &budget) }
        for candidate in candidates.prefix(8) {
            guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
                break
            }
            budget.remaining -= 1
            let hit = Self.copyElementAtPositionOnMainThread(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
            if hit.error != .success && hit.error != .noValue {
                markPresentationIncomplete("hit-error", error: hit.error, budget: &budget)
            }
            if let node = hit.element,
               let root = presentationAncestor(from: node, ownerPID: owner.identity.pid,
                   coreWindows: coreWindows, budget: &budget) {
                roots.append((root, 3))
            }
        }
        budget.source = "supplemental-root"
        appendPresentationNodes(from: roots, owner: owner, windowInfo: windowInfo,
            budget: &budget, visited: &visited, nodes: &nodes)
        return (nodes, budget.complete, budget.authoritativeRoots)
    }

    private func appendPresentationNodes(from initialRoots: [(AXUIElement, Int)], owner: PresentationOwner,
                                         windowInfo: [[String: Any]]?, budget: inout PresentationReadBudget,
                                         visited: inout [AXUIElement], nodes: inout [PresentationNode]) {
        var roots = initialRoots
        var index = 0
        while index < roots.count {
            guard visited.count < 32, budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                let reason = visited.count >= 32 ? "node-limit" : (budget.remaining <= 0 ? "read-limit" : "deadline")
                markPresentationIncomplete(reason, budget: &budget)
                break
            }
            let (node, depth) = roots[index]
            index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == owner.identity.pid else { continue }
            let role = presentationAttribute(node, kAXRoleAttribute, budget: &budget) as? String
            logPresentationRole(node, role: role, stage: "root", depth: depth, budget: &budget)
            if let role, role == kAXMenuRole || role == kAXWindowRole || role == kAXPopoverRole {
                // Do not descend into menus: submenu closure is not root closure.
                guard let position = presentationAttribute(node, kAXPositionAttribute, budget: &budget),
                      let size = presentationAttribute(node, kAXSizeAttribute, budget: &budget),
                      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
                    budget.complete = false
                    logPresentationGeometrySkip(reason: "attribute-unavailable-or-type", role: role, rect: nil,
                        decodedPosition: false, decodedSize: false, budget: &budget)
                    continue
                }
                var point = CGPoint.zero
                var extent = CGSize.zero
                let decodedPosition = AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point)
                let decodedSize = AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
                guard decodedPosition, decodedSize else {
                    budget.complete = false
                    logPresentationGeometrySkip(reason: "value-decode", role: role, rect: nil,
                        decodedPosition: decodedPosition, decodedSize: decodedSize, budget: &budget)
                    continue
                }
                let rect = CGRect(origin: point, size: extent)
                guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
                    logPresentationGeometrySkip(reason: "nonfinite", role: role, rect: rect,
                        decodedPosition: true, decodedSize: true, budget: &budget)
                    continue
                }
                guard rect.width > 0, rect.height > 0 else {
                    logPresentationGeometrySkip(reason: "empty-size", role: role, rect: rect,
                        decodedPosition: true, decodedSize: true, budget: &budget)
                    continue
                }
                guard presentationFrameIsOnscreen(rect) else {
                    logPresentationGeometrySkip(reason: "offscreen-or-display-unavailable", role: role, rect: rect,
                        decodedPosition: true, decodedSize: true, budget: &budget)
                    continue
                }
                guard !menuBands.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(rect) }) else {
                    logPresentationGeometrySkip(reason: "inside-menu-band", role: role, rect: rect,
                        decodedPosition: true, decodedSize: true, budget: &budget)
                    continue
                }
                let validation = presentationValidation(root: node, owner: owner, frame: rect, budget: &budget)
                nodes.append(PresentationNode(element: node, owner: owner, kind: role == kAXMenuRole ? .menu : .window,
                    originalRole: role, frame: rect, visible: validation != nil, validationPoint: validation?.point,
                    validationElement: validation?.element,
                    backingWindowID: matchingWindowID(in: windowInfo, ownerPID: pid, frame: rect)))
            } else if depth < 3, role != kAXMenuBarRole && role != kAXMenuItemRole {
                roots += elements(presentationAttribute(node, kAXChildrenAttribute, budget: &budget)).map { ($0, depth + 1) }
            }
        }
    }

    /// Verified ControlCenter module roots can contain transparent space.
    /// Only that strictly bound delegate can contribute descendant hit points;
    /// ordinary owners keep their complete, center-only baseline behavior.
    /// CG geometry is not evidence. This path never validates menu-bar clicks.
    private func presentationValidation(root: AXUIElement, owner: PresentationOwner, frame: CGRect,
                                        preferred: PresentationValidation? = nil,
                                        budget: inout PresentationReadBudget) -> PresentationValidation? {
        if let preferred, presentationPointIsInside(preferred.point, frame: frame),
           presentationHitMatches(root: root, source: preferred.element, owner: owner,
               at: preferred.point, budget: &budget) { return preferred }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if preferred?.point != center, presentationPointIsInside(center, frame: frame),
           presentationHitMatches(root: root, source: root, owner: owner, at: center, budget: &budget) {
            return PresentationValidation(point: center, element: root)
        }
        guard owner.identity.bundleIdentifier == SystemModulePresentationIdentity.controlCenterBundleIdentifier,
              owner.requiredBundlePath == SystemModulePresentationIdentity.controlCenterBundlePath else { return nil }
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var index = 0
        let nodeLimit = 16
        let depthLimit = 3
        while index < queue.count {
            // Point-search limits are optional visibility evidence, not
            // incomplete enumeration of the owner's presentation roots.
            guard visited.count < nodeLimit else { return nil }
            guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
                return nil
            }
            let current = queue[index]
            index += 1
            if visited.contains(where: { CFEqual($0, current.element) }) { continue }
            visited.append(current.element)
            budget.remaining -= 1
            var pid: pid_t = 0
            let pidResult = AXUIElementGetPid(current.element, &pid)
            guard pidResult == .success else {
                markPresentationIncomplete("attribute-error", error: pidResult, budget: &budget)
                continue
            }
            guard pid == owner.identity.pid else { continue }
            if current.depth > 0,
               let position = presentationAttribute(current.element, kAXPositionAttribute, budget: &budget),
               let size = presentationAttribute(current.element, kAXSizeAttribute, budget: &budget),
               CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var origin = CGPoint.zero
                var extent = CGSize.zero
                if AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
                   AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
                   [origin.x, origin.y, extent.width, extent.height].allSatisfy(\.isFinite),
                   extent.width > 0, extent.height > 0 {
                    let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
                    if presentationPointIsInside(point, frame: frame),
                       presentationHitMatches(root: root, source: current.element, owner: owner,
                           at: point, budget: &budget) {
                        Self.logger.debug("itemPresentation descendantPointConfirmed=true depth=\(current.depth) visited=\(visited.count)")
                        return PresentationValidation(point: point, element: current.element)
                    }
                }
            }
            guard current.depth < depthLimit else { continue }
            for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute] {
                let children = elements(presentationAttribute(current.element, attribute, budget: &budget))
                for child in children.prefix(nodeLimit) {
                    if queue.contains(where: { CFEqual($0.element, child) }) { continue }
                    guard queue.count < nodeLimit else { break }
                    queue.append((child, current.depth + 1))
                }
            }
        }
        return nil
    }

    private func presentationPointIsInside(_ point: CGPoint, frame: CGRect) -> Bool {
        point.x.isFinite && point.y.isFinite && frame.contains(point) &&
            !menuBands.contains(where: { $0.contains(point) })
    }

    /// Strict CF identity only: neither a matching label/frame nor a same-PID
    /// window is sufficient. AXWindow must name this exact retained root.
    private func presentationHitMatches(root: AXUIElement, source: AXUIElement,
                                        owner: PresentationOwner, at point: CGPoint,
                                        budget: inout PresentationReadBudget) -> Bool {
        guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
            markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
            return false
        }
        budget.remaining -= 1
        let hit = Self.copyElementAtPositionOnMainThread(point)
        if hit.error != .success && hit.error != .noValue {
            markPresentationIncomplete("hit-error", error: hit.error, budget: &budget)
        }
        var current = hit.element
        var visited: [AXUIElement] = []
        for _ in 0..<6 {
            guard let node = current else { return false }
            guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                markPresentationIncomplete(budget.remaining <= 0 ? "read-limit" : "deadline", budget: &budget)
                return false
            }
            if visited.contains(where: { CFEqual($0, node) }) { return false }
            visited.append(node)
            budget.remaining -= 1
            var pid: pid_t = 0
            let pidResult = AXUIElementGetPid(node, &pid)
            guard pidResult == .success else {
                markPresentationIncomplete("attribute-error", error: pidResult, budget: &budget)
                return false
            }
            guard pid == owner.identity.pid else { return false }
            // A retained descendant can be reparented to a different panel.
            // Its identity alone cannot prove this retained root is visible.
            if CFEqual(node, root) { return true }
            if let window = element(presentationAttribute(node, kAXWindowAttribute, budget: &budget)),
               CFEqual(window, root) { return true }
            current = element(presentationAttribute(node, kAXParentAttribute, budget: &budget))
        }
        return false
    }

    private func logPresentationGeometrySkip(reason: String, role: String?, rect: CGRect?,
                                              decodedPosition: Bool, decodedSize: Bool,
                                              budget: inout PresentationReadBudget) {
        guard budget.geometryDiagnosticRemaining > 0 else { return }
        budget.geometryDiagnosticRemaining -= 1
        let reasons: Set<String> = ["attribute-unavailable-or-type", "value-decode", "nonfinite", "empty-size",
            "offscreen-or-display-unavailable", "inside-menu-band"]
        let safeReason = reasons.contains(reason) ? reason : "other"
        let safeRole = role == kAXMenuRole ? "AXMenu" :
            (role == kAXWindowRole ? "AXWindow" : (role == kAXPopoverRole ? "AXPopover" : "other"))
        let geometry = rect.map { String(describing: $0) } ?? "unavailable"
        Self.logger.debug("itemPresentation geometrySkip=\(safeReason, privacy: .public) role=\(safeRole, privacy: .public) decodedPosition=\(decodedPosition) decodedSize=\(decodedSize) frame=\(geometry, privacy: .public)")
    }

    private func presentationAncestor(from element: AXUIElement, ownerPID: pid_t,
                                      coreWindows: [AXUIElement],
                                      budget: inout PresentationReadBudget) -> AXUIElement? {
        var current: AXUIElement? = element
        var visited: [AXUIElement] = []
        var menu: AXUIElement?
        for depth in 0..<6 {
            guard let node = current else { return menu }
            guard !visited.contains(where: { CFEqual($0, node) }) else {
                markPresentationIncomplete("ancestor-cycle", budget: &budget)
                return nil
            }
            visited.append(node)
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == ownerPID else { return menu }
            let role = presentationAttribute(node, kAXRoleAttribute, budget: &budget) as? String
            logPresentationRole(node, role: role, stage: "ancestor", depth: depth, budget: &budget)
            if role == kAXMenuRole { menu = node }
            if role == kAXWindowRole || role == kAXPopoverRole { return menu ?? node }
            if role == kAXApplicationRole || role == kAXMenuBarRole || role == kAXMenuBarItemRole {
                return menu
            }
            current = self.element(presentationAttribute(node, kAXParentAttribute, budget: &budget))
        }
        // Do not mistake a submenu for the root when its chain was truncated.
        if current != nil {
            // AXWindow is Apple's direct containing-window relationship. Only
            // resolve a deep non-menu chain to a window already read by the
            // core scan; never infer this association from PID or geometry.
            if menu == nil, !coreWindows.isEmpty,
               let window = self.element(presentationAttribute(element, kAXWindowAttribute, budget: &budget)),
               coreWindows.contains(where: { CFEqual($0, window) }) {
                var windowPID: pid_t = 0
                if AXUIElementGetPid(window, &windowPID) == .success, windowPID == ownerPID,
                   presentationAttribute(window, kAXRoleAttribute, budget: &budget) as? String == kAXWindowRole {
                    let source = budget.source
                    Self.logger.debug("itemPresentation windowShortcutMatchedCore=true source=\(source, privacy: .public)")
                    return window
                }
            }
            markPresentationIncomplete("ancestor-depth", budget: &budget)
            return nil
        }
        return menu
    }

    private func markPresentationIncomplete(_ reason: String, error: AXError? = nil,
                                            budget: inout PresentationReadBudget) {
        budget.complete = false
        guard budget.incompleteDiagnosticRemaining > 0 else { return }
        budget.incompleteDiagnosticRemaining -= 1
        let reasons: Set<String> = ["read-limit", "deadline", "attribute-error", "candidate-limit", "hit-error",
            "node-limit", "ancestor-cycle", "ancestor-depth"]
        let safeReason = reasons.contains(reason) ? reason : "other"
        let source = budget.source
        let remaining = budget.remaining
        Self.logger.debug("itemPresentation incompleteReason=\(safeReason, privacy: .public) source=\(source, privacy: .public) readsRemaining=\(remaining) axError=\(error?.rawValue ?? 0)")
    }

    private func logPresentationRole(_ node: AXUIElement, role: String?, stage: String, depth: Int,
                                     budget: inout PresentationReadBudget) {
        guard budget.diagnosticRemaining > 0, budget.remaining > 8,
              ProcessInfo.processInfo.systemUptime < budget.deadline - 0.02 else { return }
        budget.diagnosticRemaining -= 1
        budget.remaining -= 1
        // Diagnostics must not turn an unsupported optional subrole into a
        // functional failure, nor emit arbitrary app-provided strings.
        let subrole = copyAttribute(node, kAXSubroleAttribute).value as? String
        let roles: Set<String> = ["AXWindow", "AXMenu", "AXGroup", "AXSheet", "AXDialog", "AXSystemDialog",
            "AXPopover", "AXScrollArea", "AXWebArea", "AXButton", "AXStaticText", "AXMenuItem",
            "AXApplication", "AXMenuBar", "AXMenuBarItem"]
        let subroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXStandardWindow", "AXFloatingWindow",
            "AXSystemFloatingWindow", "AXUnknown"]
        let safeRole = role.map { roles.contains($0) ? $0 : "other" } ?? "missing"
        let safeSubrole = subrole.map { subroles.contains($0) ? $0 : "other" } ?? "missing"
        Self.logger.debug("itemPresentation roleStage=\(stage, privacy: .public) depth=\(depth) role=\(safeRole, privacy: .public) subrole=\(safeSubrole, privacy: .public)")
    }

    private func presentationWindowCandidates(in windows: [[String: Any]]?, ownerPID: pid_t) -> [PresentationWindowCandidate] {
        (windows ?? []).compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  presentationFrameIsOnscreen(rect),
                  !menuBands.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(rect) }),
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha.isFinite, alpha > 0 else { return nil }
            return PresentationWindowCandidate(id: id,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                frame: rect, alpha: alpha)
        }
    }

    private func logUnconfirmedPresentationWindows(owners: [PresentationOwner]) {
        let windows = onscreenWindowInfo()
        for (ownerIndex, owner) in owners.enumerated() {
            let candidates = presentationWindowCandidates(in: windows, ownerPID: owner.identity.pid)
            Self.logger.notice("itemPresentation ownerOrdinal=\(ownerIndex + 1) delegated=\(owner.requiredBundlePath != nil) unconfirmedOwnerWindowCandidates=\(candidates.count) logged=\(min(candidates.count, 8))")
            for (index, candidate) in candidates.prefix(8).enumerated() {
                Self.logger.notice("itemPresentation ownerWindowCandidate=\(index + 1) pid=\(owner.identity.pid) windowID=\(candidate.id) layer=\(candidate.layer) frame=\(String(describing: candidate.frame), privacy: .public) alpha=\(candidate.alpha)")
            }
        }
    }

    private func presentationFrameIsOnscreen(_ rect: CGRect) -> Bool {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    private func onscreenWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    private func matchingWindowID(in windows: [[String: Any]]?, ownerPID: pid_t, frame: CGRect) -> CGWindowID? {
        let matching = (windows ?? []).filter { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { return false }
            return abs(rect.minX - frame.minX) <= 2 && abs(rect.minY - frame.minY) <= 2 &&
                abs(rect.width - frame.width) <= 2 && abs(rect.height - frame.height) <= 2
        }
        guard matching.count == 1 else { return nil }
        return (matching[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    /// A strict, read-only observation of an ordinary item's original AX
    /// center. false means two complete successful hit chains excluded that
    /// object; it is not by itself proof of physical hiding. Failed transport,
    /// incomplete ancestry, stale ownership or geometry all remain unknown.
    func inspectNativeVisibility(id: String) -> Bool? {
        guard AXIsProcessTrusted(), !Task.isCancelled, let entry = entries[id],
              liveOwnerMatches(entry) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        var remaining = 64
        func read(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            let time = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled, remaining > 0, time > 0,
                  AXUIElementSetMessagingTimeout(node, Float(min(0.08, time))) == .success else { return nil }
            remaining -= 1
            let result = copyAttribute(node, attribute)
            guard result.error == .success, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            return result.value
        }
        func originalFrame() -> CGRect? {
            guard let position = read(entry.element, kAXPositionAttribute),
                  let size = read(entry.element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            let pointValue = unsafeDowncast(position, to: AXValue.self)
            let sizeValue = unsafeDowncast(size, to: AXValue.self)
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &extent),
                  [point.x, point.y, extent.width, extent.height].allSatisfy(\.isFinite),
                  extent.width > 0, extent.height > 0, extent.height <= 64 else { return nil }
            let rect = CGRect(origin: point, size: extent)
            guard menuBands.contains(where: { band in
                rect.width <= band.width && rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1 &&
                    band.contains(CGPoint(x: rect.midX, y: rect.midY))
            }) else { return nil }
            return rect
        }
        func sourceInHitAncestry(at point: CGPoint) -> Bool? {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let hit = Self.copyElementAtPositionOnMainThread(point)
            guard hit.error == .success, let first = hit.element else { return nil }
            var node = first
            var visited: [AXUIElement] = []
            for _ in 0..<10 {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                      !visited.contains(where: { CFEqual($0, node) }) else { return nil }
                visited.append(node)
                if CFEqual(node, entry.element) { return true }
                // A known hosted mirror is not a negative source observation.
                // Rebinding it belongs to a fresh scan, never metadata matching.
                if let host = entry.hostPresentation,
                   host.path.contains(where: { CFEqual($0, node) }) { return nil }
                guard let role = read(node, kAXRoleAttribute) as? String else { return nil }
                if role == kAXApplicationRole || role == kAXSystemWideRole { return false }
                guard let parent = element(read(node, kAXParentAttribute)) else { return nil }
                node = parent
            }
            return nil
        }
        guard let role = read(entry.element, kAXRoleAttribute) as? String,
              role == kAXMenuBarItemRole || role == kAXButtonRole,
              let initialFrame = originalFrame() else { return nil }
        let point = CGPoint(x: initialFrame.midX, y: initialFrame.midY)
        guard let first = sourceInHitAncestry(at: point), originalFrame() == initialFrame,
              liveOwnerMatches(entry), let second = sourceInHitAncestry(at: point), first == second,
              originalFrame() == initialFrame,
              read(entry.element, kAXRoleAttribute) as? String == role,
              AXIsProcessTrusted(), liveOwnerMatches(entry), !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return first
    }

    /// The native AirDrop preference recreates its source AX object. Register
    /// only the exact, currently enumerated system identity before managing it.
    /// Later reads keep that identity across disappearance in this owner epoch.
    func nativeSystemVisibilityKey(id: String) -> String? {
        guard AXIsProcessTrusted(), !Task.isCancelled, let entry = entries[id],
              entry.snapshot.ownIdentifier == nil, nativeSystemOwnerIsCurrent(entry.owner) else { return nil }
        let key: String
        if entry.owner.bundleIdentifier == "com.apple.TextInputMenuAgent",
           entry.accessibilityIdentifier == nil, id == inputMenuPersistentID {
            key = "TextInputMenu"
        } else if entry.accessibilityIdentifier == "com.apple.menuextra.airdrop",
                  SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
                      accessibilityIdentifier: entry.accessibilityIdentifier) == "module:AirDrop",
                  MenuItemIdentity.persistentID(bundleIdentifier: entry.owner.bundleIdentifier,
                      accessibilityIdentifier: entry.accessibilityIdentifier, occurrenceCount: 1) == id {
            key = "AirDrop"
        } else { return nil }
        if let registered = nativeSystemVisibilityIdentities[id],
           sameNativeSystemOwner(registered.owner, entry.owner),
           registered.identifier == entry.accessibilityIdentifier, registered.key == key {
            return registered.key
        }
        let identity = NativeSystemVisibilityIdentity(owner: entry.owner,
            identifier: entry.accessibilityIdentifier, key: key)
        guard let matches = try? nativeSystemSources(identity, id: id), matches.count == 1,
              let source = matches.first, CFEqual(source, entry.element),
              liveOwnerMatches(entry) else { return nil }
        nativeSystemVisibilityIdentities[id] = identity
        return identity.key
    }

    /// Absence means hidden only after a complete census of this exact system
    /// host. A replacement source is tested as itself, never as the old object.
    /// Unknown structure, transport, duplicate identities and occlusion are nil.
    func inspectNativeSystemVisibility(id: String, key: String) -> Bool? {
        guard AXIsProcessTrusted(), !Task.isCancelled, ["AirDrop", "TextInputMenu"].contains(key),
              let entry = entries[id], let identity = nativeSystemVisibilityIdentities[id],
              identity.key == key,
              entry.accessibilityIdentifier == identity.identifier,
              sameNativeSystemOwner(identity.owner, entry.owner),
              nativeSystemOwnerIsCurrent(identity.owner),
              let matches = try? nativeSystemSources(identity, id: id), matches.count <= 1 else { return nil }
        guard let source = matches.first else { return false }
        let current = Entry(element: source, owner: identity.owner,
            accessibilityIdentifier: identity.identifier, snapshot: entry.snapshot,
            hostPresentation: nil, hostGeometryUnresolved: true)
        guard nativeSystemSourceIsVisible(current), nativeSystemOwnerIsCurrent(identity.owner),
              AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        return true
    }

    /// Positive-only observation for a system item that remains unmanaged.
    /// Known roleless modules require their strict source/host proof; a failed
    /// observation does not claim that the system item has become hidden.
    func inspectNativeVisibleSystemItem(id: String) -> Bool? {
        guard AXIsProcessTrusted(), !Task.isCancelled, let entry = entries[id],
              entry.owner.bundleIdentifier?.hasPrefix("com.apple.") == true else { return nil }
        if SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil {
            if verifiedRawOriginVisibility(entry, diagnostic: false).centerHit { return true }
            return verifiedSystemModuleVisibility(entry)?.centerHit == true ? true : nil
        }
        return inspectNativeVisibility(id: id) == true ? true : nil
    }

    private func sameNativeSystemOwner(_ lhs: MenuBarOwner, _ rhs: MenuBarOwner) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.launchTime == rhs.launchTime
    }

    private func nativeSystemOwnerIsCurrent(_ owner: MenuBarOwner) -> Bool {
        let path: String
        switch owner.bundleIdentifier {
        case "com.apple.MenuBarAgent": path = "/System/Library/CoreServices/MenuBarAgent.app"
        case "com.apple.TextInputMenuAgent": path = "/System/Library/CoreServices/TextInputMenuAgent.app"
        default: return false
        }
        guard let running = NSRunningApplication(processIdentifier: owner.pid), !running.isTerminated,
              running.bundleURL?.standardizedFileURL.path == path else { return false }
        // Query the live application identity, not the removed item's AX object.
        return liveOwnerMatches(element: AXUIElementCreateApplication(owner.pid), owner: owner)
    }

    private var inputMenuPersistentID: String {
        MenuItemIdentity.systemInputMenuID
    }

    private func verifiedInputMenuPersistentID(owner: MenuBarOwner, element: AXUIElement) -> String? {
        guard owner.bundleIdentifier == "com.apple.TextInputMenuAgent",
              let sources = try? inputMenuSources(owner: owner, id: inputMenuPersistentID),
              sources.count == 1, let source = sources.first, CFEqual(source, element) else { return nil }
        return inputMenuPersistentID
    }

    /// The input host has no AX identifier. Its exact system bundle, process
    /// epoch and twice-enumerated singleton extras root define this identity.
    /// Failure or unsupported reads never count as proof of disappearance.
    private func inputMenuSources(owner: MenuBarOwner, id: String) throws -> [AXUIElement] {
        guard AXIsProcessTrusted(), owner.bundleIdentifier == "com.apple.TextInputMenuAgent",
              nativeSystemOwnerIsCurrent(owner) else {
            throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
        }
        var budget = PositionReadBudget()
        let app = AXUIElementCreateApplication(owner.pid)
        func census() throws -> (root: AXUIElement?, items: [AXUIElement]) {
            let extras = try positionAttribute(app, kAXExtrasMenuBarAttribute, id: id, budget: &budget)
            if extras.error == .noValue { return (nil, []) }
            guard extras.error == .success, let root = element(extras.value),
                  liveOwnerMatches(element: root, owner: owner),
                  try positionAttribute(root, kAXRoleAttribute, id: id, budget: &budget).value as? String == kAXMenuBarRole else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            let children = try positionElementArray(root, attribute: kAXChildrenAttribute, id: id, budget: &budget)
            guard children.count <= 1 else { throw MenuBarPositionBindingError(id: id, reason: .ambiguousSource) }
            for child in children {
                guard liveOwnerMatches(element: child, owner: owner),
                      try positionAttribute(child, kAXRoleAttribute, id: id, budget: &budget).value as? String == kAXMenuBarItemRole else {
                    throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
                }
                let identifier = try positionAttribute(child, kAXIdentifierAttribute, id: id, budget: &budget)
                guard identifier.error == .noValue || identifier.error == .attributeUnsupported else {
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
            }
            return (root, children)
        }
        let first = try census()
        let second = try census()
        let rootsMatch: Bool
        if let lhs = first.root, let rhs = second.root { rootsMatch = CFEqual(lhs, rhs) }
        else { rootsMatch = first.root == nil && second.root == nil }
        var itemsMatch = first.items.count == second.items.count
        for (lhs, rhs) in zip(first.items, second.items) {
            if !CFEqual(lhs, rhs) { itemsMatch = false }
        }
        guard rootsMatch, itemsMatch,
              nativeSystemOwnerIsCurrent(owner), AXIsProcessTrusted(), !Task.isCancelled else {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        return second.items
    }

    private func nativeSystemSources(_ identity: NativeSystemVisibilityIdentity, id: String) throws -> [AXUIElement] {
        if identity.key == "TextInputMenu" {
            guard identity.identifier == nil, id == inputMenuPersistentID else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            return try inputMenuSources(owner: identity.owner, id: id)
        }
        guard AXIsProcessTrusted(), !Task.isCancelled, identity.key == "AirDrop",
              identity.owner.bundleIdentifier == "com.apple.MenuBarAgent",
              identity.identifier == "com.apple.menuextra.airdrop",
              nativeSystemOwnerIsCurrent(identity.owner) else {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        let items = try systemPositionSourceItems(owner: identity.owner, id: id)
        var budget = PositionReadBudget()
        func identifier(of item: AXUIElement) throws -> String? {
            guard liveOwnerMatches(element: item, owner: identity.owner) else {
                throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
            }
            let read = try positionAttribute(item, kAXIdentifierAttribute, id: id, budget: &budget)
            if read.error == .noValue || read.error == .attributeUnsupported { return nil }
            guard read.error == .success, let value = read.value as? String else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            return value
        }
        var observed: [(element: AXUIElement, identifier: String?)] = []
        for item in items { observed.append((item, try identifier(of: item))) }
        for observation in observed {
            guard try identifier(of: observation.element) == observation.identifier else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
        }
        let matches = observed.filter { $0.identifier == identity.identifier }.map(\.element)
        if matches.isEmpty {
            guard nativeSystemOwnerIsCurrent(identity.owner), AXIsProcessTrusted(), !Task.isCancelled else {
                throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
            }
            return []
        }
        // The system module has one canonical extras source and may project
        // another source on each attached display. Only the canonical source
        // drives tray actions. A duplicate within one display remains unsafe.
        let canonicalItems = try systemPositionSourceItems(owner: identity.owner, id: id, includeWindows: false)
        var canonical: [AXUIElement] = []
        for item in canonicalItems {
            if try identifier(of: item) == identity.identifier { canonical.append(item) }
        }
        guard canonical.count == 1, let source = canonical.first else {
            throw MenuBarPositionBindingError(id: id, reason: .ambiguousSource)
        }
        var containsSource = false
        var occupiedBands: Set<Int> = []
        for match in matches {
            if CFEqual(match, source) { containsSource = true }
            if matches.count > 1 {
                guard let rect = frame(match), rect.width > 0, rect.height > 0, rect.height <= 64,
                      let band = menuBands.firstIndex(where: {
                          rect.minY >= $0.minY - 1 && rect.maxY <= $0.maxY + 1 &&
                              $0.contains(CGPoint(x: rect.midX, y: rect.midY))
                      }),
                      occupiedBands.insert(band).inserted else {
                    throw MenuBarPositionBindingError(id: id, reason: .ambiguousSource)
                }
            }
        }
        guard containsSource, AXIsProcessTrusted(), !Task.isCancelled, nativeSystemOwnerIsCurrent(identity.owner) else {
            throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
        }
        return [source]
    }

    /// The caller has just established unique protected identity from a full
    /// census. Require stable positive geometry and repeated exact-object hits.
    private func nativeSystemSourceIsVisible(_ entry: Entry) -> Bool {
        var budget = MirrorReadBudget()
        if let rect = mirrorFrame(entry.element, budget: &budget),
           rect.width > 0, rect.height > 0, rect.height <= 64,
           menuBands.contains(where: { band in
               rect.width <= band.width && rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1 &&
                   band.contains(CGPoint(x: rect.midX, y: rect.midY))
           }) {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let first = Self.copyElementAtPositionOnMainThread(point)
            if first.error == .success, first.element.map({ CFEqual($0, entry.element) }) == true,
               mirrorFrame(entry.element, budget: &budget) == rect {
                let second = Self.copyElementAtPositionOnMainThread(point)
                let identifier = mirrorAttribute(entry.element, kAXIdentifierAttribute, budget: &budget)
                let identifierMatches: Bool
                if entry.owner.bundleIdentifier == "com.apple.TextInputMenuAgent", entry.accessibilityIdentifier == nil {
                    identifierMatches = identifier.error == .noValue || identifier.error == .attributeUnsupported
                } else {
                    identifierMatches = identifier.error == .success && identifier.value as? String == entry.accessibilityIdentifier
                }
                if second.error == .success, second.element.map({ CFEqual($0, entry.element) }) == true,
                   identifierMatches,
                   mirrorFrame(entry.element, budget: &budget) == rect, liveOwnerMatches(entry), budget.isValid {
                    return true
                }
            }
        }
        // A system module can have a zero-sized leaf inside its real host
        // container. Use only the unique subtree of this newly censused source.
        guard let presentation = systemModulePresentation(entry, sourceVerified: true) else { return false }
        let point = CGPoint(x: presentation.frame.midX, y: presentation.frame.midY)
        let first = Self.copyElementAtPositionOnMainThread(point)
        guard first.error == .success, let hit = first.element,
              presentation.path.contains(where: { CFEqual($0, hit) }),
              systemModulePresentationIsCurrent(presentation, entry: entry) else { return false }
        let second = Self.copyElementAtPositionOnMainThread(point)
        guard second.error == .success, let secondHit = second.element, CFEqual(secondHit, hit),
              systemModulePresentationIsCurrent(presentation, entry: entry) else { return false }
        return true
    }

    /// Does not rescan, open overflow, alter layout, or synthesize input.
    func inspectVisibility(id: String) -> MenuBarVisibilityInspection {
        guard let entry = entries[id] else {
            return MenuBarVisibilityInspection(frame: nil, centerHit: false, hasEntry: false)
        }
        guard AXIsProcessTrusted() else {
            systemModuleContinuity.removeAll()
            return MenuBarVisibilityInspection(frame: nil, centerHit: false, hasEntry: true)
        }
        guard let rect = entryFrame(entry) else {
            let raw = verifiedRawOriginVisibility(entry, diagnostic: true)
            return raw.centerHit ? raw : (verifiedSystemModuleVisibility(entry) ?? raw)
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard rect.width > 0, rect.height > 0, center.x.isFinite, center.y.isFinite,
              menuBands.contains(where: { $0.contains(center) }) else {
            return MenuBarVisibilityInspection(frame: rect, centerHit: false, hasEntry: true)
        }
        let hit = sourceMatchesHitTest(entry.element, at: center, context: "visibility-inspection")
        if !hit, let verified = verifiedSystemModuleVisibility(entry) { return verified }
        // The compatibility hit above may accept a metadata-equivalent
        // mirror. A lasting system identity seed requires exact AX identity.
        if hit, strictPositionChallengeHit(entry, frame: rect), entryFrame(entry) == rect,
           strictPositionChallengeHit(entry, frame: rect) {
            recordVisibleSystemModule(entry)
        }
        return MenuBarVisibilityInspection(frame: rect, centerHit: hit, hasEntry: true)
    }

    /// A stale remote-host projection cannot invalidate an independent direct
    /// hit on the original AX object. This proves only positive visibility for
    /// this observation; a failed query remains unknown and never means hidden.
    private func verifiedRawOriginVisibility(_ entry: Entry, diagnostic: Bool) -> MenuBarVisibilityInspection {
        let raw = frame(entry.element)
        let roleRead = copyAttribute(entry.element, kAXRoleAttribute)
        let role = roleRead.value as? String
        let isItemRole = roleRead.error == .success && (role == kAXMenuBarItemRole || role == kAXButtonRole)
        var isVerifiedRolelessModule = false
        if roleRead.error == .noValue { isVerifiedRolelessModule = verifiedSystemModuleSource(entry) }
        let ownerCurrent = liveOwnerMatches(entry)
        var strictHit = false
        var frameStable = false
        var verified = false
        if AXIsProcessTrusted(), !Task.isCancelled, ownerCurrent, isItemRole || isVerifiedRolelessModule, let raw,
           [raw.origin.x, raw.origin.y, raw.size.width, raw.size.height].allSatisfy(\.isFinite),
           raw.size.width > 0, raw.size.height > 0, raw.height <= 64,
           menuBands.contains(where: { band in
               raw.width <= band.width && raw.minY >= band.minY - 1 && raw.maxY <= band.maxY + 1 &&
                   band.contains(CGPoint(x: raw.midX, y: raw.midY))
           }) {
            let point = CGPoint(x: raw.midX, y: raw.midY)
            let first = Self.copyElementAtPositionOnMainThread(point)
            if first.error == .success, let firstHit = first.element {
                strictHit = CFEqual(firstHit, entry.element)
            }
            if strictHit {
                if frame(entry.element) == raw { frameStable = liveOwnerMatches(entry) }
                if frameStable {
                    let second = Self.copyElementAtPositionOnMainThread(point)
                    if second.error == .success, let secondHit = second.element, CFEqual(secondHit, entry.element),
                       frame(entry.element) == raw, liveOwnerMatches(entry), !Task.isCancelled {
                        verified = true
                    }
                }
            }
        }
        if diagnostic {
            let rawDescription = raw.map(NSStringFromRect) ?? "unavailable"
            Self.logger.notice("visibilityOriginFallback hostUnresolved=\(entry.hostGeometryUnresolved) bindingPresent=\(entry.hostPresentation != nil) rawFrame=\(rawDescription, privacy: .public) rawRoleIsMenuItemOrButton=\(isItemRole) verifiedRolelessModule=\(isVerifiedRolelessModule) ownerCurrent=\(ownerCurrent) rawCenterStrictCFEqualHit=\(strictHit) rawFrameStable=\(frameStable) positiveVerified=\(verified)")
        }
        if verified { recordVisibleSystemModule(entry) }
        return MenuBarVisibilityInspection(frame: verified ? raw : nil, centerHit: verified, hasEntry: true)
    }

    private struct SystemModulePresentation {
        let windows: [AXUIElement]
        let window: AXUIElement
        let path: [AXUIElement]
        let frame: CGRect
        let windowFrame: CGRect
        let branches: [(parent: AXUIElement, children: [AXUIElement])]
    }

    /// An absent source is accepted only from a previously visible original.
    /// Every use repeats the live identity and complete no-conflict census.
    private func verifiedSystemModuleSource(_ entry: Entry) -> Bool {
        guard AXIsProcessTrusted() else { systemModuleContinuity.removeAll(); return false }
        guard !Task.isCancelled,
              SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
                  accessibilityIdentifier: entry.accessibilityIdentifier) != nil else { return false }
        do {
            let items = try systemPositionSourceItems(owner: entry.owner, id: entry.snapshot.id)
            return try checkSystemModuleContinuity(entry, sourceItems: items) != .unconfirmed
        } catch { return false }
    }

    /// Read-only preflight before hiding a new system item behind an existing
    /// blocker. Bootstrap may obtain this proof during its later visible stage.
    /// A compatibility center hit is insufficient: only the strict visibility
    /// paths inside inspectVisibility can establish the required seed.
    func ensureSystemModuleContinuityBeforeHiding(id: String) throws {
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard let entry = entries[id] else { throw MenuBarPositionBindingError(id: id, reason: .missingEntry) }
        guard SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil else { return }
        guard AXIsProcessTrusted() else {
            systemModuleContinuity.removeAll()
            throw MenuBarPositionBindingError(id: id, reason: .permission)
        }
        if systemModuleContinuity[id] == nil { _ = inspectVisibility(id: id) }
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard systemModuleContinuity[id] != nil else {
            throw MenuBarPositionBindingError(id: id, reason: .visibilityUnconfirmed)
        }
        let items = try systemPositionSourceItems(owner: entry.owner, id: id)
        _ = try checkSystemModuleContinuity(entry, sourceItems: items)
    }

    /// Called only after this original or its strictly bound presentation
    /// passed an actual current center hit. A missing census cannot arm a seed.
    private func recordVisibleSystemModule(_ entry: Entry) {
        guard SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil else { return }
        do {
            let items = try systemPositionSourceItems(owner: entry.owner, id: entry.snapshot.id)
            _ = try checkSystemModuleContinuity(entry, sourceItems: items, visiblyConfirmed: true)
        } catch {
            Self.logger.notice("systemModuleContinuity visibleSeedConfirmed=false stage=read-unconfirmed")
        }
    }

    private func checkSystemModuleContinuity(_ entry: Entry, sourceItems: [AXUIElement],
        visiblyConfirmed: Bool = false) throws -> SystemModuleContinuityPolicy.Observation {
        let id = entry.snapshot.id
        guard AXIsProcessTrusted() else {
            systemModuleContinuity.removeAll()
            throw MenuBarPositionBindingError(id: id, reason: .permission)
        }
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard let identifier = entry.accessibilityIdentifier,
              SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
                  accessibilityIdentifier: identifier) != nil else {
            systemModuleContinuity.removeValue(forKey: id)
            throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
        }
        let seed = systemModuleContinuity[id]
        guard liveOwnerMatches(entry), seed.map({
            CFEqual($0.element, entry.element) && $0.identifier == identifier &&
                $0.owner.pid == entry.owner.pid && $0.owner.launchTime == entry.owner.launchTime &&
                $0.owner.bundleIdentifier == entry.owner.bundleIdentifier
        }) != false else {
            systemModuleContinuity.removeValue(forKey: id)
            Self.logger.notice("systemModuleContinuity accepted=false stage=original-or-owner")
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        var budget = PositionReadBudget()
        func liveRole() throws -> String? {
            let identifierRead = try positionAttribute(entry.element, kAXIdentifierAttribute, id: id, budget: &budget)
            guard identifierRead.error == .success, let current = identifierRead.value as? String else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            guard current == identifier else {
                systemModuleContinuity.removeValue(forKey: id)
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            let roleRead = try positionAttribute(entry.element, kAXRoleAttribute, id: id, budget: &budget)
            if roleRead.error == .noValue { return nil } // Exact known macOS 27 module leaf.
            guard roleRead.error == .success, let role = roleRead.value as? String else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            guard role == kAXMenuBarItemRole || role == kAXButtonRole else {
                systemModuleContinuity.removeValue(forKey: id)
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            return role
        }
        let role = try liveRole()
        guard seed == nil || seed?.role == role else {
            systemModuleContinuity.removeValue(forKey: id)
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        let originalCount = sourceItems.filter { CFEqual($0, entry.element) }.count
        var identifierMatches: [AXUIElement] = []
        for item in sourceItems {
            let read = try positionAttribute(item, kAXIdentifierAttribute, id: id, budget: &budget)
            if read.error == .noValue || read.error == .attributeUnsupported { continue }
            guard read.error == .success, let value = read.value as? String else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            if value == identifier { identifierMatches.append(item) }
        }
        guard try liveRole() == role, liveOwnerMatches(entry) else {
            systemModuleContinuity.removeValue(forKey: id)
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        var policy = seed?.policy ?? SystemModuleContinuityPolicy()
        let result = policy.observe(identityCurrent: true, completeCensus: true,
            originalMatchCount: originalCount, identifierMatchCount: identifierMatches.count,
            identifierMatchesOriginal: identifierMatches.first.map { CFEqual($0, entry.element) } == true,
            visiblyConfirmed: visiblyConfirmed)
        Self.logger.notice("systemModuleContinuity sourceCFMatchCount=\(originalCount) identifierMatchCount=\(identifierMatches.count) visibleCheck=\(visiblyConfirmed) seeded=\(policy.hasVisibleSeed) retained=\(result == .retained) accepted=\(result != .unconfirmed)")
        guard result != .unconfirmed else {
            if !policy.hasVisibleSeed { systemModuleContinuity.removeValue(forKey: id) }
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        if policy.hasVisibleSeed {
            // The allowlist has four module identifiers. Retain one exact
            // original per identifier, with no timer-based identity expiry.
            systemModuleContinuity = systemModuleContinuity.filter {
                $0.key == id || $0.value.identifier != identifier
            }
            systemModuleContinuity[id] = SystemModuleContinuitySeed(element: entry.element,
                owner: entry.owner, identifier: identifier, role: role, policy: policy)
        }
        return result
    }

    /// System modules share their owner's PID with the host container, unlike
    /// remote app items. Prove a unique original-object subtree instead of
    /// applying the foreign-child mirror rule or matching image coordinates.
    private func systemModulePresentation(_ entry: Entry, sourceVerified: Bool = false) -> SystemModulePresentation? {
        if !sourceVerified {
            guard verifiedSystemModuleSource(entry) else { return nil }
        }
        guard !menuBands.isEmpty else { return nil }
        do {
            var budget = PositionReadBudget()
            let id = entry.snapshot.id
            let application = AXUIElementCreateApplication(entry.owner.pid)
            let windows = try positionElementArray(application, attribute: kAXWindowsAttribute, id: id, budget: &budget)
            guard windows.count <= 32 else { return nil }
            var matches: [SystemModulePresentation] = []
            for window in windows {
                let role = try positionAttribute(window, kAXRoleAttribute, id: id, budget: &budget)
                guard role.error == .success, role.value as? String == kAXWindowRole,
                      liveOwnerMatches(element: window, owner: entry.owner), let windowFrame = frame(window),
                      windowFrame.width > 0, windowFrame.height > 0,
                      let band = menuBands.first(where: {
                          windowFrame.minY >= $0.minY - 1 && windowFrame.maxY <= $0.maxY + 1 &&
                              $0.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY))
                      }) else { continue }
                let containers = try positionElementArray(window, attribute: kAXChildrenAttribute, id: id, budget: &budget)
                for container in containers {
                    var pending: [(node: AXUIElement, path: [AXUIElement])] = [(container, [container])]
                    var visited: [AXUIElement] = []
                    var terminals: [AXUIElement] = []
                    var targetPaths: [[AXUIElement]] = []
                    var branches: [(parent: AXUIElement, children: [AXUIElement])] = [(window, containers)]
                    while let next = pending.popLast() {
                        guard next.path.count <= 6, visited.count < 128,
                              !visited.contains(where: { CFEqual($0, next.node) }) else { return nil }
                        visited.append(next.node)
                        if CFEqual(next.node, entry.element) {
                            terminals.append(next.node)
                            targetPaths.append(next.path)
                            continue
                        }
                        let nodeRole = try positionAttribute(next.node, kAXRoleAttribute, id: id, budget: &budget)
                        let value = nodeRole.value as? String
                        guard nodeRole.error == .noValue || (nodeRole.error == .success && value != nil) else { return nil }
                        var pid: pid_t = 0
                        guard AXUIElementGetPid(next.node, &pid) == .success, pid > 0 else { return nil }
                        if value == kAXMenuBarItemRole || value == kAXButtonRole || value == kAXMenuRole || value == kAXMenuItemRole {
                            terminals.append(next.node)
                            continue
                        }
                        if pid != entry.owner.pid {
                            guard value == kAXApplicationRole, CFEqual(next.node, AXUIElementCreateApplication(pid)) else { return nil }
                            terminals.append(next.node)
                            continue
                        }
                        guard nodeRole.error == .noValue || value == kAXGroupRole || value == kAXMenuBarRole else { return nil }
                        let children = try positionElementArray(next.node, attribute: kAXChildrenAttribute, id: id, budget: &budget)
                        branches.append((next.node, children))
                        pending.append(contentsOf: children.map { ($0, next.path + [$0]) })
                    }
                    guard !targetPaths.isEmpty else { continue }
                    guard targetPaths.count == 1, let path = targetPaths.first, path.count >= 2,
                          terminals.count == 1, CFEqual(terminals[0], entry.element),
                          liveOwnerMatches(element: container, owner: entry.owner), let rect = frame(container),
                          [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                          rect.width > 0, rect.width <= 120, rect.height > 0,
                          rect.minY >= band.minY - 1, rect.maxY <= band.maxY + 1,
                          band.contains(CGPoint(x: rect.midX, y: rect.midY)),
                          validHostWindowFrame(windowFrame, containing: rect) else { return nil }
                    matches.append(SystemModulePresentation(windows: windows, window: window,
                        path: path, frame: rect, windowFrame: windowFrame, branches: branches))
                }
            }
            guard matches.count == 1, let match = matches.first,
                  systemModulePresentationIsCurrent(match, entry: entry) else { return nil }
            return match
        } catch { return nil }
    }

    private func systemModulePresentationIsCurrent(_ presentation: SystemModulePresentation, entry: Entry) -> Bool {
        guard AXIsProcessTrusted(), !Task.isCancelled, liveOwnerMatches(entry),
              let container = presentation.path.first,
              frame(container) == presentation.frame, frame(presentation.window) == presentation.windowFrame else { return false }
        do {
            var budget = PositionReadBudget()
            let id = entry.snapshot.id
            let current = try positionElementArray(AXUIElementCreateApplication(entry.owner.pid),
                attribute: kAXWindowsAttribute, id: id, budget: &budget)
            guard current.count == presentation.windows.count,
                  presentation.windows.allSatisfy({ old in current.contains(where: { CFEqual($0, old) }) }) else { return false }
            for branch in presentation.branches {
                let children = try positionElementArray(branch.parent, attribute: kAXChildrenAttribute, id: id, budget: &budget)
                guard children.count == branch.children.count,
                      branch.children.allSatisfy({ old in children.contains(where: { CFEqual($0, old) }) }) else { return false }
            }
            let identifier = try positionAttribute(entry.element, kAXIdentifierAttribute, id: id, budget: &budget)
            guard identifier.error == .success, identifier.value as? String == entry.accessibilityIdentifier,
                  liveOwnerMatches(entry), frame(container) == presentation.frame,
                  frame(presentation.window) == presentation.windowFrame, !Task.isCancelled else { return false }
            return true
        } catch { return false }
    }

    private func verifiedSystemModuleVisibility(_ entry: Entry) -> MenuBarVisibilityInspection? {
        guard SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil else { return nil }
        guard let presentation = systemModulePresentation(entry) else {
            Self.logger.notice("systemModuleVisibility positiveVerified=false stage=source-path")
            return nil
        }
        let point = CGPoint(x: presentation.frame.midX, y: presentation.frame.midY)
        let first = Self.copyElementAtPositionOnMainThread(point)
        guard first.error == .success, let hit = first.element,
              presentation.path.contains(where: { CFEqual($0, hit) }),
              systemModulePresentationIsCurrent(presentation, entry: entry) else {
            Self.logger.notice("systemModuleVisibility positiveVerified=false stage=exact-path-hit")
            return nil
        }
        let second = Self.copyElementAtPositionOnMainThread(point)
        guard second.error == .success, let repeated = second.element, CFEqual(repeated, hit),
              systemModulePresentationIsCurrent(presentation, entry: entry) else { return nil }
        recordVisibleSystemModule(entry)
        Self.logger.notice("systemModuleVisibility positiveVerified=true sourcePathVerified=true hitRepeated=true")
        return MenuBarVisibilityInspection(frame: presentation.frame, centerHit: true, hasEntry: true)
    }

    /// An actual status-item hit can identify a different verified host item.
    /// Never infer hiding from a same-PID frame or from the host window itself.
    private func verifiedOtherHostItemOccupies(point: CGPoint, hit: AXUIElement, excluding source: Entry) -> Bool {
        let role = copyAttribute(hit, kAXRoleAttribute)
        guard role.error == .success, let hitRole = role.value as? String,
              hitRole == kAXButtonRole || hitRole == kAXMenuBarItemRole,
              let band = menuBands.first(where: { $0.contains(point) }), !CFEqual(hit, source.element),
              source.hostPresentation?.path.contains(where: { CFEqual($0, hit) }) != true else { return false }
        let candidates = entries.values.filter { other in
            guard !CFEqual(other.element, source.element), let host = other.hostPresentation,
                  (CFEqual(other.element, hit) || host.path.contains(where: { CFEqual($0, hit) })),
                  !host.path.contains(where: { CFEqual($0, source.element) }) else { return false }
            if let sourceHost = source.hostPresentation,
               sourceHost.path.contains(where: { node in host.path.contains(where: { CFEqual($0, node) }) }) { return false }
            return true
        }
        // The system hit may return the original AXMenuBarItem instead of its
        // separate hosted AXButton. Exact original identity is eligible, but
        // still needs the same live strict host mapping and repeated geometry.
        // Duplicate entries or shared containers are ambiguous even if only one
        // currently yields geometry; never filter ambiguity away by its frame.
        guard candidates.count == 1, let other = candidates.first, let host = other.hostPresentation else {
            Self.logger.notice("positionHiddenInspection otherHostItemVerified=false stage=other-host-candidates count=\(candidates.count)")
            return false
        }
        var budget = MirrorReadBudget()
        guard let rect = currentHostFrame(host, original: other.element, owner: other.owner,
            identifier: other.accessibilityIdentifier, budget: &budget), rect.contains(point),
              rect.minY >= band.minY - 1, rect.maxY <= band.maxY + 1,
              liveOwnerMatches(source) else {
            Self.logger.notice("positionHiddenInspection otherHostItemVerified=false stage=other-host-geometry")
            return false
        }
        let repeated = Self.copyElementAtPositionOnMainThread(point)
        guard repeated.error == .success, let current = repeated.element, CFEqual(current, hit),
              currentHostFrame(host, original: other.element, owner: other.owner,
                  identifier: other.accessibilityIdentifier, budget: &budget) == rect,
              liveOwnerMatches(source), !Task.isCancelled else {
            Self.logger.notice("positionHiddenInspection otherHostItemVerified=false stage=other-host-recheck")
            return false
        }
        let originalCF = CFEqual(other.element, hit)
        let hostPath = host.path.contains(where: { CFEqual($0, hit) })
        Self.logger.notice("positionHiddenInspection otherHostItemVerified=true candidateUnique=true hitRepeated=true originalCF=\(originalCF) hostPath=\(hostPath)")
        return true
    }

    /// macOS 27 reports the full-width main menu bar as an AXWindow. This
    /// narrowly verifies that real native root, rather than treating every
    /// window as either proof of hiding or ordinary application occlusion.
    /// The caller must already have proven this operation's visible -> hidden
    /// transition and exact hidden preference readback; failed reveal cleanup
    /// must not opt in merely because the source no longer receives a hit.
    private func verifiedMainMenuBarWindowOccupies(point: CGPoint, hitPath: [AXUIElement],
        excluding source: Entry, callerVerifiedTransition: Bool) -> Bool {
        guard AXIsProcessTrusted(), !Task.isCancelled, !hitPath.isEmpty, hitPath.count <= 8,
              let window = hitPath.last, let band = menuBands.first(where: { $0.contains(point) }) else { return false }
        var windowPID: pid_t = 0
        let pidResult = AXUIElementGetPid(window, &windowPID)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").filter {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app"
        }
        let ownerMatches = pidResult == .success && applications.count == 1 &&
            applications.first?.processIdentifier == windowPID
        let rawFrame = frame(window)
        let frameDescription = rawFrame.map(NSStringFromRect) ?? "unavailable"
        Self.logger.notice("positionHiddenHostWindow callerVerifiedTransition=\(callerVerifiedTransition) canonicalHostOwner=\(ownerMatches) depth=\(hitPath.count - 1) frame=\(frameDescription, privacy: .public)")
        guard callerVerifiedTransition, ownerMatches, let application = applications.first,
              let launchTime = MenuBarProcessIdentity.launchTime(for: application),
              let windowFrame = rawFrame,
              [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height].allSatisfy(\.isFinite),
              windowFrame.width > 0, windowFrame.height > 0,
              abs(windowFrame.minX - band.minX) <= 1, abs(windowFrame.maxX - band.maxX) <= 1,
              abs(windowFrame.minY - band.minY) <= 1, abs(windowFrame.maxY - band.maxY) <= 1,
              windowFrame.contains(point), liveOwnerMatches(source) else { return false }
        let owner = MenuBarOwner(pid: windowPID, bundleIdentifier: application.bundleIdentifier,
            name: "", launchTime: launchTime)
        let root = AXUIElementCreateApplication(windowPID)
        var budget = PositionReadBudget()
        do {
            // Every source/mirror path node remains excluded even when the
            // system reports its ancestor as the shared menu-bar root.
            for node in hitPath.dropLast() {
                guard !CFEqual(node, source.element),
                      source.hostPresentation?.path.contains(where: { CFEqual($0, node) }) != true else {
                    Self.logger.notice("positionHiddenHostWindow verified=false stage=source-path-hit")
                    return false
                }
            }
            func validateRootAndPath() throws -> Bool {
                let windows = try positionElementArray(root, attribute: kAXWindowsAttribute,
                    id: source.snapshot.id, budget: &budget)
                guard windows.count <= 32, windows.filter({ CFEqual($0, window) }).count == 1,
                      liveOwnerMatches(element: window, owner: owner), frame(window) == windowFrame else { return false }
                let rootRole = try positionAttribute(window, kAXRoleAttribute, id: source.snapshot.id, budget: &budget)
                let rootParent = try positionAttribute(window, kAXParentAttribute, id: source.snapshot.id, budget: &budget)
                guard rootRole.error == .success, rootRole.value as? String == kAXWindowRole,
                      rootParent.error == .success, let parent = element(rootParent.value), CFEqual(parent, root) else { return false }
                var seen: [AXUIElement] = []
                for index in hitPath.indices {
                    let node = hitPath[index]
                    guard !seen.contains(where: { CFEqual($0, node) }),
                          liveOwnerMatches(element: node, owner: owner) else { return false }
                    seen.append(node)
                    let role = try positionAttribute(node, kAXRoleAttribute, id: source.snapshot.id, budget: &budget)
                    guard role.error == .success, let value = role.value as? String else { return false }
                    if index == hitPath.count - 1 { guard value == kAXWindowRole else { return false }; continue }
                    guard [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole, kAXImageRole, kAXStaticTextRole].contains(value) else { return false }
                    let expectedParent = hitPath[index + 1]
                    let parent = try positionAttribute(node, kAXParentAttribute, id: source.snapshot.id, budget: &budget)
                    guard parent.error == .success, let currentParent = element(parent.value),
                          CFEqual(currentParent, expectedParent) else { return false }
                    let children = try positionElementArray(expectedParent, attribute: kAXChildrenAttribute,
                        id: source.snapshot.id, budget: &budget)
                    guard children.filter({ CFEqual($0, node) }).count == 1 else { return false }
                }
                return liveOwnerMatches(element: window, owner: owner) && frame(window) == windowFrame &&
                    liveOwnerMatches(source) && !Task.isCancelled
            }
            guard try validateRootAndPath() else {
                Self.logger.notice("positionHiddenHostWindow verified=false stage=root-or-path")
                return false
            }
            let repeated = Self.copyElementAtPositionOnMainThread(point)
            guard repeated.error == .success, let hit = repeated.element, CFEqual(hit, hitPath[0]),
                  try validateRootAndPath() else {
                Self.logger.notice("positionHiddenHostWindow verified=false stage=repeat")
                return false
            }
            Self.logger.notice("positionHiddenHostWindow verified=true canonicalRoot=true currentWindow=true completeHitPath=true hitRepeated=true")
            return true
        } catch {
            Self.logger.notice("positionHiddenHostWindow verified=false stage=read-budget-or-error")
            return false
        }
    }

    /// true: another verified main-menu-bar element occupies the source's raw
    /// position; false: this source or its verified mirror is still hit. AX
    /// failures, stale identities, popups and window occlusion remain unknown.
    /// This observes a prepared move; it does not infer hiding from its weight.
    func inspectPositionHidden(candidate: MenuBarPositionCandidate,
                               allowVerifiedHostWindow: Bool = false) -> Bool? {
        guard AXIsProcessTrusted(), !Task.isCancelled else {
            return positionHiddenInspectionResult(nil, stage: "access-unavailable")
        }
        guard let binding = positionCandidateBindings[candidate.token],
              binding.expiresAt > ProcessInfo.processInfo.systemUptime,
              binding.candidate.id == candidate.id, binding.candidate.key == candidate.key,
              binding.owner.pid == candidate.processIdentifier,
              binding.owner.launchTime == candidate.launchTime,
              binding.owner.bundleIdentifier == candidate.bundleIdentifier else {
            return positionHiddenInspectionResult(nil, stage: "binding-unavailable")
        }
        guard let entry = entries[candidate.id], CFEqual(entry.element, binding.element),
              entry.owner.pid == binding.owner.pid, entry.owner.launchTime == binding.owner.launchTime,
              entry.owner.bundleIdentifier == binding.owner.bundleIdentifier else {
            return positionHiddenInspectionResult(nil, stage: "source-identity")
        }
        guard liveOwnerMatches(entry) else {
            return positionHiddenInspectionResult(nil, stage: "source-owner")
        }
        guard let sourceFrame = frame(entry.element), sourceFrame.width > 0, sourceFrame.height > 0,
              let band = menuBands.first(where: { $0.contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)) }),
              sourceFrame.minY >= band.minY - 1, sourceFrame.maxY <= band.maxY + 1,
              sourceFrame.width <= band.width else {
            return positionHiddenInspectionResult(nil, stage: "source-frame")
        }
        let point = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        guard point.x.isFinite, point.y.isFinite, band.contains(point) else {
            return positionHiddenInspectionResult(nil, stage: "source-point")
        }
        let sourceRole = copyAttribute(entry.element, kAXRoleAttribute)
        let role = sourceRole.value as? String
        let sourceRoleAccepted = sourceRole.error == .success && (role == kAXMenuBarItemRole || role == kAXButtonRole)
        let systemModule = SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil
        guard (systemModule ? verifiedSystemModuleSource(entry) : sourceRoleAccepted) else {
            return positionHiddenInspectionResult(nil, stage: "source-role",
                role: sourceRole.value as? String, axError: sourceRole.error)
        }
        let query = Self.copyElementAtPositionOnMainThread(point)
        guard query.error == .success, let firstHit = query.element else {
            return positionHiddenInspectionResult(nil, stage: "hit-query", axError: query.error)
        }
        if verifiedOtherHostItemOccupies(point: point, hit: firstHit, excluding: entry) {
            return finishPositionHiddenInspection(true, entry: entry, sourceFrame: sourceFrame, hit: firstHit)
        }
        var budget = PositionReadBudget()
        var visited: [AXUIElement] = []
        var current: AXUIElement? = firstHit
        var hasMenuBarItem = false
        for depth in 0..<8 {
            guard let node = current, !visited.contains(where: { CFEqual($0, node) }) else {
                return positionHiddenInspectionResult(nil, stage: "hit-lineage", depth: depth)
            }
            guard let read = try? positionAttribute(node, kAXRoleAttribute, id: candidate.id, budget: &budget) else {
                return positionHiddenInspectionResult(nil, stage: "hit-role-budget", depth: depth)
            }
            guard read.error == .success, let nodeRole = read.value as? String else {
                return positionHiddenInspectionResult(nil, stage: "hit-role", depth: depth, axError: read.error)
            }
            visited.append(node)
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid > 0 else {
                return positionHiddenInspectionResult(nil, stage: "hit-owner", depth: depth, role: nodeRole)
            }
            if nodeRole == kAXWindowRole {
                if verifiedMainMenuBarWindowOccupies(point: point, hitPath: visited, excluding: entry,
                    callerVerifiedTransition: allowVerifiedHostWindow) {
                    return finishPositionHiddenInspection(true, entry: entry, sourceFrame: sourceFrame, hit: firstHit)
                }
                return positionHiddenInspectionResult(nil, stage: "occluding-role", depth: depth, role: nodeRole)
            }
            if nodeRole == kAXMenuRole || nodeRole == kAXMenuItemRole {
                return positionHiddenInspectionResult(nil, stage: "occluding-role", depth: depth, role: nodeRole)
            }
            if CFEqual(node, entry.element) {
                return finishPositionHiddenInspection(false, entry: entry, sourceFrame: sourceFrame, hit: firstHit)
            }
            if let host = entry.hostPresentation, host.path.contains(where: { CFEqual($0, node) }) {
                var mirrorBudget = MirrorReadBudget()
                guard let rect = currentHostFrame(host, original: entry.element, owner: entry.owner,
                    identifier: entry.accessibilityIdentifier, budget: &mirrorBudget), rect.contains(point) else {
                    return positionHiddenInspectionResult(nil, stage: "mirror-unconfirmed", depth: depth, role: nodeRole)
                }
                return finishPositionHiddenInspection(false, entry: entry, sourceFrame: sourceFrame, hit: firstHit)
            }
            if nodeRole == kAXMenuBarRole {
                guard depth == 0 || hasMenuBarItem,
                      let rect = frame(node), rect.width > 0, rect.height > 0, rect.contains(point),
                      rect.minY >= band.minY - 1, rect.maxY <= band.maxY + 1 else {
                    return positionHiddenInspectionResult(nil, stage: "menubar-geometry", depth: depth, role: nodeRole)
                }
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    return positionHiddenInspectionResult(nil, stage: "menubar-owner", depth: depth)
                }
                // A role string alone is insufficient: prove this is the
                // currently exposed main/extras menu bar, not a popup subtree.
                let application = AXUIElementCreateApplication(pid)
                var isCurrentRoot = false
                for attribute in [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute] {
                    guard let root = try? positionAttribute(application, attribute, id: candidate.id, budget: &budget) else {
                        return positionHiddenInspectionResult(nil, stage: "menubar-root-budget", depth: depth)
                    }
                    if root.error == .success, let rootElement = element(root.value), CFEqual(rootElement, node) {
                        isCurrentRoot = true
                        break
                    }
                    guard root.error == .success || root.error == .noValue || root.error == .attributeUnsupported else {
                        return positionHiddenInspectionResult(nil, stage: "menubar-root-read", depth: depth, axError: root.error)
                    }
                }
                guard isCurrentRoot, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                    return positionHiddenInspectionResult(nil, stage: "menubar-root-unconfirmed", depth: depth)
                }
                return finishPositionHiddenInspection(true, entry: entry, sourceFrame: sourceFrame, hit: firstHit)
            }
            if nodeRole == kAXMenuBarItemRole || nodeRole == kAXButtonRole { hasMenuBarItem = true }
            guard [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole, kAXImageRole, kAXStaticTextRole].contains(nodeRole) else {
                return positionHiddenInspectionResult(nil, stage: "unsupported-hit-role", depth: depth, role: nodeRole)
            }
            guard let parent = try? positionAttribute(node, kAXParentAttribute, id: candidate.id, budget: &budget) else {
                return positionHiddenInspectionResult(nil, stage: "hit-parent-budget", depth: depth, role: nodeRole)
            }
            guard parent.error == .success, let next = element(parent.value) else {
                return positionHiddenInspectionResult(nil, stage: "hit-parent-read", depth: depth,
                    role: nodeRole, axError: parent.error)
            }
            current = next
        }
        return positionHiddenInspectionResult(nil, stage: "hit-depth-limit", depth: visited.count)
    }

    private func finishPositionHiddenInspection(_ hidden: Bool, entry: Entry, sourceFrame: CGRect,
                                                hit: AXUIElement) -> Bool? {
        guard AXIsProcessTrusted(), !Task.isCancelled, liveOwnerMatches(entry),
              frame(entry.element) == sourceFrame else {
            return positionHiddenInspectionResult(nil, stage: "source-recheck")
        }
        let query = Self.copyElementAtPositionOnMainThread(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))
        guard query.error == .success, let current = query.element, CFEqual(current, hit),
              liveOwnerMatches(entry), !Task.isCancelled else {
            return positionHiddenInspectionResult(nil, stage: "hit-recheck", axError: query.error)
        }
        return positionHiddenInspectionResult(hidden, stage: "confirmed")
    }

    /// Structural diagnostics only: no third-party names, IDs, titles, labels,
    /// preference keys or unfiltered AX strings enter these messages.
    private func positionHiddenInspectionResult(_ result: Bool?, stage: String, depth: Int = -1,
                                                role: String? = nil, axError: AXError? = nil) -> Bool? {
        let outcome = result.map { $0 ? "hidden" : "visible" } ?? "unknown"
        let safeRole = role.map(systemPositionDiagnosticRole) ?? "unavailable"
        let errorCode = axError.map { String($0.rawValue) } ?? "unavailable"
        Self.logger.notice("positionHiddenInspection result=\(outcome, privacy: .public) stage=\(stage, privacy: .public) depth=\(depth) role=\(safeRole, privacy: .public) axError=\(errorCode, privacy: .public)")
        return result
    }

    /// A fresh, bounded read for passive capture; never opens overflow or changes
    /// management ownership. Unknown, expired, or cancelled observations are nil.
    func isSystemOverflowExpandedForPassiveCapture() -> Bool? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              AXIsProcessTrusted(), !Task.isCancelled, !menuBands.isEmpty else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        do {
            // A previous management cancellation must not disable later passive
            // reads. Respect this task's cancellation without resetting that flag.
            let current = try freshSystemOverflowControl(deadline: deadline, allowsCancellation: true)
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            return current.state == .expanded
        } catch {
            return nil
        }
    }

    /// Open the system's overflow from inside this application, only when our
    /// own anchors cannot currently be used for management. Moving still requires
    /// all of the existing geometry and hit-test checks after the caller rescans.
    func revealSystemOverflowForManagement(requiredIDs: [String] = [], forIconInventory: Bool = false) async throws -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return false }
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard !Task.isCancelled else { throw MenuBarOverflowError.cancelled }
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
        let frames = anchors.compactMap { entryFrame($0) }
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
                guard let rect = entryFrame(entry), rect.width > 0, rect.height > 0,
                      sourceMatchesHitTest(entry.element, at: CGPoint(x: rect.midX, y: rect.midY), context: "management-anchor") else {
                    anchorsClickable = false
                    break
                }
            }
        }
        var requiredItemsClickable = true
        for id in Set(requiredIDs) {
            guard let entry = entries[id] else {
                Self.logger.notice("managementRequired entryPresent=false")
                throw MenuBarAccessError.disappeared
            }
            guard liveOwnerMatches(entry) else {
                var currentPID: pid_t = 0
                let pidResult = AXUIElementGetPid(entry.element, &currentPID)
                let app = NSRunningApplication(processIdentifier: entry.owner.pid)
                Self.logger.notice("managementRequired entryPresent=true ownerMatches=false pidResult=\(pidResult.rawValue) currentPID=\(currentPID) ownerPID=\(entry.owner.pid) bundleMatches=\(app?.bundleIdentifier == entry.owner.bundleIdentifier) launchMatches=\(app.flatMap { MenuBarProcessIdentity.launchTime(for: $0) } == entry.owner.launchTime)")
                throw MenuBarAccessError.disappeared
            }
            guard let rect = entryFrame(entry), rect.width > 0, rect.height > 0,
                  menuBands.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }),
                  sourceMatchesHitTest(entry.element, at: CGPoint(x: rect.midX, y: rect.midY), context: "management-required") else {
                requiredItemsClickable = false
                continue
            }
        }
        let needed = forIconInventory || anchorsOverlap || !anchorsClickable || !requiredItemsClickable
        managementControlNeedsRecovery = anchors.first(where: { $0.snapshot.ownIdentifier == "menu-tidy-toggle" }).map { entry in
            guard let rect = entryFrame(entry) else { return true }
            return !sourceMatchesHitTest(entry.element, at: CGPoint(x: rect.midX, y: rect.midY), context: "management-control")
        } ?? false
        Self.logger.notice("managementOverflow prepareNeeded=\(needed) anchorsOverlap=\(anchorsOverlap) anchorsClickable=\(anchorsClickable)")
        guard needed else { return false }
        let overflow = try freshSystemOverflowControl(deadline: ProcessInfo.processInfo.systemUptime + 0.75)
        guard overflow.state == .collapsed else {
            Self.logger.notice("managementOverflow alreadyExpanded=true openedByManagement=false")
            return false
        }
        let action = try systemOverflowAction(overflow, opening: true)
        guard !Task.isCancelled, !cancellationRequested else { throw MenuBarOverflowError.cancelled }
        guard liveOwnerMatches(element: overflow.element, owner: overflow.owner) else { throw MenuBarOverflowError.entryNotFound }
        var stateBudget = OverflowReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.25, allowsCancellation: false)
        guard let actionState = try overflowState(overflow.element, budget: &stateBudget) else {
            throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
        }
        if actionState == .expanded { return false }
        let pointerBefore = CGEvent(source: nil)?.location
        defer { logPointerObservation(pointerBefore, context: "overflow-open") }
        let inputBefore = overflowOwnershipInputCounts()
        let pressResult = performAXAction(overflow.element, action)
        Self.logger.notice("managementOverflow openPressAccepted=\(pressResult == .success) axError=\(pressResult.rawValue) action=\(action, privacy: .public)")
        // Exactly one action. A timeout can still accompany a real
        // transition, so observe fresh authoritative roots without retrying it.
        let openedControl = await observeSystemOverflowState(.expanded, owner: overflow.owner)
        let opened = openedControl != nil
        let inputUnchanged = inputBefore == overflowOwnershipInputCounts()
        if let openedControl, inputUnchanged {
            managementOverflowEntry = openedControl
            managementOverflowInputCounts = inputBefore
        }
        Self.logger.notice("managementOverflow opened=\(opened) openedByManagement=\(opened && inputUnchanged) inputUnchanged=\(inputUnchanged)")
        guard !Task.isCancelled, !cancellationRequested else { throw MenuBarOverflowError.cancelled }
        guard opened else {
            if pressResult == .actionUnsupported || pressResult == .notImplemented {
                throw MenuBarOverflowError.actionUnsupported
            }
            throw MenuBarOverflowError.actionUnconfirmed(axError: pressResult.rawValue)
        }
        return true
    }

    /// An overflowed control would remain unreachable after merely ordering the
    /// two boundaries. Recover only our own control beside the visible clock;
    /// the clock itself is never moved. The same AX-only move verification applies.
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
            return entryFrame(entry)
        }
        guard let result = entryFrame(control), let clockFrame = entryFrame(clock),
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
        let originalInput = managementOverflowInputCounts
        managementOverflowEntry = nil
        managementOverflowInputCounts = nil
        guard let overflow else { return }
        guard let originalInput, originalInput == overflowOwnershipInputCounts() else {
            Self.logger.notice("managementOverflow restoreSkippedForInputChange=true")
            return
        }
        let current: SystemOverflowControl
        let action: String
        do {
            current = try freshSystemOverflowControl(expectedOwner: overflow.owner,
                deadline: ProcessInfo.processInfo.systemUptime + 0.75, allowsCancellation: true)
            guard current.state == .expanded else {
                Self.logger.notice("managementOverflow restoreNeeded=false")
                return
            }
            action = try systemOverflowAction(current, opening: false)
            var stateBudget = OverflowReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.25, allowsCancellation: true)
            guard try overflowState(current.element, budget: &stateBudget) == .expanded else { return }
        } catch {
            Self.logger.notice("managementOverflow restoreTargetConfirmed=false")
            return
        }
        let pointerBefore = CGEvent(source: nil)?.location
        defer { logPointerObservation(pointerBefore, context: "overflow-close") }
        // AX reads may block briefly. Recheck after them, immediately before
        // the action; any intervening input relinquishes close ownership.
        guard originalInput == overflowOwnershipInputCounts() else {
            Self.logger.notice("managementOverflow restoreSkippedForInputChange=true")
            return
        }
        guard liveOwnerMatches(element: current.element, owner: current.owner) else { return }
        let pressResult = performAXAction(current.element, action)
        Self.logger.notice("managementOverflow restorePressAccepted=\(pressResult == .success) axError=\(pressResult.rawValue) action=\(action, privacy: .public)")
        let restored = await observeSystemOverflowState(.collapsed, owner: current.owner) != nil
        Self.logger.notice("managementOverflow restored=\(restored)")
    }

    /// Enumerate the current MenuBarAgent window, not a retained scan mirror.
    /// The recovery button must itself belong to the real host and carry one
    /// of its shipped show/hide labels. Never descend into third-party items.
    private func freshSystemOverflowControl(expectedOwner: MenuBarOwner? = nil, deadline: TimeInterval,
                                            allowsCancellation: Bool = false) throws -> SystemOverflowControl {
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        var budget = OverflowReadBudget(deadline: deadline, allowsCancellation: allowsCancellation)
        try checkOverflowReadBudget(budget)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").filter {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/MenuBarAgent.app"
        }
        guard !applications.isEmpty else { throw MenuBarOverflowError.entryNotFound }
        guard applications.count == 1, let application = applications.first else { throw MenuBarOverflowError.entryAmbiguous }
        guard let launchTime = MenuBarProcessIdentity.launchTime(for: application) else { throw MenuBarOverflowError.entryNotFound }
        let owner = MenuBarOwner(pid: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
                                name: "MenuBarAgent", launchTime: launchTime)
        if let expectedOwner {
            guard expectedOwner.pid == owner.pid, expectedOwner.launchTime == owner.launchTime,
                  expectedOwner.bundleIdentifier == owner.bundleIdentifier else { throw MenuBarOverflowError.entryNotFound }
        }
        let appElement = AXUIElementCreateApplication(owner.pid)
        let windows = try overflowElements(appElement, kAXWindowsAttribute, maximum: 32, budget: &budget)
        var windowFrames: [CGRect] = []
        var candidates: [(element: AXUIElement, windowFrame: CGRect?, source: String)] = []
        for window in windows {
            try checkOverflowReadBudget(budget)
            var windowPID: pid_t = 0
            guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == owner.pid else {
                throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
            }
            guard try overflowAttribute(window, kAXRoleAttribute, budget: &budget) as? String == kAXWindowRole else { continue }
            let windowFrame = try overflowFrame(window, budget: &budget)
            guard validHostWindowFrame(windowFrame, containing: windowFrame) else { continue }
            windowFrames.append(windowFrame)
            let children = try overflowElements(window, kAXChildrenAttribute, maximum: 60, budget: &budget)
            for child in children {
                try checkOverflowReadBudget(budget)
                var childPID: pid_t = 0
                guard AXUIElementGetPid(child, &childPID) == .success else {
                    throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
                }
                guard childPID == owner.pid else { continue }
                candidates.append((child, windowFrame, "window-child"))
            }
        }

        // The public AXOverflowButton relationship need not appear in Children.
        // Read it only from the genuine host's extras bar and direct host-owned
        // children, never from a third-party remote element in that hierarchy.
        let extrasValue = try overflowAttribute(appElement, kAXExtrasMenuBarAttribute, optional: true, budget: &budget)
        if let extrasValue {
            guard let extras = element(extrasValue) else {
                throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
            }
            var extrasPID: pid_t = 0
            guard AXUIElementGetPid(extras, &extrasPID) == .success, extrasPID == owner.pid,
                  try overflowAttribute(extras, kAXRoleAttribute, budget: &budget) as? String == kAXMenuBarRole else {
                throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
            }
            var attributeOwners: [(element: AXUIElement, source: String)] = [(extras, "extras-attribute")]
            let children = try overflowElements(extras, kAXChildrenAttribute, maximum: 60, budget: &budget)
            for child in children {
                try checkOverflowReadBudget(budget)
                var childPID: pid_t = 0
                guard AXUIElementGetPid(child, &childPID) == .success else {
                    throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
                }
                if childPID == owner.pid { attributeOwners.append((child, "extras-child-attribute")) }
            }
            for source in attributeOwners {
                let value = try overflowAttribute(source.element, kAXOverflowButtonAttribute as String,
                                                  optional: true, budget: &budget)
                guard let value else { continue }
                guard let button = element(value) else {
                    throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
                }
                candidates.append((button, nil, source.source))
            }
        }

        var found: [SystemOverflowControl] = []
        for candidate in candidates {
            try checkOverflowReadBudget(budget)
            var pid: pid_t = 0
            guard AXUIElementGetPid(candidate.element, &pid) == .success else {
                throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
            }
            guard pid == owner.pid,
                  try overflowAttribute(candidate.element, kAXRoleAttribute, optional: true, budget: &budget) as? String == kAXButtonRole,
                  let state = try overflowState(candidate.element, budget: &budget) else { continue }
            let rect = try overflowFrame(candidate.element, budget: &budget)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let belongsToWindow: Bool
            if let windowFrame = candidate.windowFrame { belongsToWindow = windowFrame.contains(center) }
            else { belongsToWindow = windowFrames.contains { $0.contains(center) } }
            guard validHostFrame(rect, identifier: nil), belongsToWindow,
                  liveOwnerMatches(element: candidate.element, owner: owner) else { continue }
            if let duplicate = found.first(where: { CFEqual($0.element, candidate.element) }) {
                guard duplicate.state == state else { throw MenuBarOverflowError.actionUnconfirmed(axError: nil) }
                Self.logger.notice("managementOverflowCandidate source=\(candidate.source, privacy: .public) duplicate=true expanded=\(state == .expanded)")
                continue
            }
            // Diagnostic action-name reads share the resolver's budget and
            // timeout. They do not select or perform an action here.
            try checkOverflowReadBudget(budget)
            budget.remaining -= 1
            let timeout = Float(min(0.12, max(0.001, budget.deadline - ProcessInfo.processInfo.systemUptime)))
            let configured = AXUIElementSetMessagingTimeout(candidate.element, timeout)
            guard configured == .success else { throw MenuBarOverflowError.actionUnconfirmed(axError: configured.rawValue) }
            let actions = copyAXActions(candidate.element)
            try checkOverflowReadBudget(budget)
            let hasPress = actions.names.contains(kAXPressAction)
            let hasShowMenu = actions.names.contains(kAXShowMenuAction)
            let hasExpand = actions.names.contains("AXExpand")
            let hasCollapse = actions.names.contains("AXCollapse")
            Self.logger.notice("managementOverflowCandidate source=\(candidate.source, privacy: .public) duplicate=false expanded=\(state == .expanded) actionsError=\(actions.error.rawValue) actionCount=\(actions.names.count) press=\(hasPress) showMenu=\(hasShowMenu) expand=\(hasExpand) collapse=\(hasCollapse)")
            found.append(SystemOverflowControl(element: candidate.element, owner: owner, state: state))
        }
        try checkOverflowReadBudget(budget)
        guard !found.isEmpty else { throw MenuBarOverflowError.entryNotFound }
        guard found.count == 1, let control = found.first else { throw MenuBarOverflowError.entryAmbiguous }
        guard liveOwnerMatches(element: control.element, owner: control.owner) else { throw MenuBarOverflowError.entryNotFound }
        return control
    }

    private func overflowState(_ node: AXUIElement, budget: inout OverflowReadBudget) throws -> SystemOverflowState? {
        let description = try overflowAttribute(node, kAXDescriptionAttribute, optional: true, budget: &budget) as? String
        let title = try overflowAttribute(node, kAXTitleAttribute, optional: true, budget: &budget) as? String
        let labels = [description, title].compactMap { $0 }
        let collapsed = labels.contains { Self.overflowAccessibilityLabels.show.contains($0) }
        let expanded = labels.contains { Self.overflowAccessibilityLabels.hide.contains($0) }
        guard collapsed || expanded else { return nil }
        guard collapsed != expanded else { throw MenuBarOverflowError.actionUnconfirmed(axError: nil) }
        return expanded ? .expanded : .collapsed
    }

    private func systemOverflowAction(_ control: SystemOverflowControl, opening: Bool) throws -> String {
        guard AXUIElementSetMessagingTimeout(control.element, 0.12) == .success else {
            throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
        }
        let actions = copyAXActions(control.element)
        let known = ["AXExpand", "AXCollapse", kAXPressAction, kAXShowMenuAction]
        let advertised = known.filter { actions.names.contains($0) }.joined(separator: ",")
        Self.logger.notice("managementOverflow opening=\(opening) actionsError=\(actions.error.rawValue) knownActions=\(advertised, privacy: .public) totalActions=\(actions.names.count)")
        guard actions.error == .success else {
            if actions.error == .actionUnsupported || actions.error == .notImplemented { throw MenuBarOverflowError.actionUnsupported }
            throw MenuBarOverflowError.actionUnconfirmed(axError: actions.error.rawValue)
        }
        let preferred = opening ? ["AXExpand", kAXPressAction, kAXShowMenuAction] : ["AXCollapse", kAXPressAction]
        if let action = preferred.first(where: { actions.names.contains($0) }) { return action }
        // Some system AXButtons omit their standard press from AXActionNames.
        // The fresh overflow resolver has already proved the system owner,
        // role and unique show/hide state. Try its standard action exactly once;
        // the caller must observe the actual transition before owning cleanup.
        // This is an AX message, not synthesized input or a coordinate click.
        if actions.names.isEmpty, text(control.element, kAXRoleAttribute) == kAXButtonRole {
            Self.logger.notice("managementOverflow standardButtonPressUnadvertised=true")
            return kAXPressAction
        }
        throw MenuBarOverflowError.actionUnsupported
    }

    private func observeSystemOverflowState(_ expected: SystemOverflowState, owner: MenuBarOwner) async -> SystemOverflowControl? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var consecutive = 0
        var samples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            samples += 1
            do {
                // Continue bounded reconciliation after cancellation so cleanup
                // can own an observed transition, without ever resending it.
                let current = try freshSystemOverflowControl(expectedOwner: owner,
                    deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.4), allowsCancellation: true)
                if current.state == expected {
                    consecutive += 1
                    if consecutive >= 2 {
                        Self.logger.notice("managementOverflow observationConfirmed=true expanded=\(expected == .expanded) samples=\(samples)")
                        return current
                    }
                } else { consecutive = 0 }
            } catch { consecutive = 0 }
            guard ProcessInfo.processInfo.systemUptime + 0.1 < deadline else { break }
            await waitForSystemOverflowTransition(milliseconds: 100)
        }
        Self.logger.notice("managementOverflow observationConfirmed=false expanded=\(expected == .expanded) samples=\(samples)")
        return nil
    }

    private func checkOverflowReadBudget(_ budget: OverflowReadBudget) throws {
        if !budget.allowsCancellation && (Task.isCancelled || cancellationRequested) { throw MenuBarOverflowError.cancelled }
        guard budget.remaining > 0, ProcessInfo.processInfo.systemUptime < budget.deadline else {
            throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
        }
    }

    private func overflowAttribute(_ node: AXUIElement, _ name: String, optional: Bool = false,
                                   budget: inout OverflowReadBudget) throws -> CFTypeRef? {
        try checkOverflowReadBudget(budget)
        budget.remaining -= 1
        let timeout = Float(min(0.12, max(0.001, budget.deadline - ProcessInfo.processInfo.systemUptime)))
        let configured = AXUIElementSetMessagingTimeout(node, timeout)
        guard configured == .success else { throw MenuBarOverflowError.actionUnconfirmed(axError: configured.rawValue) }
        let result = copyAttribute(node, name)
        try checkOverflowReadBudget(budget)
        if optional && (result.error == .noValue || result.error == .attributeUnsupported) { return nil }
        guard result.error == .success else { throw MenuBarOverflowError.actionUnconfirmed(axError: result.error.rawValue) }
        return result.value
    }

    private func overflowElements(_ node: AXUIElement, _ name: String, maximum: Int,
                                  budget: inout OverflowReadBudget) throws -> [AXUIElement] {
        guard let values = try overflowAttribute(node, name, budget: &budget) as? [CFTypeRef], values.count <= maximum else {
            throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
        }
        var result: [AXUIElement] = []
        for value in values {
            try checkOverflowReadBudget(budget)
            guard let child = element(value) else { throw MenuBarOverflowError.actionUnconfirmed(axError: nil) }
            result.append(child)
        }
        return result
    }

    private func overflowFrame(_ node: AXUIElement, budget: inout OverflowReadBudget) throws -> CGRect {
        guard let position = try overflowAttribute(node, kAXPositionAttribute, budget: &budget),
              let size = try overflowAttribute(node, kAXSizeAttribute, budget: &budget),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw MenuBarOverflowError.actionUnconfirmed(axError: nil)
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { throw MenuBarOverflowError.actionUnconfirmed(axError: nil) }
        return CGRect(origin: point, size: extent)
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

    private func logPointerObservation(_ before: CGPoint?, context: String) {
        let after = CGEvent(source: nil)?.location
        // This is an observation, not attribution: user movement may also
        // change the position. Never reposition the pointer to make it agree.
        let available = before != nil && after != nil
        Self.logger.notice("backgroundPointer context=\(context, privacy: .public) observationAvailable=\(available) unchanged=\(available && before == after)")
    }

    private func overflowOwnershipInputCounts() -> [UInt32] {
        // Reading counters neither intercepts nor synthesizes input. If AX
        // itself contributes events, conservatively leave overflow open.
        Self.overflowOwnershipEventTypes.map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }

    private enum MovePlacement: String {
        case before
        case after

        func isSatisfied(source: CGRect, anchor: CGRect) -> Bool {
            switch self {
            case .before: source.minX < anchor.minX
            case .after: source.minX >= anchor.maxX - 1 && source.midX > anchor.midX
            }
        }
    }

    /// Resolve persistent intent with the same source/owner proof used by a
    /// movement candidate. The resulting ID does not retain an operation token.
    private func persistentPositionIdentity(_ candidate: Candidate, existing: Entry?,
                                            positions: [String: Double], owners: [MenuBarOwner],
                                            inventories: inout [pid_t: [AXUIElement]]) throws -> String? {
        guard candidate.owner.pid != ProcessInfo.processInfo.processIdentifier,
              candidate.owner.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let requestID = existing?.snapshot.id ?? ""
        let key: String
        if positions.isEmpty {
            // A temporarily unreadable table cannot mint a new identity. Only
            // the exact source and owner from this run may retain a known one;
            // its live source is fully rechecked below. Writes still need a
            // fresh table and validateBackgroundPositionCandidates.
            guard let existing, existing.owner.pid == candidate.owner.pid,
                  existing.owner.launchTime == candidate.owner.launchTime,
                  existing.owner.bundleIdentifier == candidate.owner.bundleIdentifier,
                  CFEqual(existing.element, candidate.element),
                  let previousKey = MenuItemIdentity.positionKey(inPersistentID: existing.snapshot.id,
                      bundleIdentifier: candidate.owner.bundleIdentifier) else { return nil }
            key = previousKey
        } else {
            try checkPositionRequest(id: requestID, positions: positions)
            key = try positionKey(owner: candidate.owner, ownIdentifier: nil, positions: positions, id: requestID)
        }
        try checkPositionOwner(element: candidate.element, owner: candidate.owner, owners: owners, id: requestID)
        let sourceItems: [AXUIElement]
        if let cached = inventories[candidate.owner.pid] { sourceItems = cached }
        else {
            sourceItems = try positionSourceItems(owner: candidate.owner, id: requestID)
            inventories[candidate.owner.pid] = sourceItems
        }
        try checkPositionSource(element: candidate.element, ownIdentifier: nil, sourceItems: sourceItems, id: requestID)
        try checkPositionOwner(element: candidate.element, owner: candidate.owner, owners: owners, id: requestID)
        return MenuItemIdentity.persistentPositionID(bundleIdentifier: candidate.owner.bundleIdentifier, positionKey: key)
    }

    /// Retain original AX identities for a <=20-second, single-key-at-a-time
    /// challenge. No action, layout mutation or preference write occurs here.
    func prepareBackgroundPositionKeyChallenge(id: String, controlID: String,
                                               positions: [String: Double], owners: [MenuBarOwner]) throws
        -> MenuBarPositionKeyChallenge {
        try checkPositionRequest(id: id, positions: positions)
        let now = ProcessInfo.processInfo.systemUptime
        positionKeyChallenges = positionKeyChallenges.filter { $0.value.handle.deadline > now }
        guard positionKeyChallenges.count < 4, id != controlID,
              let source = entries[id], let control = entries[controlID],
              source.snapshot.canMove, source.snapshot.ownIdentifier == nil,
              let bundle = source.owner.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier, bundle != SystemModuleIdentity.ownerBundleIdentifier,
              let identifier = source.accessibilityIdentifier, !identifier.isEmpty,
              positionOwnIdentifier(control) == "menu-tidy-toggle" else {
            throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
        }
        let prefix = "status:\(bundle)::"
        let keys = positions.keys.filter { $0.hasPrefix(prefix) }.sorted()
        guard (2...4).contains(keys.count), keys.allSatisfy({ $0.count > prefix.count }) else {
            throw MenuBarPositionBindingError(id: id, reason: .ambiguousKey)
        }
        let controlKey = try positionKey(owner: control.owner, ownIdentifier: "menu-tidy-toggle",
            positions: positions, id: controlID)
        let identity = MenuBarPositionKeyResolution.Identity(sourceToken: UUID(), controlToken: UUID(),
            processIdentifier: source.owner.pid, launchTime: source.owner.launchTime,
            accessibilityIdentifier: identifier)
        let resolution = try MenuBarPositionKeyResolution(candidateKeys: keys, ownerBundleIdentifier: bundle,
            controlKey: controlKey, positions: positions, identity: identity)
        let handle = MenuBarPositionKeyChallenge(id: id, controlID: controlID, candidateKeys: keys,
            controlKey: controlKey, deadline: now + 20, token: UUID())
        let identifierElement = try positionIdentifierElement(source, expected: identifier, retaining: nil, id: id)
        positionKeyChallenges[handle.token] = PositionKeyChallengeBinding(handle: handle, source: source,
            control: control, identifierElement: identifierElement,
            originalValues: positions.filter { keys.contains($0.key) || $0.key == controlKey }, resolution: resolution)
        do {
            let checked = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners)
            guard challengeVisibility(checked.control).centerHit else { throw MenuBarAccessError.invalidGeometry }
            try checkChallengeDeadline(handle)
            Self.logger.notice("positionKeyChallenge prepared=true candidateCount=\(keys.count)")
            return handle
        } catch {
            positionKeyChallenges.removeValue(forKey: handle.token)
            throw error
        }
    }

    func beginBackgroundPositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge, key: String,
                                             positions: [String: Double], owners: [MenuBarOwner]) throws
        -> MenuBarPositionPlan {
        do {
            var checked = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners)
            guard positions[key] == checked.binding.originalValues[key] else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            checked.binding.attempt = try checked.binding.resolution.beginCandidate(key: key)
            checked.binding.activeKey = key
            let plan = try checked.binding.resolution.placementPlan(positions: positions)
            checked.binding.lastPlan = plan
            positionKeyChallenges[handle.token] = checked.binding
            return plan
        } catch { invalidatePositionKeyChallenge(handle); throw error }
    }

    func backgroundPositionKeyChallengePlan(_ handle: MenuBarPositionKeyChallenge,
                                            positions: [String: Double], owners: [MenuBarOwner]) throws
        -> MenuBarPositionPlan {
        do {
            var checked = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners)
            let plan = try checked.binding.resolution.placementPlan(positions: positions)
            checked.binding.lastPlan = plan
            positionKeyChallenges[handle.token] = checked.binding
            return plan
        } catch { invalidatePositionKeyChallenge(handle); throw error }
    }

    func validateBackgroundPositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge,
                                                positions: [String: Double], owners: [MenuBarOwner]) throws {
        do { _ = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners) }
        catch { invalidatePositionKeyChallenge(handle); throw error }
    }

    /// Each observation repeats complete original-source enumeration and live
    /// ownership checks. A source in overflow contributes no positive evidence.
    func observeBackgroundPositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge,
                                               positions: [String: Double], owners: [MenuBarOwner]) throws
        -> MenuBarPositionKeyResolution.Phase {
        do {
            var checked = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners)
            let phase = checked.binding.resolution.phase
            guard phase == .left || phase == .right, let attempt = checked.binding.attempt,
                  let plan = checked.binding.lastPlan,
                  plan.placement == (phase == .left ? .before : .after),
                  positions[plan.sourceKey] == plan.writtenWeight else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .invalidRequest)
            }
            let source = challengeVisibility(checked.source)
            let control = challengeVisibility(checked.control)
            let sameBand: Bool
            if let sourceFrame = source.frame, let controlFrame = control.frame {
                sameBand = menuBands.contains {
                    $0.contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)) &&
                        $0.contains(CGPoint(x: controlFrame.midX, y: controlFrame.midY))
                }
            } else { sameBand = false }
            try checkPositionOwner(checked.source, owners: owners, id: handle.id)
            try checkPositionOwner(checked.control, owners: owners, id: handle.controlID)
            try requirePositionIdentifier(checked.source, expected: checked.binding.resolution.identity.accessibilityIdentifier,
                retaining: checked.binding.identifierElement, id: handle.id)
            try checkChallengeDeadline(handle)
            let observation = MenuBarPositionKeyResolution.Observation(attempt: attempt,
                side: phase == .left ? .leftOfControl : .rightOfControl,
                identity: checked.binding.resolution.identity,
                sourceFrame: source.frame ?? .zero, controlFrame: control.frame ?? .zero,
                sourceCenterHit: source.centerHit && sameBand, controlCenterHit: control.centerHit && sameBand,
                completeSingleSource: true, controlWeight: positions[handle.controlKey]!,
                uptime: ProcessInfo.processInfo.systemUptime)
            try checked.binding.resolution.record(observation)
            positionKeyChallenges[handle.token] = checked.binding
            let result = checked.binding.resolution.phase
            // Emit the actual observation rectangles, not a saved snapshot or
            // an inferred identity. Consecutive lines reveal frame stability
            // without exposing candidate keys or changing the proof thresholds.
            let sourceFrameDescription = source.frame.map(NSStringFromRect) ?? "unavailable"
            let controlFrameDescription = control.frame.map(NSStringFromRect) ?? "unavailable"
            let wantedSide = phase == .left ? "left" : "right"
            let candidateOrdinal = handle.candidateKeys.firstIndex(of: plan.sourceKey) ?? -1
            let orderMatches: Bool
            let verticalAligned: Bool
            if let sourceFrame = source.frame, let controlFrame = control.frame {
                orderMatches = MenuBarPositionKeyResolution.orderMatches(side: observation.side,
                    sourceFrame: sourceFrame, controlFrame: controlFrame)
                verticalAligned = abs(sourceFrame.midY - controlFrame.midY) <= 8
            } else {
                orderMatches = false
                verticalAligned = false
            }
            Self.logger.notice("positionKeyChallenge observation=true candidateOrdinal=\(candidateOrdinal) wantedSide=\(wantedSide, privacy: .public) sourceFrame=\(sourceFrameDescription, privacy: .public) controlFrame=\(controlFrameDescription, privacy: .public) sourceHit=\(source.centerHit) controlHit=\(control.centerHit) sameBand=\(sameBand) orderMatches=\(orderMatches) verticalAligned=\(verticalAligned) phase=\(String(describing: result), privacy: .public)")
            return result
        } catch { invalidatePositionKeyChallenge(handle); throw error }
    }

    /// This can be called from cancellation cleanup. It changes only the
    /// in-memory phase; the caller must still conditionally roll back its store.
    func finishBackgroundPositionKeyChallengeAttempt(_ handle: MenuBarPositionKeyChallenge) throws {
        guard var binding = positionKeyChallenges[handle.token], binding.handle.id == handle.id else {
            throw MenuBarPositionBindingError(id: handle.id, reason: .expired)
        }
        try binding.resolution.finishAttempt()
        positionKeyChallenges[handle.token] = binding
    }

    /// Store receipts are necessary but not sufficient: reread all original
    /// candidate values and revalidate the AX source before registering a key.
    /// Registration affects operation preparation only, never scan's item IDs.
    @discardableResult
    func confirmBackgroundPositionKeyChallengeRestoration(_ handle: MenuBarPositionKeyChallenge,
                                                          originalValueRestored: Bool, layoutRefreshed: Bool,
                                                          positions: [String: Double], owners: [MenuBarOwner]) throws -> String? {
        do {
            var checked = try checkedPositionKeyChallenge(handle, positions: positions, owners: owners)
            guard checked.binding.originalValues.allSatisfy({ positions[$0.key] == $0.value }) else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            let key = try checked.binding.resolution.confirmRestoration(identity: checked.binding.resolution.identity,
                originalValueRestored: originalValueRestored, layoutRefreshed: layoutRefreshed)
            checked.binding.activeKey = nil
            checked.binding.attempt = nil
            checked.binding.lastPlan = nil
            positionKeyChallenges[handle.token] = checked.binding
            if let key {
                validatedPositionKeys = validatedPositionKeys.filter { id, mapping in
                    guard let current = entries[id] else { return false }
                    return samePositionSource(current, mapping.source) && liveOwnerMatches(current)
                }
                guard validatedPositionKeys.count < 128 || validatedPositionKeys[handle.id] != nil else {
                    throw MenuBarPositionBindingError(id: handle.id, reason: .expired)
                }
                validatedPositionKeys[handle.id] = ValidatedPositionKey(source: checked.source,
                    identifierElement: checked.binding.identifierElement,
                    accessibilityIdentifier: checked.binding.resolution.identity.accessibilityIdentifier,
                    key: key, candidateKeys: Set(handle.candidateKeys))
                Self.logger.notice("positionKeyChallenge registered=true candidateCount=\(handle.candidateKeys.count)")
            }
            return key
        } catch { invalidatePositionKeyChallenge(handle); throw error }
    }

    func discardBackgroundPositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge) {
        positionKeyChallenges.removeValue(forKey: handle.token)
    }

    private func checkedPositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge,
                                             positions: [String: Double], owners: [MenuBarOwner]) throws
        -> (binding: PositionKeyChallengeBinding, source: Entry, control: Entry) {
        // These stage names are fixed diagnostics, never application or item
        // identifiers. Keep the original fail-closed checks in the same order.
        var stage = "request"
        var sourceCount = -1
        var sourceMatches = -1
        var controlCount = -1
        var controlMatches = -1
        do {
            try checkPositionRequest(id: handle.id, positions: positions)
            stage = "deadline"
            try checkChallengeDeadline(handle)
            stage = "session"
            guard let binding = positionKeyChallenges[handle.token], !binding.invalidated,
                  binding.handle.id == handle.id, binding.handle.controlID == handle.controlID,
                  binding.handle.candidateKeys == handle.candidateKeys, binding.handle.controlKey == handle.controlKey else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "entries"
            guard let source = entries[handle.id], let control = entries[handle.controlID] else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "source-continuity"
            guard samePositionSource(source, binding.source) else {
                logPositionChallengeContinuity(source, original: binding.source, source: true)
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "control-continuity"
            guard samePositionSource(control, binding.control) else {
                logPositionChallengeContinuity(control, original: binding.control, source: false)
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "eligibility"
            guard source.snapshot.canMove, positionOwnIdentifier(control) == "menu-tidy-toggle",
                  let bundle = source.owner.bundleIdentifier else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "candidate-key-set"
            guard Set(positions.keys.filter { $0.hasPrefix("status:\(bundle)::") }) == Set(handle.candidateKeys) else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "control-weight"
            guard positions[handle.controlKey] == binding.originalValues[handle.controlKey] else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            // Only the active candidate may differ during a challenge. Preserve
            // outside edits by refusing further writes, not reassigning keys.
            stage = "inactive-candidate-values"
            guard binding.originalValues.allSatisfy({ $0.key == binding.activeKey || positions[$0.key] == $0.value }) else {
                throw MenuBarPositionBindingError(id: handle.id, reason: .identityChanged)
            }
            stage = "source-owner"
            try checkPositionOwner(source, owners: owners, id: handle.id)
            stage = "control-owner"
            try checkPositionOwner(control, owners: owners, id: handle.controlID)
            stage = "source-census"
            let sourceItems = try positionSourceItems(owner: source.owner, id: handle.id)
            sourceCount = sourceItems.count
            sourceMatches = sourceItems.filter { CFEqual($0, source.element) }.count
            stage = "source-membership"
            try checkPositionSource(source, ownIdentifier: nil, sourceItems: sourceItems, id: handle.id)
            stage = "source-identifier"
            try requirePositionIdentifier(source, expected: binding.resolution.identity.accessibilityIdentifier,
                retaining: binding.identifierElement, id: handle.id)
            stage = "control-census"
            let controlItems = try positionSourceItems(owner: control.owner, id: handle.controlID)
            controlCount = controlItems.count
            controlMatches = controlItems.filter { CFEqual($0, control.element) }.count
            stage = "control-membership"
            try checkPositionSource(control, ownIdentifier: "menu-tidy-toggle", sourceItems: controlItems, id: handle.controlID)
            stage = "source-owner-recheck"
            try checkPositionOwner(source, owners: owners, id: handle.id)
            stage = "control-owner-recheck"
            try checkPositionOwner(control, owners: owners, id: handle.controlID)
            stage = "deadline-recheck"
            try checkChallengeDeadline(handle)
            return (binding, source, control)
        } catch {
            let reason = (error as? MenuBarPositionBindingError)?.reason.rawValue ?? "other"
            Self.logger.notice("positionKeyChallenge checked=false stage=\(stage, privacy: .public) reason=\(reason, privacy: .public) sourceCount=\(sourceCount) sourceCFMatches=\(sourceMatches) controlCount=\(controlCount) controlCFMatches=\(controlMatches)")
            throw error
        }
    }

    private func logPositionChallengeContinuity(_ current: Entry, original: Entry, source: Bool) {
        let sameOwner = current.owner.pid == original.owner.pid &&
            current.owner.launchTime == original.owner.launchTime &&
            current.owner.bundleIdentifier == original.owner.bundleIdentifier
        Self.logger.notice("positionKeyChallenge continuity=false source=\(source) sameAX=\(CFEqual(current.element, original.element)) sameOwner=\(sameOwner) sameIdentifier=\(current.accessibilityIdentifier == original.accessibilityIdentifier)")
    }

    private func checkChallengeDeadline(_ handle: MenuBarPositionKeyChallenge) throws {
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: handle.id, reason: .cancelled) }
        guard ProcessInfo.processInfo.systemUptime < handle.deadline else {
            throw MenuBarPositionBindingError(id: handle.id, reason: .expired)
        }
    }

    private func invalidatePositionKeyChallenge(_ handle: MenuBarPositionKeyChallenge) {
        guard var binding = positionKeyChallenges[handle.token] else { return }
        binding.invalidated = true
        try? binding.resolution.finishAttempt()
        positionKeyChallenges[handle.token] = binding
    }

    private func samePositionSource(_ current: Entry, _ original: Entry) -> Bool {
        CFEqual(current.element, original.element) && current.owner.pid == original.owner.pid &&
            current.owner.launchTime == original.owner.launchTime &&
            current.owner.bundleIdentifier == original.owner.bundleIdentifier &&
            current.accessibilityIdentifier == original.accessibilityIdentifier
    }

    private func requirePositionIdentifier(_ entry: Entry, expected: String,
                                           retaining provider: AXUIElement, id: String) throws {
        _ = try positionIdentifierElement(entry, expected: expected, retaining: provider, id: id)
    }

    /// Scan may inherit an identifier from an immediate child. Retain that
    /// actual child, not just its string: every later use must prove the same
    /// source -> child edge, sole matching identifier and owner lifetime again.
    /// This identity evidence never selects an autosave key without a challenge.
    private func positionIdentifierElement(_ entry: Entry, expected: String,
                                           retaining retained: AXUIElement?, id: String) throws -> AXUIElement {
        var budget = PositionReadBudget()
        var stage = "owner"
        do {
            guard !expected.isEmpty, liveOwnerMatches(entry) else {
                throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
            }
            stage = "direct-read"
            let direct = try positionIdentifierText(entry.element, id: id, budget: &budget)
            let provider: AXUIElement
            if let direct {
                guard direct == expected, retained == nil || CFEqual(retained, entry.element) else {
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
                provider = entry.element
            } else {
                stage = "child-census"
                let before = try positionIdentifierChildren(entry.element, expected: expected, id: id, budget: &budget)
                guard before.matches.count == 1, let child = before.matches.first,
                      retained == nil || CFEqual(retained, child),
                      !CFEqual(child, entry.element) else {
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
                stage = "child-owner"
                guard liveOwnerMatches(element: child, owner: entry.owner) else {
                    throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
                }
                stage = "child-census-recheck"
                let after = try positionIdentifierChildren(entry.element, expected: expected, id: id, budget: &budget)
                guard before.children.count == after.children.count,
                      before.children.allSatisfy({ original in
                          after.children.filter { CFEqual($0, original) }.count == 1
                      }), after.matches.count == 1, let current = after.matches.first,
                      CFEqual(current, child) else {
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
                provider = child
            }
            stage = "source-identifier-recheck"
            let currentDirect = try positionIdentifierText(entry.element, id: id, budget: &budget)
            guard currentDirect == direct else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            stage = "provider-identifier-recheck"
            guard try positionIdentifierText(provider, id: id, budget: &budget) == expected else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            stage = "owner-recheck"
            guard liveOwnerMatches(entry), liveOwnerMatches(element: provider, owner: entry.owner) else {
                throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
            }
            if retained == nil {
                Self.logger.notice("positionKeyChallenge identifierBound=true inherited=\(!CFEqual(provider, entry.element))")
            }
            return provider
        } catch {
            let reason = (error as? MenuBarPositionBindingError)?.reason.rawValue ?? "other"
            Self.logger.notice("positionKeyChallenge identifierBound=false stage=\(stage, privacy: .public) reason=\(reason, privacy: .public) retained=\(retained != nil)")
            throw error
        }
    }

    private func positionIdentifierText(_ node: AXUIElement, id: String,
                                        budget: inout PositionReadBudget) throws -> String? {
        let read = try positionAttribute(node, kAXIdentifierAttribute, id: id, budget: &budget)
        if read.error == .noValue || read.error == .attributeUnsupported { return nil }
        guard read.error == .success, let identifier = read.value as? String else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        return identifier
    }

    /// Read the complete immediate set twice within the caller's single budget;
    /// any malformed, duplicate or unreadable child makes uniqueness unknown.
    private func positionIdentifierChildren(_ source: AXUIElement, expected: String, id: String,
                                            budget: inout PositionReadBudget) throws
        -> (children: [AXUIElement], matches: [AXUIElement]) {
        let read = try positionAttribute(source, kAXChildrenAttribute, id: id, budget: &budget)
        guard read.error == .success, let values = read.value as? [CFTypeRef], values.count <= 128 else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        var children: [AXUIElement] = []
        var matches: [AXUIElement] = []
        for value in values {
            guard let child = element(value), !CFEqual(child, source),
                  !children.contains(where: { CFEqual($0, child) }) else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            children.append(child)
            if try positionIdentifierText(child, id: id, budget: &budget) == expected { matches.append(child) }
        }
        return (children, matches)
    }

    private func challengeVisibility(_ entry: Entry) -> MenuBarVisibilityInspection {
        guard let rect = entryFrame(entry) else { return verifiedRawOriginVisibility(entry, diagnostic: false) }
        guard rect.size.width > 0, rect.size.height > 0, rect.height <= 64,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              menuBands.contains(where: { band in
                  rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1 &&
                      band.contains(CGPoint(x: rect.midX, y: rect.midY))
              }) else { return MenuBarVisibilityInspection(frame: nil, centerHit: false, hasEntry: true) }
        let matched = strictPositionChallengeHit(entry, frame: rect)
        return MenuBarVisibilityInspection(frame: rect, centerHit: matched && entryFrame(entry) == rect, hasEntry: true)
    }

    /// Unlike the general compatibility hit test, a challenge never accepts
    /// matching identifier/PID/frame alone. Require the original object in the
    /// hit ancestry, or an exact node of a freshly revalidated host binding.
    private func strictPositionChallengeHit(_ entry: Entry, frame rect: CGRect) -> Bool {
        let query = Self.copyElementAtPositionOnMainThread(CGPoint(x: rect.midX, y: rect.midY))
        guard query.error == .success else { return false }
        var current = query.element
        var visited: [AXUIElement] = []
        for _ in 0..<6 {
            guard !Task.isCancelled, let node = current,
                  !visited.contains(where: { CFEqual($0, node) }) else { return false }
            visited.append(node)
            if CFEqual(node, entry.element) { return true }
            if let host = entry.hostPresentation, host.path.contains(where: { CFEqual($0, node) }) {
                var budget = MirrorReadBudget()
                return currentHostFrame(host, original: entry.element, owner: entry.owner,
                    identifier: entry.accessibilityIdentifier, budget: &budget) == rect
            }
            guard let role = text(node, kAXRoleAttribute),
                  [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole, kAXImageRole, kAXStaticTextRole].contains(role) else {
                return false
            }
            current = element(attribute(node, kAXParentAttribute))
        }
        return false
    }

    /// Learned keys are deliberately unavailable to persistentPositionIdentity.
    /// The ordinary preparation/validation path below still performs a complete
    /// singleton-source census after resolving this in-memory alternative.
    private func operationPositionKey(_ entry: Entry, ownIdentifier: String?,
                                      positions: [String: Double], id: String) throws -> String {
        if let mapping = validatedPositionKeys[id] {
            guard ownIdentifier == nil, samePositionSource(entry, mapping.source), liveOwnerMatches(entry) else {
                validatedPositionKeys.removeValue(forKey: id)
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            // Do not fall back to the sole remaining key if the proven key or
            // another candidate disappears during the same source lifetime.
            guard let bundle = entry.owner.bundleIdentifier,
                  Set(positions.keys.filter { $0.hasPrefix("status:\(bundle)::") }) == mapping.candidateKeys,
                  positions[mapping.key] != nil else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            try requirePositionIdentifier(entry, expected: mapping.accessibilityIdentifier,
                retaining: mapping.identifierElement, id: id)
            return mapping.key
        }
        return try positionKey(owner: entry.owner, ownIdentifier: ownIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier, positions: positions, id: id)
    }

    /// `positions` must be the complete current dictionary, and `owners` a fresh
    /// running-application census. Passing a key-filtered dictionary would hide
    /// ambiguity. No geometry, accessibility action, or preference write is used.
    /// A failed batch installs no tokens; callers can prepare individual IDs when
    /// they need to select a different movement capability per item.
    func prepareBackgroundPositionCandidates(ids: [String], positions: [String: Double],
                                             owners: [MenuBarOwner]) throws -> [MenuBarPositionCandidate] {
        let requestID = ids.first ?? ""
        try checkPositionRequest(id: requestID, positions: positions)
        guard ids.count <= 128, Set(ids).count == ids.count else {
            throw MenuBarPositionBindingError(id: requestID, reason: .invalidRequest)
        }
        let now = ProcessInfo.processInfo.systemUptime
        positionCandidateBindings = positionCandidateBindings.filter { $0.value.expiresAt > now }
        guard positionCandidateBindings.count + ids.count <= 256 else {
            throw MenuBarPositionBindingError(id: requestID, reason: .expired)
        }
        var prepared: [PositionCandidateBinding] = []
        var inventories: [pid_t: [AXUIElement]] = [:]
        for id in ids {
            guard let entry = entries[id] else {
                throw MenuBarPositionBindingError(id: id, reason: .missingEntry)
            }
            let ownIdentifier = positionOwnIdentifier(entry)
            guard ownIdentifier != nil || entry.snapshot.canMove else {
                throw MenuBarPositionBindingError(id: id, reason: .protectedItem)
            }
            try checkPositionOwner(entry, owners: owners, id: id)
            let key = try operationPositionKey(entry, ownIdentifier: ownIdentifier, positions: positions, id: id)
            let sourceItems: [AXUIElement]
            if let cached = inventories[entry.owner.pid] { sourceItems = cached }
            else {
                sourceItems = try positionSourceItems(for: entry, id: id)
                inventories[entry.owner.pid] = sourceItems
            }
            try checkPositionSource(entry, ownIdentifier: ownIdentifier, sourceItems: sourceItems, id: id)
            try checkPositionOwner(entry, owners: owners, id: id)
            guard let bundle = entry.owner.bundleIdentifier else {
                throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
            }
            let candidate = MenuBarPositionCandidate(id: id, key: key, processIdentifier: entry.owner.pid,
                launchTime: entry.owner.launchTime, bundleIdentifier: bundle, token: UUID())
            prepared.append(PositionCandidateBinding(candidate: candidate, element: entry.element,
                owner: entry.owner, ownIdentifier: ownIdentifier, expiresAt: now + 300))
        }
        for binding in prepared { positionCandidateBindings[binding.candidate.token] = binding }
        Self.logger.notice("backgroundPositionBinding prepared=\(prepared.count)")
        return prepared.map(\.candidate)
    }

    /// Re-read complete source identity, exact key uniqueness and owner lifetime
    /// before a write and after a fresh scan. A rebuilt host projection is fine;
    /// replacing the originating AX object is not. This proves identity only,
    /// never that a requested order or hidden state has actually been achieved.
    func validateBackgroundPositionCandidates(_ candidates: [MenuBarPositionCandidate],
                                              positions: [String: Double], owners: [MenuBarOwner]) throws {
        try checkPositionRequest(id: candidates.first?.id ?? "", positions: positions)
        guard candidates.count <= 128, Set(candidates.map(\.token)).count == candidates.count else {
            throw MenuBarPositionBindingError(id: candidates.first?.id ?? "", reason: .invalidRequest)
        }
        var inventories: [pid_t: [AXUIElement]] = [:]
        for candidate in candidates {
            let id = candidate.id
            guard let binding = positionCandidateBindings[candidate.token],
                  binding.expiresAt > ProcessInfo.processInfo.systemUptime else {
                throw MenuBarPositionBindingError(id: id, reason: .expired)
            }
            guard binding.candidate.id == id, binding.candidate.key == candidate.key,
                  binding.owner.pid == candidate.processIdentifier,
                  binding.owner.launchTime == candidate.launchTime,
                  binding.owner.bundleIdentifier == candidate.bundleIdentifier,
                  let entry = entries[id], CFEqual(entry.element, binding.element),
                  entry.owner.pid == binding.owner.pid, entry.owner.launchTime == binding.owner.launchTime,
                  entry.owner.bundleIdentifier == binding.owner.bundleIdentifier,
                  positionOwnIdentifier(entry) == binding.ownIdentifier else {
                systemModuleContinuity.removeValue(forKey: id)
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            try checkPositionOwner(entry, owners: owners, id: id)
            guard try operationPositionKey(entry, ownIdentifier: binding.ownIdentifier,
                                          positions: positions, id: id) == candidate.key else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            let sourceItems: [AXUIElement]
            if let cached = inventories[entry.owner.pid] { sourceItems = cached }
            else {
                sourceItems = try positionSourceItems(for: entry, id: id)
                inventories[entry.owner.pid] = sourceItems
            }
            try checkPositionSource(entry, ownIdentifier: binding.ownIdentifier, sourceItems: sourceItems, id: id)
            try checkPositionOwner(entry, owners: owners, id: id)
        }
    }

    func discardBackgroundPositionCandidates(_ candidates: [MenuBarPositionCandidate]) {
        for candidate in candidates { positionCandidateBindings.removeValue(forKey: candidate.token) }
    }

    private func checkPositionRequest(id: String, positions: [String: Double]) throws {
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard AXIsProcessTrusted() else {
            systemModuleContinuity.removeAll()
            throw MenuBarPositionBindingError(id: id, reason: .permission)
        }
        guard !positions.isEmpty, positions.values.allSatisfy(\.isFinite) else {
            throw MenuBarPositionBindingError(id: id, reason: .invalidRequest)
        }
    }

    private func positionOwnIdentifier(_ entry: Entry) -> String? {
        guard entry.owner.pid == ProcessInfo.processInfo.processIdentifier,
              entry.owner.bundleIdentifier == Bundle.main.bundleIdentifier,
              let identifier = entry.snapshot.ownIdentifier,
              Self.anchorIdentifiers.contains(identifier) else { return nil }
        return identifier
    }

    private func checkPositionOwner(_ entry: Entry, owners: [MenuBarOwner], id: String) throws {
        do { try checkPositionOwner(element: entry.element, owner: entry.owner, owners: owners, id: id) }
        catch {
            if let reason = (error as? MenuBarPositionBindingError)?.reason,
               reason == .ownerChanged || reason == .ambiguousOwner {
                systemModuleContinuity.removeValue(forKey: id)
            }
            throw error
        }
    }

    private func checkPositionOwner(element: AXUIElement, owner: MenuBarOwner,
                                    owners: [MenuBarOwner], id: String) throws {
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard let bundle = owner.bundleIdentifier, !bundle.isEmpty, liveOwnerMatches(element: element, owner: owner) else {
            throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
        }
        // Do not collapse multiple matching process records to one instance, or
        // accept a stale caller census as a new process epoch.
        let matching = owners.filter { $0.bundleIdentifier == bundle }
        guard matching.count == 1 else { throw MenuBarPositionBindingError(id: id, reason: .ambiguousOwner) }
        guard let current = matching.first.flatMap(resolvedOwner), current.pid == owner.pid,
              current.launchTime == owner.launchTime else {
            throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
        }
    }

    private func positionKey(owner: MenuBarOwner, ownIdentifier: String?,
                             accessibilityIdentifier: String? = nil,
                             positions: [String: Double], id: String) throws -> String {
        guard let bundle = owner.bundleIdentifier, !bundle.isEmpty else {
            throw MenuBarPositionBindingError(id: id, reason: .ownerChanged)
        }
        if let ownIdentifier {
            // Demo items have different autosave names; never bind them to the
            // production application's existing preferences.
            guard !CommandLine.arguments.contains("--demo-items") else {
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            let autosave: String
            switch ownIdentifier {
            case "menu-tidy-toggle": autosave = "MenuTidyControl"
            case "menu-tidy-divider": autosave = "MenuTidyDivider"
            case "menu-tidy-always-divider": autosave = "MenuTidyAlwaysDivider"
            default: throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            let key = "status:\(bundle)::\(autosave)"
            guard positions[key] != nil else { throw MenuBarPositionBindingError(id: id, reason: .missingKey) }
            return key
        }
        if bundle == SystemModuleIdentity.ownerBundleIdentifier {
            guard let key = SystemModuleIdentity.positionKey(ownerBundleIdentifier: bundle,
                accessibilityIdentifier: accessibilityIdentifier) else {
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            guard let value = positions[key], value.isFinite else {
                throw MenuBarPositionBindingError(id: id, reason: .missingKey)
            }
            return key
        }
        let prefix = "status:\(bundle)::"
        let keys = positions.keys.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
        guard !keys.isEmpty else { throw MenuBarPositionBindingError(id: id, reason: .missingKey) }
        guard keys.count == 1, let key = keys.first else {
            throw MenuBarPositionBindingError(id: id, reason: .ambiguousKey)
        }
        return key
    }

    private func checkPositionSource(_ entry: Entry, ownIdentifier: String?,
                                     sourceItems: [AXUIElement], id: String) throws {
        if ownIdentifier == nil, SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil {
            _ = try checkSystemModuleContinuity(entry, sourceItems: sourceItems)
            return
        }
        try checkPositionSource(element: entry.element, ownIdentifier: ownIdentifier,
            sourceItems: sourceItems, id: id)
    }

    private func checkPositionSource(element: AXUIElement, ownIdentifier: String?,
                                     systemIdentifier: String? = nil,
                                     sourceItems: [AXUIElement], id: String) throws {
        guard sourceItems.filter({ CFEqual($0, element) }).count == 1 else {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        if let expectedIdentifier = ownIdentifier ?? systemIdentifier {
            var budget = PositionReadBudget()
            var matching: [AXUIElement] = []
            for item in sourceItems {
                let result = try positionAttribute(item, kAXIdentifierAttribute, id: id, budget: &budget)
                if result.error == .noValue || result.error == .attributeUnsupported { continue }
                guard result.error == .success, let value = result.value as? String else {
                    throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
                }
                if value == expectedIdentifier { matching.append(item) }
            }
            guard matching.count == 1, let match = matching.first, CFEqual(match, element) else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
        } else if sourceItems.count != 1 {
            throw MenuBarPositionBindingError(id: id, reason: .ambiguousSource)
        }
    }

    private func positionSourceItems(for entry: Entry, id: String) throws -> [AXUIElement] {
        if SystemModuleIdentity.positionKey(ownerBundleIdentifier: entry.owner.bundleIdentifier,
            accessibilityIdentifier: entry.accessibilityIdentifier) != nil {
            return try systemPositionSourceItems(owner: entry.owner, id: id)
        }
        return try positionSourceItems(owner: entry.owner, id: id)
    }

    /// Census the real system host, including its menu-bar windows. Several
    /// distinct modules are expected; exact identifier uniqueness is checked
    /// afterwards. Remote application leaves never become system-owned items.
    private func systemPositionSourceItems(owner: MenuBarOwner, id: String, includeWindows: Bool = true) throws -> [AXUIElement] {
        guard owner.bundleIdentifier == SystemModuleIdentity.ownerBundleIdentifier else {
            Self.logger.notice("systemPositionCensus complete=false stage=owner-bundle")
            throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
        }
        var budget = PositionReadBudget()
        let application = AXUIElementCreateApplication(owner.pid)
        let extrasRead = try positionAttribute(application, kAXExtrasMenuBarAttribute, id: id, budget: &budget)
        let extras: AXUIElement?
        if extrasRead.error == .success {
            guard let root = element(extrasRead.value) else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            extras = root
        } else {
            guard extrasRead.error == .noValue || extrasRead.error == .attributeUnsupported else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            extras = nil
        }
        let windows = try positionElementArray(application, attribute: kAXWindowsAttribute, id: id, budget: &budget)
        guard windows.count <= 32 else { throw MenuBarPositionBindingError(id: id, reason: .incompleteSource) }
        var pending: [(node: AXUIElement, depth: Int, ancestors: [AXUIElement], rootRole: String?)] =
            includeWindows ? windows.map { ($0, 0, [], kAXWindowRole) } : []
        if let extras { pending.append((extras, 0, [], kAXMenuBarRole)) }
        var visited: [AXUIElement] = []
        var items: [AXUIElement] = []
        var branches: [(parent: AXUIElement, children: [AXUIElement])] = []
        var foreignApplications: [(element: AXUIElement, owner: MenuBarOwner)] = []
        while let next = pending.popLast() {
            guard next.depth < 7, visited.count < 256,
                  !next.ancestors.contains(where: { CFEqual($0, next.node) }) else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            let roleRead = try positionAttribute(next.node, kAXRoleAttribute, id: id, budget: &budget)
            // macOS 27 host containers can return kAXErrorNoValue for AXRole.
            // This is not a transport failure and does not permit skipping
            // their descendants or accepting an unidentified terminal item.
            let roleMissing = roleRead.error == .noValue && next.rootRole == nil
            let role: String
            if roleMissing { role = "AXUnknown" }
            else if roleRead.error == .success, let value = roleRead.value as? String { role = value }
            else {
                Self.logger.notice("systemPositionCensus complete=false stage=role-read depth=\(next.depth) axError=\(roleRead.error.rawValue) visited=\(visited.count)")
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            if let expected = next.rootRole, expected != role {
                let safeRole = systemPositionDiagnosticRole(role)
                Self.logger.notice("systemPositionCensus complete=false stage=root-role depth=\(next.depth) role=\(safeRole, privacy: .public) expected=\(expected, privacy: .public) windows=\(windows.count) extrasPresent=\(extras != nil)")
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(next.node, &pid) == .success, pid > 0 else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            // The same retained object can be exposed by both extras and a
            // host window. Distinct objects with the same identifier remain
            // distinct and will fail the unique-target check.
            if visited.contains(where: { CFEqual($0, next.node) }) { continue }
            visited.append(next.node)
            // A hosted status item can expose its original application's AX
            // root below a MenuBarAgent container. It is a foreign ownership
            // boundary, not an unidentified system-module container. Require
            // the canonical application object and a live process epoch;
            // arbitrary foreign groups and remote lookalikes still fail.
            if next.depth > 0, role == kAXApplicationRole, pid != owner.pid {
                let canonical = CFEqual(next.node, AXUIElementCreateApplication(pid))
                let running = NSRunningApplication(processIdentifier: pid)
                let foreignOwner: MenuBarOwner? = running.flatMap { app in
                    app.isTerminated ? nil : resolvedOwner(MenuBarOwner(pid: pid,
                        bundleIdentifier: app.bundleIdentifier, name: "",
                        launchTime: app.launchDate?.timeIntervalSince1970 ?? 0))
                }
                guard canonical, let foreignOwner,
                      liveOwnerMatches(element: next.node, owner: foreignOwner) else {
                    Self.logger.notice("systemPositionCensus complete=false stage=foreign-application-identity depth=\(next.depth) canonical=\(canonical) ownerResolved=\(foreignOwner != nil)")
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
                foreignApplications.append((next.node, foreignOwner))
                Self.logger.notice("systemPositionCensus stage=foreign-application-boundary depth=\(next.depth) canonical=true ownerCurrent=true")
                continue
            }
            if roleMissing {
                guard pid == owner.pid else {
                    Self.logger.notice("systemPositionCensus complete=false stage=roleless-owner depth=\(next.depth)")
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
                let identifierRead = try positionAttribute(next.node, kAXIdentifierAttribute, id: id, budget: &budget)
                let identifier: String?
                if identifierRead.error == .success, let value = identifierRead.value as? String { identifier = value }
                else if identifierRead.error == .noValue || identifierRead.error == .attributeUnsupported { identifier = nil }
                else {
                    Self.logger.notice("systemPositionCensus complete=false stage=roleless-identifier depth=\(next.depth) axError=\(identifierRead.error.rawValue)")
                    throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
                }
                let knownModule = SystemModuleIdentity.positionKey(ownerBundleIdentifier: owner.bundleIdentifier,
                    accessibilityIdentifier: identifier) != nil
                let children = try positionElementArray(next.node, attribute: kAXChildrenAttribute, id: id,
                    budget: &budget, allowNoValue: knownModule)
                if children.isEmpty {
                    guard knownModule else {
                        Self.logger.notice("systemPositionCensus complete=false stage=roleless-unidentified-leaf depth=\(next.depth) identifierPresent=\(identifier != nil)")
                        throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
                    }
                    items.append(next.node)
                    Self.logger.notice("systemPositionCensus stage=roleless-module-leaf depth=\(next.depth)")
                    continue
                }
                guard pending.count + children.count <= 512 else {
                    throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
                }
                Self.logger.notice("systemPositionCensus stage=roleless-container depth=\(next.depth) children=\(children.count)")
                branches.append((next.node, children))
                pending.append(contentsOf: children.map { ($0, next.depth + 1, next.ancestors + [next.node], nil) })
                continue
            }
            if role == kAXMenuRole || role == kAXMenuItemRole { continue }
            if role == kAXMenuBarItemRole || role == kAXButtonRole || (role == kAXMenuButtonRole && pid != owner.pid) {
                if pid == owner.pid { items.append(next.node) }
                continue
            }
            guard pid == owner.pid,
                  role == kAXGroupRole || role == kAXMenuBarRole || (role == kAXWindowRole && next.depth == 0) else {
                let safeRole = systemPositionDiagnosticRole(role)
                Self.logger.notice("systemPositionCensus complete=false stage=container-role depth=\(next.depth) role=\(safeRole, privacy: .public) ownerMatches=\(pid == owner.pid) visited=\(visited.count) systemItems=\(items.count)")
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            let children = try positionElementArray(next.node, attribute: kAXChildrenAttribute, id: id, budget: &budget)
            guard pending.count + children.count <= 512 else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            branches.append((next.node, children))
            pending.append(contentsOf: children.map { ($0, next.depth + 1, next.ancestors + [next.node], nil) })
        }
        // Re-read every traversed edge and both root collections. A changing
        // or partial tree cannot turn duplicate system identifiers into one.
        for branch in branches {
            let children = try positionElementArray(branch.parent, attribute: kAXChildrenAttribute, id: id, budget: &budget)
            guard children.count == branch.children.count,
                  branch.children.allSatisfy({ child in children.contains(where: { CFEqual($0, child) }) }) else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
        }
        let currentWindows = try positionElementArray(application, attribute: kAXWindowsAttribute, id: id, budget: &budget)
        guard currentWindows.count == windows.count,
              windows.allSatisfy({ window in currentWindows.contains(where: { CFEqual($0, window) }) }) else {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        let currentExtras = try positionAttribute(application, kAXExtrasMenuBarAttribute, id: id, budget: &budget)
        if let extras {
            guard currentExtras.error == .success, let current = element(currentExtras.value), CFEqual(current, extras) else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
        } else if currentExtras.error != .noValue && currentExtras.error != .attributeUnsupported {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        // Parent edges above still include every foreign boundary. Revalidate
        // those exact roots as well, so a replaced application or process epoch
        // cannot hide a newly system-owned branch from this census.
        for foreign in foreignApplications {
            let role = try positionAttribute(foreign.element, kAXRoleAttribute, id: id, budget: &budget)
            guard role.error == .success, role.value as? String == kAXApplicationRole,
                  CFEqual(foreign.element, AXUIElementCreateApplication(foreign.owner.pid)),
                  liveOwnerMatches(element: foreign.element, owner: foreign.owner) else {
                Self.logger.notice("systemPositionCensus complete=false stage=foreign-application-recheck axError=\(role.error.rawValue)")
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
        }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < budget.deadline else {
            throw MenuBarPositionBindingError(id: id, reason: Task.isCancelled ? .cancelled : .incompleteSource)
        }
        Self.logger.notice("systemPositionCensus complete=true windows=\(windows.count) extrasPresent=\(extras != nil) visited=\(visited.count) systemItems=\(items.count) foreignApplications=\(foreignApplications.count)")
        return items
    }

    /// Log only an allowlist of structural role names. Never emit an arbitrary
    /// AX value, title, description, identifier, app name or requested category.
    private func systemPositionDiagnosticRole(_ role: String) -> String {
        let known: Set<String> = ["AXWindow", "AXDialog", "AXUnknown", "AXGroup", "AXMenuBar",
            "AXButton", "AXMenuBarItem", "AXImage", "AXStaticText", "AXMenu", "AXMenuItem",
            "AXApplication", "AXScrollArea", "AXSplitGroup", "AXLayoutArea"]
        return known.contains(role) ? role : "other"
    }

    private func positionElementArray(_ node: AXUIElement, attribute: String, id: String,
                                      budget: inout PositionReadBudget, allowNoValue: Bool = false) throws -> [AXUIElement] {
        let read = try positionAttribute(node, attribute, id: id, budget: &budget)
        // Only an exact, known system-module leaf opts in. Unsupported or
        // failed child reads never stand in for an empty collection.
        if allowNoValue && read.error == .noValue { return [] }
        guard read.error == .success, let values = read.value as? [CFTypeRef], values.count <= 256 else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        var result: [AXUIElement] = []
        for value in values {
            guard let child = element(value), !result.contains(where: { CFEqual($0, child) }) else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            result.append(child)
        }
        return result
    }

    /// Complete original-source enumeration, deliberately independent of scan's
    /// geometry filtering and weak origin/host mirror deduplication. A menu-bar
    /// item is a terminal identity; its popup menu is not another status item.
    private func positionSourceItems(owner: MenuBarOwner, id: String) throws -> [AXUIElement] {
        var budget = PositionReadBudget()
        let application = AXUIElementCreateApplication(owner.pid)
        let extras = try positionAttribute(application, kAXExtrasMenuBarAttribute, id: id, budget: &budget)
        guard extras.error == .success, let root = element(extras.value) else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var items: [AXUIElement] = []
        var branches: [(parent: AXUIElement, children: [AXUIElement])] = []
        while let next = pending.popLast() {
            guard next.depth < 7, visited.count < 128,
                  !visited.contains(where: { CFEqual($0, next.element) }) else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            visited.append(next.element)
            var pid: pid_t = 0
            guard AXUIElementGetPid(next.element, &pid) == .success, pid == owner.pid else {
                throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
            }
            let roleRead = try positionAttribute(next.element, kAXRoleAttribute, id: id, budget: &budget)
            guard roleRead.error == .success, let role = roleRead.value as? String else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            if next.depth > 0 && (role == kAXMenuBarItemRole || role == kAXButtonRole) {
                items.append(next.element)
                continue
            }
            guard (next.depth == 0 && role == kAXMenuBarRole) || (next.depth > 0 && role == kAXGroupRole) else {
                throw MenuBarPositionBindingError(id: id, reason: .unsupportedSource)
            }
            let childRead = try positionAttribute(next.element, kAXChildrenAttribute, id: id, budget: &budget)
            guard childRead.error == .success, let values = childRead.value as? [CFTypeRef], values.count <= 128 else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            var children: [AXUIElement] = []
            for value in values {
                guard let child = element(value) else {
                    throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
                }
                children.append(child)
                pending.append((child, next.depth + 1))
            }
            branches.append((next.element, children))
        }
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard ProcessInfo.processInfo.systemUptime < budget.deadline else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        // A parent gaining or losing children during enumeration must not turn
        // a partial view into a singleton proof. Compare identities, not order;
        // a preference operation is expected to change their relative order.
        for branch in branches {
            let reread = try positionAttribute(branch.parent, kAXChildrenAttribute, id: id, budget: &budget)
            guard reread.error == .success, let values = reread.value as? [CFTypeRef],
                  values.count == branch.children.count else {
                throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
            }
            var currentChildren: [AXUIElement] = []
            for value in values {
                guard let child = element(value) else {
                    throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
                }
                currentChildren.append(child)
            }
            for child in branch.children {
                guard currentChildren.filter({ CFEqual($0, child) }).count == 1 else {
                    throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
                }
            }
        }
        // Root replacement during enumeration invalidates the whole census.
        let currentRoot = try positionAttribute(application, kAXExtrasMenuBarAttribute, id: id, budget: &budget)
        guard currentRoot.error == .success, let current = element(currentRoot.value), CFEqual(current, root) else {
            throw MenuBarPositionBindingError(id: id, reason: .identityChanged)
        }
        return items
    }

    private func positionAttribute(_ node: AXUIElement, _ name: String, id: String,
                                   budget: inout PositionReadBudget) throws -> (error: AXError, value: CFTypeRef?) {
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        let remaining = budget.deadline - ProcessInfo.processInfo.systemUptime
        guard budget.remaining > 0, remaining > 0 else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        budget.remaining -= 1
        guard AXUIElementSetMessagingTimeout(node, Float(min(0.12, remaining))) == .success else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        let result = copyAttribute(node, name)
        guard !Task.isCancelled else { throw MenuBarPositionBindingError(id: id, reason: .cancelled) }
        guard ProcessInfo.processInfo.systemUptime < budget.deadline else {
            throw MenuBarPositionBindingError(id: id, reason: .incompleteSource)
        }
        return result
    }

    /// Preflight only: call before changing spacer lengths or revealing overflow.
    /// No attribute is written and no accessibility action is performed here.
    func validateBackgroundMoveSupport(ids: [String]) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        let uniqueIDs = Set(ids)
        var unsupported = 0
        var unavailable = 0
        for id in uniqueIDs {
            try Task.checkCancellation()
            guard let entry = entries[id], entry.snapshot.canMove,
                  liveOwnerMatches(entry) else { throw MenuBarAccessError.disappeared }
            let capability = attributeIsSettable(entry.element, kAXPositionAttribute)
            guard liveOwnerMatches(entry) else { throw MenuBarAccessError.disappeared }
            if capability.error == .success {
                if !capability.settable { unsupported += 1 }
            } else if capability.error == .attributeUnsupported || capability.error == .notImplemented {
                unsupported += 1
            } else {
                unavailable += 1
            }
        }
        Self.logger.notice("backgroundMovePreflight requested=\(uniqueIDs.count) unsupported=\(unsupported) unavailable=\(unavailable)")
        guard unsupported == 0, unavailable == 0 else {
            var details: [String] = []
            if unsupported > 0 { details.append("\(unsupported) 个待应用图标未提供后台移动接口") }
            if unavailable > 0 { details.append("\(unavailable) 个待应用图标的后台移动能力暂时无法确认") }
            throw MenuBarAccessError.geometryDetail(details.joined(separator: "；") + "。尚未展开或移动菜单栏，分类选择已保留；未接管鼠标。")
        }
    }

    func move(id: String, before anchorID: String) async throws {
        try await move(id: id, relativeTo: anchorID, placement: .before)
    }

    func move(id: String, after anchorID: String) async throws {
        try await move(id: id, relativeTo: anchorID, placement: .after)
    }

    private func move(id: String, relativeTo anchorID: String, placement: MovePlacement) async throws {
        cancellationRequested = false
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarAccessError.permission }
        guard id != anchorID, let entry = entries[id], let anchor = entries[anchorID],
              entry.snapshot.canMove || entry.snapshot.ownIdentifier != nil,
              liveOwnerMatches(entry), liveOwnerMatches(anchor) else { throw MenuBarAccessError.disappeared }
        let capability = attributeIsSettable(entry.element, kAXPositionAttribute)
        Self.logger.notice("backgroundMove positionSettable=\(capability.settable) axError=\(capability.error.rawValue)")
        guard capability.error == .success, capability.settable else {
            throw MenuBarAccessError.geometryDetail("此图标未提供后台移动接口，未移动鼠标；分类选择仍待应用。")
        }
        guard let sourceRect = entryFrame(entry), let anchorRect = entryFrame(anchor),
              sourceRect.width > 0, sourceRect.height > 0, anchorRect.width > 0, anchorRect.height > 0,
              abs(sourceRect.midY - anchorRect.midY) < 8,
              let band = menuBands.first(where: {
                  $0.contains(CGPoint(x: sourceRect.midX, y: sourceRect.midY)) &&
                  $0.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY))
              }) else { throw MenuBarAccessError.invalidGeometry }
        let destinationX = placement == .before ? anchorRect.minX - sourceRect.width - 3 : anchorRect.maxX + 3
        let destination = CGPoint(x: destinationX, y: sourceRect.minY)
        let requestedFrame = CGRect(origin: destination, size: sourceRect.size)
        guard destination.x.isFinite, destination.y.isFinite, band.contains(requestedFrame) else {
            throw MenuBarAccessError.differentScreen
        }
        try await Task.sleep(for: .milliseconds(100))
        guard !cancellationRequested, !Task.isCancelled else { throw MenuBarAccessError.cancelled }
        guard liveOwnerMatches(entry), liveOwnerMatches(anchor), entryFrame(entry) == sourceRect,
              entryFrame(anchor) == anchorRect else { throw MenuBarAccessError.disappeared }
        var position = destination
        guard let value = AXValueCreate(.cgPoint, &position) else { throw MenuBarAccessError.invalidGeometry }
        let pointerBefore = CGEvent(source: nil)?.location
        let result = setAXAttribute(entry.element, kAXPositionAttribute, value)
        Self.logger.notice("backgroundMove setAttempted=true axError=\(result.rawValue)")
        defer {
            let pointerAfter = CGEvent(source: nil)?.location
            let unchanged = pointerBefore != nil && pointerBefore == pointerAfter
            Self.logger.notice("backgroundMove pointerUnchanged=\(unchanged) pointerObservationAvailable=\(pointerBefore != nil && pointerAfter != nil)")
        }
        // The setter's return value is not a movement acknowledgement. Even a
        // timeout receives read-only verification, never another write attempt.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var previous: (source: CGRect, anchor: CGRect)?
        var finalSource: CGRect?
        var finalAnchor: CGRect?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard !cancellationRequested, !Task.isCancelled else { throw MenuBarAccessError.cancelled }
            guard liveOwnerMatches(entry), liveOwnerMatches(anchor) else { throw MenuBarAccessError.disappeared }
            finalSource = entryFrame(entry)
            finalAnchor = entryFrame(anchor)
            if let current = finalSource, let reference = finalAnchor,
               current != sourceRect, current.width > 0, current.height > 0,
               reference.width > 0, reference.height > 0, band.intersects(current), band.intersects(reference),
               abs(current.midY - reference.midY) < 8,
               placement.isSatisfied(source: current, anchor: reference) {
                if let previous, previous.source == current, previous.anchor == reference { return }
                previous = (current, reference)
            } else { previous = nil }
        }
        Self.logger.error("backgroundMove verified=false placement=\(placement.rawValue, privacy: .public) sourceBefore=\(String(describing: sourceRect), privacy: .public) sourceAfter=\(String(describing: finalSource), privacy: .public) anchorAfter=\(String(describing: finalAnchor), privacy: .public)")
        throw MenuBarAccessError.geometryDetail("后台移动请求尚未产生连续两次可确认的位置变化；未发送鼠标或键盘事件，分类选择仍待应用。")
    }

    /// Bounded, read-only capability inventory. Ordinals are local to this call;
    /// user labels, identifiers and custom action names never enter the log.
    func inspectNonintrusiveCapabilities() {
        guard AXIsProcessTrusted() else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        let candidates = entries.values.sorted { $0.snapshot.id < $1.snapshot.id }
        var inspected = 0
        var originalWritable = 0
        var hostWritable = 0
        for entry in candidates.prefix(64) {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard liveOwnerMatches(entry) else { continue }
            inspected += 1
            let original = logNonintrusiveCapability(entry.element, ordinal: inspected, source: "original")
            if original { originalWritable += 1 }
            if let host = entry.hostPresentation, entryFrame(entry) != nil, let container = host.path.first {
                if logNonintrusiveCapability(container, ordinal: inspected, source: "validated-host") { hostWritable += 1 }
            }
        }
        Self.logger.notice("backgroundCapabilitySummary inspected=\(inspected) candidates=\(candidates.count) originalPositionWritable=\(originalWritable) hostPositionWritable=\(hostWritable) complete=\(inspected == candidates.count)")
    }

    private func logNonintrusiveCapability(_ node: AXUIElement, ordinal: Int, source: String) -> Bool {
        let position = attributeIsSettable(node, kAXPositionAttribute)
        let actions = copyAXActions(node)
        let knownActions = [kAXPressAction, kAXShowMenuAction, kAXRaiseAction, kAXCancelAction,
                           kAXIncrementAction, kAXDecrementAction, kAXConfirmAction, kAXPickAction]
        let summary = knownActions.filter { actions.names.contains($0) }.joined(separator: ",")
        let rawRole = text(node, kAXRoleAttribute)
        let knownRoles = [kAXMenuBarItemRole, kAXButtonRole, kAXGroupRole, kAXMenuBarRole, kAXWindowRole, kAXUnknownRole]
        let role = rawRole.flatMap { knownRoles.contains($0) ? $0 : nil } ?? "other-or-unavailable"
        Self.logger.notice("backgroundCapability ordinal=\(ordinal) source=\(source, privacy: .public) role=\(role, privacy: .public) positionSettable=\(position.settable) positionError=\(position.error.rawValue) actionsError=\(actions.error.rawValue) knownActions=\(summary, privacy: .public) totalActions=\(actions.names.count)")
        return position.error == .success && position.settable
    }

    private func sourceMatchesHitTest(_ source: AXUIElement, at point: CGPoint, context: String,
                                      onFailure: ((HitTestFailure) -> Void)? = nil) -> Bool {
        guard scanCanContinue else { return false }
        var visited: [AXUIElement] = []
        var matched = false
        defer {
            let diagnosticContext = context == "source" || context == "anchor" || context == "visibility-inspection" ||
                context == "overflow-park" || context.hasPrefix("overflow-park-")
            if !matched && diagnosticContext {
                // Read only structural AX attributes after failure. Never log
                // identifiers, descriptions, titles, or application/window names.
                func structuralRole(_ node: AXUIElement) -> String {
                    guard let role = text(node, kAXRoleAttribute) else { return "unavailable" }
                    guard role.hasPrefix("AX"), role.count <= 64,
                          role.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
                        return "nonstandard"
                    }
                    return role
                }
                var diagnosticSourcePID: pid_t = 0
                let sourcePIDResult = AXUIElementGetPid(source, &diagnosticSourcePID)
                let sourceRole = structuralRole(source)
                let sourceFrame = frame(source)
                let sourceFrameDescription = sourceFrame.map { NSStringFromRect($0) } ?? "unavailable"
                let sourceIdentifier = text(source, kAXIdentifierAttribute)
                Self.logger.error("hitTestFailure context=\(context, privacy: .public) sourcePID=\(diagnosticSourcePID) sourcePIDError=\(sourcePIDResult.rawValue) sourceRole=\(sourceRole, privacy: .public) sourceFrame=\(sourceFrameDescription, privacy: .public) sourceIdentifierPresent=\(sourceIdentifier != nil) chainCount=\(visited.count)")
                var failure = HitTestFailure.unconfirmed
                var firstHitPID: pid_t?
                for (depth, node) in visited.enumerated() {
                    var nodePID: pid_t = 0
                    let nodePIDResult = AXUIElementGetPid(node, &nodePID)
                    let nodeRole = structuralRole(node)
                    let nodeFrame = frame(node)
                    let nodeFrameDescription = nodeFrame.map { NSStringFromRect($0) } ?? "unavailable"
                    let nodeIdentifier = text(node, kAXIdentifierAttribute)
                    let identifiersEqual = sourceIdentifier != nil && sourceIdentifier == nodeIdentifier
                    let pidsEqual = sourcePIDResult == .success && nodePIDResult == .success && diagnosticSourcePID == nodePID
                    let framesEqual = sourceFrame != nil && sourceFrame == nodeFrame
                    let cfEqual = CFEqual(node, source)
                    Self.logger.error("hitTestFailure context=\(context, privacy: .public) depth=\(depth) nodePID=\(nodePID) nodePIDError=\(nodePIDResult.rawValue) nodeRole=\(nodeRole, privacy: .public) nodeFrame=\(nodeFrameDescription, privacy: .public) nodeIdentifierPresent=\(nodeIdentifier != nil) identifierEqualsSource=\(identifiersEqual) pidEqualsSource=\(pidsEqual) frameEqualsSource=\(framesEqual) cfEqualsSource=\(cfEqual)")
                    if depth == 0, nodePIDResult == .success, nodePID > 0 { firstHitPID = nodePID }
                    // The system-wide hit selected this window's topmost content.
                    // Different PIDs alone cannot prove occlusion: MenuBarAgent
                    // is a normal host for remote status-item representations.
                    if onFailure != nil, case .unconfirmed = failure,
                       sourcePIDResult == .success, diagnosticSourcePID > 0,
                       nodePIDResult == .success, nodePID == firstHitPID,
                       nodePID != diagnosticSourcePID, nodeRole == kAXWindowRole,
                       nodeFrame?.contains(point) == true,
                       let application = NSRunningApplication(processIdentifier: nodePID),
                       !application.isTerminated, let bundleIdentifier = application.bundleIdentifier,
                       bundleIdentifier != "com.apple.MenuBarAgent", application.localizedName != "MenuBarAgent" {
                        // The name is transient UI context only; never log or
                        // persist it, or use it to authorize a pointer action.
                        let name = application.localizedName.map {
                            String($0.components(separatedBy: .controlCharacters).joined(separator: " ")
                                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                        }.flatMap { $0.isEmpty ? nil : $0 }
                        failure = .coveredByWindow(applicationName: name)
                    }
                }
                onFailure?(failure)
            }
        }
        let query = Self.copyElementAtPositionOnMainThread(point)
        let result = query.error
        var hit = query.element
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
            visited.append(node)
            if CFEqual(node, source) { matched = true; return true }
            var nodePID: pid_t = 0
            AXUIElementGetPid(node, &nodePID)
            if let identifier = text(source, kAXIdentifierAttribute), identifier == text(node, kAXIdentifierAttribute),
               nodePID == sourcePID, frame(node) == frame(source) { matched = true; return true }
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
        if let leftID = lhs.identifier, let rightID = rhs.identifier, leftID != rightID { return false }
        // An observed direct AX lineage is identity evidence even when origin
        // and host report different positions. Shared owner/name/order is not.
        if lhs.hostPresentation?.path.dropFirst().contains(where: { CFEqual($0, rhs.element) }) == true ||
            rhs.hostPresentation?.path.dropFirst().contains(where: { CFEqual($0, lhs.element) }) == true { return true }
        // Preserve the existing mirror rule using the two original AX frames;
        // never infer a host binding by matching its presentation coordinates.
        guard !lhs.requiresHostPresentation, !rhs.requiresHostPresentation,
              lhs.sourceFrame == rhs.sourceFrame, lhs.source != rhs.source,
              (lhs.role == kAXMenuBarItemRole && rhs.role == kAXButtonRole) ||
              (lhs.role == kAXButtonRole && rhs.role == kAXMenuBarItemRole) else { return false }
        return true
    }
    private func resolvedOwner(_ owner: MenuBarOwner) -> MenuBarOwner? {
        guard owner.pid > 0 else { return nil }
        if owner.launchTime.isFinite && owner.launchTime > 0 { return owner }
        // Background system applications such as MenuBarAgent may have no
        // NSRunningApplication.launchDate. Read their real process start time
        // rather than using zero as a reusable process identity.
        guard let launchTime = MenuBarProcessIdentity.kernelLaunchTime(pid: owner.pid) else { return nil }
        return MenuBarOwner(pid: owner.pid, bundleIdentifier: owner.bundleIdentifier,
                            name: owner.name, launchTime: launchTime)
    }
    private func walk(_ node: AXUIElement, ownersByPID: [pid_t: MenuBarOwner], source: CandidateSource,
                      enumerationRootPID: pid_t, depth: Int, remaining: inout Int, into output: inout [Candidate],
                      ancestors: [AXUIElement] = []) {
        guard scanCanContinue else { return }
        guard depth < 7, remaining > 0, !Task.isCancelled else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth,
                stage: depth >= 7 ? "filtered:depth-limit" : (remaining <= 0 ? "filtered:node-budget" : "filtered:cancelled"))
            return
        }
        remaining -= 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        // A MenuBarAgent window can expose an application's ordinary menu bar
        // alongside its status items. Both contain AXMenuBarItem leaves inside
        // the screen's menu band. Stop only the canonical AXMenuBar subtree;
        // AXExtrasMenuBar and remote status-item hosting keep their existing
        // traversal and identity checks. Labels and coordinates are not proof.
        if source == .hostWindow, role == kAXMenuBarRole,
           isApplicationMenuBar(node, hostPID: enumerationRootPID) {
            Self.logger.notice("scanApplicationMenu excluded=true canonicalRoot=true")
            return
        }
        if role == kAXMenuRole || role == kAXMenuItemRole {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:menu-content-role")
            return
        }
        let children = elements(attribute(node, kAXChildrenAttribute))
        let directHostButton = source == .hostWindow && depth == 2 && role == kAXButtonRole
        if role != kAXMenuBarItemRole && !directHostButton {
            let count = output.count
            for child in children.prefix(60) {
                walk(child, ownersByPID: ownersByPID, source: source, enumerationRootPID: enumerationRootPID,
                    depth: depth + 1, remaining: &remaining, into: &output, ancestors: ancestors + [node])
            }
            if output.count > count {
                if source == .hostWindow, depth == 1 {
                    bindHostContainer(node, children: children, ownersByPID: ownersByPID,
                        enumerationRootPID: enumerationRootPID, firstCandidate: count, remaining: remaining, into: &output)
                }
                logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:descendant-preferred")
                return
            }
        }
        // Read AX objects directly in this actor. Swift 6.2 diagnoses capturing
        // these non-Sendable objects in nested nil-coalescing autoclosures.
        var identifier = text(node, kAXIdentifierAttribute)
        if identifier == nil {
            for child in children.prefix(2) {
                if let childIdentifier = text(child, kAXIdentifierAttribute) {
                    identifier = childIdentifier
                    break
                }
            }
        }
        var label = text(node, kAXDescriptionAttribute)
        if label == nil {
            label = text(node, kAXTitleAttribute)
        }
        if label == nil {
            for child in children.prefix(2) {
                if let childDescription = text(child, kAXDescriptionAttribute) {
                    label = childDescription
                    break
                }
                if let childTitle = text(child, kAXTitleAttribute) {
                    label = childTitle
                    break
                }
            }
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, let owner = ownersByPID[pid] else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:pid-or-owner-unavailable")
            return
        }
        if owner.name == "MenuBarAgent", let identifier, ["overflow", "sectionplaceholder"].contains(where: { identifier.lowercased().contains($0) }) { return }
        let sourceRect = frame(node)
        let sourceIsUsable = sourceRect.map { rect in
            rect.width > 0 && rect.height > 0 && rect.height <= 64 &&
                (rect.width <= 500 || identifier?.hasPrefix("menu-tidy-") == true) &&
                menuBands.contains(where: { $0.intersects(rect) })
        } ?? false
        // A hidden origin may report no rectangle at all. Keep only a provisional
        // direct remote item here; the parent must establish its unique binding,
        // or scan removes it before identity/geometry can reach the model.
        guard sourceIsUsable || (source == .hostWindow && depth == 2 && ancestors.count == 2 &&
            (role == kAXMenuBarItemRole || role == kAXButtonRole)) else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:origin-geometry-without-host-path")
            return
        }
        guard role == kAXMenuBarItemRole || role == kAXButtonRole || (identifier != nil && label != nil) else {
            logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "filtered:role-or-metadata")
            return
        }
        output.append(Candidate(element: node, owner: owner, identifier: identifier,
                                name: String((label ?? owner.name).prefix(100)), sourceFrame: sourceRect ?? .zero,
                                requiresHostPresentation: !sourceIsUsable,
                                hostPresentation: nil, role: role, source: source,
                                enumerationRootPID: enumerationRootPID, ancestors: ancestors))
        logOwnWalk(node, ownersByPID: ownersByPID, source: source, depth: depth, stage: "candidate-accepted")
    }

    private func isApplicationMenuBar(_ node: AXUIElement, hostPID: pid_t) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, pid > 0, pid != hostPID else { return false }
        if scanApplicationMenuBarQueries.insert(pid).inserted {
            let application = AXUIElementCreateApplication(pid)
            let read = copyAttribute(application, kAXMenuBarAttribute)
            if read.error == .success, let root = element(read.value) {
                scanApplicationMenuBarRoots[pid] = root
            }
        }
        guard let root = scanApplicationMenuBarRoots[pid] else { return false }
        return CFEqual(root, node)
    }

    /// Do not let the hidden-item continuity fallback resurrect an ordinary
    /// menu leaf that a prior scan accepted. Only a current exact root lineage
    /// excludes it; unreadable parents do not invalidate real hidden items.
    private func belongsToScannedApplicationMenu(_ entry: Entry) -> Bool {
        guard let root = scanApplicationMenuBarRoots[entry.owner.pid] else { return false }
        var node: AXUIElement? = entry.element
        var visited: [AXUIElement] = []
        for _ in 0..<7 {
            guard let current = node, !visited.contains(where: { CFEqual($0, current) }) else { return false }
            if CFEqual(current, root) { return true }
            visited.append(current)
            node = element(attribute(current, kAXParentAttribute))
        }
        return false
    }

    private func bindHostContainer(_ container: AXUIElement, children: [AXUIElement],
                                   ownersByPID: [pid_t: MenuBarOwner], enumerationRootPID: pid_t,
                                   firstCandidate: Int, remaining: Int, into candidates: inout [Candidate]) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              remaining > 0, children.count <= 60,
              candidates.count == firstCandidate + 1,
              let hostOwner = ownersByPID[enumerationRootPID],
              hostOwner.bundleIdentifier == "com.apple.MenuBarAgent" else { return }
        var containerPID: pid_t = 0
        guard AXUIElementGetPid(container, &containerPID) == .success, containerPID == hostOwner.pid else { return }
        var remoteChildren: [AXUIElement] = []
        for child in children {
            var pid: pid_t = 0
            guard AXUIElementGetPid(child, &pid) == .success else { return }
            if pid != hostOwner.pid {
                guard ownersByPID[pid] != nil else { return }
                remoteChildren.append(child)
            }
        }
        let candidate = candidates[firstCandidate]
        guard remoteChildren.count == 1, let remote = remoteChildren.first,
              candidate.owner.pid != hostOwner.pid,
              let start = candidate.ancestors.firstIndex(where: { CFEqual($0, container) }),
              start == 1, let window = candidate.ancestors.first,
              candidate.role == kAXMenuBarItemRole || candidate.role == kAXButtonRole else { return }
        let path = Array(candidate.ancestors[start...]) + [candidate.element]
        guard (2...6).contains(path.count), CFEqual(path[1], remote) else { return }
        var budget = MirrorReadBudget()
        guard let hostFrame = mirrorFrame(container, budget: &budget),
              validHostFrame(hostFrame, identifier: candidate.identifier) else { return }
        let binding = HostPresentation(hostOwner: hostOwner, window: window,
            path: path, snapshotFrame: hostFrame, mirrorIdentity: nil)
        if path.count == 2 {
            // Keep the established direct-item fast path. Live consumers still
            // re-read the complete window/container edge before using its frame.
            var remotePID: pid_t = 0
            guard AXUIElementGetPid(remote, &remotePID) == .success, remotePID == candidate.owner.pid,
                  validHostWindow(window, ownerPID: hostOwner.pid, containing: hostFrame) else { return }
        } else {
            // The regular walk's geometry-filtered count is not uniqueness
            // evidence for an application subtree embedded in a host container.
            guard currentHostFrame(binding, original: candidate.element, owner: candidate.owner,
                identifier: candidate.identifier, budget: &budget) == hostFrame else {
                Self.logger.notice("hostPresentation extendedPathBound=false pathDepth=\(path.count)")
                return
            }
        }
        candidates[firstCandidate].hostPresentation = binding
        if path.count > 2 {
            Self.logger.notice("hostPresentation extendedPathBound=true pathDepth=\(path.count)")
        }
    }

    /// A source menu-bar item can expose the host's remote button as its one
    /// actual child even when the parent has no identifier or a stale frame.
    /// Neither names nor position equality establish this bridge.
    private func sourceChildBinding(origin: Candidate, projection: Candidate,
                                    candidates: [Candidate]) -> HostPresentation? {
        guard origin.source == .applicationExtras, projection.source == .hostWindow,
              origin.enumerationRootPID == origin.owner.pid,
              origin.role == kAXMenuBarItemRole, projection.role == kAXButtonRole,
              origin.owner.pid == projection.owner.pid,
              origin.owner.launchTime == projection.owner.launchTime,
              origin.owner.bundleIdentifier == projection.owner.bundleIdentifier,
              let host = projection.hostPresentation, host.mirrorIdentity == nil,
              let remote = host.path.last, CFEqual(remote, projection.element),
              !CFEqual(origin.element, remote) else { return nil }
        // Do not choose between multiple observed host containers for the same
        // remote object. The ordinary scan's weak frame deduplication is unused.
        guard candidates.filter({ $0.source == .applicationExtras && CFEqual($0.element, origin.element) }).count == 1,
              candidates.filter({ $0.source == .hostWindow && CFEqual($0.element, remote) }).count == 1 else {
            Self.logger.notice("sourceChildBridge accepted=false stage=ambiguous-projection")
            return nil
        }
        var identity = MirrorIdentity(identifier: nil, originPath: origin.ancestors + [origin.element])
        identity.directChild = remote
        var budget = MirrorReadBudget()
        guard sourceChildIdentityIsCurrent(identity, original: origin.element, remote: remote,
                                          owner: origin.owner, budget: &budget) else { return nil }
        let binding = HostPresentation(hostOwner: host.hostOwner, window: host.window,
            path: host.path, snapshotFrame: host.snapshotFrame, mirrorIdentity: identity)
        guard currentHostFrame(binding, original: origin.element, owner: origin.owner,
            identifier: origin.identifier, budget: &budget) == host.snapshotFrame else {
            Self.logger.notice("sourceChildBridge accepted=false stage=host-recheck")
            return nil
        }
        Self.logger.notice("sourceChildBridge accepted=true stage=source-child-and-host-confirmed")
        return binding
    }

    private func sourceChildIdentityIsCurrent(_ identity: MirrorIdentity, original: AXUIElement,
                                              remote: AXUIElement, owner: MenuBarOwner,
                                              budget: inout MirrorReadBudget) -> Bool {
        guard budget.isValid, (2...7).contains(identity.originPath.count),
              let root = identity.originPath.first, let last = identity.originPath.last,
              let retainedChild = identity.directChild, CFEqual(last, original), CFEqual(retainedChild, remote),
              liveOwnerMatches(element: original, owner: owner), liveOwnerMatches(element: remote, owner: owner),
              mirrorText(original, kAXRoleAttribute, budget: &budget) == kAXMenuBarItemRole,
              mirrorText(remote, kAXRoleAttribute, budget: &budget) == kAXButtonRole else {
            Self.logger.notice("sourceChildBridge accepted=false stage=identity-or-role")
            return false
        }
        let application = AXUIElementCreateApplication(owner.pid)
        let rootRead = mirrorAttribute(application, kAXExtrasMenuBarAttribute, budget: &budget)
        guard rootRead.error == .success, let currentRoot = element(rootRead.value), CFEqual(currentRoot, root) else {
            Self.logger.notice("sourceChildBridge accepted=false stage=origin-root")
            return false
        }
        var visited: [AXUIElement] = []
        for index in 0..<(identity.originPath.count - 1) {
            let parent = identity.originPath[index]
            let child = identity.originPath[index + 1]
            guard budget.isValid, !visited.contains(where: { CFEqual($0, parent) }),
                  liveOwnerMatches(element: parent, owner: owner),
                  let children = completeMirrorChildren(parent, budget: &budget),
                  children.filter({ CFEqual($0, child) }).count == 1 else {
                Self.logger.notice("sourceChildBridge accepted=false stage=origin-edge")
                return false
            }
            visited.append(parent)
        }
        guard !visited.contains(where: { CFEqual($0, original) }),
              let children = completeMirrorChildren(original, budget: &budget) else {
            Self.logger.notice("sourceChildBridge accepted=false stage=source-children-unavailable")
            return false
        }
        guard children.count == 1, let child = children.first, CFEqual(child, remote) else {
            Self.logger.notice("sourceChildBridge accepted=false stage=source-child-not-equal childCount=\(children.count)")
            return false
        }
        guard budget.isValid, liveOwnerMatches(element: original, owner: owner),
              liveOwnerMatches(element: remote, owner: owner) else { return false }
        return true
    }

    private func mirrorBinding(origin: Candidate, projection: Candidate,
                               candidates: [Candidate]) -> HostPresentation? {
        var budget = MirrorReadBudget()
        guard origin.source == .applicationExtras, projection.source == .hostWindow,
              origin.enumerationRootPID == origin.owner.pid,
              origin.role == kAXMenuBarItemRole, projection.role == kAXButtonRole,
              origin.owner.pid == projection.owner.pid,
              origin.owner.launchTime == projection.owner.launchTime,
              origin.owner.bundleIdentifier == projection.owner.bundleIdentifier,
              let identifier = origin.identifier, identifier == projection.identifier,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !origin.requiresHostPresentation, !projection.requiresHostPresentation,
              origin.sourceFrame == projection.sourceFrame,
              let host = projection.hostPresentation, host.mirrorIdentity == nil,
              let remote = host.path.last, CFEqual(remote, projection.element),
              liveOwnerMatches(element: origin.element, owner: origin.owner) else { return nil }
        // Count before deduplication: duplicated IDs in either source must not
        // be made unique by merging equal positions or choosing the first row.
        let identityCandidates = candidates.filter {
            $0.owner.pid == origin.owner.pid && $0.owner.launchTime == origin.owner.launchTime &&
                $0.owner.bundleIdentifier == origin.owner.bundleIdentifier && $0.identifier == identifier
        }
        guard identityCandidates.filter({ $0.source == .applicationExtras }).count == 1,
              identityCandidates.filter({ $0.source == .hostWindow }).count == 1 else { return nil }
        let identity = MirrorIdentity(identifier: identifier, originPath: origin.ancestors + [origin.element])
        guard let root = identity.originPath.first,
              mirrorSourcesAreUnique(originRoot: root, original: origin.element, remote: remote,
                  owner: origin.owner, host: host, identifier: identifier, budget: &budget),
              mirrorIdentityIsCurrent(identity, original: origin.element, remote: remote, owner: origin.owner, budget: &budget),
              mirrorFrame(origin.element, budget: &budget) == origin.sourceFrame,
              mirrorFrame(remote, budget: &budget) == projection.sourceFrame else { return nil }
        let binding = HostPresentation(hostOwner: host.hostOwner, window: host.window,
            path: host.path, snapshotFrame: host.snapshotFrame, mirrorIdentity: identity)
        guard currentHostFrame(binding, original: origin.element, owner: origin.owner,
                               identifier: identifier, budget: &budget) == host.snapshotFrame else { return nil }
        return binding
    }

    private func mirrorIdentityIsCurrent(_ identity: MirrorIdentity, original: AXUIElement,
                                         remote: AXUIElement, owner: MenuBarOwner, budget: inout MirrorReadBudget) -> Bool {
        guard budget.isValid, identity.originPath.count >= 2, identity.originPath.count <= 7,
              let root = identity.originPath.first, let last = identity.originPath.last,
              CFEqual(last, original), liveOwnerMatches(element: original, owner: owner),
              mirrorText(original, kAXRoleAttribute, budget: &budget) == kAXMenuBarItemRole,
              mirrorText(remote, kAXRoleAttribute, budget: &budget) == kAXButtonRole,
              mirrorText(original, kAXIdentifierAttribute, budget: &budget) == identity.identifier,
              mirrorText(remote, kAXIdentifierAttribute, budget: &budget) == identity.identifier,
              let originalFrame = mirrorFrame(original, budget: &budget),
              let remoteFrame = mirrorFrame(remote, budget: &budget),
              originalFrame == remoteFrame, originalFrame.width > 0, originalFrame.height > 0 else { return false }
        var remotePID: pid_t = 0
        guard AXUIElementGetPid(remote, &remotePID) == .success, remotePID == owner.pid else { return false }
        let application = AXUIElementCreateApplication(owner.pid)
        let rootRead = mirrorAttribute(application, kAXExtrasMenuBarAttribute, budget: &budget)
        guard rootRead.error == .success, let currentRoot = element(rootRead.value), CFEqual(currentRoot, root) else { return false }
        for index in 0..<(identity.originPath.count - 1) {
            let parent = identity.originPath[index]
            let child = identity.originPath[index + 1]
            var parentPID: pid_t = 0
            guard budget.isValid, AXUIElementGetPid(parent, &parentPID) == .success, parentPID == owner.pid,
                  let children = completeMirrorChildren(parent, budget: &budget),
                  children.filter({ CFEqual($0, child) }).count == 1 else { return false }
        }
        return budget.isValid
    }

    private func mirrorAttribute(_ node: AXUIElement, _ name: String,
                                 budget: inout MirrorReadBudget) -> (error: AXError, value: CFTypeRef?) {
        guard budget.isValid else { return (.cannotComplete, nil) }
        budget.remaining -= 1
        let remainingTime = budget.deadline - ProcessInfo.processInfo.systemUptime
        guard remainingTime > 0 else { return (.cannotComplete, nil) }
        // AX timeouts belong to individual objects, not CFEqual instances or
        // their descendants. Set every queried object's timeout explicitly.
        let timeout = AXUIElementSetMessagingTimeout(node, Float(min(0.12, remainingTime)))
        guard timeout == .success else { return (timeout, nil) }
        let result = copyAttribute(node, name)
        return budget.isValid ? result : (.cannotComplete, nil)
    }

    private func mirrorText(_ node: AXUIElement, _ name: String, budget: inout MirrorReadBudget) -> String? {
        let result = mirrorAttribute(node, name, budget: &budget)
        guard result.error == .success, let value = result.value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func mirrorFrame(_ node: AXUIElement, budget: inout MirrorReadBudget) -> CGRect? {
        let position = mirrorAttribute(node, kAXPositionAttribute, budget: &budget)
        let size = mirrorAttribute(node, kAXSizeAttribute, budget: &budget)
        guard position.error == .success, size.error == .success,
              let positionValue = position.value, let sizeValue = size.value,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              budget.isValid else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func mirrorSourcesAreUnique(originRoot: AXUIElement, original: AXUIElement, remote: AXUIElement,
                                        owner: MenuBarOwner, host: HostPresentation, identifier: String,
                                        budget: inout MirrorReadBudget) -> Bool {
        // The normal walk filters geometry and may truncate. Re-enumerate the
        // actual roots without geometry filtering before claiming uniqueness.
        let hostApplication = AXUIElementCreateApplication(host.hostOwner.pid)
        guard let windows = completeMirrorChildren(hostApplication, attribute: kAXWindowsAttribute, budget: &budget),
              windows.count <= 32 else {
            Self.logger.notice("mirrorIdentityCensus complete=false stage=host-windows")
            return false
        }
        guard let origins = mirrorIdentifierMatches(roots: [originRoot], ownerPID: owner.pid,
                  identifier: identifier, budget: &budget),
              origins.count == 1, let origin = origins.first, CFEqual(origin, original) else {
            Self.logger.notice("mirrorIdentityCensus complete=false stage=source-unique-identity")
            return false
        }
        guard let projections = mirrorIdentifierMatches(roots: windows, ownerPID: owner.pid,
                  identifier: identifier, hostOwner: host.hostOwner, budget: &budget),
              projections.count == 1, let projection = projections.first, CFEqual(projection, remote),
              let currentWindows = completeMirrorChildren(hostApplication, attribute: kAXWindowsAttribute, budget: &budget),
              currentWindows.count == windows.count,
              windows.allSatisfy({ originalWindow in currentWindows.filter { CFEqual($0, originalWindow) }.count == 1 }) else {
            Self.logger.notice("mirrorIdentityCensus complete=false stage=host-unique-identity")
            return false
        }
        return budget.isValid
    }

    private func mirrorIdentifierMatches(roots: [AXUIElement], ownerPID: pid_t, identifier: String,
                                         hostOwner: MenuBarOwner? = nil,
                                         budget: inout MirrorReadBudget) -> [AXUIElement]? {
        var pending = roots.map { (element: $0, depth: 0, hostContainer: false) }
        var visited: [AXUIElement] = []
        var matches: [AXUIElement] = []
        var branches: [(parent: AXUIElement, children: [AXUIElement], allowMissing: Bool)] = []
        var rolelessContainers = 0
        func failed(_ stage: String, depth: Int) -> [AXUIElement]? {
            Self.logger.notice("mirrorIdentityCensus complete=false stage=\(stage, privacy: .public) depth=\(depth) hostScope=\(hostOwner != nil) visited=\(visited.count)")
            return nil
        }
        while let next = pending.popLast() {
            guard budget.isValid, next.depth < 7, visited.count < 160,
                  !visited.contains(where: { CFEqual($0, next.element) }) else { return failed("bounds-or-cycle", depth: next.depth) }
            visited.append(next.element)
            var pid: pid_t = 0
            guard AXUIElementGetPid(next.element, &pid) == .success, pid > 0 else { return failed("node-owner", depth: next.depth) }
            let roleRead = mirrorAttribute(next.element, kAXRoleAttribute, budget: &budget)
            let role: String
            if roleRead.error == .noValue, next.hostContainer, let hostOwner,
               hostOwner.bundleIdentifier == "com.apple.MenuBarAgent", pid == hostOwner.pid,
               liveOwnerMatches(element: next.element, owner: hostOwner) {
                // macOS 27's direct host containers can omit AXRole. The
                // complete AXWindow -> container edge was read above; this
                // permits traversing its children, never accepting it as an item.
                role = kAXUnknownRole
                rolelessContainers += 1
            } else if roleRead.error == .success, let value = roleRead.value as? String, !value.isEmpty {
                role = value
            } else { return failed("role-read", depth: next.depth) }
            if role == kAXMenuRole || role == kAXMenuItemRole { continue }
            if role == kAXMenuBarItemRole || (role == kAXButtonRole && pid == ownerPID) {
                if pid == ownerPID {
                    let ownID = mirrorOptionalIdentifier(next.element, budget: &budget)
                    guard ownID.complete else { return failed("identifier-read", depth: next.depth) }
                    var itemID = ownID.identifier
                    if itemID == nil {
                        guard let children = completeMirrorChildren(next.element, allowMissing: true, budget: &budget) else {
                            return failed("item-children", depth: next.depth)
                        }
                        branches.append((next.element, children, true))
                        for child in children.prefix(2) {
                            let childID = mirrorOptionalIdentifier(child, budget: &budget)
                            guard childID.complete else { return failed("child-identifier", depth: next.depth) }
                            if let value = childID.identifier { itemID = value; break }
                        }
                    }
                    if itemID == identifier {
                        matches.append(next.element)
                        if matches.count > 1 { return failed("duplicate-identifier", depth: next.depth) }
                    }
                }
                continue
            }
            let roleless = roleRead.error == .noValue
            guard let children = completeMirrorChildren(next.element, allowMissing: !roleless, budget: &budget) else {
                return failed("children-read", depth: next.depth)
            }
            branches.append((next.element, children, !roleless))
            var childrenAreHostContainers = false
            if next.depth == 0, role == kAXWindowRole, let hostOwner, pid == hostOwner.pid {
                childrenAreHostContainers = liveOwnerMatches(element: next.element, owner: hostOwner)
            }
            pending.append(contentsOf: children.map { (element: $0, depth: next.depth + 1, hostContainer: childrenAreHostContainers) })
        }
        // A roleless container is usable only as fully enumerated structure.
        // Re-read every traversed branch so mutation cannot turn a partial
        // source or host census into an apparently unique identifier match.
        for branch in branches {
            guard let children = completeMirrorChildren(branch.parent, allowMissing: branch.allowMissing, budget: &budget),
                  children.count == branch.children.count,
                  branch.children.allSatisfy({ originalChild in children.filter { CFEqual($0, originalChild) }.count == 1 }) else {
                return failed("children-recheck", depth: -1)
            }
        }
        if let hostOwner {
            guard liveOwnerMatches(element: AXUIElementCreateApplication(hostOwner.pid), owner: hostOwner) else {
                return failed("host-epoch-recheck", depth: -1)
            }
        }
        guard budget.isValid else { return failed("budget-recheck", depth: -1) }
        if rolelessContainers > 0 {
            Self.logger.debug("mirrorIdentityCensus complete=true rolelessContainers=\(rolelessContainers) matches=\(matches.count)")
        }
        return matches
    }

    private func mirrorOptionalIdentifier(_ node: AXUIElement, budget: inout MirrorReadBudget)
        -> (complete: Bool, identifier: String?) {
        let result = mirrorAttribute(node, kAXIdentifierAttribute, budget: &budget)
        if result.error == .noValue || result.error == .attributeUnsupported { return (true, nil) }
        guard result.error == .success, let value = result.value as? String else { return (false, nil) }
        return (true, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value)
    }

    private func completeMirrorChildren(_ node: AXUIElement, attribute: String = kAXChildrenAttribute,
                                        allowMissing: Bool = false,
                                        budget: inout MirrorReadBudget) -> [AXUIElement]? {
        let result = mirrorAttribute(node, attribute, budget: &budget)
        if allowMissing && (result.error == .noValue || result.error == .attributeUnsupported) { return [] }
        guard result.error == .success, let values = result.value as? [CFTypeRef], values.count <= 60 else { return nil }
        var children: [AXUIElement] = []
        for value in values {
            guard budget.isValid, let child = element(value) else { return nil }
            children.append(child)
        }
        return children
    }

    private func validHostFrame(_ rect: CGRect, identifier: String?) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
            rect.width > 0 && rect.height > 0 && rect.height <= 64 &&
            (rect.width <= 500 || identifier.map { Self.anchorIdentifiers.contains($0) } == true) &&
            menuBands.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    private func validHostWindow(_ window: AXUIElement, ownerPID: pid_t, containing item: CGRect) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == ownerPID,
              text(window, kAXRoleAttribute) == kAXWindowRole,
              let rect = frame(window) else { return false }
        return validHostWindowFrame(rect, containing: item)
    }

    private func validHostWindowFrame(_ rect: CGRect, containing item: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0, rect.contains(CGPoint(x: item.midX, y: item.midY)) else { return false }
        // Popovers extending below the menu row cannot lend their geometry to
        // an icon, even if one of their small children touches the top edge.
        return menuBands.contains { band in
            rect.minY >= band.minY - 1 && rect.maxY <= band.maxY + 1 &&
                rect.width >= item.width && band.intersects(rect)
        }
    }

    /// A failed/stale binding is unknown geometry, never permission to reuse the
    /// origin's stale overflow placeholder as the new display position.
    private func entryFrame(_ entry: Entry) -> CGRect? {
        guard !entry.hostGeometryUnresolved else { return nil }
        guard let binding = entry.hostPresentation else { return frame(entry.element) }
        var budget = MirrorReadBudget()
        return currentHostFrame(binding, original: entry.element, owner: entry.owner,
                                identifier: entry.accessibilityIdentifier, budget: &budget)
    }

    private func currentHostFrame(_ binding: HostPresentation, original: AXUIElement,
                                  owner: MenuBarOwner, identifier: String?, budget: inout MirrorReadBudget) -> CGRect? {
        guard budget.isValid, liveOwnerMatches(element: original, owner: owner), let container = binding.path.first,
              let identity = binding.path.last, (2...6).contains(binding.path.count),
              let host = NSRunningApplication(processIdentifier: binding.hostOwner.pid), !host.isTerminated,
              host.bundleIdentifier == "com.apple.MenuBarAgent",
              let currentHostOwner = resolvedOwner(MenuBarOwner(pid: binding.hostOwner.pid, bundleIdentifier: host.bundleIdentifier,
                  name: "", launchTime: host.launchDate?.timeIntervalSince1970 ?? 0)),
              currentHostOwner.launchTime == binding.hostOwner.launchTime else { return nil }
        if let mirror = binding.mirrorIdentity {
            if mirror.directChild != nil {
                guard sourceChildIdentityIsCurrent(mirror, original: original, remote: identity,
                    owner: owner, budget: &budget) else { return nil }
            } else {
                guard mirror.identifier != nil, mirror.identifier == identifier,
                      mirrorIdentityIsCurrent(mirror, original: original, remote: identity, owner: owner, budget: &budget) else { return nil }
            }
        } else if !CFEqual(identity, original) { return nil }
        let application = AXUIElementCreateApplication(binding.hostOwner.pid)
        guard let windows = completeMirrorChildren(application, attribute: kAXWindowsAttribute, budget: &budget), windows.count <= 32,
              windows.filter({ CFEqual($0, binding.window) }).count == 1,
              let windowChildren = completeMirrorChildren(binding.window, budget: &budget),
              windowChildren.filter({ CFEqual($0, container) }).count == 1,
              hostDescendantPathIsCurrent(binding, owner: owner, budget: &budget) else { return nil }
        var windowPID: pid_t = 0
        guard let rect = mirrorFrame(container, budget: &budget), validHostFrame(rect, identifier: identifier),
              AXUIElementGetPid(binding.window, &windowPID) == .success, windowPID == binding.hostOwner.pid,
              mirrorText(binding.window, kAXRoleAttribute, budget: &budget) == kAXWindowRole,
              let windowFrame = mirrorFrame(binding.window, budget: &budget),
              validHostWindowFrame(windowFrame, containing: rect), budget.isValid else { return nil }
        return rect
    }

    private func hostDescendantPathIsCurrent(_ binding: HostPresentation, owner: MenuBarOwner,
                                             budget: inout MirrorReadBudget) -> Bool {
        let path = binding.path
        guard (2...6).contains(path.count), let container = path.first, let identity = path.last else { return false }
        var containerPID: pid_t = 0
        guard budget.isValid, AXUIElementGetPid(container, &containerPID) == .success,
              containerPID == binding.hostOwner.pid,
              let children = completeMirrorChildren(container, budget: &budget) else { return false }
        var remoteChildren: [AXUIElement] = []
        for child in children {
            var pid: pid_t = 0
            guard budget.isValid, AXUIElementGetPid(child, &pid) == .success, pid > 0 else { return false }
            if pid != binding.hostOwner.pid { remoteChildren.append(child) }
        }
        guard remoteChildren.count == 1, let remote = remoteChildren.first, CFEqual(remote, path[1]) else {
            Self.logger.notice("hostPresentation livePathValid=false stage=remote-root pathDepth=\(path.count)")
            return false
        }
        var visited: [AXUIElement] = [container]
        for index in 1..<path.count {
            let node = path[index]
            guard budget.isValid, !visited.contains(where: { CFEqual($0, node) }),
                  liveOwnerMatches(element: node, owner: owner),
                  let role = mirrorText(node, kAXRoleAttribute, budget: &budget) else { return false }
            visited.append(node)
            if index == path.count - 1 {
                guard role == kAXMenuBarItemRole || role == kAXButtonRole else { return false }
            } else {
                guard [kAXApplicationRole, kAXWindowRole, kAXGroupRole, kAXImageRole,
                       kAXMenuBarRole, kAXUnknownRole].contains(role),
                      let descendants = completeMirrorChildren(node, budget: &budget),
                      descendants.filter({ CFEqual($0, path[index + 1]) }).count == 1 else {
                    Self.logger.notice("hostPresentation livePathValid=false stage=descendant-edge pathDepth=\(path.count)")
                    return false
                }
            }
        }
        // An AXApplication may expose unrelated windows and buttons. A long
        // path is eligible only when a complete, bounded subtree read finds
        // exactly this one menu item/button, without any geometry filtering.
        if path.count > 2, !hostSubtreeHasUniqueItem(remote, identity: identity, owner: owner, budget: &budget) {
            Self.logger.notice("hostPresentation livePathValid=false stage=descendant-census pathDepth=\(path.count)")
            return false
        }
        return budget.isValid
    }

    private func hostSubtreeHasUniqueItem(_ root: AXUIElement, identity: AXUIElement,
                                          owner: MenuBarOwner, budget: inout MirrorReadBudget) -> Bool {
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var items: [AXUIElement] = []
        while let next = pending.popLast() {
            guard budget.isValid, next.depth < 6, visited.count < 120,
                  !visited.contains(where: { CFEqual($0, next.element) }),
                  liveOwnerMatches(element: next.element, owner: owner),
                  let role = mirrorText(next.element, kAXRoleAttribute, budget: &budget) else { return false }
            visited.append(next.element)
            if role == kAXMenuBarItemRole || role == kAXButtonRole {
                items.append(next.element)
                guard items.count == 1, CFEqual(next.element, identity) else { return false }
                continue
            }
            guard [kAXApplicationRole, kAXWindowRole, kAXGroupRole, kAXImageRole,
                   kAXMenuBarRole, kAXUnknownRole, kAXStaticTextRole].contains(role),
                  let children = completeMirrorChildren(next.element, allowMissing: true, budget: &budget) else { return false }
            pending.append(contentsOf: children.map { (element: $0, depth: next.depth + 1) })
        }
        return items.count == 1 && budget.isValid
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
        let positionResult = copyAttribute(node, kAXPositionAttribute).error
        let sizeResult = copyAttribute(node, kAXSizeAttribute).error
        let role = attribute(node, kAXRoleAttribute) as? String ?? "nil"
        let frameDescription = String(describing: frame(node))
        Self.logger.notice("anchorWalk stage=\(stage, privacy: .public) id=\(ownNodeIdentifier ?? "nil", privacy: .public) childIDs=\(childIdentifiers.joined(separator: ","), privacy: .public) nodePID=\(pid) pidError=\(pidResult.rawValue) ownerBundle=\(ownersByPID[pid]?.bundleIdentifier ?? "nil", privacy: .public) role=\(role, privacy: .public) source=\(String(describing: source), privacy: .public) depth=\(depth) frame=\(frameDescription, privacy: .public) positionError=\(positionResult.rawValue) sizeError=\(sizeResult.rawValue)")
    }
    // These synchronous, nonescaping bridges capture immutable AX arguments
    // only. Queries/mutations of our own AX tree can invoke AppKit directly and
    // therefore use its main thread, as do the existing attribute reads below.
    private nonisolated func attributeIsSettable(_ element: AXUIElement, _ name: String) -> (error: AXError, settable: Bool) {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return (pidResult, false) }
        let query: () -> (error: AXError, settable: Bool) = {
            var settable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            return (error, settable.boolValue)
        }
        if pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: query)
        }
        return query()
    }

    private nonisolated func copyAXActions(_ element: AXUIElement) -> (error: AXError, names: [String]) {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return (pidResult, []) }
        let query: () -> (error: AXError, names: [String]) = {
            var value: CFArray?
            let error = AXUIElementCopyActionNames(element, &value)
            guard error == .success else { return (error, []) }
            guard let names = value as? [String] else { return (.failure, []) }
            return (error, names)
        }
        if pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: query)
        }
        return query()
    }

    private nonisolated func setAXAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return pidResult }
        let write: () -> AXError = { AXUIElementSetAttributeValue(element, name as CFString, value) }
        if pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: write)
        }
        return write()
    }

    private nonisolated func performAXAction(_ element: AXUIElement, _ action: String) -> AXError {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return pidResult }
        let perform: () -> AXError = { AXUIElementPerformAction(element, action as CFString) }
        if pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: perform)
        }
        return perform()
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> (error: AXError, value: CFTypeRef?) {
        if let budget = scanReadBudget {
            guard let timeout = budget.timeout(at: ProcessInfo.processInfo.systemUptime,
                                               cancelled: Task.isCancelled) else { return (.cannotComplete, nil) }
            // AX messaging timeouts are per object. Configuring only an
            // application's root leaves its descendants on the system default.
            let configured = AXUIElementSetMessagingTimeout(element, Float(timeout))
            guard configured == .success else { return (configured, nil) }
        }
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return (pidResult, nil) }
        if pid == ProcessInfo.processInfo.processIdentifier {
            return Self.copyOwnAttributeOnMainThread(element, name)
        }
        // Other processes keep their bounded AX messaging off the UI thread.
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    private nonisolated static func copyOwnAttributeOnMainThread(
        _ element: AXUIElement, _ name: String
    ) -> (error: AXError, value: CFTypeRef?) {
        // AX can directly invoke our AppKit accessibility implementation. Keep
        // those reads on its main thread, serialized with hierarchy requests.
        // A nonisolated, nonescaping synchronous closure captures only immutable
        // call arguments; no actor state or AX reference escapes into a task.
        let read: () -> (error: AXError, value: CFTypeRef?) = {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }
        if Thread.isMainThread { return read() }
        // The main actor awaits this actor; it must never synchronously wait for
        // this call. Do not hold additional locks around the queue transition.
        return DispatchQueue.main.sync(execute: read)
    }
    private nonisolated static func copyElementAtPositionOnMainThread(
        _ point: CGPoint
    ) -> (error: AXError, element: AXUIElement?) {
        // A system-wide hit can resolve to our own AppKit hierarchy before its
        // PID is known, so dispatch the query itself, not only later attributes.
        let read: () -> (error: AXError, element: AXUIElement?) = {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.12)
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
            return (error, element)
        }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync(execute: read)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let result = copyAttribute(element, name)
        return result.error == .success ? result.value : nil
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
