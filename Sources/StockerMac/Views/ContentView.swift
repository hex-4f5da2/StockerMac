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
                        } ?? store.groups.first?.id
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
                    ForEach(Market.allCases) { market in
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

                    if store.groups.isEmpty {
                        emptyGroupHint
                    } else {
                        LazyVGrid(columns: groupColumns, spacing: 6) {
                            ForEach(store.groups) { group in
                                groupTile(group)
                                    .contextMenu {
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
                                        Button("上移") { store.moveGroup(group.id, by: -1) }
                                            .disabled(group.id == store.groups.first?.id)
                                        Button("下移") { store.moveGroup(group.id, by: 1) }
                                            .disabled(group.id == store.groups.last?.id)
                                        Divider()
                                        Button("重命名") {
                                            groupName = group.name
                                            groupToRename = group
                                        }
                                        Divider()
                                        Button("删除分组", role: .destructive) { groupToDelete = group }
                                    }
                            }
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
        .alert("新建分组", isPresented: $isCreatingGroup) {
            TextField("分组名称", text: $groupName)
            Button("取消", role: .cancel) {}
            Button("创建") { _ = store.createGroup(named: groupName) }
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("分组名称最长 30 个字符，不能与已有分组重名。")
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
            Text("股票不会从自选中删除，只会移除这个分组。")
        }
    }

    private var groupSectionHeader: some View {
        HStack(spacing: 4) {
            Text("自选分组")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(store.groups.count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                groupName = ""
                isCreatingGroup = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StockerTheme.accent)
            .help("新建分组")

            Menu {
                Button("按名称升序") {
                    store.sortGroups(by: .nameAscending)
                }
                Button("按名称降序") {
                    store.sortGroups(by: .nameDescending)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(store.groups.count < 2)
            .help("排序分组")
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .padding(.horizontal, 8)
    }

    private var groupColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
        ]
    }

    private func groupTile(_ group: StockGroup) -> some View {
        let isSelected = store.selectedGroupID == group.id
        return Button {
            store.selectGroup(group.id)
        } label: {
            HStack(spacing: 3) {
                Text(group.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .allowsTightening(true)
                Spacer(minLength: 2)
                if store.hasGroupAverageAlert(group.id) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 7.5))
                        .foregroundStyle(StockerTheme.accent)
                }
                Text("\(store.itemCount(in: group.id))")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? StockerTheme.accent : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
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
        .accessibilityValue("\(store.itemCount(in: group.id)) 只股票")
    }

    private var emptyGroupHint: some View {
        Button {
            groupName = ""
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
