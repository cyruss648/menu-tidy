import XCTest
@testable import MenuTidyCore

final class MenuTidyLaunchPlanTests: XCTestCase {
    func testIsolatedUIPreviewCannotMixWithLiveOrDiagnosticModes() {
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--preview-ui"]), .normal)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--preview-ui", "--preview-permissions"]), .normal)
        for flags in [["--preview-permissions"], ["--preview-ui", "--demo-items"],
                      ["--preview-ui", "--settings"], ["--preview-ui", "--probe-targeted-events"],
                      ["--preview-ui", "--preview-ui"], ["--preview-ui", "--unknown"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags), .rejected)
        }
    }

    func testNormalLaunchAcceptsOnlyKnownApplicationOptions() {
        for flags in [[], ["--settings"], ["--demo-items"], ["--settings", "--demo-items"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags), .normal)
        }
        for flags in [["--unknown"], ["--probe-typo"], ["file.txt"], ["--settings", "--unknown"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags), .rejected)
        }
    }

    func testObserverHasExactOrderedArgumentsAndCannotEnterInputMode() {
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--observe-menu-bar-owner", "example.App"]), .ownerObserver("example.App"))
        for flags in [["--observe-menu-bar-owner"], ["example.App", "--observe-menu-bar-owner"],
                      ["--observe-menu-bar-owner", "bad/path"],
                      ["--observe-menu-bar-owner", "example.App", "--probe-private-record"],
                      ["--observe-menu-bar-owner-typo", "example.App"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags), .rejected)
        }
    }

    func testEachInputModeNeedsItsOwnExactSelection() {
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--probe-legacy-no-cursor"]), .legacyNoCursor)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--probe-private-record"]), .privateRecord)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--probe-targeted-events"]), .targetedEvents)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--probe-targeted-events", "--probe-private-window-field"]), .targetedEvents)
        let modes = ["--probe-legacy-no-cursor", "--probe-private-record", "--probe-targeted-events", "--probe-status-items"]
        for first in modes {
            for second in modes where first != second {
                XCTAssertEqual(MenuTidyLaunchPlan.parse([first, second]), .rejected)
            }
            XCTAssertEqual(MenuTidyLaunchPlan.parse([first, "--settings"]), .rejected)
            XCTAssertEqual(MenuTidyLaunchPlan.parse([first, "--unknown"]), .rejected)
        }
    }

    func testObserveOnlyCannotBeCombinedWithAnyActionSelection() {
        let observation = ["--probe-status-items", "--probe-observe-only"]
        XCTAssertEqual(MenuTidyLaunchPlan.parse(observation), .statusItems)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(observation + ["--probe-status-host", "--probe-preferred-position"]), .statusItems)
        for action in ["--probe-legacy-no-cursor", "--probe-private-record", "--probe-targeted-events",
                       "--probe-status-host-drag", "--probe-ax-source", "--probe-ax-host",
                       "--probe-preferred-reorder", "--probe-menu-agent-weights"] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(observation + [action]), .rejected)
        }
        XCTAssertEqual(MenuTidyLaunchPlan.parse(["--probe-targeted-events", "--probe-observe-only"]), .rejected)
    }

    func testWeightsContainerAndHidingRequireCompleteSingleMode() {
        let weights = ["--probe-status-items", "--probe-status-host", "--probe-preferred-position", "--probe-menu-agent-weights"]
        let container = weights + ["--probe-menu-agent-container"]
        for flags in [weights, container, container + ["--probe-position-hiding"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags), .statusItems)
            for index in 0..<3 {
                var incomplete = flags
                incomplete.remove(at: index)
                XCTAssertEqual(MenuTidyLaunchPlan.parse(incomplete), .rejected)
            }
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags + ["--probe-private-record"]), .rejected)
        }
        XCTAssertEqual(MenuTidyLaunchPlan.parse(weights + ["--probe-position-hiding"]), .rejected)
    }

    func testStatusActionDependenciesAndAliases() {
        let base = ["--probe-status-items"]
        for action in ["--probe-ax-source", "--probe-source-ax"] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(base + [action]), .statusItems)
            XCTAssertEqual(MenuTidyLaunchPlan.parse(base + [action, "--probe-ax-showmenu"]), .statusItems)
            XCTAssertEqual(MenuTidyLaunchPlan.parse(base + [action, "--probe-status-host-drag"]), .rejected)
        }
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-ax-host"]), .rejected)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-status-host", "--probe-ax-host"]), .statusItems)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-ax-source", "--probe-source-ax"]), .rejected)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-ax-showmenu"]), .rejected)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-status-host-drag"]), .rejected)
        XCTAssertEqual(MenuTidyLaunchPlan.parse(base + ["--probe-status-host", "--probe-status-host-drag"]), .statusItems)
    }

    func testReorderRequiresOwnHostAndPreferenceSetupWithoutOtherActions() {
        let reorder = ["--probe-status-items", "--probe-status-host", "--probe-preferred-position", "--probe-preferred-reorder"]
        XCTAssertEqual(MenuTidyLaunchPlan.parse(reorder), .statusItems)
        for index in 0..<3 {
            var incomplete = reorder
            incomplete.remove(at: index)
            XCTAssertEqual(MenuTidyLaunchPlan.parse(incomplete), .rejected)
        }
        XCTAssertEqual(MenuTidyLaunchPlan.parse(reorder + ["--probe-ax-source"]), .rejected)
    }

    func testDuplicateFlagsFailClosed() {
        for flag in ["--settings", "--probe-status-items", "--probe-legacy-no-cursor", "--probe-targeted-events"] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse([flag, flag]), .rejected)
        }
    }

    func testRetiredCommandStaysDisabledEvenWithOtherModes() {
        for flags in [[], ["--probe-private-record"], ["--observe-menu-bar-owner", "example.App"], ["--unknown"]] {
            XCTAssertEqual(MenuTidyLaunchPlan.parse(flags + ["--probe-private-record-command"]), .disabledCommand)
        }
    }
}
