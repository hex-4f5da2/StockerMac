import Foundation

@main
enum KLineChecks {
    static func main() async throws {
        precondition(IntradayTradingAxis.position(hour: 9, minute: 30) == 0)
        precondition(IntradayTradingAxis.position(hour: 10, minute: 30) == 60)
        precondition(IntradayTradingAxis.position(hour: 11, minute: 30) == 120)
        precondition(IntradayTradingAxis.position(hour: 13, minute: 1) == 121)
        precondition(IntradayTradingAxis.position(hour: 14, minute: 0) == 180)
        precondition(IntradayTradingAxis.position(hour: 15, minute: 0) == 240)

        let service = KLineService()
        let marketItems = [WatchItem(code: "SH600000", name: "浦发银行", market: .cn)]

        for period in KLinePeriod.allCases {
            let label = "A 股 \(period.title)"
            do {
                let candles = try await service.fetchCandles(
                    for: marketItems[0],
                    period: period
                )
                try validate(candles, label: label)
                if period == .timeShare {
                    precondition(candles.allSatisfy { $0.averagePrice?.isFinite == true })
                    let positions = candles.map {
                        IntradayTradingAxis.position(for: $0.timestamp)
                    }
                    precondition(zip(positions, positions.dropFirst()).allSatisfy { pair in
                        pair.1 - pair.0 == 1 || (pair.0 == 120 && pair.1 == 120)
                    })
                }
            } catch {
                throw CheckError.fetch(label, error.localizedDescription)
            }
        }

        let overview = try await service.fetchOverview(for: marketItems[0])
        precondition(overview.opening > 0)
        precondition(overview.previousClose > 0)
        precondition(overview.high >= overview.low)
        precondition(overview.volume.map { $0 > 0 } == true)
        precondition(overview.amount.map { $0 > 0 } == true)
        precondition(overview.turnoverRate.map { $0 > 0 } == true)
        precondition(overview.totalMarketValue.map { $0 > 0 } == true)
        print(
            "A 股概览：今开 \(overview.opening)，昨收 \(overview.previousClose)，"
                + "成交额 \(overview.amount ?? 0)"
        )

        let networkRoute = MarketDataRoute(
            mode: .network, provider: .tencent,
            stockDBHost: "127.0.0.1", stockDBPort: 7899
        )
        let networkService = KLineService(route: networkRoute)
        let networkMinutes = try await networkService.fetchCandles(for: marketItems[0], period: .timeShare)
        let networkDays = try await networkService.fetchCandles(for: marketItems[0], period: .day)
        try validate(networkMinutes, label: "网络分时")
        try validate(networkDays, label: "网络日K")
    }

    private static func validate(_ candles: [KLineCandle], label: String) throws {
        guard !candles.isEmpty else { throw CheckError.empty(label) }
        guard candles == candles.sorted(by: { $0.timestamp < $1.timestamp }) else {
            throw CheckError.notSorted(label)
        }
        guard candles.allSatisfy({
            $0.opening > 0
                && $0.close > 0
                && $0.high >= max($0.opening, $0.close)
                && $0.low <= min($0.opening, $0.close)
                && $0.volume >= 0
        }) else {
            throw CheckError.invalidOHLC(label)
        }

        let latest = candles[candles.index(before: candles.endIndex)]
        print(
            "\(label)：\(candles.count) 根，最新收盘 \(latest.close)，"
                + "区间 \(latest.low)–\(latest.high)"
        )
    }
}

private enum CheckError: LocalizedError {
    case empty(String)
    case notSorted(String)
    case invalidOHLC(String)
    case fetch(String, String)

    var errorDescription: String? {
        switch self {
        case .empty(let label): "\(label) 没有返回数据"
        case .notSorted(let label): "\(label) 时间顺序错误"
        case .invalidOHLC(let label): "\(label) 开高低收关系错误"
        case .fetch(let label, let message): "\(label) 请求失败：\(message)"
        }
    }
}
