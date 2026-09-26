import AppKit
import ApplicationServices
import Foundation

/// A separately dispatched, read-only observer. It retains original source AX
/// objects across native on/off changes; it never resolves identity by a title,
/// position, identifier string, or a replacement object's similar appearance.
@MainActor
private final class MenuBarVisibilityObserver {
    private struct Source {
        let element: AXUIElement
        let ordinal: Int
        let initial: Bool
    }

    private let bundleIdentifier: String
    private let started = ProcessInfo.processInfo.systemUptime
    // Leave half a second for the bounded final AX reply and JSON flush.
    private var deadline: TimeInterval { started + 89.5 }
    private var originalPID: pid_t?
    private var originalEpoch: TimeInterval?
    private var originalExtras: AXUIElement?
    private var sources: [Source] = []
    private var hadCompleteCensus = false
    private var sequence = 0
    private let system = AXUIElementCreateSystemWide()

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        // This changes only this client's AX request timeout, not an attribute
        // of any observed application. No AX actions or attribute writes exist.
        AXUIElementSetMessagingTimeout(system, 0.1)
    }

    func run() {
        guard AXIsProcessTrusted() else {
            emit(["event": "unavailable", "reason": "accessibility-not-granted"])
            return
        }
        emit(["event": "started", "intervalMilliseconds": 500, "maximumSeconds": 90])
        var next = started
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ProcessInfo.processInfo.systemUptime >= next {
                autoreleasepool { sample() }
                next = ProcessInfo.processInfo.systemUptime + 0.5
            }
            let remaining = min(next, deadline) - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: min(remaining, 0.1)))
            }
        }
        emit(["event": "finished", "samples": sequence, "retainedSourceCount": sources.count])
    }

    private func sample() {
        sequence += 1
        let owners = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier }
        var record: [String: Any] = ["event": "sample", "sequence": sequence,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "ownerCount": owners.count]
        guard owners.count == 1, let owner = owners.first,
              let epoch = MenuBarProcessIdentity.launchTime(for: owner) else {
            record["ownerCurrent"] = false
            record["censusComplete"] = false
            emit(record)
            return
        }
        let pid = owner.processIdentifier
        if originalPID == nil { originalPID = pid; originalEpoch = epoch }
        let ownerCurrent = originalPID == pid && originalEpoch == epoch
        record["ownerPID"] = pid
        record["ownerEpoch"] = epoch
        record["ownerCurrent"] = ownerCurrent
        // A restarted process is a different observation subject. Keep its
        // lifecycle record, but never reuse original elements against its PID.
        guard ownerCurrent, ProcessInfo.processInfo.systemUptime < deadline else {
            record["censusComplete"] = false
            emit(record)
            return
        }
        let root = AXUIElementCreateApplication(pid)
        let extrasRead = attribute(root, kAXExtrasMenuBarAttribute)
        record["extrasError"] = extrasRead.0.rawValue
        let extras = asElement(extrasRead.1)
        let census: [AXUIElement]?
        if extrasRead.0 == .success, let extras, ownerMatches(extras, pid: pid) {
            if originalExtras == nil { originalExtras = extras }
            record["sameExtrasObject"] = originalExtras.map { CFEqual($0, extras) } ?? false
            census = completeChildren(extras, ownerPID: pid)
        } else { census = nil }
        record["censusComplete"] = census != nil
        record["targetItemCount"] = census.map { $0.count as Any } ?? NSNull()
        if let census {
            for item in census where !sources.contains(where: { CFEqual($0.element, item) }) {
                guard sources.count < 64 else {
                    record["retentionLimitReached"] = true
                    break
                }
                sources.append(Source(element: item, ordinal: sources.count, initial: !hadCompleteCensus))
            }
            hadCompleteCensus = true
        }
        var items: [[String: Any]] = []
        for source in sources {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            let raw = rawFrame(source.element)
            let frame = raw.frame
            var item: [String: Any] = ["sourceOrdinal": source.ordinal,
                "sameAsInitialObject": source.initial,
                "inCurrentChildren": census.map { list -> Any in list.contains { CFEqual($0, source.element) } } ?? NSNull(),
                "sourceOwnerMatches": ownerMatches(source.element, pid: pid),
                "positionError": raw.positionError.rawValue, "sizeError": raw.sizeError.rawValue,
                "frame": frame.map { [$0.minX, $0.minY, $0.width, $0.height] as Any } ?? NSNull(),
                "positiveSize": frame.map { $0.width > 0 && $0.height > 0 } ?? false]
            if let frame, frame.width > 0, frame.height > 0, frame.height <= 64 {
                let hit = sourceCenterHit(source.element, frame: frame)
                let repeated = rawFrame(source.element).frame
                let stable = repeated == frame
                item["frameStable"] = stable
                item["centerHit"] = hit.map { ($0 && stable) as Any } ?? NSNull()
            } else { item["centerHit"] = NSNull() }
            items.append(item)
        }
        record["items"] = items
        record["ownerCurrentAtEnd"] = !owner.isTerminated &&
            MenuBarProcessIdentity.launchTime(for: owner) == originalEpoch
        emit(record)
    }

    /// Two complete direct-child reads must agree, including parent edges and
    /// owner. No descendant or unrelated application census is performed.
    private func completeChildren(_ extras: AXUIElement, ownerPID: pid_t) -> [AXUIElement]? {
        func children() -> [AXUIElement]? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(extras, kAXChildrenAttribute as CFString, &count) == .success,
                  count >= 0, count <= 64 else { return nil }
            if count == 0 { return [] }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(extras, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
                  let values, CFArrayGetCount(values) == count else { return nil }
            var result: [AXUIElement] = []
            for index in 0..<count {
                guard let pointer = CFArrayGetValueAtIndex(values, index) else { return nil }
                let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                guard let item = asElement(value), !result.contains(where: { CFEqual($0, item) }),
                      ownerMatches(item, pid: ownerPID), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                let parent = attribute(item, kAXParentAttribute)
                guard parent.0 == .success, let parentElement = asElement(parent.1), CFEqual(parentElement, extras) else { return nil }
                result.append(item)
            }
            return result
        }
        guard let first = children(), let second = children(), first.count == second.count,
              zip(first, second).allSatisfy({ CFEqual($0.0, $0.1) }) else { return nil }
        return second
    }

    private func rawFrame(_ element: AXUIElement) -> (frame: CGRect?, positionError: AXError, sizeError: AXError) {
        let position = attribute(element, kAXPositionAttribute)
        let size = attribute(element, kAXSizeAttribute)
        guard position.0 == .success, size.0 == .success,
              let rawPosition = position.1, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = size.1, CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            return (nil, position.0, size.0)
        }
        let pointValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite) else {
            return (nil, position.0, size.0)
        }
        return (CGRect(origin: point, size: dimensions), position.0, size.0)
    }

    private func sourceCenterHit(_ source: AXUIElement, frame: CGRect) -> Bool? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &hit) == .success else { return nil }
        var seen: [AXUIElement] = []
        for _ in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let current = hit,
                  !seen.contains(where: { CFEqual($0, current) }) else { return nil }
            if CFEqual(current, source) { return true }
            seen.append(current)
            let parent = attribute(current, kAXParentAttribute)
            if parent.0 == .noValue || parent.0 == .attributeUnsupported { return false }
            guard parent.0 == .success else { return nil }
            hit = asElement(parent.1)
            if hit == nil { return false }
        }
        return nil
    }

    private func ownerMatches(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        var actual: pid_t = 0
        return AXUIElementGetPid(element, &actual) == .success && actual == pid
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    }

    private func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

@MainActor
func runMenuBarVisibilityObserver(bundleIdentifier: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    MenuBarVisibilityObserver(bundleIdentifier: bundleIdentifier).run()
}
