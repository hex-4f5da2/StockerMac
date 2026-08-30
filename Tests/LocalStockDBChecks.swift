import Foundation

@main
enum LocalStockDBChecks {
    static func main() async throws {
        let client = LocalStockDBClient()
        let items = [
            WatchItem(code: "SH600519", name: "贵州茅台", market: .cn),
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
        ]

        let quotes = try await client.fetchQuotes(for: items)
        precondition(quotes.count == 2, "本地行情应同时返回个股与指数")
        precondition(quotes.allSatisfy { $0.current > 0 && !$0.updatedAt.isEmpty })

        let codeMatches = try await client.search("600519")
        precondition(codeMatches.first?.code == "SH600519", "代码搜索失败")
        let pinyinMatches = try await client.search("gzmt")
        precondition(pinyinMatches.contains { $0.code == "SH600519" }, "拼音首字母搜索失败")

        let minutes = try await client.fetchCandles(for: items[0], period: .timeShare)
        precondition(minutes.count == 242, "完整分时应为 242 点，实际为 \(minutes.count)")
        precondition(minutes.reduce(0) { $0 + $1.volume } > 0, "分时成交量不能为空")

        let days = try await client.fetchCandles(for: items[0], period: .day)
        precondition(!days.isEmpty, "本地日 K 不能为空")
        let indexDays = try await client.fetchCandles(for: items[1], period: .day)
        precondition(indexDays.count == 120, "五大指数历史日 K 未接入")
        let overview = try await client.fetchOverview(for: items[0])
        precondition(overview.amount != nil && overview.volume != nil, "概览成交量额不能为空")

        print("Local StockDB checks passed: quotes=\(quotes.count), search=\(pinyinMatches.count), minutes=\(minutes.count), days=\(days.count), indexDays=\(indexDays.count)")
    }
}
