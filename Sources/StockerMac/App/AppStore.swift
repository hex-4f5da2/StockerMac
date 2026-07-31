import Combine
import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
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
    @Published private(set) var positionHistory: [PositionHistoryRecord]
    @Published private(set) var stockPriceAlerts: [StockPriceAlert]
    @Published private(set) var groupAverageAlerts: [GroupAverageAlert]
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published var selectedMarket: Market?
    @Published var showingPositionsOnly = false
    @Published var showingUngroupedOnly = false
    @Published var selectedGroupID: UUID?
    @Published var selectedID: String?
    @Published var provider: QuoteProvider
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

    init() {
        let state = StateStore().load()
        items = state.items
        groups = state.groups
        let validGroupIDs = Set(state.groups.map(\.id))
        let validItemIDs = Set(state.items.map(\.id))
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
        provider = state.provider
        refreshInterval = state.refreshInterval
        colorPreference = state.colorPreference
        statusBarDisplayMode = state.statusBarDisplayMode
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
                return groupIDs(for: row.id).contains(selectedGroupID)
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
            let fetched = try await service.fetchQuotes(for: quoteItems, provider: provider)
            quotes.merge(Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })) { _, new in new }
            await evaluateAlerts(at: Date())
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

        let existingIDs = Set(items.map(\.id))
        var seenIDs = existingIDs
        var results: [SearchSuggestion] = []
        var lastError: Error?

        for keyword in keywords {
            do {
                let matches = try await service.search(keyword, provider: provider)
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
            resetGroupAlertReferences(for: [validGroupID])
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
            result.formUnion(groupIDs(for: itemID))
        }

        items.removeAll { existingIDs.contains($0.id) }
        for id in existingIDs {
            quotes[id] = nil
            groupMemberships[id] = nil
        }
        stockPriceAlerts.removeAll { existingIDs.contains($0.itemID) }
        resetGroupAlertReferences(for: affectedGroupIDs)
        if let selectedID, existingIDs.contains(selectedID) { self.selectedID = nil }
        persist()
    }

    @discardableResult
    func createGroup(named rawName: String) -> StockGroup? {
        let name = normalizedGroupName(rawName)
        guard !name.isEmpty, !groups.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        let group = StockGroup(name: name)
        groups.append(group)
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
        persist()
        return true
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        groupAverageAlerts.removeAll { $0.groupID == id }
        for itemID in Array(groupMemberships.keys) {
            groupMemberships[itemID]?.remove(id)
            if groupMemberships[itemID]?.isEmpty == true { groupMemberships[itemID] = nil }
        }
        if selectedGroupID == id { selectAll() }
        persist()
    }

    func moveGroups(from offsets: IndexSet, to destination: Int) {
        groups.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let sourceIndex = groups.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard groups.indices.contains(destinationIndex) else { return }
        groups.swapAt(sourceIndex, destinationIndex)
        persist()
    }

    func sortGroups(by order: StockGroupSortOrder) {
        groups = order.sorted(groups)
        persist()
    }

    func groupIDs(for itemID: String) -> Set<UUID> {
        groupMemberships[itemID] ?? []
    }

    func belongsToGroup(itemID: String, groupID: UUID) -> Bool {
        groupIDs(for: itemID).contains(groupID)
    }

    func toggleMembership(itemID: String, groupID: UUID) {
        guard items.contains(where: { $0.id == itemID }), groups.contains(where: { $0.id == groupID }) else { return }
        var memberships = groupMemberships[itemID] ?? []
        let wasMember = memberships.contains(groupID)
        if wasMember { memberships.remove(groupID) }
        else { memberships.insert(groupID) }
        groupMemberships[itemID] = memberships.isEmpty ? nil : memberships
        resetGroupAlertReferences(for: [groupID])
        if selectedID == itemID && ((selectedGroupID == groupID && wasMember) || (showingUngroupedOnly && !memberships.isEmpty)) {
            selectedID = nil
        }
        persist()
    }

    func itemCount(in groupID: UUID) -> Int {
        items.reduce(into: 0) { count, item in
            if groupIDs(for: item.id).contains(groupID) { count += 1 }
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
        selectedGroupID = nil
        selectedID = nil
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
        if showingPositionsOnly { return "我的持仓" }
        if showingUngroupedOnly { return "未分组" }
        if let selectedGroupID, let group = groups.first(where: { $0.id == selectedGroupID }) { return group.name }
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
        stateStore.save(PersistedState(
            items: items,
            provider: provider,
            refreshInterval: refreshInterval,
            colorPreference: colorPreference,
            statusBarDisplayMode: statusBarDisplayMode,
            groups: groups,
            groupMemberships: groupMemberships,
            positionHistory: positionHistory,
            stockPriceAlerts: stockPriceAlerts,
            groupAverageAlerts: groupAverageAlerts
        ))
    }

    private func groupAveragePercentage(for groupID: UUID) -> Double? {
        let percentages = items.compactMap { item -> Double? in
            guard groupIDs(for: item.id).contains(groupID) else { return nil }
            return quotes[item.id]?.percentage
        }
        guard !percentages.isEmpty else { return nil }
        return percentages.reduce(0, +) / Double(percentages.count)
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
            await notificationService.send(
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
            await notificationService.send(
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
