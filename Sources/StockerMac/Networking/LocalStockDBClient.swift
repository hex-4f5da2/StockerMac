import Foundation

/// StockerMac 的唯一行情入口。采集器负责外网，本类只访问本机 StockDB HTTP 服务。
actor LocalStockDBClient {
    static let shared = LocalStockDBClient()

    private let baseURL: URL
    private let session: URLSession
    private var directoryCache: [SecurityDirectoryEntry]?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:7899/")!,
        session: URLSession = LocalStockDBClient.makeSession()
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }

    func fetchQuotes(for items: [WatchItem]) async throws -> [Quote] {
        let cnItems = items.filter { $0.market == .cn }
        return try await withThrowingTaskGroup(of: Quote?.self) { group in
            for item in cnItems {
                group.addTask { try await self.fetchQuote(for: item) }
            }
            var quotes: [Quote] = []
            for try await quote in group {
                if let quote { quotes.append(quote) }
            }
            return quotes
        }
    }

    func fetchQuote(for item: WatchItem) async throws -> Quote? {
        guard item.market == .cn else { return nil }
        let symbol = Self.normalizedSymbol(item.code)
        let table = Self.indexSymbols.contains(symbol) ? "实时指数最新" : "实时行情最新"
        guard let row = try await dictionary(table + ":" + symbol) else { return nil }
        try Self.validateFreshness(row)
        let current = Self.double(row["current"])
        let previousClose = Self.double(row["previous_close"])
        guard current > 0 else { return nil }
        return Quote(
            code: symbol,
            name: Self.string(row["name"]).nonEmptyValue ?? item.name.nonEmptyValue ?? symbol,
            market: .cn,
            current: current,
            opening: Self.double(row["open"]),
            close: previousClose,
            low: Self.double(row["low"]),
            high: Self.double(row["high"]),
            change: Self.double(row["change"], fallback: current - previousClose),
            percentage: Self.double(row["change_pct"]),
            updatedAt: Self.string(row["quote_time"]).nonEmptyValue
                ?? Self.string(row["received_at"])
        )
    }

    func fetchOverview(for item: WatchItem) async throws -> MarketOverview {
        guard item.market == .cn else { throw LocalStockDBError.unsupportedMarket }
        let symbol = Self.normalizedSymbol(item.code)
        let table = Self.indexSymbols.contains(symbol) ? "实时指数最新" : "实时行情最新"
        guard let row = try await dictionary(table + ":" + symbol) else {
            throw LocalStockDBError.missingData
        }
        try Self.validateFreshness(row)
        return MarketOverview(
            opening: Self.double(row["open"]),
            previousClose: Self.double(row["previous_close"]),
            high: Self.double(row["high"]),
            low: Self.double(row["low"]),
            volume: Self.optionalPositive(row["volume"]),
            amount: Self.optionalPositive(row["amount"]),
            turnoverRate: Self.optionalPositive(row["turnover"]),
            priceEarningsRatio: Self.optionalPositive(row["pe_ttm"]),
            totalMarketValue: Self.optionalPositive(row["total_mv"]),
            updatedAt: Self.string(row["quote_time"]).nonEmptyValue
                ?? Self.string(row["received_at"])
        )
    }

    func search(_ rawKeyword: String, limit: Int = 30) async throws -> [SearchSuggestion] {
        let keyword = Self.searchToken(rawKeyword)
        guard !keyword.isEmpty else { return [] }
        let entries = try await directory()
        return entries.lazy
            .filter { entry in
                entry.symbol.lowercased().hasPrefix(keyword)
                    || entry.code.hasPrefix(keyword)
                    || entry.name.localizedCaseInsensitiveContains(rawKeyword)
                    || entry.fullPinyin.hasPrefix(keyword)
                    || entry.initials.hasPrefix(keyword)
            }
            .prefix(limit)
            .map { SearchSuggestion(code: $0.symbol, name: $0.name, market: .cn) }
    }

    func fetchCandles(for item: WatchItem, period: KLinePeriod) async throws -> [KLineCandle] {
        guard item.market == .cn else { throw LocalStockDBError.unsupportedMarket }
        let symbol = Self.normalizedSymbol(item.code)
        switch period {
        case .timeShare, .oneMinute:
            return try await latestMinuteCandles(symbol: symbol)
        case .fiveDay:
            return try await recentMinuteCandles(symbol: symbol, calendarDays: 10, tradingDays: 5)
        case .fiveMinute:
            return Self.aggregateIntraday(try await latestMinuteCandles(symbol: symbol), minutes: 5)
        case .fifteenMinute:
            return Self.aggregateIntraday(try await latestMinuteCandles(symbol: symbol), minutes: 15)
        case .thirtyMinute:
            return Self.aggregateIntraday(try await latestMinuteCandles(symbol: symbol), minutes: 30)
        case .sixtyMinute:
            return Self.aggregateIntraday(try await latestMinuteCandles(symbol: symbol), minutes: 60)
        case .oneTwentyMinute:
            return Self.aggregateIntraday(try await latestMinuteCandles(symbol: symbol), minutes: 120)
        case .day:
            return Array(try await dailyCandles(symbol: symbol, period: .day).suffix(120))
        case .week:
            return Self.aggregateCalendar(try await dailyCandles(symbol: symbol, period: .day), component: .weekOfYear)
        case .month:
            return Self.aggregateCalendar(try await dailyCandles(symbol: symbol, period: .day), component: .month)
        case .year:
            return Self.aggregateCalendar(try await dailyCandles(symbol: symbol, period: .day), component: .year)
        }
    }

    private func directory() async throws -> [SecurityDirectoryEntry] {
        if let directoryCache { return directoryCache }
        let rows = try await dictionaries("实时证券目录:*")
        let entries = rows.compactMap { row -> SecurityDirectoryEntry? in
            let symbol = Self.string(row["symbol"])
            let name = Self.string(row["name"])
            guard !symbol.isEmpty, !name.isEmpty else { return nil }
            let tokens = Self.pinyinTokens(name)
            return SecurityDirectoryEntry(
                symbol: symbol,
                code: Self.string(row["code"]),
                name: name,
                fullPinyin: tokens.full,
                initials: tokens.initials
            )
        }.sorted { lhs, rhs in
            if lhs.symbol == rhs.symbol { return lhs.name < rhs.name }
            return lhs.symbol < rhs.symbol
        }
        directoryCache = entries
        return entries
    }

    private func latestMinuteCandles(symbol: String) async throws -> [KLineCandle] {
        let table = Self.indexSymbols.contains(symbol) ? "实时指数最新" : "实时行情最新"
        guard let quote = try await dictionary(table + ":" + symbol) else {
            throw LocalStockDBError.missingData
        }
        let date = Self.string(quote["quote_date"]).replacingOccurrences(of: "-", with: "")
        guard date.count == 8 else { throw LocalStockDBError.missingData }
        var rows = try await dictionaries("实时分钟K:\(symbol):\(date)*")
        if let current = try await dictionary("实时分钟当前:" + symbol) {
            let currentStamp = Self.int64(current["date"])
            rows.removeAll { Self.int64($0["date"]) == currentStamp }
            rows.append(current)
        }
        if rows.isEmpty, !Self.indexSymbols.contains(symbol) {
            rows = try await dictionaries("分钟k:\(String(symbol.dropFirst(2))):\(date)*")
        }
        return Self.minuteCandles(from: rows)
    }

    private func recentMinuteCandles(symbol: String, calendarDays: Int, tradingDays: Int) async throws -> [KLineCandle] {
        guard !Self.indexSymbols.contains(symbol) else { return try await latestMinuteCandles(symbol: symbol) }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -calendarDays, to: end) ?? end
        let range = Self.dateString(start) + "000000<" + Self.dateString(end) + "235959"
        var candles = Self.minuteCandles(from: try await rangedDictionaries(
            table: "分钟k", key: String(symbol.dropFirst(2)), range: range
        ))
        if let live = try? await latestMinuteCandles(symbol: symbol), !live.isEmpty {
            let liveDay = Calendar.shanghai.startOfDay(for: live[0].timestamp)
            candles.removeAll { Calendar.shanghai.isDate($0.timestamp, inSameDayAs: liveDay) }
            candles.append(contentsOf: live)
        }
        let days = Array(Set(candles.map { Calendar.shanghai.startOfDay(for: $0.timestamp) }))
            .sorted().suffix(tradingDays)
        let selected = Set(days)
        return candles.filter { selected.contains(Calendar.shanghai.startOfDay(for: $0.timestamp)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func dailyCandles(symbol: String, period: KLinePeriod) async throws -> [KLineCandle] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .year, value: -4, to: end) ?? end
        let isIndex = Self.indexSymbols.contains(symbol)
        let rows = try await rangedDictionaries(
            table: isIndex ? "实时指数日K" : "日k",
            key: isIndex ? symbol : String(symbol.dropFirst(2)),
            range: Self.dateString(start) + "<" + Self.dateString(end)
        )
        return Array(rows.compactMap(Self.dailyCandle).sorted { $0.timestamp < $1.timestamp }.suffix(1200))
    }

    private func dictionary(_ key: String) async throws -> [String: Any]? {
        let value = try await request(key)
        return value as? [String: Any]
    }

    private func dictionaries(_ key: String) async throws -> [[String: Any]] {
        let value = try await request(key)
        return Self.dictionaryValues(value)
    }

    private func rangedDictionaries(table: String, key: String, range: String) async throws -> [[String: Any]] {
        let bounds = range.split(separator: "<", maxSplits: 1).map(String.init)
        guard bounds.count == 2 else { return [] }
        let value = try await request(queryItems: [
            URLQueryItem(name: "cmd", value: "get"),
            URLQueryItem(name: "t", value: table),
            URLQueryItem(name: "k1", value: "key:" + key),
            URLQueryItem(name: "k2", value: "fwd:\(bounds[0]),\(bounds[1])"),
        ])
        return Self.dictionaryValues(value)
    }

    private static func dictionaryValues(_ value: Any) -> [[String: Any]] {
        if let row = value as? [String: Any] { return [row] }
        guard let pairs = value as? [Any] else { return [] }
        return pairs.compactMap { pair in
            guard let values = pair as? [Any], values.count > 1 else { return nil }
            return values[1] as? [String: Any]
        }
    }

    private func request(_ key: String) async throws -> Any {
        try await request(queryItems: [
            URLQueryItem(name: "cmd", value: "get"),
            URLQueryItem(name: "t", value: key),
        ])
    }

    private func request(queryItems: [URLQueryItem]) async throws -> Any {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LocalStockDBError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw LocalStockDBError.unavailable
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static let indexSymbols = Set(["SH000001", "SZ399001", "SH000688", "SZ399006", "BJ899050"])

    static func normalizedSymbol(_ raw: String) -> String {
        let value = raw.uppercased().replacingOccurrences(of: ".", with: "")
        if value.hasPrefix("SH") || value.hasPrefix("SZ") || value.hasPrefix("BJ") { return value }
        if value.hasPrefix("4") || value.hasPrefix("8") || value.hasPrefix("92") { return "BJ" + value }
        if value.hasPrefix("5") || value.hasPrefix("6") || value.hasPrefix("9") { return "SH" + value }
        return "SZ" + value
    }

    private static func minuteCandles(from rows: [[String: Any]]) -> [KLineCandle] {
        let sorted = rows.sorted { int64($0["date"]) < int64($1["date"]) }
        var cumulativeVolume = 0.0
        var cumulativeAmount = 0.0
        var currentDay: Date?
        return sorted.compactMap { row in
            guard let timestamp = timestamp(row["date"], format: "yyyyMMddHHmmss") else { return nil }
            let day = Calendar.shanghai.startOfDay(for: timestamp)
            if currentDay != day {
                currentDay = day
                cumulativeVolume = 0
                cumulativeAmount = 0
            }
            let volume = double(row["volume"])
            cumulativeVolume += volume
            cumulativeAmount += double(row["amount"])
            return KLineCandle(
                timestamp: timestamp,
                opening: double(row["open"]), high: double(row["high"]),
                low: double(row["low"]), close: double(row["close"]), volume: volume,
                averagePrice: cumulativeVolume > 0 ? cumulativeAmount / cumulativeVolume : nil
            )
        }
    }

    private static func dailyCandle(_ row: [String: Any]) -> KLineCandle? {
        guard let timestamp = timestamp(row["date"], format: "yyyyMMdd") else { return nil }
        return KLineCandle(
            timestamp: timestamp, opening: double(row["open"]), high: double(row["high"]),
            low: double(row["low"]), close: double(row["close"]),
            volume: double(row["volume"])
        )
    }

    private static func aggregateIntraday(_ candles: [KLineCandle], minutes: Int) -> [KLineCandle] {
        guard minutes > 1 else { return candles }
        if minutes == 120 {
            return aggregate(candles, key: { candle in
                Calendar.shanghai.component(.hour, from: candle.timestamp) < 13 ? "am" : "pm"
            })
        }
        return aggregate(candles, key: { candle in
            let hour = Calendar.shanghai.component(.hour, from: candle.timestamp)
            let minute = Calendar.shanghai.component(.minute, from: candle.timestamp)
            let sessionOffset = hour < 13 ? hour * 60 + minute - 570 : 121 + hour * 60 + minute - 780
            return String(max(0, sessionOffset) / minutes)
        })
    }

    private static func aggregateCalendar(_ candles: [KLineCandle], component: Calendar.Component) -> [KLineCandle] {
        aggregate(candles, key: { candle in
            let calendar = Calendar.shanghai
            switch component {
            case .day: return dateString(candle.timestamp)
            case .weekOfYear:
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: candle.timestamp)
                return "\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
            case .month:
                let parts = calendar.dateComponents([.year, .month], from: candle.timestamp)
                return "\(parts.year ?? 0)-\(parts.month ?? 0)"
            default: return String(calendar.component(.year, from: candle.timestamp))
            }
        })
    }

    private static func aggregate(_ candles: [KLineCandle], key: (KLineCandle) -> String) -> [KLineCandle] {
        var order: [String] = []
        var groups: [String: [KLineCandle]] = [:]
        for candle in candles.sorted(by: { $0.timestamp < $1.timestamp }) {
            let groupKey = key(candle)
            if groups[groupKey] == nil { order.append(groupKey) }
            groups[groupKey, default: []].append(candle)
        }
        return order.compactMap { groupKey in
            guard let values = groups[groupKey], let first = values.first, let last = values.last else { return nil }
            return KLineCandle(
                timestamp: last.timestamp, opening: first.opening,
                high: values.map(\.high).max() ?? first.high,
                low: values.map(\.low).min() ?? first.low,
                close: last.close, volume: values.reduce(0) { $0 + $1.volume },
                averagePrice: last.averagePrice
            )
        }
    }

    private static func timestamp(_ value: Any?, format: String) -> Date? {
        let raw = String(int64(value))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.date(from: raw)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func pinyinTokens(_ value: String) -> (full: String, initials: String) {
        let latin = value.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? value
        let words = latin.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (words.joined(), words.compactMap(\.first).map(String.init).joined())
    }

    private static func searchToken(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        return Int64(value as? String ?? "") ?? 0
    }
    private static func double(_ value: Any?, fallback: Double = 0) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        return Double(value as? String ?? "") ?? fallback
    }
    private static func optionalPositive(_ value: Any?) -> Double? {
        let result = double(value)
        return result > 0 ? result : nil
    }

    private static func validateFreshness(_ row: [String: Any], now: Date = Date()) throws {
        guard isCollectionSession(now) else { return }
        if (row["is_stale"] as? Bool) == true { throw LocalStockDBError.staleCollector }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let receivedAt = formatter.date(from: string(row["received_at"])),
              now.timeIntervalSince(receivedAt) <= 30 else {
            throw LocalStockDBError.staleCollector
        }
    }

    private static func isCollectionSession(_ date: Date) -> Bool {
        let calendar = Calendar.shanghai
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let value = hour * 60 + minute
        return (9 * 60 + 15...11 * 60 + 30).contains(value)
            || (13 * 60...15 * 60 + 5).contains(value)
    }
}

private struct SecurityDirectoryEntry: Sendable {
    let symbol: String
    let code: String
    let name: String
    let fullPinyin: String
    let initials: String
}

enum LocalStockDBError: LocalizedError {
    case invalidURL
    case unavailable
    case missingData
    case unsupportedMarket
    case staleCollector

    var errorDescription: String? {
        switch self {
        case .invalidURL: "本地 StockDB 地址无效"
        case .unavailable: "本地 StockDB 服务未启动"
        case .missingData: "本地数据库暂无该证券行情"
        case .unsupportedMarket: "本地版目前仅支持 A 股"
        case .staleCollector: "本地行情采集器数据已过期，请检查后台进程"
        }
    }
}

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}

private extension Calendar {
    static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}
