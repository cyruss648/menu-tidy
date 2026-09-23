import MenuTidyCore
import SwiftUI

/// Permission onboarding, explicit grouping drafts, and day-to-day preferences.
struct SettingsView: View {
    @ObservedObject var model: MenuTidyModel
    @State private var page: Page = .items
    @State private var searchText = ""
    @State private var groupFilter = "all"
    @State private var permissionHelpExpanded = false

    private let accent = Color(red: 0.14, green: 0.55, blue: 0.50)
    private enum Page: String, CaseIterable, Identifiable {
        case items = "管理图标"
        case settings = "权限与设置"
        var id: String { rawValue }
    }
    private var isBusy: Bool { model.isRefreshing || model.isApplying }
    private var groupingControlsDisabled: Bool { isBusy || model.isArranging }
    private var filteredItems: [ManagedItemRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.items.filter { item in
            (groupFilter == "all" || item.group.id == groupFilter)
                && (query.isEmpty || [item.name, item.ownerName, item.bundleIdentifier ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Picker("页面", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                Spacer()
                Label(model.accessibilityGranted ? "辅助功能已开启" : "需要辅助功能权限",
                      systemImage: model.accessibilityGranted ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(model.accessibilityGranted ? accent : .secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            Divider()
            if page == .items { managementPage } else { settingsPage }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity,
               minHeight: 680, idealHeight: 740, maxHeight: .infinity)
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
                Text("Menu Tidy")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("选择图标的显示方式，让菜单栏各就其位。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isBusy { ProgressView().controlSize(.small) }
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Button {
                model.toggleVisibility()
            } label: {
                Label(model.isCollapsed ? "展开图标" : "收起图标",
                      systemImage: model.isCollapsed ? "chevron.left" : "chevron.right")
            }
            .disabled(isBusy || model.isArranging || !model.hasCompletedSetup || model.temporarilyRevealingAll)
            .help("仅切换「收起后隐藏」的图标；「始终隐藏」不会随普通展开显示。")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var statusText: String {
        if model.isApplying { return "正在应用分组…" }
        if model.isRefreshing && model.isArranging { return "正在确认拖拽分组…" }
        if model.isRefreshing { return "正在读取图标…" }
        if model.isArranging { return "拖拽整理中" }
        if model.temporarilyRevealingAll { return "全部分组已展开" }
        if !model.accessibilityGranted { return "等待授权" }
        return model.isCollapsed ? "已收起" : "已展开"
    }

    private var managementPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    if !model.accessibilityGranted { permissionCard(compact: true) }
                    if model.isArranging { arrangementNotice } else { arrangementEntry }
                    HStack(spacing: 10) {
                        ForEach(ItemVisibility.allCases, id: \.id) { groupSummary($0) }
                    }
                    managementNotices
                    if model.temporarilyRevealingAll && !model.isArranging { temporaryRevealNotice }
                    listToolbar
                    itemList
                        .frame(height: max(160, geometry.size.height - (model.accessibilityGranted ? 250 : 450)))
                    applyBar
                }
                .padding(20)
            }
        }
    }

    private var arrangementEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 19)).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("也可以直接拖动菜单栏图标")
                    .font(.system(size: 12, weight: .medium))
                Text("进入整理模式后，按住 ⌘ 将图标拖到对应分组。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
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
        Button {
            groupFilter = groupFilter == group.id ? "all" : group.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: groupSymbol(group)).foregroundStyle(groupColor(group))
                    Text(group.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(model.items.filter { $0.group == group }.count)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Text(groupDescription(group))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(groupFilter == group.id ? accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(groupFilter == group.id ? accent.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("筛选\(group.title)的图标；再次点击显示全部。")
        .accessibilityLabel("\(group.title)，\(model.items.filter { $0.group == group }.count) 个图标")
        .accessibilityValue(groupFilter == group.id ? "已筛选" : "未筛选")
    }

    private func groupSymbol(_ group: ItemVisibility) -> String {
        switch group {
        case .visible: "pin"
        case .collapsible: "chevron.left.chevron.right"
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
        case .collapsible: "点击「···」展开，再次点击收起。"
        case .alwaysHidden: "普通展开不显示，可在列表中改回。"
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索应用或图标", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索应用或图标")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            Picker("筛选分组", selection: $groupFilter) {
                Text("全部图标").tag("all")
                ForEach(ItemVisibility.allCases, id: \.id) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 132)
            Button { model.refreshMenuItems() } label: {
                Label("刷新图标", systemImage: "arrow.clockwise")
            }
            .disabled(groupingControlsDisabled || !model.accessibilityGranted)
        }
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("图标 / 所属应用")
                Spacer()
                Text("显示方式").frame(width: 148, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if filteredItems.isEmpty {
                emptyList.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredItems, id: \.id) { item in
                            itemRow(item)
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 135, maxHeight: .infinity)
        .modifier(SettingsCardStyle())
    }

    private func itemRow(_ item: ManagedItemRow) -> some View {
        HStack(spacing: 12) {
            itemIcon(item)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if item.isPending {
                        rowBadge("待应用", color: .orange)
                    } else if !item.isAvailable {
                        rowBadge("当前不可用", color: .secondary)
                    } else if !item.canMove {
                        rowBadge("受保护", color: .secondary)
                    }
                }
                Text(itemSubtitle(item))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(item.detail)
            }
            Spacer(minLength: 10)
            Picker("\(item.name)的显示方式", selection: Binding(
                get: { item.group }, set: { model.setGroup(id: item.id, group: $0) }
            )) {
                ForEach(ItemVisibility.allCases, id: \.id) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 125)
            .disabled(!item.canMove || !item.isAvailable || groupingControlsDisabled || !model.accessibilityGranted)
            .help(item.canMove ? "修改后点击「应用分组」才会调整菜单栏。" : item.detail)
            if !item.isAvailable {
                Button { model.forgetItem(id: item.id) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(groupingControlsDisabled)
                .help("忘记此图标保存的规则")
                .accessibilityLabel("忘记\(item.name)的规则")
                .frame(width: 18)
            } else {
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(item.isPending ? accent.opacity(0.035) : .clear)
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
    private func itemSubtitle(_ item: ManagedItemRow) -> String {
        var components: [String] = []
        if !item.ownerName.isEmpty, item.ownerName != item.name { components.append(item.ownerName) }
        if !item.detail.isEmpty {
            components.append(item.detail)
        } else if !item.isAvailable {
            components.append("应用未运行或图标不可用，已保存的规则仍保留。")
        } else if !item.canMove {
            components.append("系统或本应用保护项，不能改变显示方式。")
        }
        if components.isEmpty { components.append(item.bundleIdentifier ?? "菜单栏图标") }
        return components.joined(separator: " · ")
    }
    private func rowBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    private var emptyList: some View {
        VStack(spacing: 7) {
            Image(systemName: !model.accessibilityGranted ? "lock.shield" : "menubar.rectangle")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            if !model.accessibilityGranted {
                Text("授权后，在这里管理菜单栏图标").font(.system(size: 12, weight: .medium))
                Text("可以在列表中选择，也可以按住 ⌘ 拖动分组。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.isRefreshing {
                Text("正在读取菜单栏图标…").font(.system(size: 12))
            } else if !searchText.isEmpty || groupFilter != "all" {
                Text("没有匹配的图标").font(.system(size: 12, weight: .medium))
                Button("清除搜索与筛选") { searchText = ""; groupFilter = "all" }
                    .buttonStyle(.link)
            } else {
                Text("暂未发现菜单栏图标").font(.system(size: 12, weight: .medium))
                Text("确认应用已显示菜单栏图标，再点击「刷新图标」。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
    }

    private var applyBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isArranging ? "请先完成菜单栏拖拽分组" : (model.hasPendingChanges ? "有未应用的分组更改" : "在列表中选择，再应用到菜单栏"))
                    .font(.system(size: 12, weight: .medium))
                Text(model.isArranging ? "整理期间暂停列表修改，完成后重新读取分组。" : (model.hasPendingChanges ? "当前选择尚未应用，点击右侧按钮后执行。" : "「始终隐藏」仍可在此管理，普通展开不会显示它。"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.temporarilyRevealingAll {
                Button("临时显示全部") { model.revealAllTemporarily() }
                    .disabled(groupingControlsDisabled)
                    .help("展开包括「始终隐藏」在内的全部分组；系统空间不足时，请通过系统溢出入口查看图标。")
            }
            Button { model.applyItemRules() } label: {
                HStack(spacing: 6) {
                    if model.isApplying { ProgressView().controlSize(.small) }
                    Text(model.isApplying ? "正在应用…" : "应用分组")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .help("应用当前分组选择（⌘↩）。整理期间请暂时不要操作鼠标或键盘。")
            .disabled(groupingControlsDisabled || !model.accessibilityGranted || !model.hasPendingChanges)
        }
        .padding(.top, 3)
    }

    private var temporaryRevealNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("已临时展开全部分组").font(.system(size: 12, weight: .medium))
                Text("包含「始终隐藏」。系统空间不足时仍需系统溢出入口；结束后恢复此前的展开／收起状态。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("结束临时显示") { model.endTemporaryReveal() }.disabled(groupingControlsDisabled)
        }
        .padding(12)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var managementNotices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.managementError {
                issueNotice(error, symbol: "exclamationmark.triangle.fill", isError: true)
            }
            ForEach(Array(environmentNotices.enumerated()), id: \.offset) { _, issue in
                issueNotice(issue, symbol: "exclamationmark.triangle")
            }
            if let message = model.managementMessage { issueNotice(message, symbol: "info.circle", tint: accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var environmentNotices: [String] {
        var result: [String] = []
        for issue in [model.environmentIssue, model.layoutIssue].compactMap({ $0 }) {
            if !result.contains(issue) { result.append(issue) }
        }
        return result
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.isArranging { arrangementNotice }
                permissionCard(compact: false)
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用偏好").font(.system(size: 13, weight: .semibold))
                    preferencesCard
                }
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
                    Text("辅助功能用于读取图标信息、调整菜单栏位置。列表显示应用图标和名称，不请求屏幕录制权限。")
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
                    Button("权限说明与设置") { page = .settings }.buttonStyle(.link)
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

            DisclosureGroup("已开启仍未识别？", isExpanded: $permissionHelpExpanded) {
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
            preferenceRow(title: "键盘快捷键", subtitle: "随时展开或收起，不展开「始终隐藏」图标。") {
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
            Divider()
            preferenceRow(title: "启动时收起图标", subtitle: model.hasCompletedSetup ? "打开 Menu Tidy 时保持菜单栏整洁。" : "首次应用分组后可启用。") {
                Toggle("启动时收起图标", isOn: $model.startCollapsed)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!model.hasCompletedSetup)
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
                Label("仅使用辅助功能管理菜单栏，不请求屏幕录制", systemImage: "lock.shield")
                    .font(.system(size: 10, weight: .medium))
                Text("右键点击菜单栏「···」可打开设置。刘海屏或图标过多时，展开空间仍取决于屏幕宽度。")
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
