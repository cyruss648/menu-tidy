import Foundation

/// Pure, fail-closed CLI selection. No app, window, preference or event is
/// created while deciding whether a diagnostic was explicitly requested.
public enum MenuTidyLaunchPlan: Equatable, Sendable {
    case normal
    case ownerObserver(String)
    case ownerCheck(String)
    case relaunchAfterExit(pid: Int32, launchTime: Double, showSettings: Bool)
    case statusItems
    case targetedEvents
    case legacyNoCursor
    case privateRecord
    case disabledCommand
    case rejected

    public static func parse(_ arguments: [String]) -> Self {
        // A retired input mode remains inert even in a mixed command line.
        if arguments.contains("--probe-private-record-command") { return .disabledCommand }
        let flags = Set(arguments)
        let options = arguments.filter { $0.hasPrefix("--") }
        guard Set(options).count == options.count else { return .rejected }
        if flags.contains("--preview-ui") {
            return flags.isSubset(of: ["--preview-ui", "--preview-permissions"]) ? .normal : .rejected
        }
        if flags.contains("--observe-menu-bar-owner") || flags.contains("--check-menu-bar-owner") {
            guard arguments.count == 2,
                  ["--observe-menu-bar-owner", "--check-menu-bar-owner"].contains(arguments[0]),
                  arguments[1].count <= 255,
                  arguments[1].range(of: #"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$"#,
                    options: .regularExpression) != nil else { return .rejected }
            return arguments[0] == "--check-menu-bar-owner"
                ? .ownerCheck(arguments[1]) : .ownerObserver(arguments[1])
        }
        if flags.contains("--relaunch-after-exit") {
            guard arguments.count == 4, arguments[0] == "--relaunch-after-exit",
                  let pid = Int32(arguments[1]), pid > 0,
                  let launchTime = Double(arguments[2]), launchTime.isFinite, launchTime > 0,
                  ["background", "settings"].contains(arguments[3]) else { return .rejected }
            return .relaunchAfterExit(pid: pid, launchTime: launchTime, showSettings: arguments[3] == "settings")
        }
        if flags.isSubset(of: ["--settings", "--demo-items"]) { return .normal }
        if flags == ["--probe-legacy-no-cursor"] { return .legacyNoCursor }
        if flags == ["--probe-private-record"] { return .privateRecord }
        if flags == ["--probe-targeted-events"] ||
            flags == ["--probe-targeted-events", "--probe-private-window-field"] { return .targetedEvents }

        let base: Set<String> = ["--probe-status-items"]
        let layout: Set<String> = ["--probe-status-host", "--probe-preferred-position"]
        guard base.isSubset(of: flags) else { return .rejected }
        if flags.contains("--probe-menu-agent-weights") {
            let required = base.union(layout).union(["--probe-menu-agent-weights"])
            let container = required.union(["--probe-menu-agent-container"])
            return flags == required || flags == container ||
                flags == container.union(["--probe-position-hiding"]) ? .statusItems : .rejected
        }
        if flags.contains("--probe-observe-only") {
            // Observation must not silently accept a request for another action.
            return flags.isSubset(of: base.union(layout).union(["--probe-observe-only"]))
                ? .statusItems : .rejected
        }
        if flags.contains("--probe-preferred-reorder") {
            return flags == base.union(layout).union(["--probe-preferred-reorder"])
                ? .statusItems : .rejected
        }
        let sourceActions: Set<String> = ["--probe-ax-source", "--probe-source-ax"]
        let actions = sourceActions.union(["--probe-ax-host"])
        let selected = flags.intersection(actions)
        if !selected.isEmpty {
            guard selected.count == 1,
                  flags.isSubset(of: base.union(layout).union(actions).union(["--probe-ax-showmenu"])),
                  !flags.contains("--probe-ax-host") || flags.contains("--probe-status-host") else { return .rejected }
            return .statusItems
        }
        guard flags.isSubset(of: base.union(layout).union(["--probe-status-host-drag"])),
              !flags.contains("--probe-status-host-drag") || flags.contains("--probe-status-host") else { return .rejected }
        return .statusItems
    }
}
