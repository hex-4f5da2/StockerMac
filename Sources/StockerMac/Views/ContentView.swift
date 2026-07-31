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
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } content: {
            DashboardView(percentageSortMode: $quotePercentageSortMode)
                .navigationSplitViewColumnWidth(min: 600, ideal: 760)
        } detail: {
            InspectorView(row: store.selectedRow)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        .frame(minWidth: 1060, minHeight: 680)
        .background(WindowModeResizer(mode: .fullSize))
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isCreatingGroup = false
    @State private var groupName = ""
    @State private var groupToRename: StockGroup?
    @State private var groupToDelete: StockGroup?

    var body: some View {
        List(selection: sidebarSelection) {
            Section("行情") {
                Label("全部自选", systemImage: "star.fill")
                    .badge(store.items.count)
                    .tag("all")
                ForEach(Market.allCases) { market in
                    Label(market.title, systemImage: icon(for: market))
                        .badge(store.items.filter { $0.market == market }.count)
                        .tag(market.rawValue)
                }
            }

            Section("资产") {
                Label("我的持仓", systemImage: "briefcase.fill")
                    .badge(store.items.filter { $0.quantity > 0 }.count)
                    .tag("positions")
            }

            Section {
                Button {
                    groupName = ""
                    isCreatingGroup = true
                } label: {
                    Label("新建分组", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StockerTheme.accent)

                ForEach(store.groups) { group in
                    HStack {
                        Label(group.name, systemImage: "folder")
                        Spacer()
                        if store.hasGroupAverageAlert(group.id) {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(StockerTheme.accent)
                        }
                    }
                    .badge(store.itemCount(in: group.id))
                    .tag(group.sidebarID)
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
                .onMove(perform: store.moveGroups)

                Label("未分组", systemImage: "tray")
                    .badge(store.ungroupedItemCount)
                    .tag("ungrouped")
            } header: {
                HStack {
                    Text("分组")
                    Spacer()
                    Menu {
                        Button("按名称升序") {
                            store.sortGroups(by: .nameAscending)
                        }
                        Button("按名称降序") {
                            store.sortGroups(by: .nameDescending)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(store.groups.count < 2)
                    .help("排序分组")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.isAutoRefreshEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isAutoRefreshEnabled ? "实时更新中" : "自动刷新已暂停")
                        .font(.caption).fontWeight(.medium)
                    Text(store.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "等待首次更新")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.bar)
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

    private var sidebarSelection: Binding<String> {
        Binding(
            get: {
                if let groupID = store.selectedGroupID { return "group:\(groupID.uuidString)" }
                if store.showingUngroupedOnly { return "ungrouped" }
                if store.showingPositionsOnly { return "positions" }
                return store.selectedMarket?.rawValue ?? "all"
            },
            set: { selection in
                if selection == "all" { store.selectAll() }
                else if selection == "positions" { store.selectPositions() }
                else if selection == "ungrouped" { store.selectUngrouped() }
                else if let market = Market(rawValue: selection) { store.selectMarket(market) }
                else if selection.hasPrefix("group:"), let id = UUID(uuidString: String(selection.dropFirst(6))) {
                    store.selectGroup(id)
                }
            }
        )
    }

    private func icon(for market: Market) -> String {
        switch market {
        case .cn: "building.columns"
        case .hk: "building.2"
        case .us: "globe.americas.fill"
        }
    }
}
