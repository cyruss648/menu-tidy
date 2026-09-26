import Foundation
import CoreGraphics

/// A temporary move is reversible only when the actual group and a unique,
/// immediate neighbour can be established from trusted geometry.
public enum TemporaryItemPlacementPolicy {
    public enum Placement: Equatable, Sendable {
        case before
        case after
    }

    public struct Entry: Sendable {
        public let id: String
        public let frame: CGRect
        public let reliable: Bool
        public init(id: String, frame: CGRect, reliable: Bool) {
            self.id = id
            self.frame = frame
            self.reliable = reliable
        }
    }
    public struct Position: Equatable, Sendable {
        public let id: String
        /// The observed right neighbour, even when restoration uses the left.
        public let rightNeighborID: String
        public let anchorID: String
        public let anchorFrame: CGRect
        public let placement: Placement
        public let group: ItemVisibility
        public let targetFrame: CGRect
        public let rightFrame: CGRect
        public let alwaysFrame: CGRect
        public let regularFrame: CGRect
        public let controlFrame: CGRect

        public static func == (lhs: Position, rhs: Position) -> Bool {
            func equal(_ left: CGRect, _ right: CGRect) -> Bool {
                left.origin.x == right.origin.x && left.origin.y == right.origin.y &&
                    left.width == right.width && left.height == right.height
            }
            return lhs.id == rhs.id && lhs.rightNeighborID == rhs.rightNeighborID && lhs.group == rhs.group &&
                lhs.anchorID == rhs.anchorID && lhs.placement == rhs.placement && equal(lhs.anchorFrame, rhs.anchorFrame) &&
                equal(lhs.targetFrame, rhs.targetFrame) && equal(lhs.rightFrame, rhs.rightFrame) &&
                equal(lhs.alwaysFrame, rhs.alwaysFrame) && equal(lhs.regularFrame, rhs.regularFrame) &&
                equal(lhs.controlFrame, rhs.controlFrame)
        }
    }

    public static func position(targetID: String, entries: [Entry], alwaysID: String,
                                regularID: String, controlID: String,
                                menuBarExclusions: [CGRect] = [],
                                preferredAnchorID: String? = nil,
                                preferredPlacement: Placement? = nil) -> Position? {
        let grouped = Dictionary(grouping: entries, by: \.id)
        func unique(_ id: String) -> Entry? {
            guard let matches = grouped[id], matches.count == 1, let item = matches.first,
                  item.reliable, valid(item.frame) else { return nil }
            return item
        }
        guard Set([targetID, alwaysID, regularID, controlID]).count == 4,
              let target = unique(targetID), let always = unique(alwaysID),
              let regular = unique(regularID), let control = unique(controlID),
              always.frame.maxX <= regular.frame.minX + 1,
              regular.frame.maxX <= control.frame.minX + 1,
              [target, always, control].allSatisfy({ abs($0.frame.midY - regular.frame.midY) < 8 }),
              target.frame.maxX <= control.frame.minX + 1 else { return nil }

        let row = entries.filter { valid($0.frame) && abs($0.frame.midY - target.frame.midY) < 8 }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let targetIndex = row.firstIndex(where: { $0.id == targetID }),
              row.indices.contains(targetIndex + 1) else { return nil }
        let right = row[targetIndex + 1]
        let hasObstruction = row.enumerated().contains { index, item in
            guard item.id != targetID, item.id != right.id else { return false }
            // Native AX frames may include a two-point border shared with the
            // immediate left item. This does not weaken the target/right pair's
            // own ordering checks or allow unknown intervening items to vanish.
            if targetIndex > 0, index == targetIndex - 1,
               item.reliable, grouped[item.id]?.count == 1,
               item.frame.minX < target.frame.minX,
               item.frame.maxX <= target.frame.minX + 2 {
                return false
            }
            // A second right-side item cannot inherit the immediate pair's
            // border allowance merely because its origin sorts after the right.
            return item.frame.maxX > target.frame.minX + 1 &&
                item.frame.minX < max(right.frame.minX - 1, target.frame.maxX - 1)
        }
        // Observed native AX rectangles can share a two-point border on either
        // side. Only the unique, reliable immediate pair gets this allowance;
        // strictly increasing endpoints rule out nested or coincident frames.
        guard right.reliable, grouped[right.id]?.count == 1,
              right.frame.minX > target.frame.minX,
              right.frame.maxX > target.frame.maxX,
              target.frame.maxX <= right.frame.minX + 2,
              !hasObstruction else { return nil }
        let group: ItemVisibility
        if target.frame.maxX <= always.frame.minX + 1 { group = .alwaysHidden }
        else if target.frame.minX >= always.frame.maxX - 1 && target.frame.maxX <= regular.frame.minX + 1 { group = .collapsible }
        else if target.frame.minX >= regular.frame.maxX - 1 { group = .visible }
        else { return nil }

        func matchesPreference(_ anchor: Entry, _ placement: Placement) -> Bool {
            (preferredAnchorID == nil || preferredAnchorID == anchor.id) &&
                (preferredPlacement == nil || preferredPlacement == placement)
        }
        func result(anchor: Entry, placement: Placement) -> Position {
            Position(id: targetID, rightNeighborID: right.id, anchorID: anchor.id,
                anchorFrame: anchor.frame, placement: placement, group: group,
                targetFrame: target.frame, rightFrame: right.frame, alwaysFrame: always.frame,
                regularFrame: regular.frame, controlFrame: control.frame)
        }
        // Preserve the original preference and checks for the right neighbour.
        // A caller verifying recovery can require the exact original relation.
        if matchesPreference(right, .before),
           provesAdjacentGap(from: target.frame, to: right.frame, exclusions: menuBarExclusions) {
            return result(anchor: right, placement: .before)
        }
        guard targetIndex > 0 else { return nil }
        let left = row[targetIndex - 1]
        guard matchesPreference(left, .after), left.reliable, grouped[left.id]?.count == 1,
              left.frame.minX < target.frame.minX,
              left.frame.maxX <= target.frame.minX + 2 else { return nil }
        // Only the immediate neighbours may share the observed AX border.
        // Keep every other unknown/duplicate/intervening rectangle in the test.
        let leftObstruction = row.enumerated().contains { index, item in
            guard item.id != targetID, item.id != left.id else { return false }
            if index == targetIndex + 1, item.id == right.id,
               item.reliable, grouped[item.id]?.count == 1,
               item.frame.minX > target.frame.minX, item.frame.maxX > target.frame.maxX,
               target.frame.maxX <= item.frame.minX + 2 {
                return false
            }
            return item.frame.maxX > left.frame.minX + 1 && item.frame.minX < target.frame.maxX - 1
        }
        guard !leftObstruction,
              provesAdjacentGap(from: left.frame, to: target.frame, exclusions: menuBarExclusions) else { return nil }
        return result(anchor: left, placement: .after)
    }

    public static func restores(_ position: Position, original: Position) -> Bool {
        position.id == original.id && position.group == original.group &&
            position.anchorID == original.anchorID && position.placement == original.placement
    }

    private static func provesAdjacentGap(from left: CGRect, to right: CGRect,
                                          exclusions: [CGRect]) -> Bool {
        // A larger available gap could conceal an unobserved status item.
        // Native host padding can consume 14 points; keep the existing two
        // points of geometry tolerance. Only confirmed, full-height unavailable
        // regions reduce the gap, and overlapping regions count only once.
        let gap = max(0, right.minX - left.maxX)
        return gap - unavailableGapWidth(from: left, to: right, exclusions: exclusions) <= 16
    }

    private static func unavailableGapWidth(from target: CGRect, to right: CGRect,
                                            exclusions: [CGRect]) -> CGFloat {
        guard target.maxX < right.minX else { return 0 }
        let top = max(target.minY, right.minY)
        let bottom = min(target.maxY, right.maxY)
        guard top < bottom else { return 0 }
        let intervals = exclusions.compactMap { rectangle -> ClosedRange<CGFloat>? in
            guard valid(rectangle), rectangle.minY <= top, rectangle.maxY >= bottom else { return nil }
            let lower = max(target.maxX, rectangle.minX)
            let upper = min(right.minX, rectangle.maxX)
            return lower < upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var width: CGFloat = 0
        var end = target.maxX
        for interval in intervals {
            let start = max(end, interval.lowerBound)
            if interval.upperBound > start { width += interval.upperBound - start }
            end = max(end, interval.upperBound)
        }
        return width
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }
}
