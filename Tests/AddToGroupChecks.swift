import Foundation

@main
@MainActor
enum AddToGroupChecks {
    static func main() {
        let defaults = UserDefaults.standard
        let key = "StockerMac.PersistedState.v1"
        let originalData = defaults.data(forKey: key)
        defer {
            if let originalData { defaults.set(originalData, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let focus = StockGroup(name: "重点观察")
        let initial = PersistedState(
            items: [],
            provider: .tencent,
            refreshInterval: 10,
            colorPreference: .redUp,
            groups: [focus]
        )
        defaults.set(try! JSONEncoder().encode(initial), forKey: key)

        let store = AppStore()
        let suggestions = [
            SearchSuggestion(code: "SH600000", name: "浦发银行", market: .cn),
            SearchSuggestion(code: "AAPL", name: "Apple", market: .us)
        ]
        let addedIDs = store.add(suggestions, toGroup: focus.id)

        precondition(addedIDs == Set(suggestions.map(\.id)))
        precondition(store.selectedGroupID == focus.id)
        precondition(store.selectedMarket == nil)
        precondition(store.rows.map(\.id) == suggestions.map(\.id))
        precondition(suggestions.allSatisfy { store.belongsToGroup(itemID: $0.id, groupID: focus.id) })

        let saved = try! JSONDecoder().decode(PersistedState.self, from: defaults.data(forKey: key)!)
        precondition(suggestions.allSatisfy { saved.groupMemberships[$0.id] == [focus.id] })

        print("Add-to-group checks passed: membership, current group selection and persistence")
    }
}
