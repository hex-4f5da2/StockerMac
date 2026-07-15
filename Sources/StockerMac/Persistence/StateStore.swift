import Foundation

struct StateStore: Sendable {
    private let key = "StockerMac.PersistedState.v1"

    func load() -> PersistedState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return .initial
        }
        return state
    }

    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
