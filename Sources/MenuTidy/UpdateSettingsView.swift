import MenuTidyCore
import SwiftUI

/// Content only: the parent settings page owns the single vertical scroll view.
struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(copy("软件更新"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(format("当前版本 %@", updates.currentVersion))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                preferenceRow(title: copy("自动检查更新"), detail: copy("默认每 30 分钟检查当前更新通道。菜单栏操作进行中会顺延；关闭后仍可手动检查。")) {
                    HStack(spacing: 10) {
                        Picker(copy("自动检查间隔"), selection: Binding(
                            get: { updates.updateCheckInterval },
                            set: { updates.setUpdateCheckInterval($0) })) {
                            ForEach(UpdateCheckInterval.choices, id: \.self) { seconds in
                                Text(updateIntervalLabel(seconds)).tag(seconds)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        .disabled(!updates.canConfigureUpdates || !updates.automaticallyChecksForUpdates)
                        Toggle(copy("自动检查更新"), isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates)
                    }
                }
                Divider()
                preferenceRow(title: copy("自动下载并在退出时安装"),
                              detail: updates.automaticallyChecksForUpdates
                                ? copy("开启后会在后台下载，并在你退出应用时完成安装。默认关闭，由你确认安装。")
                                : copy("开启自动检查更新后可启用；重新开启时会保留之前的自动安装选择。")) {
                    Toggle(copy("自动下载并在退出时安装"), isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.setAutomaticallyDownloadsUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates || !updates.allowsAutomaticUpdates)
                }
                Divider()
                preferenceRow(title: copy("空闲时自动安装并重新打开"),
                              detail: copy("需开启自动检查和自动下载，默认关闭。开启后新下载的更新会在解锁、托盘关闭且操作结束后自动安装；此前已准备好的更新可从“检查更新…”安装。")) {
                    Toggle(copy("空闲时自动安装并重新打开"), isOn: Binding(
                        get: { updates.automaticallyInstallsWhenIdle },
                        set: { updates.setAutomaticallyInstallsWhenIdle($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates ||
                            (!updates.automaticallyInstallsWhenIdle &&
                             (!updates.automaticallyChecksForUpdates || !updates.automaticallyDownloadsUpdates)))
                }
                if updates.hasPreparedUpdate {
                    HStack {
                        Text(copy("更新已验证，可在操作结束后安装。关闭自动安装仍会保留退出时安装。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(copy("安装并重新打开")) { updates.installPreparedUpdate() }
                            .disabled(!updates.canInstallPreparedUpdate)
                    }
                    .padding(.vertical, 10)
                }
                Divider()
                UpdateStatusRow(
                    status: copy(updates.statusMessage),
                    lastCheck: updates.lastUpdateCheckDate.map {
                        format("最近检查：%@", $0.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(preferences.locale)))
                    } ?? copy("尚无检查记录"),
                    issue: updates.issue.map(copy),
                    operationInProgress: updates.operationInProgress,
                    sessionInProgress: updates.sessionInProgress,
                    canCheckForUpdates: updates.canCheckForUpdates,
                    checkForUpdates: updates.checkForUpdates)
                Divider()
                HStack(spacing: 16) {
                    Button { showsHistory = true } label: {
                        Label(copy("更新记录"), systemImage: "clock.arrow.circlepath")
                    }
                    .help(copy("在应用内查看随当前版本附带的历史更新记录，离线也可阅读。"))
                    Spacer(minLength: 8)
                    Link(copy("GitHub 发布 ↗"), destination: ProjectLinks.releases)
                        .help(copy("在浏览器打开 GitHub，查看最新发布及安装包。"))
                    Link(copy("反馈问题 ↗"), destination: ProjectLinks.issues)
                        .help(copy("在浏览器打开 GitHub 问题反馈页面。"))
                }
                .font(.system(size: 11))
                .padding(.vertical, 13)
            }
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
            }
            Text(copy("更新会保留你的分类与偏好设置。检查和下载来自 GitHub 发布服务，不上传菜单栏图标或分类。"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showsHistory) {
            ReleaseHistoryView(currentVersion: updates.currentVersion)
        }
    }

    private func copy(_ key: LocalizedMessage) -> String { preferences.localized(key) }
    private func format(_ key: StaticString, _ arguments: CVarArg...) -> String {
        preferences.localizedFormat(key, arguments: arguments)
    }

    private func preferenceRow<Control: View>(title: String, detail: String,
                                              @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 13)
    }

    private func updateIntervalLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 { return format("每 %lld 小时", Int64(seconds / 3600)) }
        return format("每 %lld 分钟", Int64(seconds / 60))
    }
}

/// All update states share two text lines; full details never add height to the settings page.
struct UpdateStatusRow: View {
    let status: String
    let lastCheck: String
    let issue: String?
    let operationInProgress: Bool
    let sessionInProgress: Bool
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 16) {
            DeferredActivity(isActive: operationInProgress) { showsActivity in
                VStack(alignment: .leading, spacing: 5) {
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(issue == nil ? Color.primary : Color.orange)
                        .help(status)
                    Text(issue ?? (showsActivity ? waitingMessage : lastCheck))
                        .font(.system(size: 10))
                        .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                        .help(issue ?? (showsActivity ? waitingMessage : lastCheck))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DeferredActivity(isActive: sessionInProgress) { showsActivity in
                ActivityIndicator(isVisible: showsActivity, label: copy("正在处理软件更新"))
            }
            Button { showsDetails = true } label: {
                Image(systemName: issue == nil ? "info.circle" : "exclamationmark.triangle")
                    .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy("软件更新状态详情"))
            .help(copy("软件更新状态详情"))
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(copy("软件更新")).font(.headline)
                    Text(status)
                    Text(lastCheck).foregroundStyle(.secondary)
                    if operationInProgress {
                        Text(waitingMessage).foregroundStyle(.secondary)
                    }
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(16)
                .frame(width: 360, alignment: .leading)
            }
            Button(copy("检查更新…"), action: checkForUpdates)
                .disabled(!canCheckForUpdates)
        }
        .padding(.vertical, 13)
    }

    private var waitingMessage: String { copy("当前菜单栏操作结束后可检查或安装更新。") }
    private func copy(_ key: LocalizedMessage) -> String { preferences.localized(key) }
}
