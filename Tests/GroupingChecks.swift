import Foundation

private struct LegacyState: Encodable {
    let items: [WatchItem]
    let provider: QuoteProvider
    let refreshInterval: Double
    let colorPreference: ColorSchemePreference
}

@main
enum GroupingChecks {
    static func main() throws {
        precondition(
            SearchInputParser.keywords(from: "600000, 00700,AAPL,600000") == ["600000", "00700", "AAPL"]
        )

        let item = WatchItem(code: "AAPL", name: "苹果", market: .us)
        let legacyData = try JSONEncoder().encode(LegacyState(
            items: [item], provider: .sina, refreshInterval: 10, colorPreference: .redUp
        ))
        let migrated = try JSONDecoder().decode(PersistedState.self, from: legacyData)
        precondition(migrated.items == [item])
        precondition(migrated.groups.isEmpty)
        precondition(migrated.groupMemberships.isEmpty)
        precondition(migrated.positionHistory.isEmpty)
        precondition(migrated.statusBarDisplayMode == .ticker)

        let focus = StockGroup(name: "重点观察")
        let longTerm = StockGroup(name: "长期持有")
        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let history = PositionHistoryRecord(
            code: "AAPL",
            name: "苹果",
            market: .us,
            costPrice: 180,
            quantity: 10,
            closedPrice: 195,
            closedAt: closedAt
        )
        let state = PersistedState(
            items: [item],
            provider: .tencent,
            refreshInterval: 20,
            colorPreference: .greenUp,
            statusBarDisplayMode: .icon,
            groups: [focus, longTerm],
            groupMemberships: [item.id: [focus.id, longTerm.id]],
            positionHistory: [history]
        )
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        precondition(restored.groups == [focus, longTerm])
        precondition(restored.groupMemberships[item.id] == [focus.id, longTerm.id])
        precondition(restored.positionHistory == [history])
        precondition(restored.positionHistory.first?.profit == 150)
        precondition(restored.statusBarDisplayMode == .icon)
        print("Grouping/search checks passed: comma parsing, migration, history, ordering and multi-group membership")
    }
}
