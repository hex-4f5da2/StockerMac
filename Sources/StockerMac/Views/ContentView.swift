import StockerCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingBatchDelete = false
    @State private var isShowingCompactGroupPicker = false
    @State private var compactGroupID: UUID?
    @State private var pendingCompactGroupID: UUID?
    @State private var isCompactWindowPinned = false
    @State private var isShowingPositionHistory = false
    @State private var quotePercentageSortMode: QuotePercentageSortMode = .original

    var body: some View {
        Group {
            if let compactGroupID,
               store.groups.contains(where: { $0.id == compactGroupID }) {
                CompactGroupView(
                    groupID: compactGroupID,
                    isAlwaysOnTop: $isCompactWindowPinned,
                    percentageSortMode: $quotePercentageSortMode
                ) {
                    self.compactGroupID = nil
                }
            } else {
                fullSizeView
            }
        }
        .sheet(isPresented: $store.isSearchPresented) { StockSearchView() }
        .sheet(isPresented: $isShowingBatchDelete) {
            BatchDeleteView(candidateIDs: store.rows.map(\.id))
        }
        .sheet(isPresented: $isShowingCompactGroupPicker) {
            CompactGroupPickerView(selection: $pendingCompactGroupID) {
                guard let pendingCompactGroupID else { return }
                compactGroupID = pendingCompactGroupID
                isShowingCompactGroupPicker = false
            }
        }
        .sheet(isPresented: $isShowingPositionHistory) {
            PositionHistoryView()
        }
        .alert("无法更新行情", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
    }

    private var fullSizeView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 230)
        } content: {
            if store.showingTelegraph {
                TelegraphView()
                    .navigationSplitViewColumnWidth(min: 520, ideal: 600)
            } else {
                DashboardView(percentageSortMode: $quotePercentageSortMode)
                    .navigationSplitViewColumnWidth(min: 520, ideal: 600)
            }
        } detail: {
            if store.showingTelegraph {
                TelegraphDetailView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 330)
            } else {
                InspectorView(row: store.selectedRow)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 330)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.showingTelegraph {
                    Button { store.isSearchPresented = true } label: { Label("添加股票", systemImage: "plus") }
                    Button { isShowingBatchDelete = true } label: { Label("批量删除", systemImage: "trash") }
                        .disabled(store.rows.isEmpty)
                        .help("批量删除当前列表中的股票")
                    Button { isShowingPositionHistory = true } label: {
                        Label("清仓历史", systemImage: "clock.arrow.circlepath")
                    }
                    .help("查看清仓历史")
                    Button {
                        pendingCompactGroupID = compactGroupID.flatMap { id in
                            store.groups.contains(where: { $0.id == id }) ? id : nil
                        } ?? store.groupSections.first?.group.id
                        isShowingCompactGroupPicker = true
                    } label: {
                        Label("小窗模式", systemImage: "rectangle.compress.vertical")
                    }
                    .help("选择一个分组并进入小窗模式")
                    Button { store.toggleAutoRefresh() } label: {
                        Label(store.isAutoRefreshEnabled ? "暂停自动刷新" : "继续自动刷新",
                              systemImage: store.isAutoRefreshEnabled ? "pause.fill" : "play.fill")
                    }
                    Button { Task { await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Label("刷新", systemImage: "arrow.clockwise") }
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowModeResizer(mode: .fullSize))
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var telegraphVM: TelegraphViewModel
    @State private var isCreatingGroup = false
    @State private var createGroupPresetParent: UUID?
    @State private var groupName = ""
    @State private var groupToRename: StockGroup?
    @State private var groupToDelete: StockGroup?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("行情")
                    navRow(
                        "全部自选",
                        icon: "star.fill",
                        badge: store.items.count,
                        isSelected: isAllSelected
                    ) {
                        store.selectAll()
                    }
                    ForEach(Market.supportedCases) { market in
                        navRow(
                            market.title,
                            icon: icon(for: market),
                            badge: store.items.filter { $0.market == market }.count,
                            isSelected: store.selectedMarket == market
                        ) {
                            store.selectMarket(market)
                        }
                    }

                    sectionHeader("资产")
                    navRow(
                        "我的持仓",
                        icon: "briefcase.fill",
                        badge: store.items.filter { $0.quantity > 0 }.count,
                        isSelected: store.showingPositionsOnly
                    ) {
                        store.selectPositions()
                    }

                    if AppStore.telegraphEnabled {
                        sectionHeader("消息")
                        navRow(
                            "电报",
                            icon: "newspaper.fill",
                            badge: telegraphVM.unreadCount,
                            isSelected: store.showingTelegraph
                        ) {
                            store.selectTelegraph()
                        }
                    }

                    groupSectionHeader

                    if store.groupSections.isEmpty {
                        emptyGroupHint
                    } else {
                        ForEach(store.groupSections) { section in
                            groupSectionBlock(section)
                        }
                    }

                    ungroupedRow
                }
                .padding(.horizontal, 10)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            Divider()

            refreshStatus
        }
        .navigationTitle("Stocker")
        .sheet(isPresented: $isCreatingGroup) {
            GroupCreateView(presetParentID: createGroupPresetParent)
        }
        .alert("重命名分组", isPresented: Binding(
            get: { groupToRename != nil },
            set: { if !$0 { groupToRename = nil } }
        )) {
            TextField("分组名称", text: $groupName)
            Button("取消", role: .cancel) { groupToRename = nil }
            Button("保存") {
                if let groupToRename { _ = store.renameGroup(groupToRename.id, to: groupName) }
                groupToRename = nil
            }
            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("删除分组？", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { groupToDelete = nil }
            Button("删除", role: .destructive) {
                if let groupToDelete { store.deleteGroup(groupToDelete.id) }
                groupToDelete = nil
            }
        } message: {
            Text(deleteGroupMessage)
        }
    }

    private var deleteGroupMessage: String {
        guard let groupToDelete else { return "" }
        let childCount = store.childGroups(of: groupToDelete.id).count
        if childCount > 0 {
            return "将同时删除其 \(childCount) 个二级分组。股票不会从自选中删除，只会移除分组关系。"
        }
        return "股票不会从自选中删除，只会移除这个分组。"
    }

    private var groupSectionHeader: some View {
        HStack(spacing: 4) {
            Text("自选分组")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(store.groupSections.count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            Image(systemName: "flame.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .help("按平均涨跌幅自动排序，每分钟更新一次；无行情的分组排在末尾")

            Button {
                createGroupPresetParent = nil
                isCreatingGroup = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StockerTheme.accent)
            .help("新建分组")
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .padding(.horizontal, 8)
    }

    /// 分组块：一级行（点击聚合查看）+ 平铺的二级标签（点击直达），无需展开。
    private func groupSectionBlock(_ section: GroupStrengthSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            primaryGroupRow(section)
            if !section.children.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(section.children) { child in
                        secondaryGroupChip(child)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.top, 3)
    }

    private func primaryGroupRow(_ section: GroupStrengthSection) -> some View {
        let group = section.group
        let isSelected = store.selectedGroupID == group.id
        let containsSelection = store.selectedGroupID.map { selectedID in
            selectedID == group.id || section.children.contains { $0.id == selectedID }
        } ?? false
        let rowBackground = isSelected
            ? StockerTheme.accent.opacity(0.16)
            : (containsSelection ? StockerTheme.accent.opacity(0.07) : Color.primary.opacity(0.035))
        let moveTargets = store.groupSections.map(\.group).filter { $0.id != group.id }

        return Button {
            store.selectGroup(group.id)
        } label: {
            HStack(spacing: 4) {
                Text(group.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                if group.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(StockerTheme.accent)
                        .rotationEffect(.degrees(30))
                }
                if store.hasGroupAverageAlert(group.id) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 7.5))
                        .foregroundStyle(StockerTheme.accent)
                }
                Spacer(minLength: 4)
                if let average = section.averagePercentage {
                    TrendText(value: average, text: Formatters.percent(average))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("-")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text("\(section.memberCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected || containsSelection ? StockerTheme.accent : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        group.isPinned ? StockerTheme.accent.opacity(0.45) : (isSelected ? StockerTheme.accent.opacity(0.35) : Color.primary.opacity(0.065)),
                        lineWidth: group.isPinned ? 1 : 0.7
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleGroupPinned(group.id)
            } label: {
                Label(
                    group.isPinned ? "取消置顶锁定" : "置顶锁定",
                    systemImage: group.isPinned ? "pin.slash" : "pin.fill"
                )
            }
            Divider()
            Button {
                store.toggleGroupAverageAlert(group.id)
            } label: {
                Label(
                    store.hasGroupAverageAlert(group.id) ? "关闭平均涨跌幅提醒" : "开启平均涨跌幅提醒",
                    systemImage: store.hasGroupAverageAlert(group.id) ? "bell.slash" : "bell"
                )
            }
            .disabled(section.memberCount == 0)
            Divider()
            Button {
                createGroupPresetParent = group.id
                isCreatingGroup = true
            } label: {
                Label("新建二级分组", systemImage: "folder.badge.plus")
            }
            Divider()
            Menu {
                ForEach(moveTargets) { target in
                    Button(target.name) {
                        store.moveGroup(group.id, underParent: target.id)
                    }
                }
            } label: {
                Label("移动分组到", systemImage: "arrow.down.right")
            }
            .disabled(moveTargets.isEmpty)
            Divider()
            Button("重命名") {
                groupName = group.name
                groupToRename = group
            }
            Divider()
            Button("删除分组", role: .destructive) { groupToDelete = group }
        }
        .accessibilityValue("\(section.memberCount) 只股票，平均涨跌幅 \(section.averagePercentage.map(Formatters.percent) ?? "暂无行情")")
    }

    private func secondaryGroupChip(_ group: StockGroup) -> some View {
        let isSelected = store.selectedGroupID == group.id
        let average = store.groupAveragePercentage(for: group.id)
        let moveTargets = store.groupSections.map(\.group).filter {
            $0.id != group.id && $0.id != group.parentID
        }

        return Button {
            store.selectGroup(group.id)
        } label: {
            HStack(spacing: 3) {
                if group.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6.5))
                        .foregroundStyle(StockerTheme.accent)
                        .rotationEffect(.degrees(30))
                }
                Text(group.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if let average {
                    TrendText(value: average, text: Formatters.percent(average))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("-")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                group.isPinned ? StockerTheme.accent.opacity(0.14) : (isSelected ? StockerTheme.accent.opacity(0.18) : Color.primary.opacity(0.045)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        group.isPinned ? StockerTheme.accent.opacity(0.4) : (isSelected ? StockerTheme.accent.opacity(0.35) : Color.primary.opacity(0.06)),
                        lineWidth: group.isPinned ? 0.9 : 0.6
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleGroupPinned(group.id)
            } label: {
                Label(
                    group.isPinned ? "取消置顶锁定" : "置顶锁定",
                    systemImage: group.isPinned ? "pin.slash" : "pin.fill"
                )
            }
            Divider()
            Button {
                store.toggleGroupAverageAlert(group.id)
            } label: {
                Label(
                    store.hasGroupAverageAlert(group.id) ? "关闭平均涨跌幅提醒" : "开启平均涨跌幅提醒",
                    systemImage: store.hasGroupAverageAlert(group.id) ? "bell.slash" : "bell"
                )
            }
            .disabled(store.itemCount(in: group.id) == 0)
            Divider()
            Menu {
                Button {
                    store.moveGroup(group.id, underParent: nil)
                } label: {
                    Label("作为一级分组", systemImage: "arrow.up.left")
                }
                if !moveTargets.isEmpty {
                    Divider()
                    ForEach(moveTargets) { target in
                        Button(target.name) {
                            store.moveGroup(group.id, underParent: target.id)
                        }
                    }
                }
            } label: {
                Label("移动分组到", systemImage: "arrow.down.right")
            }
            Divider()
            Button("重命名") {
                groupName = group.name
                groupToRename = group
            }
            Divider()
            Button("删除分组", role: .destructive) { groupToDelete = group }
        }
    }

    private var emptyGroupHint: some View {
        Button {
            createGroupPresetParent = nil
            isCreatingGroup = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(StockerTheme.accent)
                Text("创建第一个分组")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var ungroupedRow: some View {
        let isSelected = store.showingUngroupedOnly
        return Button {
            store.selectUngrouped()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? StockerTheme.accent : .secondary)
                    .frame(width: 16)
                Text("未分组")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer()
                countBadge(store.ungroupedItemCount, isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                isSelected ? StockerTheme.accent.opacity(0.16) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected ? StockerTheme.accent.opacity(0.35) : Color.primary.opacity(0.065),
                        lineWidth: 0.7
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue("\(store.ungroupedItemCount) 只股票")
        .padding(.top, 6)
    }

    private func navRow(
        _ title: String,
        icon: String,
        badge: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? StockerTheme.accent : .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                countBadge(badge, isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                isSelected ? StockerTheme.accent.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue("\(badge)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 3)
    }

    private func countBadge(_ count: Int, isSelected: Bool) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(isSelected ? StockerTheme.accent : .secondary)
            .monospacedDigit()
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 16)
            .background(
                isSelected ? StockerTheme.accent.opacity(0.12) : Color.primary.opacity(0.055),
                in: Capsule()
            )
    }

    private var refreshStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isAutoRefreshEnabled ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (store.isAutoRefreshEnabled ? Color.green : Color.orange).opacity(0.35), radius: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.isAutoRefreshEnabled ? "实时更新中" : "自动刷新已暂停")
                    .font(.caption.weight(.medium))
                Text(store.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "等待首次更新")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var isAllSelected: Bool {
        store.selectedMarket == nil
            && !store.showingPositionsOnly
            && !store.showingUngroupedOnly
            && !store.showingTelegraph
            && store.selectedGroupID == nil
    }

    private func icon(for market: Market) -> String {
        switch market {
        case .cn: "building.columns"
        case .hk: "building.2"
        case .us: "globe.americas.fill"
        }
    }
}

/// 新建分组：选上级（无 = 一级分组）+ 名称，一次对话框覆盖两级创建。
private struct GroupCreateView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let presetParentID: UUID?
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var showsInvalidHint = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("新建分组").font(.title2.bold())
                Text("挂在一级分组下即成为二级分组；一级分组可聚合查看名下全部细分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("上级分组")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("上级分组", selection: $parentID) {
                        Text("无（作为一级分组）").tag(Optional<UUID>.none)
                        ForEach(store.groupSections) { section in
                            Text(section.group.name).tag(Optional(section.group.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("分组名称")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("例如：电池、固态、锂矿", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                }

                if showsInvalidHint {
                    Text("名称为空、超过 30 个字符，或与已有分组重名。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 380, height: 300)
        .onAppear {
            parentID = presetParentID.flatMap { id in
                store.groups.first { $0.id == id && $0.parentID == nil }?.id
            }
        }
    }

    private func create() {
        guard store.createGroup(named: name, parentID: parentID) != nil else {
            showsInvalidHint = true
            return
        }
        dismiss()
    }
}

/// 横向流式布局：放不下自动换行，用于二级分组标签。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
