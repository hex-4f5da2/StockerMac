import Combine
import Foundation
import StockerCore
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    /// 电报（财联社/金十快讯）功能开关。关闭后不再轮询拉取，侧边栏与设置项同步隐藏，可缓解卡顿。
    static let telegraphEnabled = false

    private static let marketIndexItems = [
        WatchItem(code: "SH000001", name: "上证指数", market: .cn),
        WatchItem(code: "SZ399001", name: "深证成指", market: .cn),
        WatchItem(code: "SH000688", name: "科创50", market: .cn),
        WatchItem(code: "SZ399006", name: "创业板指", market: .cn),
        WatchItem(code: "BJ899050", name: "北证50", market: .cn)
    ]

    @Published var items: [WatchItem]
    @Published var groups: [StockGroup]
    @Published private(set) var groupMemberships: [String: Set<UUID>]
    @Published private(set) var groupSections: [GroupStrengthSection] = []
    @Published private(set) var positionHistory: [PositionHistoryRecord]
    @Published private(set) var stockPriceAlerts: [StockPriceAlert]
    @Published private(set) var groupAverageAlerts: [GroupAverageAlert]
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published var selectedMarket: Market?
    @Published var showingPositionsOnly = false
    @Published var showingUngroupedOnly = false
    @Published var showingTelegraph = false
    @Published var selectedGroupID: UUID?
    @Published var selectedID: String?
    @Published var dataMode: MarketDataMode
    @Published var provider: QuoteProvider
    @Published var stockDBHost: String
    @Published var stockDBPort: Int
    @Published var refreshInterval: Double
    @Published var colorPreference: ColorSchemePreference
    @Published var statusBarDisplayMode: StatusBarDisplayMode
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAutoRefreshEnabled = true
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isSearchPresented = false

    private let service = QuoteService()
    private let notificationService = NotificationService()
    private let stateStore = StateStore()
    private var refreshTask: Task<Void, Never>?
    private var persistDebounce: Task<Void, Never>?
    /// 上次按强度重排分组的时间；与行情刷新解耦，每分钟最多重排一次。
    private var lastGroupOrderingAt: Date?

    init() {
        let state = StateStore().load()
        // 港美股枚举仍可解码旧数据，但本地行情版不再把它们载入产品界面。
        let supportedItems = state.items.filter { $0.market == .cn }
        items = supportedItems
        groups = GroupOrdering.sanitizeGroups(state.groups)
        let validGroupIDs = Set(state.groups.map(\.id))
        let validItemIDs = Set(supportedItems.map(\.id))
        groupMemberships = state.groupMemberships.reduce(into: [:]) { result, entry in
            guard validItemIDs.contains(entry.key) else { return }
            let validMemberships = entry.value.intersection(validGroupIDs)
            if !validMemberships.isEmpty { result[entry.key] = validMemberships }
        }
        positionHistory = state.positionHistory
        let now = Date()
        stockPriceAlerts = state.stockPriceAlerts.filter {
            validItemIDs.contains($0.itemID) && $0.isValid(at: now)
        }
        groupAverageAlerts = state.groupAverageAlerts.filter {
            validGroupIDs.contains($0.groupID)
        }
        dataMode = state.dataMode
        provider = state.provider
        stockDBHost = state.stockDBHost
        stockDBPort = state.stockDBPort
        refreshInterval = state.refreshInterval
        colorPreference = state.colorPreference
        statusBarDisplayMode = state.statusBarDisplayMode
        rebuildGroupSections()
    }

    deinit { refreshTask?.cancel() }

    var allRows: [QuoteRow] {
        items.map { QuoteRow(item: $0, quote: quotes[$0.id]) }
    }

    var marketIndexRows: [QuoteRow] {
        Self.marketIndexItems.map { item in
            QuoteRow(item: item, quote: quotes[item.id])
        }
    }

    var positionRows: [QuoteRow] {
        allRows.filter(\.hasPosition)
    }

    var rows: [QuoteRow] {
        allRows
            .filter { selectedMarket == nil || $0.item.market == selectedMarket }
            .filter { !showingPositionsOnly || $0.hasPosition }
            .filter { !showingUngroupedOnly || groupIDs(for: $0.id).isEmpty }
            .filter { row in
                guard let selectedGroupID else { return true }
                return !groupIDs(for: row.id).intersection(groupTreeIDs(selectedGroupID)).isEmpty
            }
    }

    var selectedRow: QuoteRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID } ?? allRows.first { $0.id == selectedID }
    }

    var summary: PortfolioSummary {
        let positioned = rows.filter(\.hasPosition)
        return PortfolioSummary(
            marketValue: positioned.reduce(0) { $0 + $1.marketValue },
            dayProfit: positioned.reduce(0) { $0 + $1.dayProfit },
            totalProfit: positioned.reduce(0) { $0 + $1.totalProfit },
            positionCount: positioned.count
        )
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(max(5, self.refreshInterval)))
                if self.isAutoRefreshEnabled { await self.refresh() }
            }
        }
    }

    func restartRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
        start()
        persist()
    }

    var marketDataRoute: MarketDataRoute {
        MarketDataRoute(
            mode: dataMode, provider: provider,
            stockDBHost: stockDBHost, stockDBPort: stockDBPort
        )
    }

    func applyMarketDataRoute() {
        stockDBHost = stockDBHost.trimmingCharacters(in: .whitespacesAndNewlines)
        stockDBPort = min(65_535, max(1, stockDBPort))
        quotes.removeAll()
        persistImmediately()
        restartRefreshLoop()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var quoteItemsByID = items.reduce(into: [String: WatchItem]()) { result, item in
                result[item.id] = item
            }
            for indexItem in Self.marketIndexItems {
                if quoteItemsByID[indexItem.id] == nil {
                    quoteItemsByID[indexItem.id] = indexItem
                }
            }
            let quoteItems = Array(quoteItemsByID.values)
            let fetched = try await service.fetchQuotes(for: quoteItems, route: marketDataRoute)
            quotes.merge(Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })) { _, new in new }
            await evaluateAlerts(at: Date())
            if lastGroupOrderingAt == nil || Date().timeIntervalSince(lastGroupOrderingAt!) >= 60 {
                rebuildGroupSections()
                lastGroupOrderingAt = Date()
            }
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleAutoRefresh() { isAutoRefreshEnabled.toggle() }

    func search(_ input: String) async -> [SearchSuggestion] {
        let keywords = SearchInputParser.keywords(from: input)
        guard !keywords.isEmpty else { return [] }

        var seenIDs = Set<String>()
        var results: [SearchSuggestion] = []
        var lastError: Error?

        for keyword in keywords {
            do {
                let matches = try await service.search(keyword, route: marketDataRoute)
                for suggestion in matches where seenIDs.insert(suggestion.id).inserted {
                    results.append(suggestion)
                }
            } catch {
                lastError = error
            }
        }

        errorMessage = results.isEmpty ? lastError?.localizedDescription : nil
        return results
    }

    func add(_ suggestion: SearchSuggestion) {
        _ = add([suggestion])
    }

    @discardableResult
    func add(_ suggestions: [SearchSuggestion], toGroup groupID: UUID? = nil) -> Set<String> {
        var knownIDs = Set(items.map(\.id))
        let newItems = suggestions.compactMap { suggestion -> WatchItem? in
            guard suggestion.market == .cn else { return nil }
            guard knownIDs.insert(suggestion.id).inserted else { return nil }
            return WatchItem(code: suggestion.code, name: suggestion.name, market: suggestion.market)
        }
        guard !newItems.isEmpty else { return [] }

        items.append(contentsOf: newItems)
        let validGroupID = groupID.flatMap { requestedID in
            groups.contains(where: { $0.id == requestedID }) ? requestedID : nil
        }
        if let validGroupID {
            for item in newItems {
                groupMemberships[item.id, default: []].insert(validGroupID)
            }
            resetGroupAlertReferences(for: membershipAlertScope(for: validGroupID))
            rebuildGroupSections()
            selectGroup(validGroupID)
        } else {
            let markets = Set(newItems.map(\.market))
            if markets.count == 1, let market = markets.first { selectMarket(market) }
            else { selectAll() }
        }
        selectedID = newItems.last?.id
        persist()
        Task { await refresh() }
        return Set(newItems.map(\.id))
    }

    func remove(_ id: String) {
        remove(Set([id]))
    }

    func remove(_ ids: Set<String>) {
        let existingIDs = ids.intersection(items.map(\.id))
        guard !existingIDs.isEmpty else { return }
        let affectedGroupIDs = existingIDs.reduce(into: Set<UUID>()) { result, itemID in
            for groupID in groupIDs(for: itemID) {
                result.formUnion(membershipAlertScope(for: groupID))
            }
        }

        items.removeAll { existingIDs.contains($0.id) }
        for id in existingIDs {
            quotes[id] = nil
            groupMemberships[id] = nil
        }
        stockPriceAlerts.removeAll { existingIDs.contains($0.itemID) }
        resetGroupAlertReferences(for: affectedGroupIDs)
        rebuildGroupSections()
        if let selectedID, existingIDs.contains(selectedID) { self.selectedID = nil }
        persist()
    }

    @discardableResult
    func createGroup(named rawName: String, parentID: UUID? = nil) -> StockGroup? {
        let name = normalizedGroupName(rawName)
        guard !name.isEmpty, !groups.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        // 父级必须存在且自身是一级分组，保证层级不超过两级
        let validParentID = parentID.flatMap { requestedID in
            groups.first { $0.id == requestedID && $0.parentID == nil }?.id
        }
        let group = StockGroup(name: name, parentID: validParentID)
        groups.append(group)
        rebuildGroupSections()
        selectGroup(group.id)
        persist()
        return group
    }

    func renameGroup(_ id: UUID, to rawName: String) -> Bool {
        let name = normalizedGroupName(rawName)
        guard !name.isEmpty,
              !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
              let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].name = name
        rebuildGroupSections()
        persist()
        return true
    }

    func toggleGroupPinned(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isPinned.toggle()
        rebuildGroupSections()
        persist()
    }

    /// 删除分组；删除一级分组会连带删除其全部二级分组。股票保留在自选中。
    func deleteGroup(_ id: UUID) {
        let removedIDs = groupTreeIDs(id)
        guard !removedIDs.isEmpty else { return }
        groups.removeAll { removedIDs.contains($0.id) }
        groupAverageAlerts.removeAll { removedIDs.contains($0.groupID) }
        for itemID in Array(groupMemberships.keys) {
            groupMemberships[itemID]?.subtract(removedIDs)
            if groupMemberships[itemID]?.isEmpty == true { groupMemberships[itemID] = nil }
        }
        if let selectedGroupID, removedIDs.contains(selectedGroupID) { selectAll() }
        rebuildGroupSections()
        persist()
    }

    /// 移动分组：parentID 指向目标一级分组（挂为其二级），nil 表示提升为一级。
    /// 被移动的一级分组若自带二级，其二级自动升为一级；股票、均价提醒按分组 ID 自动跟随。
    func moveGroup(_ id: UUID, underParent parentID: UUID?) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let oldParentID = groups[index].parentID

        if let parentID {
            guard parentID != id,
                  let parent = groups.first(where: { $0.id == parentID }),
                  parent.parentID == nil,
                  parentID != oldParentID else { return }
            if oldParentID == nil {
                for childIndex in groups.indices where groups[childIndex].parentID == id {
                    groups[childIndex].parentID = nil
                }
            }
            groups[index].parentID = parentID
        } else {
            guard oldParentID != nil else { return }
            groups[index].parentID = nil
        }

        var affected = Set<UUID>([id])
        if let oldParentID { affected.insert(oldParentID) }
        if let parentID { affected.insert(parentID) }
        resetGroupAlertReferences(for: affected)
        rebuildGroupSections()
        persist()
    }

    func groupIDs(for itemID: String) -> Set<UUID> {
        groupMemberships[itemID] ?? []
    }

    func belongsToGroup(itemID: String, groupID: UUID) -> Bool {
        groupIDs(for: itemID).contains(groupID)
    }

    /// 是否属于分组生效范围（一级 = 自身 + 全部二级）。
    func belongsToGroupTree(itemID: String, groupID: UUID) -> Bool {
        !groupIDs(for: itemID).intersection(groupTreeIDs(groupID)).isEmpty
    }

    func childGroups(of parentID: UUID) -> [StockGroup] {
        groups.filter { $0.parentID == parentID }
    }

    func parentGroup(of groupID: UUID) -> StockGroup? {
        guard let parentID = groups.first(where: { $0.id == groupID })?.parentID else { return nil }
        return groups.first { $0.id == parentID }
    }

    func groupTreeIDs(_ groupID: UUID) -> Set<UUID> {
        GroupOrdering.treeIDs(of: groupID, in: groups)
    }

    func toggleMembership(itemID: String, groupID: UUID) {
        guard items.contains(where: { $0.id == itemID }), groups.contains(where: { $0.id == groupID }) else { return }
        var memberships = groupIDs(for: itemID)
        let wasMember = memberships.contains(groupID)
        if wasMember { memberships.remove(groupID) }
        else { memberships.insert(groupID) }
        groupMemberships[itemID] = memberships.isEmpty ? nil : memberships
        resetGroupAlertReferences(for: membershipAlertScope(for: groupID))
        if selectedID == itemID {
            let stillInSelectedGroup = selectedGroupID.map { !memberships.intersection(groupTreeIDs($0)).isEmpty } ?? true
            if !stillInSelectedGroup || (showingUngroupedOnly && !memberships.isEmpty) {
                selectedID = nil
            }
        }
        rebuildGroupSections()
        persist()
    }

    func itemCount(in groupID: UUID) -> Int {
        GroupOrdering.memberCount(of: groupID, items: items, groups: groups, memberships: groupMemberships)
    }

    /// 一级分组下该股票直接所属的二级分组名，按侧边栏显示顺序返回。
    func subgroupNames(for itemID: String, underPrimary primaryID: UUID) -> [String] {
        let memberships = groupIDs(for: itemID)
        guard let section = groupSections.first(where: { $0.group.id == primaryID }) else { return [] }
        return section.children
            .filter { memberships.contains($0.id) }
            .map(\.name)
    }

    /// 小窗分组行情行：一级分组返回名下全部股票（含各二级）。
    func rowsForGroup(_ groupID: UUID) -> [QuoteRow] {
        let scope = groupTreeIDs(groupID)
        guard !scope.isEmpty else { return [] }
        return allRows.filter { row in
            !groupIDs(for: row.id).intersection(scope).isEmpty
        }
    }

    var ungroupedItemCount: Int {
        items.filter { groupIDs(for: $0.id).isEmpty }.count
    }

    func priceAlert(for itemID: String) -> StockPriceAlert? {
        stockPriceAlerts.first { $0.itemID == itemID && $0.isValid(at: Date()) }
    }

    @discardableResult
    func setPriceAlert(itemID: String, targetPrice: Double, now: Date = Date()) -> Bool {
        guard let currentPrice = quotes[itemID]?.current,
              let direction = AlertRules.priceDirection(currentPrice: currentPrice, targetPrice: targetPrice),
              items.contains(where: { $0.id == itemID }) else { return false }

        let alert = StockPriceAlert(
            itemID: itemID,
            targetPrice: targetPrice,
            direction: direction,
            createdAt: now,
            expiresAt: AlertRules.endOfDay(containing: now)
        )
        stockPriceAlerts.removeAll { $0.itemID == itemID }
        stockPriceAlerts.append(alert)
        persist()
        Task { await notificationService.requestAuthorization() }
        return true
    }

    func clearPriceAlert(itemID: String) {
        stockPriceAlerts.removeAll { $0.itemID == itemID }
        persist()
    }

    func hasGroupAverageAlert(_ groupID: UUID) -> Bool {
        groupAverageAlerts.contains { $0.groupID == groupID }
    }

    func toggleGroupAverageAlert(_ groupID: UUID, now: Date = Date()) {
        if hasGroupAverageAlert(groupID) {
            groupAverageAlerts.removeAll { $0.groupID == groupID }
        } else if groups.contains(where: { $0.id == groupID }) {
            groupAverageAlerts.append(GroupAverageAlert(
                groupID: groupID,
                referencePercentage: groupAveragePercentage(for: groupID),
                updatedAt: now
            ))
            Task { await notificationService.requestAuthorization() }
        }
        persist()
    }

    func selectAll() {
        selectedMarket = nil
        showingPositionsOnly = false
        showingUngroupedOnly = false
        showingTelegraph = false
        selectedGroupID = nil
        selectedID = nil
    }

    func selectTelegraph() {
        selectAll()
        showingTelegraph = true
    }

    func selectMarket(_ market: Market) {
        selectAll()
        selectedMarket = market
    }

    func selectPositions() {
        selectAll()
        showingPositionsOnly = true
    }

    func selectUngrouped() {
        selectAll()
        showingUngroupedOnly = true
    }

    func selectGroup(_ id: UUID) {
        selectAll()
        selectedGroupID = id
    }

    var selectedCollectionTitle: String {
        if showingTelegraph { return "电报" }
        if showingPositionsOnly { return "我的持仓" }
        if showingUngroupedOnly { return "未分组" }
        if let selectedGroupID, let group = groups.first(where: { $0.id == selectedGroupID }) {
            if let parent = parentGroup(of: selectedGroupID) {
                return "\(parent.name) · \(group.name)"
            }
            return group.name
        }
        return selectedMarket?.title ?? "市场总览"
    }

    func updatePosition(id: String, costPrice: Double, quantity: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].costPrice = max(0, costPrice)
        items[index].quantity = max(0, quantity)
        persist()
    }

    @discardableResult
    func clearPosition(id: String, at closedAt: Date = Date()) -> PositionHistoryRecord? {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].quantity > 0 else { return nil }

        let record = positionHistoryRecord(for: items[index], closedAt: closedAt)
        positionHistory.insert(record, at: 0)
        items[index].costPrice = 0
        items[index].quantity = 0
        if showingPositionsOnly, selectedID == id {
            selectedID = nil
        }
        persist()
        return record
    }

    func persist() {
        persistDebounce?.cancel()
        let snapshot = PersistedState(
            items: items,
            provider: provider,
            refreshInterval: refreshInterval,
            colorPreference: colorPreference,
            dataMode: dataMode,
            stockDBHost: stockDBHost,
            stockDBPort: stockDBPort,
            statusBarDisplayMode: statusBarDisplayMode,
            groups: groups,
            groupMemberships: groupMemberships,
            positionHistory: positionHistory,
            stockPriceAlerts: stockPriceAlerts,
            groupAverageAlerts: groupAverageAlerts
        )
        persistDebounce = Task { [stateStore] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: "StockerMac.PersistedState.v1")
                }
                _ = stateStore
            }.value
        }
    }

    /// 同步落盘，仅用于测试的确定性断言。
    func flushPersistForTesting() {
        persistImmediately()
    }

    private func persistImmediately() {
        persistDebounce?.cancel()
        persistDebounce = nil
        let snapshot = PersistedState(
            items: items,
            provider: provider,
            refreshInterval: refreshInterval,
            colorPreference: colorPreference,
            dataMode: dataMode,
            stockDBHost: stockDBHost,
            stockDBPort: stockDBPort,
            statusBarDisplayMode: statusBarDisplayMode,
            groups: groups,
            groupMemberships: groupMemberships,
            positionHistory: positionHistory,
            stockPriceAlerts: stockPriceAlerts,
            groupAverageAlerts: groupAverageAlerts
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "StockerMac.PersistedState.v1")
        }
    }

    /// 分组平均涨跌幅（等权）：一级 = 名下全部股票，二级 = 直接成员；无行情返回 nil。
    func groupAveragePercentage(for groupID: UUID) -> Double? {
        GroupOrdering.averagePercentage(
            of: groupID,
            items: items,
            groups: groups,
            memberships: groupMemberships,
            quotes: quotes
        )
    }

    /// 归属变化会影响的分组：自身 + 父级（二级变化会改变一级平均）。
    private func membershipAlertScope(for groupID: UUID) -> Set<UUID> {
        var ids = Set<UUID>([groupID])
        if let parentID = groups.first(where: { $0.id == groupID })?.parentID {
            ids.insert(parentID)
        }
        return ids
    }

    /// 按强度重建侧边栏分组块；排序只影响展示，不改动持久化的存储顺序。
    private func rebuildGroupSections() {
        let sections = GroupOrdering.buildSections(
            items: items,
            groups: groups,
            memberships: groupMemberships,
            quotes: quotes
        )
        withAnimation(.smooth(duration: 0.3)) {
            groupSections = sections
        }
    }

    private func resetGroupAlertReferences(for groupIDs: Set<UUID>) {
        for index in groupAverageAlerts.indices where groupIDs.contains(groupAverageAlerts[index].groupID) {
            groupAverageAlerts[index].referencePercentage = groupAveragePercentage(for: groupAverageAlerts[index].groupID)
            groupAverageAlerts[index].updatedAt = Date()
        }
    }

    private func evaluateAlerts(at now: Date) async {
        var stateChanged = false
        var firedPriceAlertIDs = Set<String>()

        for alert in stockPriceAlerts {
            guard alert.isValid(at: now) else {
                firedPriceAlertIDs.insert(alert.itemID)
                stateChanged = true
                continue
            }
            guard let quote = quotes[alert.itemID], alert.isTriggered(by: quote.current) else { continue }
            let name = items.first(where: { $0.id == alert.itemID })
                .map { QuoteRow(item: $0, quote: quote).displayName } ?? quote.name
            try? await notificationService.send(
                identifier: "stock-price-\(alert.itemID)-\(alert.createdAt.timeIntervalSince1970)",
                title: "\(name)已\(alert.direction.title) \(Formatters.price(alert.targetPrice))",
                body: "当前价格 \(Formatters.price(quote.current))，本次当日价格提醒已完成。"
            )
            firedPriceAlertIDs.insert(alert.itemID)
            stateChanged = true
        }
        stockPriceAlerts.removeAll { firedPriceAlertIDs.contains($0.itemID) }

        for index in groupAverageAlerts.indices {
            guard let average = groupAveragePercentage(for: groupAverageAlerts[index].groupID) else { continue }
            guard let movement = groupAverageAlerts[index].movement(from: average) else {
                if groupAverageAlerts[index].referencePercentage == nil {
                    groupAverageAlerts[index].referencePercentage = average
                    groupAverageAlerts[index].updatedAt = now
                    stateChanged = true
                }
                continue
            }
            guard let group = groups.first(where: { $0.id == groupAverageAlerts[index].groupID }) else { continue }
            let direction = movement > 0 ? "上升" : "下降"
            try? await notificationService.send(
                identifier: "group-average-\(group.id.uuidString)-\(now.timeIntervalSince1970)",
                title: "\(group.name)平均涨跌幅已\(direction) 1 个百分点",
                body: "当前平均涨跌幅 \(Formatters.percent(average))，较上次提醒基准\(direction) \(Formatters.percent(abs(movement)))。"
            )
            groupAverageAlerts[index].referencePercentage = average
            groupAverageAlerts[index].updatedAt = now
            stateChanged = true
        }

        if stateChanged { persist() }
    }

    private func normalizedGroupName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
    }

    private func positionHistoryRecord(for item: WatchItem, closedAt: Date) -> PositionHistoryRecord {
        let quote = quotes[item.id]
        return PositionHistoryRecord(
            code: item.code,
            name: QuoteRow(item: item, quote: quote).displayName,
            market: item.market,
            costPrice: item.costPrice,
            quantity: item.quantity,
            closedPrice: quote.map(\.current),
            closedAt: closedAt
        )
    }
}

// MARK: - 电报模块自选股快照

extension AppStore: WatchlistProviding {
    var watchlistCodes: [SecurityID] {
        items.compactMap { item in
            guard item.market == .cn else { return nil }
            return SecurityID(market: .cn, code: item.code.uppercased())
        }
    }
}
