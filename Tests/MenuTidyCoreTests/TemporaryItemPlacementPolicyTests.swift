import CoreGraphics
import Foundation
import XCTest
@testable import MenuTidyCore

final class TemporaryItemPlacementPolicyTests: XCTestCase {
    private typealias Policy = TemporaryItemPlacementPolicy
    private func entry(_ id: String, _ x: Double, width: Double = 20,
                       y: Double = 4, reliable: Bool = true) -> Policy.Entry {
        Policy.Entry(id: id, frame: CGRect(x: x, y: y, width: width, height: 24), reliable: reliable)
    }
    private var anchors: [Policy.Entry] { [entry("always", 100), entry("regular", 240), entry("control", 400)] }
    private func position(_ items: [Policy.Entry], exclusions: [CGRect] = [],
                          preferredAnchorID: String? = nil,
                          preferredPlacement: Policy.Placement? = nil) -> Policy.Position? {
        Policy.position(targetID: "target", entries: items, alwaysID: "always", regularID: "regular", controlID: "control",
            menuBarExclusions: exclusions, preferredAnchorID: preferredAnchorID,
            preferredPlacement: preferredPlacement)
    }

    func testCapturesCollapsibleGroupAndActualRightNeighbor() throws {
        let result = try XCTUnwrap(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 210, width: 24)]))
        XCTAssertEqual(result.group, .collapsible)
        XCTAssertEqual(result.rightNeighborID, "neighbor")
    }

    func testBoundaryCanBeRightNeighborOnlyWhenActuallyAdjacent() throws {
        let result = try XCTUnwrap(position(anchors + [entry("target", 210, width: 24)]))
        XCTAssertEqual(result.group, .collapsible)
        XCTAssertEqual(result.rightNeighborID, "regular")
        XCTAssertNil(position(anchors + [entry("target", 160, width: 24)]))
    }

    func testAlwaysHiddenAndVisiblePositionsAreDistinguished() throws {
        XCTAssertEqual(try XCTUnwrap(position(anchors + [entry("target", 70, width: 24)])).group, .alwaysHidden)
        let visible = try XCTUnwrap(position(anchors + [entry("target", 370, width: 24)]))
        XCTAssertEqual(visible.group, .visible)
        XCTAssertEqual(visible.rightNeighborID, "control")
    }

    func testNativeFourteenPointPaddingPreservesVisibleControlAdjacency() throws {
        let result = try XCTUnwrap(position(anchors + [entry("target", 362, width: 24)]))
        XCTAssertEqual(result.group, .visible)
        XCTAssertEqual(result.rightNeighborID, "control")
        XCTAssertEqual(result.rightFrame.minX - result.targetFrame.maxX, 14)
    }

    func testNativePaddingToleranceStopsAtSixteenPoints() throws {
        let result = try XCTUnwrap(position(anchors + [entry("target", 360, width: 24)]))
        XCTAssertEqual(result.rightNeighborID, "control")
        XCTAssertNil(position(anchors + [entry("target", 359.5, width: 24)]))
    }

    func testLargerGapCannotProveThatAnUnobservedNeighborIsAbsent() {
        XCTAssertNil(position(anchors + [entry("target", 330, width: 24)]))
        XCTAssertNil(position(anchors + [entry("target", 170, width: 24), entry("neighbor", 220)]))
    }

    func testConfirmedNotchExcludesOnlyUnavailablePartOfAdjacentGap() throws {
        let items = [entry("always", 352, width: 22), entry("regular", 1166, width: 22),
            entry("control", 1476, width: 30), entry("target", 706, width: 46),
            Policy.Entry(id: "neighbor", frame: CGRect(x: 988.5, y: 1, width: 17.5, height: 30), reliable: true)]
        XCTAssertNil(position(items))
        let result = try XCTUnwrap(position(items, exclusions: [CGRect(x: 760, y: 0, width: 221, height: 32)]))
        XCTAssertEqual(result.group, .collapsible)
        XCTAssertEqual(result.rightNeighborID, "neighbor")
        XCTAssertEqual(result.rightFrame.minX - result.targetFrame.maxX, 236.5)
    }

    func testNotchDoesNotExcuseMoreThanSixteenPointsOfAvailableGap() throws {
        let items = anchors + [entry("target", 330, width: 24)]
        XCTAssertNotNil(position(items, exclusions: [CGRect(x: 360, y: 0, width: 30, height: 32)]))
        XCTAssertNil(position(items, exclusions: [CGRect(x: 360, y: 0, width: 29.99, height: 32)]))
    }

    func testOnlyGapIntersectionCountsAndOverlappingExclusionsCountOnce() {
        let items = anchors + [entry("target", 330, width: 24)]
        // Only 14 of these 40 points lie between the actual pair.
        XCTAssertNil(position(items, exclusions: [CGRect(x: 328, y: 0, width: 40, height: 32)]))
        let partial = CGRect(x: 360, y: 0, width: 20, height: 32)
        XCTAssertNil(position(items, exclusions: [partial, partial]))
        XCTAssertNotNil(position(items, exclusions: [partial, CGRect(x: 370, y: 0, width: 20, height: 32)]))
    }

    func testWrongRowPartialHeightAndInvalidExclusionsCannotProveAdjacency() {
        let items = anchors + [entry("target", 330, width: 24)]
        for rectangle in [CGRect(x: 354, y: 60, width: 46, height: 32),
                          CGRect(x: 354, y: 5, width: 46, height: 22),
                          CGRect(x: CGFloat.nan, y: 0, width: 46, height: 32),
                          CGRect(x: 354, y: 0, width: -46, height: 32)] {
            XCTAssertNil(position(items, exclusions: [rectangle]))
        }
    }

    func testNotchDoesNotBypassUnknownNeighborIdentityOrOverlapChecks() {
        let notch = [CGRect(x: 120, y: 0, width: 280, height: 32)]
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("unknown", 206, reliable: false)], exclusions: notch))
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 220), entry("neighbor", 226)], exclusions: notch))
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 201.99)], exclusions: notch))
    }

    func testPlaceholderTargetOrNeighborCannotProvideRestorePosition() {
        XCTAssertNil(position(anchors + [entry("target", 210, width: 24, reliable: false)]))
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 210, width: 24, reliable: false)]))
    }

    func testUnreliableAnchorCannotClassifyItem() {
        let items = [entry("always", 100, reliable: false), entry("regular", 240), entry("control", 400), entry("target", 210, width: 24)]
        XCTAssertNil(position(items))
    }

    func testOverlappingAndDuplicateItemsCannotSupplyAdjacency() {
        XCTAssertNil(position(anchors + [entry("target", 210, width: 40)]))
        XCTAssertNil(position(anchors + [entry("target", 210, width: 24), entry("target", 180)]))
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 210), entry("neighbor", 214)]))
    }

    func testReliableImmediateLeftItemMayShareTwoPointBorder() throws {
        let result = try XCTUnwrap(position(anchors + [
            entry("left", 146, width: 36), entry("target", 180, width: 24), entry("neighbor", 210, width: 24)
        ]))
        XCTAssertEqual(result.group, .collapsible)
        XCTAssertEqual(result.rightNeighborID, "neighbor")
        XCTAssertEqual(result.targetFrame.maxX, 204)
        XCTAssertEqual(result.rightFrame.minX, 210)
    }

    func testLeftBorderToleranceDoesNotExtendPastTwoPoints() {
        XCTAssertNil(position(anchors + [
            entry("left", 146, width: 36.01), entry("target", 180, width: 24), entry("neighbor", 210, width: 24)
        ]))
    }

    func testOnlyImmediateLeftItemCanReceiveBorderTolerance() {
        XCTAssertNil(position(anchors + [
            entry("fartherLeft", 140, width: 42), entry("immediateLeft", 160, width: 20),
            entry("target", 180, width: 24), entry("neighbor", 210, width: 24)
        ]))
    }

    func testUnreliableOrDuplicateLeftItemCannotReceiveBorderTolerance() {
        let targetAndNeighbor = [entry("target", 180, width: 24), entry("neighbor", 210, width: 24)]
        XCTAssertNil(position(anchors + targetAndNeighbor + [entry("left", 146, width: 36, reliable: false)]))
        XCTAssertNil(position(anchors + targetAndNeighbor + [
            entry("left", 146, width: 36), entry("left", 130, width: 20)
        ]))
    }

    func testLeftBorderExceptionDoesNotAllowRightOverlapBeyondTwoPoints() {
        XCTAssertNil(position(anchors + [
            entry("left", 146, width: 36), entry("target", 180, width: 24), entry("neighbor", 201.99, width: 24)
        ]))
    }

    func testUnidentifiedGeometryBetweenTargetAndNeighborIsNotSkipped() {
        XCTAssertNil(position(anchors + [entry("target", 180, width: 24), entry("unknown", 204, reliable: false), entry("neighbor", 228)]))
    }

    func testInvertedBoundariesOrAnotherMenuRowAreRejected() {
        XCTAssertNil(position([entry("regular", 100), entry("always", 240), entry("control", 400), entry("target", 70, width: 24)]))
        XCTAssertNil(position(anchors + [entry("target", 210, width: 24, y: 70)]))
    }

    func testRestoreNeedsBothOriginalGroupAndNeighbor() throws {
        let original = try XCTUnwrap(position(anchors + [entry("target", 180, width: 24), entry("neighbor", 210, width: 24)]))
        let changedNeighbor = try XCTUnwrap(position(anchors + [entry("target", 210, width: 24)]))
        XCTAssertFalse(Policy.restores(changedNeighbor, original: original))
        let visible = try XCTUnwrap(position(anchors + [entry("target", 344, width: 24), entry("neighbor", 374, width: 20)]))
        XCTAssertFalse(Policy.restores(visible, original: original))
        XCTAssertTrue(Policy.restores(original, original: original))
    }

    func testNativeLayoutShiftDoesNotRequireOriginalPixelCoordinate() throws {
        let items = anchors + [entry("target", 180, width: 24), entry("neighbor", 210, width: 24)]
        let original = try XCTUnwrap(position(items))
        let shifted = items.map { Policy.Entry(id: $0.id, frame: $0.frame.offsetBy(dx: 40, dy: 0), reliable: $0.reliable) }
        let result = try XCTUnwrap(position(shifted))
        XCTAssertNotEqual(result, original)
        XCTAssertTrue(Policy.restores(result, original: original))
    }

    private var leftFallbackItems: [Policy.Entry] {
        [entry("always", 100), entry("regular", 400), entry("control", 500),
         entry("left", 214), entry("target", 240, width: 24), entry("right", 315.5)]
    }

    func testLargeRightGapUsesTrustedSixPointLeftAdjacency() throws {
        let result = try XCTUnwrap(position(leftFallbackItems))
        XCTAssertEqual(result.group, .collapsible)
        XCTAssertEqual(result.placement, .after)
        XCTAssertEqual(result.anchorID, "left")
        XCTAssertEqual(result.targetFrame.minX - result.anchorFrame.maxX, 6)
        // Legacy fields still report the observed right item, not the anchor.
        XCTAssertEqual(result.rightNeighborID, "right")
        XCTAssertEqual(result.rightFrame.minX - result.targetFrame.maxX, 51.5)
    }

    func testDefaultStillPrefersRightWhenBothNeighboursAreTrusted() throws {
        let items = anchors + [entry("left", 154), entry("target", 180, width: 24), entry("right", 210)]
        let result = try XCTUnwrap(position(items))
        XCTAssertEqual(result.placement, .before)
        XCTAssertEqual(result.anchorID, "right")
        let forcedLeft = try XCTUnwrap(position(items, preferredAnchorID: "left", preferredPlacement: .after))
        XCTAssertEqual(forcedLeft.anchorID, "left")
        XCTAssertEqual(forcedLeft.placement, .after)
    }

    func testPreferredAnchorOrDirectionCannotFallBackToDifferentRelation() {
        XCTAssertNil(position(leftFallbackItems, preferredAnchorID: "right", preferredPlacement: .before))
        XCTAssertNil(position(leftFallbackItems, preferredAnchorID: "missing"))
        XCTAssertNil(position(leftFallbackItems, preferredAnchorID: "left", preferredPlacement: .before))
        XCTAssertNil(position(leftFallbackItems, preferredPlacement: .before))
    }

    func testUnreliableDuplicateOrUnknownImmediateLeftCannotBeSkipped() {
        let withoutLeft = leftFallbackItems.filter { $0.id != "left" }
        XCTAssertNil(position(withoutLeft + [entry("left", 214, reliable: false)]))
        XCTAssertNil(position(leftFallbackItems + [entry("left", 180)]))
        XCTAssertNil(position(leftFallbackItems + [entry("unknown", 236, width: 2, reliable: false)]))
        // Even reliable geometry cannot establish a unique duplicated identity.
        XCTAssertNil(position(leftFallbackItems + [entry("unknown", 236, width: 2), entry("unknown", 180)]))
    }

    func testLeftFallbackStopsAtSixteenPointsOfAvailableGap() {
        let withoutLeft = leftFallbackItems.filter { $0.id != "left" }
        XCTAssertNotNil(position(withoutLeft + [entry("left", 204)]))
        XCTAssertNil(position(withoutLeft + [entry("left", 203.99)]))
    }

    func testLeftFallbackOnlySubtractsConfirmedFullHeightExclusions() {
        let items = leftFallbackItems.filter { $0.id != "left" } + [entry("left", 188)]
        XCTAssertNil(position(items))
        XCTAssertNotNil(position(items, exclusions: [CGRect(x: 216, y: 0, width: 16, height: 32)]))
        XCTAssertNil(position(items, exclusions: [CGRect(x: 216, y: 0, width: 15.99, height: 32)]))
        XCTAssertNil(position(items, exclusions: [CGRect(x: 216, y: 5, width: 16, height: 22)]))
        let partial = CGRect(x: 216, y: 0, width: 8, height: 32)
        XCTAssertNil(position(items, exclusions: [partial, partial]))
    }

    func testLeftFallbackUsesOnlyExistingTwoPointBorderAllowance() throws {
        let withoutLeft = leftFallbackItems.filter { $0.id != "left" }
        let sharedBorder = try XCTUnwrap(position(withoutLeft + [entry("left", 206, width: 36)]))
        XCTAssertEqual(sharedBorder.placement, .after)
        XCTAssertNil(position(withoutLeft + [entry("left", 206, width: 36.01)]))
        XCTAssertNil(position(leftFallbackItems + [entry("overlappingLeft", 180, width: 50)]))
        let withoutRight = leftFallbackItems.filter { $0.id != "right" }
        XCTAssertNil(position(withoutRight + [entry("right", 261.99)]))
    }

    func testLeftAnchorRestorationIgnoresChangingObservedRightNeighbour() throws {
        let original = try XCTUnwrap(position(leftFallbackItems))
        let changedRight = leftFallbackItems.filter { $0.id != "right" } + [entry("otherRight", 270)]
        let restored = try XCTUnwrap(position(changedRight,
            preferredAnchorID: original.anchorID, preferredPlacement: original.placement))
        XCTAssertNotEqual(restored.rightNeighborID, original.rightNeighborID)
        XCTAssertTrue(Policy.restores(restored, original: original))
        // The same anchor identity on the opposite side is not restoration.
        let swapped = leftFallbackItems.filter { $0.id != "target" } + [entry("target", 180, width: 24)]
        let wrongSide = try XCTUnwrap(position(swapped))
        XCTAssertEqual(wrongSide.anchorID, original.anchorID)
        XCTAssertEqual(wrongSide.placement, .before)
        XCTAssertFalse(Policy.restores(wrongSide, original: original))
    }

    private var sharedRightBorderItems: [Policy.Entry] {
        [entry("always", 100), entry("regular", 700), entry("control", 800),
         entry("left", 540, width: 24), entry("target", 570, width: 36), entry("right", 604, width: 34)]
    }

    func testImmediateTrustedRightMayShareExactlyTwoPointBorder() throws {
        let result = try XCTUnwrap(position(sharedRightBorderItems))
        XCTAssertEqual(result.placement, .before)
        XCTAssertEqual(result.anchorID, "right")
        XCTAssertEqual(result.targetFrame.maxX - result.anchorFrame.minX, 2)
        let restored = try XCTUnwrap(position(sharedRightBorderItems,
            preferredAnchorID: result.anchorID, preferredPlacement: result.placement))
        XCTAssertTrue(Policy.restores(restored, original: result))
    }

    func testSharedRightBorderAlsoPermitsExplicitOriginalLeftRelation() throws {
        let before = try XCTUnwrap(position(sharedRightBorderItems))
        let after = try XCTUnwrap(position(sharedRightBorderItems,
            preferredAnchorID: "left", preferredPlacement: .after))
        XCTAssertEqual(after.anchorID, "left")
        XCTAssertEqual(after.placement, .after)
        XCTAssertEqual(after.targetFrame.minX - after.anchorFrame.maxX, 6)
        XCTAssertFalse(Policy.restores(after, original: before))
        XCTAssertTrue(Policy.restores(after, original: after))
    }

    func testSharedRightBorderRejectsTwoPointZeroOneAndNestedFrames() {
        let withoutRight = sharedRightBorderItems.filter { $0.id != "right" }
        XCTAssertNil(position(withoutRight + [entry("right", 603.99, width: 34)]))
        XCTAssertNil(position(withoutRight + [entry("right", 605, width: 0.5)]))
        XCTAssertNil(position(withoutRight + [entry("right", 570, width: 36)]))
    }

    func testSharedRightBorderDoesNotExtendToUnknownDuplicateOrNonImmediateItem() {
        let withoutRight = sharedRightBorderItems.filter { $0.id != "right" }
        XCTAssertNil(position(withoutRight + [entry("right", 604, width: 34, reliable: false)]))
        XCTAssertNil(position(sharedRightBorderItems + [entry("right", 640)]))
        // The second right item overlaps the target by 1.5 points. Only the
        // actual immediate neighbour can receive the two-point allowance.
        XCTAssertNil(position(sharedRightBorderItems + [entry("other", 604.5)]))
        XCTAssertNil(position(sharedRightBorderItems + [entry("other", 604.5, reliable: false)],
            preferredAnchorID: "left", preferredPlacement: .after))
    }

    func testSharedRightBorderDoesNotLoosenGroupBoundaryGeometry() {
        XCTAssertNil(position(anchors + [entry("target", 78, width: 24)]))
        XCTAssertNil(position(anchors + [entry("target", 218, width: 24)]))
        XCTAssertNil(position(anchors + [entry("target", 378, width: 24)]))
    }

    func testInvalidGeometryAndMissingControlFailClosed() {
        XCTAssertNil(position(anchors + [entry("target", .nan, width: 24)]))
        XCTAssertNil(position(anchors.filter { $0.id != "control" } + [entry("target", 210, width: 24)]))
    }
}
