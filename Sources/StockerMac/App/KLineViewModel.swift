import Combine
import Foundation

@MainActor
final class KLineViewModel: ObservableObject {
    @Published var period: KLinePeriod
    @Published private(set) var candles: [KLineCandle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var overview: MarketOverview?

    let item: WatchItem
    private let service: KLineService

    init(item: WatchItem, service: KLineService = KLineService()) {
        self.item = item
        self.service = service
        period = item.market == .cn ? .timeShare : .day
    }

    var availablePeriods: [KLinePeriod] {
        KLinePeriod.allCases.filter { $0.isAvailable(for: item.market) }
    }

    func load() async {
        let requestedPeriod = period
        if candles.isEmpty { isLoading = true }
        else { isRefreshing = true }
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let fetched = try await service.fetchCandles(for: item, period: requestedPeriod)
            let fetchedOverview = try? await service.fetchOverview(for: item)
            guard requestedPeriod == period else { return }
            candles = fetched
            if let fetchedOverview { overview = fetchedOverview }
            lastUpdated = Date()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedPeriod == period else { return }
            errorMessage = error.localizedDescription
        }
    }

    func select(_ period: KLinePeriod) {
        guard period.isAvailable(for: item.market), self.period != period else { return }
        self.period = period
        candles = []
        errorMessage = nil
    }
}
