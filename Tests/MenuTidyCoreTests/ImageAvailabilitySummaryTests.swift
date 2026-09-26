import XCTest
@testable import MenuTidyCore

final class ImageAvailabilitySummaryTests: XCTestCase {
    func testUnrelatedCachedImagesDoNotInflateCoverage() {
        let result = ImageAvailabilitySummary(
            requested: ["hidden-a", "hidden-b"],
            available: ["hidden-a", "visible-c", "offline-d"])

        XCTAssertEqual(result.captured, ["hidden-a"])
        XCTAssertEqual(result.missing, ["hidden-b"])
        XCTAssertTrue(result.hasMissingImages)
        XCTAssertFalse(result.isComplete)
    }

    func testRepeatedIDsCountOnlyOnce() {
        let result = ImageAvailabilitySummary(
            requested: Set(["hidden-a", "hidden-a", "always-b", "always-b"]),
            available: Set(["hidden-a", "hidden-a"]))

        XCTAssertEqual(result.requested.count, 2)
        XCTAssertEqual(result.captured.count, 1)
        XCTAssertEqual(result.missing, ["always-b"])
    }

    func testPreparationFailureDoesNotInvalidateCompleteExistingImages() {
        // A failed preparation produced no new images. Coverage must still use
        // the valid images already available, without reporting a false gap.
        let previouslyVerified: Set<String> = ["hidden-a", "always-b"]
        let newlyCaptured: Set<String> = []
        let result = ImageAvailabilitySummary(
            requested: ["hidden-a", "always-b"],
            available: previouslyVerified.union(newlyCaptured))

        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.hasMissingImages)
        XCTAssertEqual(result.captured.count, 2)
    }

    func testNoObservedRequestsCannotClaimAllConfiguredImagesAreReady() {
        let result = ImageAvailabilitySummary(requested: [], available: ["old-hidden-a"])

        XCTAssertTrue(result.requested.isEmpty)
        XCTAssertTrue(result.captured.isEmpty)
        XCTAssertFalse(result.hasMissingImages)
        XCTAssertFalse(result.isComplete)
    }

    func testPartialCaptureIdentifiesExactRemainingRequest() {
        let result = ImageAvailabilitySummary(
            requested: ["hidden-a", "hidden-b", "always-c"],
            available: ["hidden-a", "always-c"])

        XCTAssertEqual(result.captured, ["hidden-a", "always-c"])
        XCTAssertEqual(result.missing, ["hidden-b"])
        XCTAssertTrue(result.hasMissingImages)
    }

    func testNoAvailableImagesLeavesEveryObservedRequestMissing() {
        let result = ImageAvailabilitySummary(requested: ["hidden-a", "always-b"], available: [])

        XCTAssertTrue(result.captured.isEmpty)
        XCTAssertEqual(result.missing, result.requested)
        XCTAssertTrue(result.hasMissingImages)
        XCTAssertFalse(result.isComplete)
    }
}
