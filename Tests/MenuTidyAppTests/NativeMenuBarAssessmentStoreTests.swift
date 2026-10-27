import XCTest
@testable import MenuTidy

final class NativeMenuBarAssessmentStoreTests: XCTestCase {
    @MainActor
    func testAssessmentAllowListRetainsMenuTidyAndSystemOwners() {
        let allowed = NativeMenuBarAssessmentStore.allowedBundleIdentifiers(
            ownBundle: "dev.hdh.MenuTidy",
            observedBundles: ["st", "com.apple.TextInputMenuAgent"],
            runningBundles: ["org.example.Visible", "st"],
            hiddenBundles: ["st"])

        XCTAssertFalse(allowed.contains("st"))
        XCTAssertTrue(allowed.contains("org.example.Visible"))
        XCTAssertTrue(allowed.contains("dev.hdh.MenuTidy"))
        XCTAssertTrue(allowed.contains("com.apple.MenuBarAgent"))
        XCTAssertTrue(allowed.contains("com.apple.controlcenter"))
        XCTAssertTrue(allowed.contains("com.apple.systemuiserver"))
        XCTAssertTrue(allowed.contains("com.apple.TextInputMenuAgent"))
    }

    @MainActor
    func testAssessmentAllowListDoesNotLetHiddenBundlesReenterThroughObservedInventory() {
        let allowed = NativeMenuBarAssessmentStore.allowedBundleIdentifiers(
            ownBundle: "dev.hdh.MenuTidy",
            observedBundles: ["st", "org.example.Helper"],
            runningBundles: [],
            hiddenBundles: ["st", "org.example.Helper"])

        XCTAssertEqual(allowed, [
            "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
            "dev.hdh.MenuTidy"
        ])
    }

    @MainActor
    func testReplacementAllowListKeepsOtherHiddenBundlesHiddenDuringTemporaryReveal() {
        let allowed = NativeMenuBarAssessmentStore.allowedBundleIdentifiers(
            ownBundle: "dev.hdh.MenuTidy",
            observedBundles: ["st", "org.example.OtherHidden"],
            runningBundles: [],
            hiddenBundles: ["org.example.OtherHidden"])

        XCTAssertTrue(allowed.contains("st"), "The clicked bundle must be the temporary visible target")
        XCTAssertFalse(allowed.contains("org.example.OtherHidden"),
            "Replacing the assertion must preserve every sibling hidden choice")
    }
}
