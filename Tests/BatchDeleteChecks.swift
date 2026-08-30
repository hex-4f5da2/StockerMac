import Foundation

@main
@MainActor
enum BatchDeleteChecks {
    static func main() {
        let defaults = UserDefaults.standard
        let key = "StockerMac.PersistedState.v1"
        let originalData = defaults.data(forKey: key)
        defer {
            if let originalData { defaults.set(originalData, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let group = StockGroup(name: "测试分组")
        let first = WatchItem(code: "SH600000", name: "浦发银行", market: .cn, costPrice: 8, quantity: 100)
        let second = WatchItem(code: "SH600519", name: "贵州茅台", market: .cn)
        let initial = PersistedState(
            items: [first, second],
            provider: .tencent,
            refreshInterval: 10,
            colorPreference: .redUp,
            groups: [group],
            groupMemberships: [first.id: [group.id], second.id: [group.id]]
        )
        defaults.set(try! JSONEncoder().encode(initial), forKey: key)

        let store = AppStore()
        store.selectedID = first.id
        store.remove(Set([first.id, "missing:item"]))

        precondition(store.items.map(\.id) == [second.id])
        precondition(store.selectedID == nil)
        precondition(store.groupIDs(for: first.id).isEmpty)
        precondition(store.groupIDs(for: second.id) == [group.id])

        store.flushPersistForTesting()
        let saved = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(saved.items.map(\.id) == [second.id])
        precondition(saved.groupMemberships[first.id] == nil)
        precondition(saved.groupMemberships[second.id] == [group.id])

        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.updatePosition(id: second.id, costPrice: 180, quantity: 5)
        let record = store.clearPosition(id: second.id, at: closedAt)
        precondition(record?.code == second.code)
        precondition(record?.costPrice == 180)
        precondition(record?.quantity == 5)
        precondition(record?.closedPrice == nil)
        precondition(record?.closedAt == closedAt)
        precondition(store.items == [second])
        precondition(store.items[0].costPrice == 0)
        precondition(store.items[0].quantity == 0)
        precondition(store.groupIDs(for: second.id) == [group.id])

        store.flushPersistForTesting()
        let clearedState = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(clearedState.items.map(\.id) == [second.id])
        precondition(clearedState.positionHistory == [record].compactMap { $0 })
        precondition(clearedState.groupMemberships[second.id] == [group.id])

        print("Batch delete/clear checks passed: items, selection, memberships, single-position clearing, history and persistence")
    }
}
