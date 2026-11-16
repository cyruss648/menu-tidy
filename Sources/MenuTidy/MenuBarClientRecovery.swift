import AppKit
import Darwin
import MenuTidyCore

@MainActor
enum MenuBarClientRecovery {
    static var bootIdentifier: String? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }

    /// A separate invocation of this same signed executable obtains its own AX
    /// client connection. Its evidence authorizes only an orderly relaunch.
    static func freshClientSeesItem(_ owner: MenuBarClientRecoveryPolicy.Owner) async -> Bool {
        guard owner.isValid, let executable = Bundle.main.executableURL,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = ["--check-menu-bar-owner", owner.bundleIdentifier]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        defer {
            if child.isRunning { child.terminate() }
            try? output.fileHandleForReading.close()
        }
        do { try child.run(); try output.fileHandleForWriting.close() } catch { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        guard !Task.isCancelled, !child.isRunning, child.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 65_536,
              let evidence = try? JSONDecoder().decode(MenuBarClientProbeEvidence.self, from: data) else { return false }
        return evidence.confirmsVisibleItem(for: owner)
    }

    static func scheduleRelaunch(showSettings: Bool) -> Bool {
        let current = NSRunningApplication.current
        guard let executable = Bundle.main.executableURL,
              Bundle.main.bundleURL.pathExtension == "app",
              let launchTime = MenuBarProcessIdentity.launchTime(for: current) else { return false }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--relaunch-after-exit", String(current.processIdentifier), String(launchTime),
            showSettings ? "settings" : "background"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run(); return true } catch { return false }
    }
}

/// The helper never terminates another process. A refused or incomplete normal
/// quit leaves the old instance running; the helper expires without launching.
@MainActor
func relaunchMenuTidyAfterExit(pid: pid_t, launchTime: TimeInterval, showSettings: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let bundle = Bundle.main.bundleIdentifier
    let ownURL = Bundle.main.bundleURL.standardizedFileURL
    guard bundle == "dev.hdh.MenuTidy", ownURL.pathExtension == "app",
          pid > 0, launchTime.isFinite, launchTime > 0,
          pid != ProcessInfo.processInfo.processIdentifier else { return }
    if let previous = NSRunningApplication(processIdentifier: pid), !previous.isTerminated {
        guard previous.bundleIdentifier == bundle,
              previous.bundleURL?.standardizedFileURL == ownURL,
              MenuBarProcessIdentity.launchTime(for: previous) == launchTime else { return }
    } else if !MenuBarProcessIdentity.hasEnded(pid: pid, bundleIdentifier: bundle, launchTime: launchTime) {
        return
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while !MenuBarProcessIdentity.hasEnded(pid: pid, bundleIdentifier: bundle, launchTime: launchTime) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = showSettings
    configuration.arguments = showSettings ? ["--settings"] : []
    let completion = RelaunchOpenCompletion()
    NSWorkspace.shared.openApplication(at: ownURL, configuration: configuration) { _, _ in
        Task { @MainActor in completion.completed = true }
    }
    let openDeadline = ProcessInfo.processInfo.systemUptime + 5
    while !completion.completed && ProcessInfo.processInfo.systemUptime < openDeadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

@MainActor
private final class RelaunchOpenCompletion {
    var completed = false
}
