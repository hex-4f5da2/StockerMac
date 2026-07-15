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
        let second = WatchItem(code: "AAPL", name: "Apple", market: .us)
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

        let saved = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(saved.items.map(\.id) == [second.id])
        precondition(saved.groupMemberships[first.id] == nil)
        precondition(saved.groupMemberships[second.id] == [group.id])

        print("Batch delete checks passed: items, selection, memberships and persistence")
    }
}
