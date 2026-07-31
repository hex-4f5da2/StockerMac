import Foundation

@main
enum LiveAPIChecks {
    static func main() async throws {
        let items = [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
            WatchItem(code: "SZ399001", name: "深证成指", market: .cn),
            WatchItem(code: "SH000688", name: "科创50", market: .cn),
            WatchItem(code: "SZ399006", name: "创业板指", market: .cn),
            WatchItem(code: "BJ899050", name: "北证50", market: .cn),
            WatchItem(code: "00700", market: .hk),
            WatchItem(code: "AAPL", market: .us)
        ]
        let expectedIndexCodes = Set(items.prefix(5).map(\.code))
        let service = QuoteService()

        for provider in QuoteProvider.allCases {
            let quotes = try await service.fetchQuotes(for: items, provider: provider)
            precondition(quotes.count == items.count, "\(provider.title) only returned \(quotes.count) quotes")
            precondition(Set(quotes.map(\.market)) == Set(Market.allCases))
            let indexQuotes = quotes.filter { expectedIndexCodes.contains($0.code) }
            precondition(Set(indexQuotes.map(\.code)) == expectedIndexCodes)
            precondition(indexQuotes.allSatisfy { $0.current > 0 })
            print("\(provider.title): " + quotes.map { "\($0.code)=\($0.current)" }.joined(separator: ", "))
        }
    }
}
