import Foundation

/// Retains Sparkle's verified-update handler. Automatic installation gets one
/// attempt per update; a cancelled termination requires an explicit retry.
@MainActor
final class ReadyUpdateInstaller {
    private let idleDelay: Duration
    private let willInstall: () -> Void
    private var handler: (() -> Void)?
    private var idleTask: Task<Void, Never>?
    private var generation = 0
    private var automaticallyAttempted = false
    private(set) var isInstalling = false

    var hasUpdate: Bool { handler != nil }

    init(idleDelay: Duration = .seconds(5), willInstall: @escaping () -> Void) {
        self.idleDelay = idleDelay
        self.willInstall = willInstall
    }

    func stage(_ handler: @escaping () -> Void) {
        clear()
        self.handler = handler
    }

    func updateAutomaticInstallation(enabled: Bool, canInstall: @escaping () -> Bool) {
        guard enabled, hasUpdate, !automaticallyAttempted, !isInstalling, canInstall() else {
            cancelIdleWait()
            return
        }
        guard idleTask == nil else { return }
        let expectedGeneration = generation
        idleTask = Task { [weak self, idleDelay] in
            do { try await Task.sleep(for: idleDelay) } catch { return }
            guard let self, expectedGeneration == self.generation else { return }
            self.idleTask = nil
            guard canInstall() else { return }
            self.install()
        }
    }

    @discardableResult
    func install() -> Bool {
        guard let handler, !isInstalling else { return false }
        cancelIdleWait()
        automaticallyAttempted = true
        isInstalling = true
        willInstall()
        handler()
        return true
    }

    func terminationWasCancelled() {
        cancelIdleWait()
        isInstalling = false
        // Keep the handler for a user retry; model changes must not form a quit loop.
    }

    func clear() {
        cancelIdleWait()
        handler = nil
        automaticallyAttempted = false
        isInstalling = false
    }

    private func cancelIdleWait() {
        generation += 1
        idleTask?.cancel()
        idleTask = nil
    }
}
