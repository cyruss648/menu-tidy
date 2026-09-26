import Foundation

/// Pure, fail-closed CLI selection. No app, window, preference or event is
/// created while deciding whether a diagnostic was explicitly requested.
public enum MenuTidyLaunchPlan: Equatable, Sendable {
    case normal
    case ownerObserver(String)
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
        guard flags.count == arguments.count else { return .rejected }
        if flags.contains("--observe-menu-bar-owner") {
            guard arguments.count == 2, arguments[0] == "--observe-menu-bar-owner",
                  arguments[1].count <= 255,
                  arguments[1].range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,
                    options: .regularExpression) != nil else { return .rejected }
            return .ownerObserver(arguments[1])
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
