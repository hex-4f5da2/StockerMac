import Foundation

@main
enum LiveAPIChecks {
    static func main() async throws {
        let items = [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
            WatchItem(code: "SH600000", market: .cn),
            WatchItem(code: "00700", market: .hk),
            WatchItem(code: "AAPL", market: .us)
        ]
        let service = QuoteService()

        for provider in QuoteProvider.allCases {
            let quotes = try await service.fetchQuotes(for: items, provider: provider)
            precondition(quotes.count == items.count, "\(provider.title) only returned \(quotes.count) quotes")
            precondition(Set(quotes.map(\.market)) == Set(Market.allCases))
            precondition(quotes.contains { $0.code == "SH000001" && $0.current > 0 })
            print("\(provider.title): " + quotes.map { "\($0.code)=\($0.current)" }.joined(separator: ", "))
        }
    }
}
