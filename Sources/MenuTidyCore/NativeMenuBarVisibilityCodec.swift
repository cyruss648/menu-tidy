import Foundation
import CoreFoundation

/// Pure value codec. This type performs no preference writes or notifications.
/// A mutation is not evidence that MenuBarAgent accepted a visibility change.
public enum NativeMenuBarVisibilityCodec {
    public enum Failure: Error, Equatable, LocalizedError {
        case oversized, malformed, duplicateLocation, missingTarget, unsafeTarget

        public var errorDescription: String? {
            switch self {
            case .oversized: "系统菜单栏显示记录超出可处理范围，未修改设置。"
            case .malformed: "系统菜单栏显示记录的格式无法确认，未修改设置。"
            case .duplicateLocation: "系统菜单栏显示记录有重复项目，未修改设置。"
            case .missingTarget: "此应用尚未出现在系统菜单栏显示记录中，请启动应用后重试。"
            case .unsafeTarget: "系统记录中的图标归属不一致，隐藏尚未执行。请重新启动对应应用后点击“重新检查”；若仍失败，需要修复旧归属记录。重复批量重试无法解决。"
            }
        }
    }

    public struct Limits {
        public init() {}
        public var maximumBytes = 1_048_576
        public var maximumRecords = 512
        public var maximumDepth = 16
        public var maximumNodes = 20_000
        public var maximumStringBytes = 16_384
    }

    public struct Change {
        public let data: Data
        public let undo: Undo
    }

    public struct Undo {
        fileprivate let location: [String: Any]
        fileprivate let original: [String: Any]
        fileprivate let written: [String: Any]
    }

    public enum Restore {
        case restored(Data)
        case conflict
    }

    public struct Snapshot {
        fileprivate let pairs: [Pair]
        fileprivate let limits: Limits
        public var count: Int { pairs.count }

        public func isAllowed(bundleIdentifier: String) throws -> Bool {
            let index = try targetIndex(bundleIdentifier)
            return (pairs[index].record["isAllowed"] as! NSNumber).boolValue
        }

        /// nil means no write and no ownership. In particular, an existing
        /// false value must never be registered as a hide owned by this app.
        public func settingAllowed(_ allowed: Bool, bundleIdentifier: String) throws -> Change? {
            let index = try targetIndex(bundleIdentifier)
            let original = pairs[index].record
            guard (original["isAllowed"] as! NSNumber).boolValue != allowed else { return nil }
            var written = original
            written["isAllowed"] = NSNumber(value: allowed)
            var next = pairs
            next[index].record = written
            return Change(data: try encode(next, limits: limits),
                          undo: Undo(location: pairs[index].location,
                                     original: original, written: written))
        }

        /// Call on a freshly read snapshot. Restore only a complete record
        /// which still matches this operation's write; merge into fresh data.
        /// The caller must recheck the fresh bytes immediately before writing.
        public func restoring(_ undo: Undo) throws -> Restore {
            guard let index = pairs.firstIndex(where: { equal($0.location, undo.location) }),
                  equal(pairs[index].record, undo.written) else { return .conflict }
            var next = pairs
            next[index].record = undo.original
            return .restored(try encode(next, limits: limits))
        }

        /// A bounded single-record archive suitable for ownership journals.
        public func record(bundleIdentifier: String) throws -> Data {
            try encode([pairs[targetIndex(bundleIdentifier)]], limits: limits)
        }

        public func matches(record: Data, bundleIdentifier: String) throws -> Bool {
            let expected = try NativeMenuBarVisibilityCodec.decode(record, limits: limits)
            guard expected.count == 1 else { throw Failure.malformed }
            let expectedIndex = try expected.targetIndex(bundleIdentifier)
            guard let index = try? targetIndex(bundleIdentifier) else { return false }
            return equal(pairs[index].record, expected.pairs[expectedIndex].record)
        }

        /// A pure merge into this fresh snapshot, never a whole-table rollback.
        public func replacingRecord(bundleIdentifier: String, expected: Data, replacement: Data) throws -> Data? {
            guard try matches(record: expected, bundleIdentifier: bundleIdentifier) else { return nil }
            let source = try NativeMenuBarVisibilityCodec.decode(replacement, limits: limits)
            guard source.count == 1 else { throw Failure.malformed }
            let sourceIndex = try source.targetIndex(bundleIdentifier)
            let index = try targetIndex(bundleIdentifier)
            var next = pairs
            next[index].record = source.pairs[sourceIndex].record
            return try encode(next, limits: limits)
        }

        private func targetIndex(_ bundleIdentifier: String) throws -> Int {
            guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
                  bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw Failure.unsafeTarget
            }
            let location: [String: Any] = ["bundle": ["_0": bundleIdentifier]]
            guard let index = pairs.firstIndex(where: { equal($0.location, location) }) else {
                throw Failure.missingTarget
            }
            // Additional menu-item owners cannot be safely attributed to this
            // exact bundle. Refuse instead of hiding a broader application.
            guard let locations = pairs[index].record["menuItemLocations"] as? [Any],
                  !locations.isEmpty,
                  locations.allSatisfy({ equal($0, location) }) else {
                throw Failure.unsafeTarget
            }
            return index
        }
    }

    fileprivate struct Pair {
        let location: [String: Any]
        var record: [String: Any]
    }

    public static func decode(_ data: Data, limits: Limits = Limits()) throws -> Snapshot {
        guard data.count <= limits.maximumBytes else { throw Failure.oversized }
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw Failure.malformed }
        var nodes = 0
        try validate(value, depth: 0, nodes: &nodes, limits: limits)
        guard let values = value as? [Any], values.count.isMultiple(of: 2),
              values.count / 2 <= limits.maximumRecords else { throw Failure.malformed }
        var pairs: [Pair] = []
        for index in stride(from: 0, to: values.count, by: 2) {
            guard let location = values[index] as? [String: Any], validLocation(location),
                  let record = values[index + 1] as? [String: Any],
                  let ownLocation = record["location"], equal(location, ownLocation),
                  let locations = record["menuItemLocations"] as? [Any],
                  locations.allSatisfy({ ($0 as? [String: Any]).map(validLocation) == true }),
                  let allowed = record["isAllowed"] as? NSNumber,
                  CFGetTypeID(allowed) == CFBooleanGetTypeID() else { throw Failure.malformed }
            guard !pairs.contains(where: { equal($0.location, location) }) else {
                throw Failure.duplicateLocation
            }
            pairs.append(Pair(location: location, record: record))
        }
        return Snapshot(pairs: pairs, limits: limits)
    }

    /// Codable enum location shape. Unknown cases remain opaque: for example,
    /// adhocBinary carries a Codable URL dictionary under _0, not a String.
    /// The enclosing bounded plist validation already checked its contents.
    /// Only the exact bundle case can ever match a managed target.
    private static func validLocation(_ location: [String: Any]) -> Bool {
        guard location.count == 1, let entry = location.first, !entry.key.isEmpty,
              let payload = entry.value as? [String: Any] else { return false }
        guard entry.key == "bundle" else { return true }
        guard payload.count == 1, let value = payload["_0"] as? String, !value.isEmpty else { return false }
        return true
    }

    private static func encode(_ pairs: [Pair], limits: Limits) throws -> Data {
        let values: [Any] = pairs.flatMap { [$0.location, $0.record] }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        guard data.count <= limits.maximumBytes else { throw Failure.oversized }
        return data
    }

    private static func validate(_ value: Any, depth: Int, nodes: inout Int, limits: Limits) throws {
        nodes += 1
        guard depth <= limits.maximumDepth, nodes <= limits.maximumNodes else { throw Failure.oversized }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                guard key.utf8.count <= limits.maximumStringBytes else { throw Failure.oversized }
                try validate(child, depth: depth + 1, nodes: &nodes, limits: limits)
            }
        } else if let array = value as? [Any] {
            for child in array { try validate(child, depth: depth + 1, nodes: &nodes, limits: limits) }
        } else if let string = value as? String {
            guard string.utf8.count <= limits.maximumStringBytes else { throw Failure.oversized }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw Failure.malformed }
        } else if let date = value as? Date {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.malformed }
        } else if !(value is Data) { throw Failure.malformed }
    }

    /// Preserve plist type distinctions (especially Bool versus integer 0/1),
    /// while ignoring dictionary ordering and binary-plist encoding details.
    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            return left.count == right.count && left.allSatisfy { key, value in
                right[key].map { equal(value, $0) } == true
            }
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy(equal)
        }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            guard CFGetTypeID(left) == CFGetTypeID(right) else { return false }
            // CoreFoundation numbers distinguish floating-point from integer
            // plist values; widths of equal integer values are not semantic.
            let leftFloat = ["f", "d"].contains(String(cString: left.objCType))
            let rightFloat = ["f", "d"].contains(String(cString: right.objCType))
            return leftFloat == rightFloat && left == right
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = lhs as? Data, let right = rhs as? Data { return left == right }
        if let left = lhs as? Date, let right = rhs as? Date { return left == right }
        return false
    }
}
