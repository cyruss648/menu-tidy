import MenuTidyCore
import SwiftUI

/// Keep small presentation choices when the closed hosting tree is released.
@MainActor
final class SettingsViewState: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case items = "托盘图标"
        case settings = "权限与设置"
        var id: String { rawValue }
    }
    @Published var page: Page = .items
    @Published var traySearchText = ""
    @Published var trayFilter = "all"
    @Published var savedRecordsExpanded = false
    @Published var permissionHelpExpanded = false
    @Published var imageWarningDetailsExpanded = false
    @Published var managementErrorDetailsExpanded = false
    @Published var recoveryDetailsExpanded = false
    @Published var offlineDraftsExpanded = false
}

/// One management surface for immediate choices, explicit retries and recovery.
struct SettingsView: View {
    @ObservedObject var model: MenuTidyModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var presentation: SettingsViewState
    @State private var itemToForget: ManagedItemRow?
    @State private var draftToAssociate: PendingDraftRecord?
    @State private var associationTargetID = ""
    @State private var associationIssue: String?

    private let accent = Color(red: 0.14, green: 0.55, blue: 0.50)
    private typealias Page = SettingsViewState.Page
    private var isBusy: Bool { model.isRefreshing || model.isApplying || model.isActivatingPanelItem || model.isRecoveringPositions }
    private var groupingControlsDisabled: Bool { isBusy || model.isArranging }
    private var trayControlsDisabled: Bool {
        !model.trayPlacementSelectionAllowed
    }
    private var requiresPositionAccess: Bool {
        !model.usesNativeVisibility && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
    private var showsPositionAccessCard: Bool { requiresPositionAccess || model.needsLegacyPositionRecovery }
    private var groupingPermissionsGranted: Bool {
        model.accessibilityGranted && (model.usesNativeVisibility
            ? model.nativeVisibilityAccessAvailable : (!requiresPositionAccess || model.menuBarPositionAccessAvailable))
    }
    private var groupingPermissionStatus: String {
        if !model.accessibilityGranted { return "需要辅助功能权限" }
        if model.usesNativeVisibility {
            return model.nativeVisibilityAccessAvailable ? "辅助功能与菜单栏显示设置已授权" : "还需授权菜单栏显示设置"
        }
        if requiresPositionAccess && !model.menuBarPositionAccessAvailable { return "后台分组还需目录授权" }
        return requiresPositionAccess ? "辅助功能与排序目录已授权" : "辅助功能已授权"
    }
    private var usesPanelVisibility: Bool {
        (model.usesNativeVisibility || model.usesPositionHiding) && !model.isArranging
    }
    private var groupingPermissionHelp: String {
        model.usesNativeVisibility
            ? "辅助功能用于读取图标并打开原生菜单；菜单栏显示设置用于控制图标是否显示。屏幕录制可选，用于显示原始图标外观。"
            : "辅助功能与排序目录用于调整原生图标。屏幕录制为可选增强，用于显示原始菜单栏图像；未开启时托盘显示应用身份图标。"
    }
    private var currentTrayItems: [ManagedItemRow] { model.items.filter(\.isAvailable) }
    private var unavailableItems: [ManagedItemRow] { model.items.filter { !$0.isAvailable } }
    private var attentionCount: Int {
        currentTrayItems.filter { $0.canMove && ($0.isPending || model.trayPlacementFailure(id: $0.id) != nil) }.count
    }
    private var filteredTrayItems: [ManagedItemRow] {
        let query = presentation.traySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentTrayItems.filter { item in
            let group = model.trayPlacementGroup(id: item.id)
            let needsAttention = item.canMove && (item.isPending || model.trayPlacementFailure(id: item.id) != nil)
            let matchesFilter = presentation.trayFilter == "all" || presentation.trayFilter == group.id ||
                (presentation.trayFilter == "attention" && needsAttention)
            return matchesFilter && (query.isEmpty || [item.name, item.ownerName, item.bundleIdentifier ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Picker("页面", selection: $presentation.page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                Spacer()
                Label(groupingPermissionStatus,
                      systemImage: groupingPermissionsGranted ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(groupingPermissionsGranted ? accent : .secondary)
                    .help(groupingPermissionHelp)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            Divider()
            if isBusy { operationStatus }
            if presentation.page == .items { managementPage } else { settingsPage }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: 820, idealWidth: 960, maxWidth: .infinity,
               minHeight: 680, idealHeight: 740, maxHeight: .infinity)
        .sheet(item: $draftToAssociate) { draft in draftAssociationSheet(draft) }
        .alert("忘记此应用的显示设置？", isPresented: Binding(
            get: { itemToForget != nil }, set: { if !$0 { itemToForget = nil } }
        )) {
            Button("忘记此应用", role: .destructive) {
                if let item = itemToForget { model.forgetItem(id: item.id) }
                itemToForget = nil
            }
            Button("取消", role: .cancel) { itemToForget = nil }
        } message: {
            Text("将删除“\(itemToForget?.name ?? "此应用")”全部离线显示规则和待应用草稿。应用下次启动时，不再沿用这些选择；其他应用的记录保留。")
        }
        .onChange(of: model.managementError) { _ in presentation.managementErrorDetailsExpanded = false }
        .onChange(of: model.positionRecoveryMessage) { _ in presentation.recoveryDetailsExpanded = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isUIPreview ? "Menu Tidy · 交互预览" : "Menu Tidy")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("常用图标留在菜单栏，其余收进箭头下方的托盘。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Button { model.toggleVisibility() } label: {
                Label(model.isPanelPresented ? "收起托盘" : "打开托盘",
                      systemImage: model.isPanelPresented ? "chevron.up" : "chevron.down")
            }
            .disabled(model.isRecoveringPositions || model.isArranging)
            .help("打开独立托盘后，点击其中的图标使用对应应用。后台更新列表时也可打开。")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var statusText: String {
        if model.operationCancellationRequested { return "正在安全停止…" }
        if model.isRecoveringPositions { return model.usesNativeVisibility ? "正在恢复图标显示…" : "正在恢复排序…" }
        if model.isApplying { return "正在调整图标…" }
        if model.isRefreshing && model.isArranging { return "正在确认拖拽分组…" }
        if model.isRefreshing { return "正在读取图标…" }
        if model.isActivatingPanelItem { return "正在操作图标…" }
        if model.isArranging { return "拖拽整理中" }
        return model.isPanelPresented ? "托盘已打开" : "托盘已收起"
    }

    /// Keep progress outside the scrolling list so that a long list never hides
    /// the current phase or the action that stops a system operation.
    private var operationStatus: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.small)
                .accessibilityLabel("操作进行中")
            VStack(alignment: .leading, spacing: 4) {
                Text(model.operationCancellationRequested ? "正在停止并恢复临时改动" : statusText)
                    .font(.system(size: 12, weight: .semibold))
                Text(operationDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(operationDetail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.operationStartedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("已用 \(Int(model.operationElapsedSeconds)) 秒")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已用时 \(Int(model.operationElapsedSeconds)) 秒")
                }
            }
            if model.canCancelCurrentOperation || model.operationCancellationRequested {
                Button(model.operationCancellationRequested ? "正在停止…" : "停止") {
                    model.cancelCurrentOperation()
                }
                .disabled(!model.canCancelCurrentOperation || model.operationCancellationRequested)
                .keyboardShortcut(.cancelAction)
                .help("停止后续处理，先恢复本次临时改动；未完成的选择会保留。快捷键 Esc。")
                .accessibilityLabel("停止当前操作")
            } else if model.isActivatingPanelItem {
                Button("停止") { model.cancelPanelItemActivation() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("停止图标操作")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(accent.opacity(0.07))
    }

    private var operationDetail: String {
        if model.operationCancellationRequested {
            return "正在结束当前步骤并恢复临时改动，请稍候。未完成的选择会保留。"
        }
        if let progress = model.panelItemProgress, model.isActivatingPanelItem { return progress }
        if model.isRecoveringPositions { return "恢复完成后会重新确认菜单栏状态。" }
        if let progress = model.managementMessage { return progress }
        if model.isRefreshing { return "正在读取最新状态；列表中的选择会保留。" }
        return model.usesNativeVisibility ? "正在确认图标的显示状态。" : "先检查当前状态，再调整并验证位置。"
    }

    private var managementPage: some View {
        VStack(spacing: 0) {
            managementActions
                .padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.accessibilityGranted { permissionCard(compact: true) }
                    if model.usesNativeVisibility && !model.nativeVisibilityAccessAvailable { nativeVisibilityAccessCard(compact: true) }
                    if model.nativeSystemVisibilityAccessNeeded { nativeSystemVisibilityAccessCard }
                    if showsPositionAccessCard && !model.menuBarPositionAccessAvailable { menuBarPositionAccessCard(compact: true) }
                    recoveryNotice
                    if model.isArranging { arrangementNotice }
                    compatibilityNotices
                    HStack(spacing: 10) {
                        ForEach(ItemVisibility.allCases) { groupSummary($0) }
                    }
                    trayListToolbar
                    if currentTrayItems.contains(where: { model.trayPlacementNeedsIdentification(id: $0.id) }) {
                        Label("需要确认身份的图标，请逐项“识别并连接”；批量操作会跳过这些项目。", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    trayItemList
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                        Text("更改选择会立即处理；同一应用的多个图标可能共用显示设置。缺少原始图像时，托盘显示应用图标。")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if !model.screenCaptureGranted {
                            Button("增强图标外观") { presentation.page = .settings }.buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let issue = model.draftPersistenceIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    savedRecords
                    if !model.isArranging && !model.usesNativeVisibility { arrangementEntry }
                    if !usesPanelVisibility && model.temporarilyRevealingAll && !model.isArranging { temporaryRevealNotice }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Batch controls stay visible while scrolling a long list.
    private var managementActions: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("图标显示方式").font(.system(size: 15, weight: .semibold))
                Text(managementSummary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试失败项\(model.trayRetryCount > 0 ? " · \(model.trayRetryCount)" : "")") {
                model.retryFailedTrayPlacements()
            }
            .disabled(!model.trayPlacementBatchActionsAllowed || model.trayRetryCount == 0)
            .help("仅重试当前可处理的失败项，保留各自的三项选择；归属待修复项不参与批量重试；需要单独识别的图标请使用行内按钮。范围不受搜索与筛选影响。")
            Button("应用全部待处理\(model.trayPendingApplicationCount > 0 ? " · \(model.trayPendingApplicationCount)" : "")") {
                model.applyPendingTrayPlacements()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.trayPlacementBatchActionsAllowed || model.trayPendingApplicationCount == 0)
            .help("继续处理所有可直接应用的未完成选择，包括失败项。已确认、离线、归属待修复和需要单独识别的图标不重复处理。范围不受搜索与筛选影响。")
        }
    }

    private var managementSummary: String {
        if let reason = model.trayPlacementBlockedReason { return reason }
        if model.trayPlacementOutstandingCount > 0 {
            return "\(model.trayPlacementOutstandingCount) 项尚未完成 · 选择已保留，批量处理可直接应用的项目"
        }
        return "三项选择，即改即用 · 未完成时可统一应用或重试"
    }

    private var trayListToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索应用或图标", text: $presentation.traySearchText)
                    .textFieldStyle(.plain).accessibilityLabel("搜索应用或图标")
                if !presentation.traySearchText.isEmpty {
                    Button { presentation.traySearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            Picker("筛选图标", selection: $presentation.trayFilter) {
                Text("全部图标").tag("all")
                ForEach(ItemVisibility.allCases) { Text($0.title).tag($0.id) }
                Text("需要处理 · \(attentionCount)").tag("attention")
            }
            .labelsHidden().frame(width: 144)
            Button { model.refreshMenuItems() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(groupingControlsDisabled || !model.accessibilityGranted)
            .keyboardShortcut("r", modifiers: .command)
            .help("重新读取图标与状态，保留所有选择。刷新不会反复重试失败项。快捷键 ⌘R。")
            Menu {
                Button("临时显示全部") { model.revealAllTemporarily() }
                    .disabled(groupingControlsDisabled || model.positionRecoveryMessage != nil)
                Button("更新原始图标图像") { model.refreshMenuItems(prepareOverflow: true) }
                    .disabled(groupingControlsDisabled || !groupingPermissionsGranted || !model.screenCaptureGranted
                              || model.positionRecoveryMessage != nil)
                Divider()
                Button("权限与设置…") { presentation.page = .settings }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("更多图标操作")
        }
    }

    private var trayItemList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用 / 图标 · \(filteredTrayItems.count)")
                Spacer()
                Text("更改后立即处理").frame(width: 294, alignment: .center)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if filteredTrayItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: presentation.trayFilter == "attention" ? "checkmark.circle" : "tray")
                        .font(.system(size: 25)).foregroundStyle(.secondary)
                    Text(trayEmptyTitle).font(.system(size: 13, weight: .medium))
                    if !presentation.traySearchText.isEmpty || presentation.trayFilter != "all" {
                        Button("显示全部图标") { presentation.traySearchText = ""; presentation.trayFilter = "all" }.buttonStyle(.link)
                    } else {
                        Text(model.accessibilityGranted ? "确认对应应用已运行，再点击上方“刷新”。" : "完成上方授权后即可读取和管理图标。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130).padding(16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredTrayItems) { item in
                        trayItemRow(item)
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .modifier(SettingsCardStyle())
    }

    private var trayEmptyTitle: String {
        if !model.accessibilityGranted { return "授权后开始整理" }
        if model.isRefreshing && currentTrayItems.isEmpty { return "正在读取菜单栏图标…" }
        if presentation.trayFilter == "attention" && presentation.traySearchText.isEmpty { return "当前没有需要处理的图标" }
        return currentTrayItems.isEmpty ? "暂未发现菜单栏图标" : "没有匹配的图标"
    }

    private func trayItemRow(_ item: ManagedItemRow) -> some View {
        let pending = model.trayPlacementIsPending(id: item.id)
        let message = model.trayPlacementFailure(id: item.id)
        let needsConfirmation = item.isPending && !pending && message == nil
        let retryTitle = message == nil ? "应用" : model.trayPlacementRetryTitle(id: item.id)
        return HStack(spacing: 12) {
            itemIcon(item)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if pending {
                        ProgressView().controlSize(.small)
                        rowBadge("处理中", color: accent)
                    } else if !item.canMove {
                        rowBadge("系统保留", color: .secondary)
                    } else if message != nil {
                        rowBadge(model.trayPlacementNeedsOwnershipRepair(id: item.id) ? "归属待修复" : "需处理", color: .orange)
                    } else if needsConfirmation {
                        rowBadge("待应用", color: .secondary)
                    }
                }
                if let message, !pending {
                    Text(model.trayPlacementNeedsOwnershipRepair(id: item.id) ? message : issueSummary(message))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .lineLimit(model.trayPlacementNeedsOwnershipRepair(id: item.id) ? 4 : 2).help(message)
                        .accessibilityLabel("需要处理：\(message)")
                } else if pending {
                    Text("正在按顺序处理，可继续更改选择。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(needsConfirmation ? "选择已保留，等待应用并确认。" :
                            (!item.canMove ? "由系统管理，保持显示。" :
                                (item.ownerName.isEmpty || item.ownerName == item.name ? "更改后自动处理" : item.ownerName)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !pending && (message != nil || needsConfirmation) && item.canMove {
                Button(retryTitle) { model.retryTrayPlacement(id: item.id) }
                    .controlSize(.small).disabled(trayControlsDisabled)
                    .accessibilityLabel("\(retryTitle)\(item.name)")
                    .help(message ?? "应用并确认此前保存的选择。")
            }
            Picker("\(item.name)的显示方式", selection: Binding(
                get: { model.trayPlacementGroup(id: item.id) },
                set: { model.requestTrayPlacement(id: item.id, group: $0) }
            )) {
                ForEach(ItemVisibility.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 294)
            .disabled(trayControlsDisabled || !item.canMove || !item.isAvailable)
            .help(item.canMove ? "选择后立即保存并处理。处理中继续更改，将以最新选择为准。" : item.detail)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(message != nil && !pending ? Color.orange.opacity(0.035) : .clear)
    }

    private var savedRecords: some View {
        Group {
            if !unavailableItems.isEmpty || !model.offlineDrafts.isEmpty || !model.discardedOfflineDrafts.isEmpty {
                DisclosureGroup("离线与保留记录 · \(unavailableItems.count + model.offlineDrafts.count)", isExpanded: $presentation.savedRecordsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("应用未运行或图标身份尚未确认的记录保留在这里，不参加批量操作。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(unavailableItems) { item in
                            HStack(spacing: 10) {
                                itemIcon(item)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.system(size: 12, weight: .medium))
                                    Text("应用未运行或图标不可用 · \(item.group.title)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(model.forgetItemAffectsApplication(id: item.id) ? "忘记此应用…" : "忘记此图标规则") {
                                    if model.forgetItemAffectsApplication(id: item.id) { itemToForget = item }
                                    else { model.forgetItem(id: item.id) }
                                }
                                .controlSize(.small)
                                .disabled(groupingControlsDisabled || !model.canForgetItem(id: item.id))
                                .accessibilityLabel("忘记\(item.name)的规则")
                                .help(model.forgetItemAffectsApplication(id: item.id)
                                    ? "仅在此应用没有可用图标时操作；删除它的离线显示规则和草稿，保留其他应用记录。"
                                    : "忘记此图标的已保存规则，保留其他图标与离线草稿。")
                            }
                        }
                        if !model.discardedOfflineDrafts.isEmpty {
                            HStack {
                                Text("已删除 \(model.discardedOfflineDrafts.count) 条待关联草稿")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("撤销删除", action: model.undoOfflineDraftDeletion)
                                    .controlSize(.small)
                                    .disabled(!model.canUndoOfflineDraftDeletion)
                                    .help("恢复本次打开应用期间最后一批删除的草稿；不覆盖新的选择")
                            }
                        }
                        if !model.offlineDrafts.isEmpty {
                            DisclosureGroup(isExpanded: $presentation.offlineDraftsExpanded) {
                                offlineDraftList.padding(.top, 8)
                            } label: {
                                HStack {
                                    Text("待关联草稿 · \(model.offlineDrafts.count)")
                                    Spacer()
                                    Button("一键删除草稿", action: model.discardOfflineDrafts)
                                        .controlSize(.small)
                                        .disabled(!model.canDiscardOfflineDrafts)
                                        .accessibilityLabel("删除全部待关联草稿")
                                        .help("删除当前全部待关联草稿；已保存的分类与当前图标显示不变")
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(14).modifier(SettingsCardStyle())
            }
        }
    }

    private var arrangementEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 19)).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("也可以在菜单栏中拖拽整理")
                    .font(.system(size: 12, weight: .medium))
                Text("进入整理模式后按住 ⌘ 拖动图标，完成时确认分组。列表选择会立即处理。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("在菜单栏拖拽分组") { model.beginArrangement() }
                .disabled(isBusy || !model.accessibilityGranted)
                .help(model.accessibilityGranted
                    ? "显示菜单栏分组标记；拖动完成后验证分组并收起。"
                    : "请先在权限页开启辅助功能权限，以便读取并保存拖动后的分组。")
        }
        .padding(12)
        .modifier(SettingsCardStyle())
    }

    private var arrangementNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(accent).accessibilityHidden(true)
                Text(model.isRefreshing ? "正在确认拖拽后的分组" : "按住 ⌘，在菜单栏中拖动图标")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("整理模式")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
            }
            HStack(spacing: 8) {
                arrangementZone("始终隐藏", color: .orange)
                arrangementMarker("常隐")
                arrangementZone("收起后隐藏", color: .secondary)
                arrangementMarker("收起")
                arrangementZone("常驻显示", color: accent)
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("从左到右：始终隐藏、常隐标记、收起后隐藏、收起标记、常驻显示、Menu Tidy 入口。")
            Text("「常隐」左侧始终隐藏；两个标记之间收起后隐藏；「收起」右侧常驻显示。标记仅在整理时显示。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("也可点击菜单栏「···」或其右键菜单完成。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("保持展开并退出") { model.leaveArrangementExpanded() }
                    .disabled(isBusy)
                    .help("保留已拖动的图标位置，退出整理模式并保持全部分组展开。")
                Button { model.finishArrangement() } label: {
                    Text(model.isRefreshing ? "正在确认…" : "完成并收起")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .help("只保存连续两次可信扫描确认的分组，再收起。位置未知时不会猜测分类。")
            }
        }
        .padding(12)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func arrangementZone(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
    }

    private func arrangementMarker(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func groupSummary(_ group: ItemVisibility) -> some View {
        let count = currentTrayItems.filter { model.trayPlacementGroup(id: $0.id) == group }.count
        let pendingCount = currentTrayItems.filter { model.trayPlacementGroup(id: $0.id) == group &&
            ($0.isPending || model.trayPlacementIsPending(id: $0.id) || model.trayPlacementFailure(id: $0.id) != nil) }.count
        return Button {
            presentation.trayFilter = presentation.trayFilter == group.id ? "all" : group.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: groupSymbol(group)).foregroundStyle(groupColor(group))
                    Text(group.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(count)")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("当前选择").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(groupDescription(group))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pendingCount > 0 ? "\(pendingCount) 项尚待确认" : "无待处理选择")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pendingCount > 0 ? .orange : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(presentation.trayFilter == group.id ? accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(presentation.trayFilter == group.id ? accent.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("按当前选择筛选\(group.title)的图标，数量包含尚未应用的草稿；再次点击显示全部。")
        .accessibilityLabel("\(group.title)，当前选择 \(count) 个图标" + (pendingCount > 0 ? "，其中 \(pendingCount) 项尚待确认" : "，无待处理选择"))
        .accessibilityValue(presentation.trayFilter == group.id ? "已筛选" : "未筛选")
    }

    private func groupSymbol(_ group: ItemVisibility) -> String {
        switch group {
        case .visible: "menubar.rectangle"
        case .collapsible: "tray"
        case .alwaysHidden: "eye.slash"
        }
    }

    private func groupColor(_ group: ItemVisibility) -> Color {
        switch group {
        case .visible: accent
        case .collapsible: .secondary
        case .alwaysHidden: .orange
        }
    }
    private func groupDescription(_ group: ItemVisibility) -> String {
        switch group {
        case .visible: "保持在菜单栏，随时可用。"
        case .collapsible: "收进托盘，点击菜单栏箭头查看。"
        case .alwaysHidden: "普通展开不显示，可临时显示全部。"
        }
    }

    private func itemIcon(_ item: ManagedItemRow) -> some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .opacity(item.isAvailable ? 1 : 0.45)
        .accessibilityHidden(true)
    }

    private var offlineDraftList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("保留的离线草稿 · \(model.offlineDrafts.count)")
                    .font(.system(size: 12, weight: .medium))
                Text("这些旧选择暂时无法关联当前图标，不参与自动处理。删除草稿不会改变已保存的分类或当前图标显示。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(14)
            ForEach(model.offlineDrafts) { draft in
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(draft.rule.name).font(.system(size: 12, weight: .medium))
                            rowBadge("离线草稿", color: .orange)
                        }
                        Text(draft.requiresReassociationAfterRestart
                            ? "原图标身份暂时无法确认，请明确关联当前图标。"
                            : "等待原图标重新出现；不会按名称自动关联。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(draft.rule.visibility.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    if draft.requiresReassociationAfterRestart {
                        Button("关联图标…") {
                            associationTargetID = ""
                            associationIssue = nil
                            draftToAssociate = draft
                        }
                        .disabled(groupingControlsDisabled)
                        .accessibilityLabel("关联\(draft.rule.name)的草稿")
                    }
                    Button { model.discardDraft(id: draft.id) } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(groupingControlsDisabled)
                    .help("删除此草稿；已应用规则不变")
                    .accessibilityLabel("删除\(draft.rule.name)的草稿")
                }
                .padding(14)
            }
        }
        .modifier(SettingsCardStyle())
    }

    private var associationTargets: [ManagedItemRow] {
        let counts = Dictionary(grouping: model.items, by: \.id).mapValues(\.count)
        return model.items.filter { $0.isAvailable && $0.canMove && counts[$0.id] == 1 }
    }

    private func draftAssociationSheet(_ draft: PendingDraftRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("关联待应用草稿").font(.system(size: 17, weight: .semibold))
            Text("将「\(draft.rule.name)」的「\(draft.rule.visibility.title)」选择关联到下面的当前图标。关联后仍需应用，不会立即移动或隐藏。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Picker("当前图标", selection: $associationTargetID) {
                Text("请选择图标").tag("")
                ForEach(associationTargets) { item in
                    Text("\(item.name) · \(item.ownerName)" + (model.pendingDraftID(for: item.id) == nil ? "" : "（已有草稿）"))
                        .tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(groupingControlsDisabled)
            if associationTargets.isEmpty {
                Text("当前没有可关联的图标。请返回列表刷新后重试。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let issue = associationIssue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { draftToAssociate = nil }.keyboardShortcut(.cancelAction)
                Button("关联并保留为待应用") {
                    if model.reassociateDraft(id: draft.id, to: associationTargetID) {
                        draftToAssociate = nil
                    } else {
                        associationIssue = model.managementError ?? "当前图标不可用，未修改草稿。请返回列表刷新后重试。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(groupingControlsDisabled || associationTargetID.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
    private func rowBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    private var temporaryRevealNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("原生菜单栏分组已展开").font(.system(size: 12, weight: .medium))
                Text("包含「始终隐藏」。系统空间不足时仍需系统溢出入口；结束后恢复此前的展开／收起状态。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("结束临时显示") { model.endTemporaryReveal() }.disabled(groupingControlsDisabled)
            Button("收起现有分组") { model.collapseNativeGroups() }.disabled(groupingControlsDisabled)
        }
        .padding(12)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var managementNotices: some View {
        VStack(alignment: .leading, spacing: 6) {
            recoveryNotice
            compatibilityNotices
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recoveryNotice: some View {
        Group {
            if let recovery = model.positionRecoveryMessage {
                VStack(alignment: .leading, spacing: 8) {
                    detailedIssueNotice(recovery, symbol: "arrow.uturn.backward.circle",
                                        title: "查看图标恢复详情", isExpanded: $presentation.recoveryDetailsExpanded)
                    HStack {
                        Button(model.usesNativeVisibility ? "重试恢复图标" : "重试恢复原排序") { model.retryPositionRecovery() }
                        Button("恢复隐藏项并保留外部改动") { model.keepCurrentPositionLayout() }
                            .help("恢复仍由 Menu Tidy 管理的图标状态；保留其他操作改过的设置。待应用分类不会标为成功。")
                    }
                    .disabled(groupingControlsDisabled)
                }
            }
        }
    }

    private var compatibilityNotices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = model.panelItemProgress, !isBusy {
                issueNotice(progress, symbol: "arrow.left.arrow.right", tint: accent)
            }
            if let error = model.managementError {
                detailedIssueNotice(error, symbol: "exclamationmark.triangle.fill",
                                    title: "查看完整原因", isExpanded: $presentation.managementErrorDetailsExpanded)
            }
            if let warning = model.iconImageWarning {
                VStack(alignment: .leading, spacing: 5) {
                    issueNotice(warning, symbol: "photo")
                    if let details = model.iconImageWarningDetails {
                        DisclosureGroup("查看图像获取详情", isExpanded: $presentation.imageWarningDetailsExpanded) {
                            Text(details)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 5)
                        }
                        .font(.system(size: 11))
                        .padding(.leading, 24)
                    }
                }
            }
            if let error = model.panelActivationError {
                issueNotice("图标操作：\(error)", symbol: "cursorarrow.click", isError: true)
            }
            if let error = model.panelError {
                issueNotice("图标栏：\(error)", symbol: "rectangle.on.rectangle.slash", isError: true)
            }
            ForEach(Array(environmentNotices.enumerated()), id: \.offset) { _, issue in
                issueNotice(issue, symbol: "exclamationmark.triangle")
            }
            if let message = model.managementMessage, !isBusy { issueNotice(message, symbol: "info.circle", tint: accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Quote the beginning of the actual result rather than inferring that all
    /// items failed, succeeded, or were restored from an unstructured error.
    private func detailedIssueNotice(_ detail: String, symbol: String, title: String,
                                     isExpanded: Binding<Bool>) -> some View {
        let summary = issueSummary(detail)
        return VStack(alignment: .leading, spacing: 5) {
            issueNotice(summary, symbol: symbol, isError: true)
            if summary != detail {
                DisclosureGroup(title, isExpanded: isExpanded) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                }
                .font(.system(size: 11))
                .padding(.leading, 24)
            }
        }
    }

    private func issueSummary(_ detail: String) -> String {
        let firstLine = detail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? detail
        let firstSentence = firstLine.firstIndex(of: "。").map { String(firstLine[...$0]) } ?? firstLine
        return firstSentence.count > 100 ? String(firstSentence.prefix(100)) + "…" : firstSentence
    }
    private var environmentNotices: [String] {
        var result: [String] = []
        for issue in [model.environmentIssue, model.layoutIssue].compactMap({ $0 }) {
            if !result.contains(issue) { result.append(issue) }
        }
        return result
    }

    private var settingsPage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if model.isArranging { arrangementNotice }
                permissionCard(compact: false)
                if model.usesNativeVisibility { nativeVisibilityAccessCard(compact: false) }
                if model.nativeSystemVisibilityAccessNeeded { nativeSystemVisibilityAccessCard }
                if showsPositionAccessCard { menuBarPositionAccessCard(compact: false) }
                screenCapturePermissionCard
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用偏好").font(.system(size: 13, weight: .semibold))
                    preferencesCard
                }
                UpdateSettingsView(updates: updates)
                managementNotices
                if let issue = model.shortcutIssue { issueNotice(issue, symbol: "keyboard") }
                if let issue = model.loginIssue {
                    VStack(alignment: .leading, spacing: 6) {
                        issueNotice(issue, symbol: "person.crop.circle.badge.exclamationmark")
                        Button("打开系统登录项设置") { model.showSystemLoginSettings() }
                            .buttonStyle(.link).padding(.leading, 24)
                    }
                }
                footer
            }
            .padding(20)
        }
    }

    private func permissionCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.accessibilityGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                    .font(.system(size: 21)).foregroundStyle(accent)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.accessibilityGranted ? "辅助功能已开启" : "先允许 Menu Tidy 整理菜单栏")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.usesNativeVisibility
                        ? "辅助功能用于读取菜单栏图标并打开对应的原生菜单。图标的显示与隐藏另需下方菜单栏设置文件授权；屏幕录制只用于增强原始图标外观，未开启时托盘仍可使用应用身份图标。"
                        : "辅助功能用于读取图标、确认位置，以及请求系统支持的图标操作。调整原生位置另需排序目录授权；屏幕录制仅用于增强原始图标外观，未开启时托盘仍可使用应用身份图标。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !model.accessibilityGranted {
                HStack(alignment: .top, spacing: 16) {
                    permissionStep("1", title: "打开授权页面", detail: "申请权限或打开系统设置。")
                    permissionStep("2", title: "开启 Menu Tidy", detail: "在系统设置的「\(model.permissionSettingsName)」中开启。")
                    permissionStep("3", title: "返回应用", detail: "自动检测权限，再刷新图标列表。")
                }
                Text("系统开关需要你亲自确认，应用不能代替或绕过授权。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if !model.accessibilityGranted {
                    Button("申请辅助功能权限") { model.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                }
                Button("打开系统设置") { model.openAccessibilitySettings() }
                Button("重新检测") { model.recheckPermissions() }
                Spacer(minLength: 0)
                if compact {
                    Button("权限说明与设置") { presentation.page = .settings }.buttonStyle(.link)
                }
            }

            if let message = model.permissionCheckMessage {
                issueNotice(message, symbol: "info.circle", tint: accent)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前运行的应用")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(model.applicationPath)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.applicationPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("在访达中显示应用") { model.revealApplication() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .fixedSize()
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

            DisclosureGroup("已开启仍未识别？", isExpanded: $presentation.permissionHelpExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("应用更新或重新签名后，系统中旧的授权记录可能失效，即使开关仍显示为开启。")
                    Text("请在系统设置中移除旧的 Menu Tidy 记录，重新添加上方显示的当前应用并开启权限，然后返回点击「重新检测」。")
                    Text("移除、添加和开启权限都需要你在系统设置中确认，应用不能自动绕过系统授权。")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .modifier(SettingsCardStyle())
    }

    private func nativeVisibilityAccessCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.nativeVisibilityAccessAvailable ? "checkmark.shield.fill" : "doc.text")
                    .font(.system(size: compact ? 18 : 21)).foregroundStyle(accent)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.nativeVisibilityAccessAvailable ? "菜单栏显示设置已授权" : "允许调整菜单栏显示设置")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    Text("在系统选择窗口中确认已定位的菜单栏设置文件。授权后，选择常驻或收进托盘即可处理；点击托盘图标仍可打开应用的原生菜单。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !compact {
                Text("仅授权这一个菜单栏设置文件。已保存的图标选择会保留，完成授权后可继续处理。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(model.nativeVisibilityAccessAvailable ? "重新选择设置文件…" : "授权菜单栏显示设置…") {
                    model.requestNativeVisibilityAccess()
                }
                Button("重新检测文件访问") { model.recheckNativeVisibilityAccess() }
                Spacer(minLength: 0)
                if compact { Button("权限说明") { presentation.page = .settings }.buttonStyle(.link) }
            }
            .disabled(groupingControlsDisabled)
            if let message = model.nativeVisibilityAccessMessage {
                issueNotice(message, symbol: "info.circle", tint: model.nativeVisibilityAccessAvailable ? accent : .orange)
            }
        }
        .padding(compact ? 12 : 16)
        .modifier(SettingsCardStyle())
    }

    private var nativeSystemVisibilityAccessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("允许管理系统图标").font(.system(size: 13, weight: .semibold))
            Text("隔空投送和输入法切换图标使用各自的系统显示设置。只需在选择窗口中授权已定位的设置文件，完成后可重试连接。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("授权系统图标显示设置…") { model.requestNativeSystemVisibilityAccess() }
                .disabled(groupingControlsDisabled)
            if let message = model.nativeSystemVisibilityAccessMessage {
                issueNotice(message, symbol: "info.circle", tint: .orange)
            }
        }
        .padding(12)
        .modifier(SettingsCardStyle())
    }

    private func menuBarPositionAccessCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.menuBarPositionAccessAvailable ? "folder.badge.checkmark" : "folder.badge.questionmark")
                    .font(.system(size: compact ? 18 : 21))
                    .foregroundStyle(accent)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.usesNativeVisibility ? "恢复旧版菜单栏位置" :
                        (model.menuBarPositionAccessAvailable ? "菜单栏排序目录可访问" : "后台分组还需单独授权排序目录"))
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    Text(model.usesNativeVisibility
                        ? "旧版本留下的位置记录尚待恢复。这里的目录授权仅用于完成这次恢复；日常托盘显示使用上方的菜单栏设置文件。"
                        : (compact
                            ? "辅助功能授权不包含排序目录。点击下方按钮，在系统选择窗口中确认目录；仍可使用 ⌘ 拖拽分组。"
                            : "后台分组需要读取和更新系统菜单栏排序记录。请通过系统目录选择窗口，仅授权菜单栏的 Preferences 目录；辅助功能权限不会自动提供这项访问。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !compact {
                Text("~/Library/Group Containers/com.apple.MenuBar/Library/Preferences")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.usesNativeVisibility
                    ? "恢复时保留其他操作对菜单栏所做的修改。完成后，这项旧版目录权限不再是日常托盘使用的前提。"
                    : "只访问菜单栏排序目录，不需要「完整磁盘访问权限」。目录可访问后，仍需逐项确认身份和实际位置，才能保存为已应用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(model.menuBarPositionAccessAvailable ? "重新选择排序目录…" : "授权排序目录…") {
                    model.requestMenuBarPositionAccess()
                }
                .help("打开系统目录选择窗口，由你确认仅访问菜单栏排序目录。")
                Button("重新检测目录访问") { model.recheckMenuBarPositionAccess() }
                Spacer(minLength: 0)
                if compact {
                    Button("权限说明") { presentation.page = .settings }.buttonStyle(.link)
                }
            }
            .disabled(groupingControlsDisabled)
            if let message = model.menuBarPositionAccessMessage {
                issueNotice(message, symbol: "info.circle",
                            tint: model.menuBarPositionAccessAvailable ? accent : .orange)
            }
        }
        .padding(compact ? 12 : 16)
        .modifier(SettingsCardStyle())
    }

    private var screenCapturePermissionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.screenCaptureGranted ? "checkmark.rectangle" : "rectangle.on.rectangle")
                    .font(.system(size: 21)).foregroundStyle(accent)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.screenCaptureGranted ? "原始图标外观已启用" : "增强托盘图标外观（可选）")
                        .font(.system(size: 13, weight: .semibold))
                    Text("不开启也能使用托盘，届时显示应用身份图标与名称。开启后可显示原始菜单栏图标；这项权限不会增加应用操作的兼容性。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("只采集已确认的图标窗口或小块区域，不上传、不保存到磁盘，也不采集声音。原始图标是最近的快照，隐藏期间可能不会及时反映状态变化。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.screenCaptureGranted {
                HStack(alignment: .top, spacing: 16) {
                    permissionStep("1", title: "申请权限", detail: "点击下方按钮，按 macOS 提示操作。")
                    permissionStep("2", title: "开启当前应用", detail: "在系统设置的屏幕录制或屏幕与系统音频录制页面开启 Menu Tidy。")
                    permissionStep("3", title: "返回并检测", detail: "完成系统确认后返回，点击「重新检测」。")
                }
                Text("系统授权需要你亲自确认。即使系统页面名称包含音频，Menu Tidy 也不采集声音。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if !model.screenCaptureGranted {
                    Button("申请屏幕录制权限") { model.requestScreenCapture() }
                        .buttonStyle(.borderedProminent)
                }
                Button("打开系统设置") { model.openScreenCaptureSettings() }
                    .help("打开屏幕录制权限设置，选择当前安装的 Menu Tidy。")
                Button("重新检测") { model.refreshPermissions() }
                Spacer(minLength: 0)
            }
            .disabled(isBusy)
            VStack(alignment: .leading, spacing: 7) {
                Text("若 macOS 提示需要重新启动应用，请先退出 Menu Tidy，再从当前安装位置重新打开；已保存的设置会保留。授权尚未生效时，托盘仍可显示应用身份图标。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.screenCaptureGranted {
                    Button("退出 Menu Tidy") { model.quit() }
                        .buttonStyle(.link)
                        .disabled(isBusy)
                        .help("退出后请从应用程序文件夹重新打开 Menu Tidy。")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .modifier(SettingsCardStyle())
    }

    private func permissionStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(accent).frame(width: 18, height: 18)
                .background(accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            preferenceRow(title: "展开后自动收起", subtitle: "仅影响「收起后隐藏」分组，默认关闭。") {
                HStack(spacing: 9) {
                    Picker("自动收起等待时间", selection: $model.autoCollapseDelay) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) 秒").tag(Double($0)) }
                    }
                    .labelsHidden().frame(width: 85).disabled(!model.autoCollapseEnabled)
                    Toggle("展开后自动收起", isOn: $model.autoCollapseEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Divider()
            preferenceRow(title: "键盘快捷键", subtitle: usesPanelVisibility ? "随时打开或收起独立托盘。" : "随时展开或收起，不展开「始终隐藏」图标。") {
                HStack(spacing: 12) {
                    Text("⌃ ⌥ M")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Control Option M")
                    Toggle("启用 Control Option M 快捷键", isOn: $model.shortcutEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            if !model.usesPositionHiding && !model.usesNativeVisibility {
                Divider()
                preferenceRow(title: "启动时收起图标", subtitle: model.hasCompletedSetup ? "打开 Menu Tidy 时保持菜单栏整洁。" : "完成一次托盘设置后可启用。") {
                    Toggle("启动时收起图标", isOn: $model.startCollapsed)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!model.hasCompletedSetup)
                }
            }
            Divider()
            preferenceRow(title: "登录时启动", subtitle: "登录 Mac 后自动开启 Menu Tidy。") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .modifier(SettingsCardStyle())
    }

    private func preferenceRow<Control: View>(title: String, subtitle: String,
                                              @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 13)
    }
    private func issueNotice(_ text: String, symbol: String, isError: Bool = false,
                             tint: Color = .orange) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(isError ? .red : tint)
                .frame(width: 16).accessibilityHidden(true)
            Text(text).foregroundStyle(isError ? Color.primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
    private var footer: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("图标栏画面只在内存中显示，不上传、不存盘、不采集声音", systemImage: "lock.shield")
                    .font(.system(size: 10, weight: .medium))
                Text("点击菜单栏箭头打开独立托盘，右键打开设置。没有原始图像时显示应用身份图标；原生菜单栏的可见容量仍受屏幕宽度限制。")
                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("退出 Menu Tidy") { model.quit() }
                .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct SettingsCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
            }
    }
}
