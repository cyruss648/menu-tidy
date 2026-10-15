import AppKit
import CoreGraphics

/// Notifications are wake-up hints, not visibility evidence. Re-read the
/// current WindowServer session before admitting work, including app launch.
@MainActor
final class DesktopSessionMonitor {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var probe: Timer?
    private var inactive = false
    private var systemSleeping = false
    private var screensSleeping = false
    private var lastAvailable: Bool?
    var onChange: ((Bool) -> Void)?

    static func sessionIsAvailable(_ session: [String: Any]?) -> Bool {
        guard let session,
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        // WindowServer omits this property when unlocked. A malformed value
        // remains unknown; it must not authorize AX work.
        if let locked = session["CGSSessionScreenIsLocked"] {
            guard let value = locked as? Bool else { return false }
            return !value
        }
        return true
    }

    func currentAvailability() -> Bool {
        !inactive && !systemSleeping && !screensSleeping && CGDisplayIsAsleep(CGMainDisplayID()) == 0 &&
            Self.sessionIsAvailable(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    func refreshAvailability() -> Bool {
        let available = currentAvailability()
        publish(available)
        return available
    }

    func start() {
        guard workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }
        lastAvailable = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.sessionDidResignActiveNotification: self.inactive = true
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.inactive = false
                    case NSWorkspace.willSleepNotification: self.systemSleeping = true
                    case NSWorkspace.screensDidSleepNotification: self.screensSleeping = true
                    case NSWorkspace.didWakeNotification: self.systemSleeping = false
                    case NSWorkspace.screensDidWakeNotification: self.screensSleeping = false
                    default: break
                    }
                    self.publish(self.currentAvailability())
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(rawName), object: nil,
                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Pause immediately even if the dictionary update follows
                    // the lock notification. An unlock still needs a live read.
                    self.publish(rawName == "com.apple.screenIsLocked" ? false : self.currentAvailability())
                }
            })
        }
        publish(currentAvailability())
    }

    private func publish(_ available: Bool) {
        if !available, probe == nil {
            // No AX reads or mutations while paused. This small session-only
            // probe handles a missed unlock notification or a late session read.
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publish(self.currentAvailability())
                }
            }
            timer.tolerance = 0.3
            probe = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if available {
            probe?.invalidate()
            probe = nil
        }
        guard lastAvailable != available else { return }
        lastAvailable = available
        onChange?(available)
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        probe?.invalidate()
        probe = nil
        onChange = nil
    }
}
