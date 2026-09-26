import AppKit
import Darwin
import Foundation

/// Use the same process epoch for application and menu-bar owner checks.
/// Background system hosts can omit NSRunningApplication.launchDate.
enum MenuBarProcessIdentity {
    static func launchTime(for application: NSRunningApplication) -> TimeInterval? {
        guard !application.isTerminated else { return nil }
        if let time = application.launchDate?.timeIntervalSince1970,
           time.isFinite, time > 0 { return time }
        return kernelLaunchTime(pid: application.processIdentifier)
    }

    static func kernelLaunchTime(pid: pid_t) -> TimeInterval? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }
}
