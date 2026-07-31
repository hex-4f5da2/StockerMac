import Foundation

enum KLineParser {
    static func parseTencentTimeShare(_ data: Data, apiCode: String) throws -> [KLineCandle] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let dataObject = root["data"] as? [String: Any],
              let instrument = dataObject[apiCode] as? [String: Any],
              let minuteObject = instrument["data"] as? [String: Any],
              let date = minuteObject["date"] as? String,
              let rows = minuteObject["data"] as? [String] else {
            throw KLineServiceError.decodingFailed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmm"

        var previousPrice: Double?
        var previousCumulativeVolume = 0.0
        var candles: [KLineCandle] = []
        for row in rows {
            let fields = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4,
                  fields[0].count == 4,
                  let hour = Int(fields[0].prefix(2)),
                  let minute = Int(fields[0].suffix(2)),
                  isTradingMinute(hour: hour, minute: minute),
                  let timestamp = formatter.date(from: date + fields[0]),
                  let price = Double(fields[1]),
                  let cumulativeVolume = Double(fields[2]),
                  let cumulativeAmount = Double(fields[3]),
                  price > 0, cumulativeVolume >= previousCumulativeVolume else { continue }

            let opening = previousPrice ?? price
            let minuteVolume = cumulativeVolume - previousCumulativeVolume
            let averagePrice = cumulativeVolume > 0
                ? cumulativeAmount / (cumulativeVolume * 100)
                : price
            candles.append(KLineCandle(
                timestamp: timestamp,
                opening: opening,
                high: max(opening, price),
                low: min(opening, price),
                close: price,
                volume: minuteVolume,
                averagePrice: averagePrice
            ))
            previousPrice = price
            previousCumulativeVolume = cumulativeVolume
        }
        return candles
    }

    static func parseTencent(
        _ data: Data,
        apiCode: String,
        period: KLinePeriod
    ) throws -> [KLineCandle] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let dataObject = root["data"] as? [String: Any],
              let instrument = dataObject[apiCode] as? [String: Any] else {
            throw KLineServiceError.decodingFailed
        }

        let rows: [[Any]]
        switch period {
        case .timeShare, .oneMinute:
            rows = instrument["m1"] as? [[Any]] ?? []
        case .fiveDay, .fiveMinute:
            rows = instrument["m5"] as? [[Any]] ?? []
        case .fifteenMinute:
            rows = instrument["m15"] as? [[Any]] ?? []
        case .thirtyMinute:
            rows = instrument["m30"] as? [[Any]] ?? []
        case .sixtyMinute:
            rows = instrument["m60"] as? [[Any]] ?? []
        case .oneTwentyMinute:
            rows = instrument["m120"] as? [[Any]] ?? []
        case .day:
            rows = (instrument["qfqday"] as? [[Any]])
                ?? (instrument["day"] as? [[Any]])
                ?? []
        case .week:
            rows = (instrument["qfqweek"] as? [[Any]])
                ?? (instrument["week"] as? [[Any]])
                ?? []
        case .month, .year:
            rows = (instrument["qfqmonth"] as? [[Any]])
                ?? (instrument["month"] as? [[Any]])
                ?? []
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = period.usesDateOnly ? "yyyy-MM-dd" : "yyyyMMddHHmm"

        var candlesByDate: [Date: KLineCandle] = [:]
        for row in rows {
            guard row.count >= 6,
                  let rawDate = row[0] as? String,
                  let timestamp = formatter.date(from: rawDate),
                  let opening = number(row[1]),
                  let close = number(row[2]),
                  let high = number(row[3]),
                  let low = number(row[4]),
                  let volume = number(row[5]),
                  opening.isFinite, close.isFinite, high.isFinite, low.isFinite, volume.isFinite,
                  opening > 0, close > 0,
                  high >= max(opening, close),
                  low <= min(opening, close) else { continue }

            candlesByDate[timestamp] = KLineCandle(
                timestamp: timestamp,
                opening: opening,
                high: high,
                low: low,
                close: close,
                volume: max(0, volume)
            )
        }

        let candles = candlesByDate.values.sorted { $0.timestamp < $1.timestamp }
        return period == .year ? aggregateByYear(candles) : candles
    }

    private static func number(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func isTradingMinute(hour: Int, minute: Int) -> Bool {
        let minutes = hour * 60 + minute
        return (9 * 60 + 30...11 * 60 + 30).contains(minutes)
            || (13 * 60 + 1...15 * 60).contains(minutes)
    }

    private static func aggregateByYear(_ candles: [KLineCandle]) -> [KLineCandle] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let groups = Dictionary(grouping: candles) {
            calendar.component(.year, from: $0.timestamp)
        }
        return groups.keys.sorted().compactMap { year in
            guard let rows = groups[year]?.sorted(by: { $0.timestamp < $1.timestamp }),
                  let first = rows.first,
                  let last = rows.last else { return nil }
            return KLineCandle(
                timestamp: last.timestamp,
                opening: first.opening,
                high: rows.map(\.high).max() ?? first.high,
                low: rows.map(\.low).min() ?? first.low,
                close: last.close,
                volume: rows.reduce(0) { $0 + $1.volume }
            )
        }
    }
}
