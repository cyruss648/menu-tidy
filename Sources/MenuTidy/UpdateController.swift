import AppKit
import Combine
import MenuTidyCore
import Sparkle

/// One updater owns the standard update dialogs, preferences, and install lifecycle.
/// Diagnostic and demo launches never construct Sparkle or contact the update feed.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var updateCheckInterval = UpdateCheckInterval.defaultValue
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var canConfigureUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var statusMessage = AppPreferences.shared.localized("尚未检查更新")
    @Published private(set) var issue: String?
    @Published private(set) var waitingToInstall = false

    private weak var model: MenuTidyModel?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var postponedInstallation: (() -> Void)?
    private var schedulingPolicy = UpdateSchedulingPolicy()
    private var schedulingTask: Task<Void, Never>?
    private var automaticCheckTimer: Timer?
    private let intervalDefaultsKey = "updateCheckInterval"

    var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version)（\(build)）"
    }

    var operationInProgress: Bool {
        guard let model else { return false }
        return model.isApplying || model.isRefreshing || model.isRecoveringPositions ||
            model.isArranging || model.isActivatingPanelItem
    }

    init(model: MenuTidyModel, enabled: Bool) {
        self.model = model
        super.init()
        guard enabled else {
            statusMessage = AppPreferences.shared.localized("演示模式不检查或安装更新")
            return
        }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host != nil,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else {
            statusMessage = AppPreferences.shared.localized("此安装版本尚未启用应用内更新")
            issue = AppPreferences.shared.localized("更新服务尚未配置完成，暂时无法检查新版本。")
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        // Initial values come from Info.plist. Sparkle persists subsequent choices
        // made here or in its own UI; never overwrite them during app launch.
        updater.sendsSystemProfile = false
        updateCheckInterval = UpdateCheckInterval.validated(UserDefaults.standard.double(forKey: intervalDefaultsKey))
        updater.updateCheckInterval = updateCheckInterval
        observe(updater)
        model.objectWillChange.sink { [weak self] in
            // ObservableObject sends before its properties change.
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.resumeInstallationIfReady()
                self?.scheduleUpdaterWork()
            }
        }.store(in: &subscriptions)
        // Main starts the model immediately after this initializer. Defer to the
        // next main-actor turn so its initial scan can finish before Sparkle runs.
        scheduleUpdaterWork()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let controller else { return }
        schedulingPolicy.manualCheckWasRequested()
        issue = nil
        statusMessage = AppPreferences.shared.localized("正在检查新版本…")
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard canConfigureUpdates, let updater = controller?.updater else { return }
        if !enabled { schedulingPolicy.automaticChecksWereDisabled() }
        updater.automaticallyChecksForUpdates = enabled
        refreshState()
        scheduleAutomaticCheckTimer(from: updater.lastUpdateCheckDate)
    }

    func setUpdateCheckInterval(_ interval: TimeInterval) {
        let validated = UpdateCheckInterval.validated(interval)
        updateCheckInterval = validated
        UserDefaults.standard.set(validated, forKey: intervalDefaultsKey)
        controller?.updater.updateCheckInterval = validated
        scheduleAutomaticCheckTimer(from: controller?.updater.lastUpdateCheckDate)
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard canConfigureUpdates, let updater = controller?.updater,
              !enabled || updater.allowsAutomaticUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
        refreshState()
    }

    private func observe(_ updater: SPUUpdater) {
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
        updater.publisher(for: \.allowsAutomaticUpdates).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
        updater.publisher(for: \.sessionInProgress).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] _ in self?.updaterStateDidChange() }
            .store(in: &subscriptions)
    }

    private func updaterStateDidChange() {
        refreshState()
        if !automaticallyChecksForUpdates { schedulingPolicy.automaticChecksWereDisabled() }
        scheduleUpdaterWork()
    }

    private func scheduleUpdaterWork() {
        guard schedulingTask == nil else { return }
        schedulingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.schedulingTask = nil
            self.performScheduledUpdaterWork()
        }
    }

    private func performScheduledUpdaterWork() {
        guard let updater = controller?.updater else { return }
        switch schedulingPolicy.nextAction(
            operationInProgress: operationInProgress || waitingToInstall,
            automaticChecksEnabled: updater.automaticallyChecksForUpdates,
            updateSessionInProgress: updater.sessionInProgress,
            canCheckForUpdates: updater.canCheckForUpdates
        ) {
        case .startUpdater:
            do {
                try updater.start()
                schedulingPolicy.didStartUpdater(successfully: true)
                canConfigureUpdates = true
                refreshState()
                scheduleAutomaticCheckTimer(from: updater.lastUpdateCheckDate)
            } catch {
                schedulingPolicy.didStartUpdater(successfully: false)
                issue = AppPreferences.shared.localizedFormat("更新服务无法启动：%@", error.localizedDescription)
                statusMessage = AppPreferences.shared.localized("暂时无法检查更新")
            }
        case .checkInBackground:
            // Never dispatch in a KVO/delegate callback. One pending request is
            // consumed here; if new work starts, its later idle event may retry.
            updater.checkForUpdatesInBackground()
        case nil:
            break
        }
    }

    private func refreshState() {
        guard let updater = controller?.updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        sessionInProgress = updater.sessionInProgress
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        canCheckForUpdates = canConfigureUpdates && updater.canCheckForUpdates &&
            !operationInProgress && !waitingToInstall
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !operationInProgress, !waitingToInstall else {
            if operationInProgress {
                schedulingPolicy.checkWasDeferred(isBackgroundCheck: updateCheck == .updatesInBackground,
                                                 automaticChecksEnabled: updater.automaticallyChecksForUpdates)
            }
            throw NSError(domain: "dev.hdh.MenuTidy.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppPreferences.shared.localized("菜单栏操作结束后可检查更新。")])
        }
        issue = nil
        statusMessage = AppPreferences.shared.localized("正在检查新版本…")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusMessage = AppPreferences.shared.localizedFormat("发现新版本 %@", item.displayVersionString)
        issue = nil
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        statusMessage = AppPreferences.shared.localized("当前没有可安装的新版本")
        issue = nil
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        statusMessage = AppPreferences.shared.localizedFormat("正在下载 %@…", item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        statusMessage = AppPreferences.shared.localizedFormat("已下载 %@，正在验证更新…", item.displayVersionString)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        statusMessage = AppPreferences.shared.localized("已取消下载，可随时重新检查更新")
        issue = nil
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        statusMessage = AppPreferences.shared.localizedFormat("%@ 已准备好，将在退出时安装", item.displayVersionString)
        // Opting in to automatic downloads also opts in to installation on quit.
        // Returning false leaves scheduling with Sparkle; it does not veto install.
        return false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard operationInProgress else { return false }
        postponedInstallation = installHandler
        waitingToInstall = true
        statusMessage = AppPreferences.shared.localized("更新已准备好，等待当前菜单栏操作结束…")
        refreshState()
        return true
    }

    private func resumeInstallationIfReady() {
        guard !operationInProgress, let installation = postponedInstallation else { return }
        postponedInstallation = nil
        waitingToInstall = false
        statusMessage = AppPreferences.shared.localized("正在准备安装并重新打开 Menu Tidy…")
        // Sparkle sends an Apple quit event. AppDelegate.applicationShouldTerminate
        // remains responsible for awaiting transactional cleanup, including races
        // after this check. Do not prepare for termination before that quit event.
        installation()
        refreshState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        postponedInstallation = nil
        waitingToInstall = false
        if let error = error as NSError? {
            if error.domain == "dev.hdh.MenuTidy.Update" && error.code == 1 {
                statusMessage = schedulingPolicy.hasDeferredBackgroundCheck
                    ? AppPreferences.shared.localized("等待当前菜单栏操作结束后检查更新…")
                    : AppPreferences.shared.localized("当前菜单栏操作结束后可重新检查更新")
                issue = nil
            } else if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                statusMessage = AppPreferences.shared.localized("当前没有可安装的新版本")
                issue = nil
            } else {
                statusMessage = AppPreferences.shared.localized("本次更新检查未完成")
                issue = error.localizedDescription
            }
        }
        refreshState()
        scheduleUpdaterWork()
        scheduleAutomaticCheckTimer(from: Date())
    }

    /// Sparkle refuses to schedule any automatic check sooner than one hour.
    /// This timer preserves the shorter intervals selected in Settings.
    private func scheduleAutomaticCheckTimer(from reference: Date?) {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        guard canConfigureUpdates, let updater = controller?.updater,
              updater.automaticallyChecksForUpdates else { return }
        let delay = UpdateCheckInterval.delay(since: reference, interval: updateCheckInterval, now: Date())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.performDueAutomaticUpdateCheck() }
        }
        timer.tolerance = min(30, max(1, delay * 0.1))
        automaticCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func performDueAutomaticUpdateCheck() {
        automaticCheckTimer = nil
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates else { return }
        if operationInProgress || waitingToInstall || updater.sessionInProgress || !updater.canCheckForUpdates {
            scheduleAutomaticCheckTimer(from: Date().addingTimeInterval(30 - updateCheckInterval))
            return
        }
        updater.checkForUpdatesInBackground()
    }
}
