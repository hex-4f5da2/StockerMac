import Foundation

@main
enum LiveAPIChecks {
    static func main() async throws {
        let items = [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
            WatchItem(code: "SZ399001", name: "深证成指", market: .cn),
            WatchItem(code: "SH000688", name: "科创50", market: .cn),
            WatchItem(code: "SZ399006", name: "创业板指", market: .cn),
            WatchItem(code: "BJ899050", name: "北证50", market: .cn)
        ]
        let expectedIndexCodes = Set(items.prefix(5).map(\.code))
        let service = QuoteService()

        let routes = [
            MarketDataRoute.localDefault,
            MarketDataRoute(mode: .network, provider: .sina, stockDBHost: "127.0.0.1", stockDBPort: 7899),
            MarketDataRoute(mode: .network, provider: .tencent, stockDBHost: "127.0.0.1", stockDBPort: 7899),
        ]
        for route in routes {
            let quotes = try await service.fetchQuotes(for: items, route: route)
            precondition(quotes.count == items.count, "\(route.mode.title) only returned \(quotes.count) quotes")
            precondition(Set(quotes.map(\.market)) == Set(Market.supportedCases))
            let indexQuotes = quotes.filter { expectedIndexCodes.contains($0.code) }
            precondition(Set(indexQuotes.map(\.code)) == expectedIndexCodes)
            precondition(indexQuotes.allSatisfy { $0.current > 0 })
            let search = try await service.search("600519", route: route)
            precondition(search.contains { $0.code == "SH600519" }, "\(route.mode.title) 搜索路由失败")
            print("\(route.mode.title)/\(route.provider.title): "
                  + quotes.map { "\($0.code)=\($0.current)" }.joined(separator: ", "))
        }
    }
}
