// Optional standalone wrapper. It uses its own TCC identity and can therefore
// stop with permission-unavailable; prefer the signed application's explicit
// diagnostic CLI mode when testing its granted permissions.
// Compile from the repository root (compilation does not run the experiment):
// swiftc -swift-version 6 -warnings-as-errors \
//   Sources/MenuTidyCore/MenuTidyLaunchPlan.swift \
//   Sources/MenuTidy/TargetedEventProbe.swift \
//   scripts/probes/TargetedEventProbeCLI.swift -o .local/probes/TargetedEventProbe
// The optional --probe-private-window-field argument adds an undocumented
// window-routing diagnostic group. It is disabled unless explicitly requested.
// Invocation must include --probe-targeted-events. The shared entry point
// rejects missing, mixed, or unknown diagnostic arguments before creating UI.

@main
enum TargetedEventProbeCLI {
    @MainActor
    static func main() {
        runTargetedEventProbe()
    }
}
