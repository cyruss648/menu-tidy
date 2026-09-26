import SwiftUI

/// Content only: the parent settings page owns the single vertical scroll view.
struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("软件更新", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("当前版本 \(updates.currentVersion)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                preferenceRow(title: "自动检查更新", detail: "定期检查当前更新通道；关闭后仍可手动检查。") {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates)
                }
                Divider()
                preferenceRow(title: "自动下载并在退出时安装",
                              detail: updates.automaticallyChecksForUpdates
                                ? "开启后会在后台下载，并在你退出应用时完成安装。默认关闭，由你确认安装。"
                                : "开启自动检查更新后可启用；重新开启时会保留之前的自动安装选择。") {
                    Toggle("自动下载并在退出时安装", isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.setAutomaticallyDownloadsUpdates($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates || !updates.allowsAutomaticUpdates)
                }
                Divider()
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(updates.statusMessage)
                            .font(.system(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = updates.lastUpdateCheckDate {
                            Text("最近检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("尚无检查记录")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if updates.operationInProgress {
                            Text("当前菜单栏操作结束后可检查或安装更新。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if updates.sessionInProgress {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在处理软件更新")
                    }
                    Button("检查更新…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
                .padding(.vertical, 13)
                if let issue = updates.issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 13)
                }
            }
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
            }
            Text("更新会保留你的分类与偏好设置。检查和下载来自 GitHub 发布服务，不上传菜单栏图标或分类。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
}
