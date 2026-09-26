import AppKit
import CoreGraphics
import OSLog
import MenuTidyCore
@preconcurrency import ScreenCaptureKit

/// Prefers independent status-item windows, with explicit visible-icon snapshots
/// as an in-memory compatibility path. Never captures a full display or app.
@MainActor
final class MenuBarIconCapture {
    enum CaptureError: LocalizedError {
        case unsupportedSystem, unsupportedSnapshotSystem, permissionRequired, noIndependentWindows, noCapturedImages

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem:
                return "独立图标栏需要 macOS 14 或更新版本。"
            case .unsupportedSnapshotSystem:
                return "原始图标快照需要 macOS 15.2 或更新版本。"
            case .permissionRequired:
                return "请先允许 Menu Tidy 录制屏幕，以读取菜单栏图标的原始图像。"
            case .noIndependentWindows:
                return "系统没有提供独立图标窗口，且尚无原始图标快照。请先在图标可见时采集，再打开独立图标栏。"
            case .noCapturedImages:
                return "未能取得实时图像或已确认的图标快照，请在图标可见时重新采集。"
            }
        }
    }

    private struct Binding {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let size: CGSize
    }

    fileprivate struct CachedIcon {
        let image: NSImage
        let ownerPID: pid_t
        let ownerLaunchTime: TimeInterval
        let date: Date
    }

    struct CacheCheckpoint {
        fileprivate let ids: Set<String>
        fileprivate let previous: [String: CachedIcon]
        fileprivate let environmentEpoch: UUID
        fileprivate let generation: Int
    }

    private struct CaptureSummary: Equatable {
        let live: Int
        let cached: Int
        let requested: Int
        let unavailable: Int
        let failed: Int
    }

    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "IconCapture")
    private var bindings: [String: Binding] = [:]
    private var cachedIcons: [String: CachedIcon] = [:]
    private var cacheEnvironment: String?
    private var environmentEpoch = UUID()
    private var lastInventorySignature: String?
    private var lastCaptureSummary: CaptureSummary?
    private var generation = 0
    private(set) var usesCachedImages = false
    private(set) var lastCacheDate: Date?

    /// Keep the last verified image until the caller's post-capture AX checks
    /// accept its replacement. Checkpoints never leave memory or cross owners.
    func beginVisibleCaptureValidation(ids: [String]) throws -> CacheCheckpoint {
        try validateCaptureState()
        let selected = Set(ids)
        return CacheCheckpoint(ids: selected,
            previous: cachedIcons.filter { selected.contains($0.key) && Self.ownerIsRunning($0.value) },
            environmentEpoch: environmentEpoch, generation: generation)
    }

    /// Complete even on cancellation, but never resurrect an image after a
    /// display/appearance change, permission loss or source process restart.
    func finishVisibleCaptureValidation(_ checkpoint: CacheCheckpoint, invalidIDs: Set<String>) {
        guard CGPreflightScreenCaptureAccess() else { clearCapturedContent(); return }
        invalidateChangedEnvironment()
        guard checkpoint.environmentEpoch == environmentEpoch, checkpoint.generation == generation else { return }
        let invalid = checkpoint.ids.intersection(invalidIDs)
        for id in invalid {
            if let previous = checkpoint.previous[id], Self.ownerIsRunning(previous) { cachedIcons[id] = previous }
            else { cachedIcons.removeValue(forKey: id) }
        }
        if !invalid.isEmpty { generation += 1 }
        updateLastCacheDate()
        if cachedIcons.isEmpty { usesCachedImages = false }
    }

    /// Inspect already captured, still-valid images without requesting another
    /// screenshot or treating a potential live window binding as an image.
    func availableCachedImageIDs(matching snapshots: [MenuBarItemSnapshot]? = nil) throws -> Set<String> {
        try validateCaptureState()
        cachedIcons = cachedIcons.filter { Self.ownerIsRunning($0.value) }
        updateLastCacheDate()
        guard let snapshots else { return Set(cachedIcons.keys) }
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        return Set(snapshots.compactMap { item -> String? in
            guard counts[item.id] == 1, item.canMove, item.ownIdentifier == nil,
                  let cached = cachedIcons[item.id], cached.ownerPID == item.processIdentifier,
                  let owner = NSRunningApplication(processIdentifier: item.processIdentifier), !owner.isTerminated,
                  owner.bundleIdentifier == item.bundleIdentifier,
                  MenuBarProcessIdentity.launchTime(for: owner) == cached.ownerLaunchTime else { return nil }
            return item.id
        })
    }

    func refreshBindings(snapshots: [MenuBarItemSnapshot]) async throws {
        guard #available(macOS 14.0, *) else { throw CaptureError.unsupportedSystem }
        try validateCaptureState()
        generation += 1
        let currentGeneration = generation
        bindings.removeAll()
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        let owners = Dictionary(snapshots.filter { counts[$0.id] == 1 && $0.canMove && $0.ownIdentifier == nil }
            .map { ($0.id, $0.processIdentifier) }, uniquingKeysWith: { first, _ in first })
        // A collapsed/native-overflow scan is a partial inventory. Absence from
        // this scan is not evidence that an already verified icon disappeared.
        // Keep it for the same process lifetime; an explicit conflicting owner,
        // process exit, permission/environment change still invalidates it.
        cachedIcons = cachedIcons.filter { id, cached in
            Self.ownerIsRunning(cached) && (owners[id] == nil || owners[id] == cached.ownerPID)
        }
        updateLastCacheDate()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            try validateCaptureFailure(error, generation: currentGeneration)
            throw error
        }
        try validateCaptureState(generation: currentGeneration)
        // Structural inventory only: no window titles or application names.
        // This runs before filtering, so a missing candidate can be distinguished
        // from a status window that exists at an unexpected layer or size.
        logInventoryIfChanged(content.windows)
        let windows = content.windows.filter(Self.isSmallStatusWindow)
        var proposed: [String: Binding] = [:]
        for item in snapshots where item.hasReliableGeometry && item.ownIdentifier == nil &&
            counts[item.id] == 1 && item.processIdentifier > 0 {
            let candidates = windows.filter { window in
                guard let owner = window.owningApplication,
                      owner.processID == item.processIdentifier || owner.bundleIdentifier == "com.apple.MenuBarAgent" else { return false }
                return Self.matchesIconGeometry(window.frame, item.frame)
            }
            let ownerMatches = candidates.filter { $0.owningApplication?.processID == item.processIdentifier }
            let preferred = ownerMatches.isEmpty ? candidates : ownerMatches
            // Matching a containing host window is not enough: there must be a
            // unique small window for this item, and no second item using it.
            guard preferred.count == 1, let window = preferred.first, let owner = window.owningApplication else { continue }
            proposed[item.id] = Binding(windowID: window.windowID, ownerPID: owner.processID, size: window.frame.size)
        }
        let windowUseCounts = Dictionary(grouping: proposed.values, by: \.windowID).mapValues(\.count)
        bindings = proposed.filter { windowUseCounts[$0.value.windowID] == 1 }
        Self.logger.notice("iconCapture bindings=\(self.bindings.count) requested=\(snapshots.count) smallWindowCandidates=\(windows.count)")
        for window in windows {
            Self.logger.debug("iconCapture candidate layer=\(window.windowLayer) width=\(window.frame.width) height=\(window.frame.height)")
        }
    }

    func capture(ids: [String]) async throws -> [String: NSImage] {
        guard #available(macOS 14.0, *) else { throw CaptureError.unsupportedSystem }
        try validateCaptureState()
        cachedIcons = cachedIcons.filter { Self.ownerIsRunning($0.value) }
        updateLastCacheDate()
        usesCachedImages = false
        let requested = Array(Set(ids))
        if requested.isEmpty { return [:] }
        let selected = requested.compactMap { id in bindings[id].map { (id, $0) } }
        let currentGeneration = generation
        // The panel polls every 750 ms. A cache-only poll never asks SCK for
        // window metadata or emits an unchanged inventory/capture summary.
        // refreshBindings is the explicit retry point when icons are refreshed.
        if selected.isEmpty {
            return try completeCapture(liveImages: [:], requested: requested, selectedCount: 0, failed: 0,
                generation: currentGeneration)
        }
        var windows: [CGWindowID: SCWindow] = [:]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            try validateCaptureFailure(error, generation: currentGeneration)
            // A failed live binding is retried only on an explicit refresh;
            // a verified snapshot can still serve subsequent panel polls.
        }
        try validateCaptureState(generation: currentGeneration)
        var images: [String: NSImage] = [:]
        var failed = 0
        for (id, binding) in selected {
            try validateCaptureState(generation: currentGeneration)
            guard let window = windows[binding.windowID], Self.isSmallStatusWindow(window),
                  window.owningApplication?.processID == binding.ownerPID,
                  abs(window.frame.width - binding.size.width) <= 1,
                  abs(window.frame.height - binding.size.height) <= 1 else {
                bindings.removeValue(forKey: id)
                failed += 1
                continue
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let bounds = filter.contentRect
            guard scale.isFinite, scale > 0, scale <= 4,
                  Self.isSmallFrame(bounds) else {
                bindings.removeValue(forKey: id)
                failed += 1
                continue
            }
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((bounds.width * scale).rounded()))
            configuration.height = max(1, Int((bounds.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                try validateCaptureState(generation: currentGeneration)
                guard Self.imageMatchesRectangle(image, size: bounds.size) else {
                    bindings.removeValue(forKey: id)
                    failed += 1
                    continue
                }
                images[id] = MenuBarIconImage.make(from: image, size: bounds.size)
            } catch {
                try validateCaptureFailure(error, generation: currentGeneration)
                bindings.removeValue(forKey: id)
                failed += 1
            }
        }
        return try completeCapture(liveImages: images, requested: requested, selectedCount: selected.count,
            failed: failed, generation: currentGeneration)
    }

    /// The caller verifies current center-hit identity before this call and
    /// verifies it again afterward, discarding changed items via the method below.
    /// This method never reveals icons, acquires permissions, or writes to disk.
    func captureVisibleIcons(snapshots: [MenuBarItemSnapshot]) async throws -> [String: NSImage] {
        guard #available(macOS 15.2, *) else { throw CaptureError.unsupportedSnapshotSystem }
        try validateCaptureState()
        let currentGeneration = generation
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        var images: [String: NSImage] = [:]
        var pendingCache: [String: CachedIcon] = [:]
        var candidateOrdinal = 0
        for (index, item) in snapshots.enumerated() where Self.visibleCaptureRectangle(item.frame) == nil {
            Self.logger.debug("iconSnapshot candidate=\(index) rejectedRectangle=\(NSStringFromRect(item.frame), privacy: .public)")
        }
        for item in snapshots where item.canMove && item.hasReliableGeometry && item.ownIdentifier == nil &&
            item.processIdentifier > 0 && counts[item.id] == 1 {
            guard let captureRect = Self.visibleCaptureRectangle(item.frame) else { continue }
            candidateOrdinal += 1
            try validateCaptureState(generation: currentGeneration)
            do {
                // A separate request for this item's small original rectangle;
                // no full-display buffer, synthetic glyph, or application icon.
                // Region capture rounds fractional point bounds outward. Submit
                // those exact bounds so Retina output is checked against the
                // requested region, not an impossible half-point image height.
                guard Self.isVisibleMenuBarRectangle(captureRect) else { continue }
                let image = try await SCScreenshotManager.captureImage(in: captureRect)
                try validateCaptureState(generation: currentGeneration)
                let matches = Self.imageMatchesRectangle(image, size: captureRect.size)
                Self.logger.debug("iconSnapshot candidate=\(candidateOrdinal) expectedWidth=\(captureRect.width) expectedHeight=\(captureRect.height) pixelWidth=\(image.width) pixelHeight=\(image.height) dimensionsMatch=\(matches)")
                guard Self.isVisibleMenuBarRectangle(captureRect),
                      matches,
                      let owner = NSRunningApplication(processIdentifier: item.processIdentifier), !owner.isTerminated,
                      let launchTime = MenuBarProcessIdentity.launchTime(for: owner), launchTime.isFinite, launchTime > 0 else { continue }
                let result = MenuBarIconImage.make(from: image, size: captureRect.size)
                pendingCache[item.id] = CachedIcon(image: result, ownerPID: item.processIdentifier,
                    ownerLaunchTime: launchTime, date: Date())
                images[item.id] = result
            } catch {
                try validateCaptureFailure(error, generation: currentGeneration)
                let failure = error as NSError
                Self.logger.notice("iconSnapshot candidate=\(candidateOrdinal) failed=true errorDomain=\(failure.domain, privacy: .public) errorCode=\(failure.code)")
            }
        }
        try validateCaptureState(generation: currentGeneration)
        // Commit one uncancelled batch; the caller then discards any item whose
        // post-capture hit test or geometry changed during the screenshots.
        cachedIcons.merge(pendingCache) { _, new in new }
        updateLastCacheDate()
        Self.logger.notice("iconCapture visibleSnapshots=\(images.count) verifiedCandidates=\(snapshots.count)")
        guard !images.isEmpty else { throw CaptureError.noCapturedImages }
        return images
    }

    func discardCachedImages(ids: [String]) {
        if !ids.isEmpty { generation += 1 }
        for id in ids { cachedIcons.removeValue(forKey: id) }
        updateLastCacheDate()
        if cachedIcons.isEmpty { usesCachedImages = false }
    }

    private func updateLastCacheDate() {
        lastCacheDate = cachedIcons.values.map(\.date).max()
    }

    private func completeCapture(liveImages: [String: NSImage], requested: [String], selectedCount: Int,
                                 failed: Int, generation: Int) throws -> [String: NSImage] {
        try validateCaptureState(generation: generation)
        var images = liveImages
        for id in requested where images[id] == nil {
            if let cached = cachedIcons[id] { images[id] = cached.image }
        }
        usesCachedImages = images.count > liveImages.count
        let summary = CaptureSummary(live: liveImages.count, cached: images.count - liveImages.count,
            requested: requested.count, unavailable: requested.count - selectedCount, failed: failed)
        if summary != lastCaptureSummary {
            Self.logger.notice("iconCapture captured=\(summary.live) cached=\(summary.cached) requested=\(summary.requested) unavailable=\(summary.unavailable) failed=\(summary.failed)")
            lastCaptureSummary = summary
        }
        guard !images.isEmpty else {
            throw selectedCount == 0 ? CaptureError.noIndependentWindows : CaptureError.noCapturedImages
        }
        return images
    }

    private func validateCaptureState(generation expected: Int? = nil) throws {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            clearCapturedContent()
            throw CaptureError.permissionRequired
        }
        invalidateChangedEnvironment()
        if let expected, generation != expected { throw CancellationError() }
    }

    private func validateCaptureFailure(_ error: Error, generation: Int) throws {
        if error is CancellationError { throw CancellationError() }
        try Task.checkCancellation()
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
            clearCapturedContent()
            throw CaptureError.permissionRequired
        }
        try validateCaptureState(generation: generation)
    }

    private func clearCapturedContent() {
        cachedIcons.removeAll()
        bindings.removeAll()
        lastCacheDate = nil
        usesCachedImages = false
        lastCaptureSummary = nil
        lastInventorySignature = nil
        environmentEpoch = UUID()
        generation += 1
    }

    private func logInventoryIfChanged(_ windows: [SCWindow]) {
        let layerCounts = Dictionary(grouping: windows, by: \.windowLayer).mapValues(\.count)
        let hosts = windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" }
            .sorted { $0.windowID < $1.windowID }
        let signature = layerCounts.keys.sorted().map { "\($0):\(layerCounts[$0, default: 0])" }.joined(separator: ";") + "|" +
            hosts.map { "\($0.owningApplication?.processID ?? 0):\($0.windowID):\($0.windowLayer):\(NSStringFromRect($0.frame)):\($0.isOnScreen)" }.joined(separator: ";")
        guard signature != lastInventorySignature else { return }
        lastInventorySignature = signature
        Self.logger.notice("iconCapture inventory totalWindows=\(windows.count) distinctLayers=\(layerCounts.count)")
        for layer in layerCounts.keys.sorted() {
            Self.logger.notice("iconCapture inventory layer=\(layer) count=\(layerCounts[layer, default: 0])")
        }
        for window in hosts {
            let ownerPID = window.owningApplication?.processID ?? 0
            let geometry = NSStringFromRect(window.frame)
            Self.logger.notice("iconCapture menuBarHost pid=\(ownerPID) windowID=\(window.windowID) layer=\(window.windowLayer) frame=\(geometry, privacy: .public) onScreen=\(window.isOnScreen)")
        }
    }

    private func invalidateChangedEnvironment() {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        let screens = NSScreen.screens.map { screen in
            "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"):\(screen.backingScaleFactor):\(NSStringFromRect(screen.frame))"
        }.joined(separator: ";")
        let signature = "\(appearance)|\(screens)"
        if let previous = cacheEnvironment, previous != signature {
            clearCapturedContent()
        }
        cacheEnvironment = signature
    }

    private static func ownerIsRunning(_ cached: CachedIcon) -> Bool {
        guard let owner = NSRunningApplication(processIdentifier: cached.ownerPID), !owner.isTerminated else { return false }
        return MenuBarProcessIdentity.launchTime(for: owner) == cached.ownerLaunchTime
    }

    private static func imageMatchesRectangle(_ image: CGImage, size: CGSize) -> Bool {
        // Reject unexpected full-screen output or a distorted/empty result.
        // This validates bounds only; the caller's AX checks validate identity.
        guard image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return false }
        let xScale = CGFloat(image.width) / size.width
        let yScale = CGFloat(image.height) / size.height
        return xScale >= 1 - 1 / size.width && yScale >= 1 - 1 / size.height &&
            xScale <= 4 + 1 / size.width && yScale <= 4 + 1 / size.height &&
            abs(xScale - yScale) <= 1 / size.width + 1 / size.height
    }

    private static func isVisibleMenuBarRectangle(_ frame: CGRect) -> Bool {
        visibleCaptureRectangle(frame) == frame
    }

    private static func visibleCaptureRectangle(_ frame: CGRect) -> CGRect? {
        guard isSmallFrame(frame), let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let height = min(64, max(28, screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        let band = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        return MenuBarCaptureGeometry.captureRectangle(for: frame, band: band, display: bounds)
    }

    private static func isSmallStatusWindow(_ window: SCWindow) -> Bool {
        // Menu-bar content belongs near the status-window layer. Ordinary app
        // windows, whole MenuBarAgent bars and floating panels are not eligible.
        (24...28).contains(window.windowLayer) && isSmallFrame(window.frame)
    }

    private static func isSmallFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) &&
            (4...256).contains(frame.width) && (8...64).contains(frame.height)
    }

    private static func matchesIconGeometry(_ window: CGRect, _ item: CGRect) -> Bool {
        guard isSmallFrame(item), window.contains(CGPoint(x: item.midX, y: item.midY)),
              abs(window.width - item.width) <= max(12, item.width * 0.6),
              abs(window.height - item.height) <= max(16, item.height * 0.8) else { return false }
        let overlap = window.intersection(item)
        return !overlap.isNull && overlap.width * overlap.height >= item.width * item.height * 0.8
    }
}
