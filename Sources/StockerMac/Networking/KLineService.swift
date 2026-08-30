import CoreFoundation
import Foundation

actor KLineService {
    private let session: URLSession
    private var localClients: [String: LocalStockDBClient] = [:]
    private var resolvedUSCodes: [String: String] = [:]
    private let routeOverride: MarketDataRoute?

    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    init(
        session: URLSession = KLineService.makeDefaultSession(),
        route: MarketDataRoute? = nil
    ) {
        self.session = session
        routeOverride = route
    }

    func fetchCandles(for item: WatchItem, period: KLinePeriod) async throws -> [KLineCandle] {
        guard period.isAvailable(for: item.market) else {
            throw KLineServiceError.unsupportedMarket
        }

        let route = currentRoute()
        if route.mode == .localStockDB {
            return try await localClient(for: route).fetchCandles(for: item, period: period)
        }

        let apiCode = try await apiCode(for: item)
        let urlString: String
        switch period {
        case .timeShare:
            urlString = "https://ifzq.gtimg.cn/appstock/app/minute/query?code=\(apiCode)"
        case .fiveDay:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m5,,240"
        case .oneMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m1,,240"
        case .fiveMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m5,,96"
        case .fifteenMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m15,,64"
        case .thirtyMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m30,,32"
        case .sixtyMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m60,,16"
        case .oneTwentyMinute:
            urlString = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(apiCode),m120,,8"
        case .day:
            urlString = "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(apiCode),day,,,120,qfq"
        case .week:
            urlString = "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(apiCode),week,,,120,qfq"
        case .month:
            urlString = "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(apiCode),month,,,120,qfq"
        case .year:
            urlString = "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(apiCode),month,,,240,qfq"
        }

        guard let url = URL(string: urlString) else { throw KLineServiceError.invalidURL }
        let data = try await request(url)
        if period == .timeShare {
            return try KLineParser.parseTencentTimeShare(data, apiCode: apiCode)
        }
        let candles = try KLineParser.parseTencent(data, apiCode: apiCode, period: period)
        return period.limitsToLatestTradingDay ? latestTradingDay(from: candles) : candles
    }

    func fetchOverview(for item: WatchItem) async throws -> MarketOverview {
        let route = currentRoute()
        if route.mode == .localStockDB {
            return try await localClient(for: route).fetchOverview(for: item)
        }
        let code: String
        switch item.market {
        case .cn: code = item.code.lowercased()
        case .hk: code = "hk\(item.code)"
        case .us: code = "us\(item.code.uppercased())"
        }
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(code)") else {
            throw KLineServiceError.invalidURL
        }
        let data = try await request(url)
        guard let response = decodeChinese(data),
              let firstQuote = response.firstIndex(of: "\""),
              let lastQuote = response.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            throw KLineServiceError.decodingFailed
        }
        let fields = response[response.index(after: firstQuote)..<lastQuote]
            .split(separator: "~", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count > 45 else { throw KLineServiceError.decodingFailed }

        let amount: Double?
        let turnoverRate: Double?
        let priceEarningsRatio: Double?
        let totalMarketValue: Double?
        if item.market == .cn {
            amount = number(fields[37]).map { $0 * 10_000 }
            turnoverRate = positiveNumber(fields[38])
            priceEarningsRatio = positiveNumber(fields[39])
            totalMarketValue = number(fields[45]).map { $0 * 100_000_000 }
        } else {
            amount = nil
            turnoverRate = nil
            priceEarningsRatio = nil
            totalMarketValue = nil
        }

        return MarketOverview(
            opening: number(fields[5]) ?? 0,
            previousClose: number(fields[4]) ?? 0,
            high: number(fields[33]) ?? 0,
            low: number(fields[34]) ?? 0,
            volume: positiveNumber(fields[36]),
            amount: amount,
            turnoverRate: turnoverRate,
            priceEarningsRatio: priceEarningsRatio,
            totalMarketValue: totalMarketValue,
            updatedAt: fields[30]
        )
    }

    private func apiCode(for item: WatchItem) async throws -> String {
        switch item.market {
        case .cn:
            return item.code.lowercased()
        case .hk:
            return "hk\(item.code)"
        case .us:
            if let cached = resolvedUSCodes[item.id] { return cached }
            let resolved = try await resolveUSCode(item.code)
            resolvedUSCodes[item.id] = resolved
            return resolved
        }
    }

    private func currentRoute() -> MarketDataRoute {
        if let routeOverride { return routeOverride }
        let state = StateStore().load()
        return MarketDataRoute(
            mode: state.dataMode, provider: state.provider,
            stockDBHost: state.stockDBHost, stockDBPort: state.stockDBPort
        )
    }

    private func localClient(for route: MarketDataRoute) throws -> LocalStockDBClient {
        guard let url = route.localURL else { throw KLineServiceError.invalidURL }
        let key = url.absoluteString
        if let client = localClients[key] { return client }
        let client = LocalStockDBClient(baseURL: url)
        localClients[key] = client
        return client
    }

    private func resolveUSCode(_ code: String) async throws -> String {
        let quoteCode = "us\(code.uppercased())"
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(quoteCode)") else {
            throw KLineServiceError.invalidURL
        }
        let data = try await request(url)
        guard let response = decodeChinese(data),
              let firstQuote = response.firstIndex(of: "\""),
              let lastQuote = response.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            throw KLineServiceError.decodingFailed
        }

        let payload = response[response.index(after: firstQuote)..<lastQuote]
        let fields = payload.split(separator: "~", omittingEmptySubsequences: false)
        guard fields.count > 2 else { throw KLineServiceError.decodingFailed }
        let canonical = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "us\(canonical.isEmpty ? code.uppercased() : canonical)"
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw KLineServiceError.badResponse
        }
        return data
    }

    private func latestTradingDay(from candles: [KLineCandle]) -> [KLineCandle] {
        guard let latest = candles.last else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return candles.filter { calendar.isDate($0.timestamp, inSameDayAs: latest.timestamp) }
    }

    private func decodeChinese(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: cfEncoding))
    }

    private func number(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func positiveNumber(_ value: String) -> Double? {
        guard let value = number(value), value > 0 else { return nil }
        return value
    }
}

enum KLineServiceError: LocalizedError {
    case invalidURL
    case badResponse
    case decodingFailed
    case unsupportedMarket

    var errorDescription: String? {
        switch self {
        case .invalidURL: "K 线地址无效"
        case .badResponse: "K 线服务暂时不可用"
        case .decodingFailed: "K 线数据解析失败"
        case .unsupportedMarket: "当前市场暂不支持该周期"
        }
    }
}
