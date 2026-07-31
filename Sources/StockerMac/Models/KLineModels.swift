import Foundation

enum KLinePeriod: String, CaseIterable, Identifiable, Sendable {
    case timeShare
    case fiveDay
    case day
    case week
    case month
    case year
    case oneTwentyMinute
    case sixtyMinute
    case thirtyMinute
    case fifteenMinute
    case fiveMinute
    case oneMinute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeShare: "分时"
        case .fiveDay: "五日"
        case .day: "日K"
        case .week: "周K"
        case .month: "月K"
        case .year: "年K"
        case .oneTwentyMinute: "120分"
        case .sixtyMinute: "60分"
        case .thirtyMinute: "30分"
        case .fifteenMinute: "15分"
        case .oneMinute: "1分"
        case .fiveMinute: "5分"
        }
    }

    func isAvailable(for market: Market) -> Bool {
        switch self {
        case .timeShare, .fiveDay, .oneMinute, .fiveMinute, .fifteenMinute,
             .thirtyMinute, .sixtyMinute, .oneTwentyMinute:
            market == .cn
        case .day, .week, .month, .year:
            true
        }
    }

    var usesTradingDayAxis: Bool {
        switch self {
        case .timeShare, .oneMinute, .fiveMinute, .fifteenMinute,
             .thirtyMinute, .sixtyMinute, .oneTwentyMinute:
            true
        case .fiveDay, .day, .week, .month, .year:
            false
        }
    }

    var limitsToLatestTradingDay: Bool { usesTradingDayAxis }

    var usesDateOnly: Bool {
        switch self {
        case .day, .week, .month, .year: true
        default: false
        }
    }

    var isLineChart: Bool { self == .timeShare || self == .fiveDay }
}

struct KLineCandle: Hashable, Identifiable, Sendable {
    let timestamp: Date
    let opening: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let averagePrice: Double?

    var id: Date { timestamp }
    var change: Double { close - opening }

    init(
        timestamp: Date,
        opening: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Double,
        averagePrice: Double? = nil
    ) {
        self.timestamp = timestamp
        self.opening = opening
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.averagePrice = averagePrice
    }
}

struct MarketOverview: Sendable {
    let opening: Double
    let previousClose: Double
    let high: Double
    let low: Double
    let volume: Double?
    let amount: Double?
    let turnoverRate: Double?
    let priceEarningsRatio: Double?
    let totalMarketValue: Double?
    let updatedAt: String
}

enum IntradayTradingAxis {
    static let upperBound = 240
    static let tickValues = [0, 60, 120, 180, 240]

    static func position(for date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return position(hour: components.hour ?? 9, minute: components.minute ?? 30)
    }

    static func position(hour: Int, minute: Int) -> Int {
        let minutes = hour * 60 + minute
        if minutes <= 11 * 60 + 30 {
            return min(120, max(0, minutes - (9 * 60 + 30)))
        }
        return min(upperBound, max(120, 120 + minutes - 13 * 60))
    }

    static func label(at position: Int) -> String {
        switch position {
        case 0: "09:30"
        case 60: "10:30"
        case 120: "11:30/13:00"
        case 180: "14:00"
        case 240: "15:00"
        default: ""
        }
    }
}

enum MarketSession {
    static func isOpen(_ market: Market, at date: Date = Date()) -> Bool {
        let timeZoneID = market == .us ? "America/New_York" : "Asia/Shanghai"
        guard let timeZone = TimeZone(identifier: timeZoneID) else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              (2...6).contains(weekday) else { return false }

        let minutes = hour * 60 + minute
        switch market {
        case .cn:
            return (9 * 60 + 15...11 * 60 + 35).contains(minutes)
                || (12 * 60 + 55...15 * 60 + 5).contains(minutes)
        case .hk:
            return (9 * 60 + 15...12 * 60 + 5).contains(minutes)
                || (12 * 60 + 55...16 * 60 + 10).contains(minutes)
        case .us:
            return (9 * 60 + 25...16 * 60 + 5).contains(minutes)
        }
    }
}
