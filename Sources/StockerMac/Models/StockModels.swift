import Foundation

enum Market: String, Codable, CaseIterable, Identifiable, Sendable {
    case cn
    case hk
    case us

    /// 港美股 case 仅保留用于无损解码旧配置；当前产品只展示 A 股。
    static let supportedCases: [Market] = [.cn]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cn: "A 股"
        case .hk: "港 股"
        case .us: "美 股"
        }
    }

    var shortTitle: String { rawValue.uppercased() }

    var currency: String {
        switch self {
        case .cn: "CNY"
        case .hk: "HKD"
        case .us: "USD"
        }
    }

    var symbol: String {
        switch self {
        case .cn: "¥"
        case .hk: "HK$"
        case .us: "$"
        }
    }
}

enum QuoteProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case sina
    case tencent

    var id: String { rawValue }
    var title: String { self == .sina ? "新浪财经" : "腾讯财经" }
}

enum ColorSchemePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case redUp
    case greenUp
    case monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redUp: "红涨绿跌"
        case .greenUp: "绿涨红跌"
        case .monochrome: "单色"
        }
    }
}

enum StatusBarDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ticker
    case icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ticker: "轮播股票与涨跌幅"
        case .icon: "仅显示 Stocker 图标"
        }
    }
}

struct WatchItem: Codable, Hashable, Identifiable, Sendable {
    let code: String
    var name: String
    let market: Market
    var costPrice: Double
    var quantity: Double

    var id: String { "\(market.rawValue):\(code.uppercased())" }

    init(code: String, name: String = "", market: Market, costPrice: Double = 0, quantity: Double = 0) {
        self.code = code.uppercased()
        self.name = name
        self.market = market
        self.costPrice = costPrice
        self.quantity = quantity
    }
}

struct StockGroup: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    /// 上级分组 ID；nil = 一级分组。父级必须是一级分组，保证层级最多两级。
    var parentID: UUID?
    /// 置顶锁定：不参与强度动态排序，固定排在同层最前。
    var isPinned: Bool

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, isPinned: Bool = false) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parentID = parentID
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct Quote: Hashable, Identifiable, Sendable {
    let code: String
    let name: String
    let market: Market
    let current: Double
    let opening: Double
    let close: Double
    let low: Double
    let high: Double
    let change: Double
    let percentage: Double
    let updatedAt: String

    var id: String { "\(market.rawValue):\(code.uppercased())" }
}

struct QuoteRow: Hashable, Identifiable, Sendable {
    let item: WatchItem
    let quote: Quote?

    var id: String { item.id }
    var displayName: String { quote?.name.nonEmpty ?? item.name.nonEmpty ?? item.code }
    var current: Double { quote?.current ?? 0 }
    var percentage: Double { quote?.percentage ?? 0 }
    var change: Double { quote?.change ?? 0 }
    var amplitude: Double {
        guard let quote, quote.close != 0 else { return 0 }
        return (quote.high - quote.low) / quote.close * 100
    }
    var marketValue: Double { current * item.quantity }
    var dayProfit: Double { change * item.quantity }
    var totalProfit: Double { (current - item.costPrice) * item.quantity }
    var hasPosition: Bool { item.quantity != 0 }
}

struct SearchSuggestion: Hashable, Identifiable, Sendable {
    let code: String
    let name: String
    let market: Market
    var id: String { "\(market.rawValue):\(code.uppercased())" }
}

struct KLineRoute: Codable, Hashable, Sendable {
    let code: String
    let name: String
    let market: Market

    init(item: WatchItem) {
        code = item.code
        name = item.name
        market = item.market
    }

    init(suggestion: SearchSuggestion) {
        code = suggestion.code
        name = suggestion.name
        market = suggestion.market
    }

    var item: WatchItem {
        WatchItem(code: code, name: name, market: market)
    }
}

enum SearchInputParser {
    static func keywords(from input: String) -> [String] {
        var seen = Set<String>()
        return input
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.localizedLowercase).inserted }
    }
}

struct PortfolioSummary: Sendable {
    let marketValue: Double
    let dayProfit: Double
    let totalProfit: Double
    let positionCount: Int

    static let empty = PortfolioSummary(marketValue: 0, dayProfit: 0, totalProfit: 0, positionCount: 0)
}

struct PositionHistoryRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let code: String
    let name: String
    let market: Market
    let costPrice: Double
    let quantity: Double
    let closedPrice: Double?
    let closedAt: Date

    init(
        id: UUID = UUID(),
        code: String,
        name: String,
        market: Market,
        costPrice: Double,
        quantity: Double,
        closedPrice: Double?,
        closedAt: Date = Date()
    ) {
        self.id = id
        self.code = code.uppercased()
        self.name = name
        self.market = market
        self.costPrice = costPrice
        self.quantity = quantity
        self.closedPrice = closedPrice
        self.closedAt = closedAt
    }

    var displayName: String { name.nonEmpty ?? code }
    var closedValue: Double? { closedPrice.map { $0 * quantity } }
    var profit: Double? { closedPrice.map { ($0 - costPrice) * quantity } }
}

enum PriceAlertDirection: String, Codable, Sendable {
    case risesTo
    case fallsTo

    var title: String {
        switch self {
        case .risesTo: "涨到"
        case .fallsTo: "跌到"
        }
    }
}

struct StockPriceAlert: Codable, Hashable, Identifiable, Sendable {
    let itemID: String
    var targetPrice: Double
    var direction: PriceAlertDirection
    var createdAt: Date
    var expiresAt: Date

    var id: String { itemID }

    func isTriggered(by currentPrice: Double) -> Bool {
        switch direction {
        case .risesTo: currentPrice >= targetPrice
        case .fallsTo: currentPrice <= targetPrice
        }
    }

    func isValid(at date: Date) -> Bool {
        date < expiresAt
    }
}

struct GroupAverageAlert: Codable, Hashable, Identifiable, Sendable {
    let groupID: UUID
    var referencePercentage: Double?
    var updatedAt: Date

    var id: UUID { groupID }

    func movement(from currentPercentage: Double, threshold: Double = 1) -> Double? {
        guard let referencePercentage else { return nil }
        let movement = currentPercentage - referencePercentage
        return abs(movement) >= threshold ? movement : nil
    }
}

enum AlertRules {
    static func priceDirection(currentPrice: Double, targetPrice: Double) -> PriceAlertDirection? {
        guard currentPrice.isFinite, targetPrice.isFinite, currentPrice > 0, targetPrice > 0,
              currentPrice != targetPrice else { return nil }
        return targetPrice > currentPrice ? .risesTo : .fallsTo
    }

    static func endOfDay(containing date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }
}

struct PersistedState: Codable, Sendable {
    var items: [WatchItem]
    var provider: QuoteProvider
    var refreshInterval: Double
    var colorPreference: ColorSchemePreference
    var statusBarDisplayMode: StatusBarDisplayMode
    var groups: [StockGroup]
    var groupMemberships: [String: Set<UUID>]
    var positionHistory: [PositionHistoryRecord]
    var stockPriceAlerts: [StockPriceAlert]
    var groupAverageAlerts: [GroupAverageAlert]

    init(
        items: [WatchItem],
        provider: QuoteProvider,
        refreshInterval: Double,
        colorPreference: ColorSchemePreference,
        statusBarDisplayMode: StatusBarDisplayMode = .ticker,
        groups: [StockGroup] = [],
        groupMemberships: [String: Set<UUID>] = [:],
        positionHistory: [PositionHistoryRecord] = [],
        stockPriceAlerts: [StockPriceAlert] = [],
        groupAverageAlerts: [GroupAverageAlert] = []
    ) {
        self.items = items
        self.provider = provider
        self.refreshInterval = refreshInterval
        self.colorPreference = colorPreference
        self.statusBarDisplayMode = statusBarDisplayMode
        self.groups = groups
        self.groupMemberships = groupMemberships
        self.positionHistory = positionHistory
        self.stockPriceAlerts = stockPriceAlerts
        self.groupAverageAlerts = groupAverageAlerts
    }

    private enum CodingKeys: String, CodingKey {
        case items, provider, refreshInterval, colorPreference, statusBarDisplayMode, groups, groupMemberships, positionHistory
        case stockPriceAlerts, groupAverageAlerts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([WatchItem].self, forKey: .items)
        provider = try container.decode(QuoteProvider.self, forKey: .provider)
        refreshInterval = try container.decode(Double.self, forKey: .refreshInterval)
        colorPreference = try container.decode(ColorSchemePreference.self, forKey: .colorPreference)
        statusBarDisplayMode = try container.decodeIfPresent(StatusBarDisplayMode.self, forKey: .statusBarDisplayMode) ?? .ticker
        groups = try container.decodeIfPresent([StockGroup].self, forKey: .groups) ?? []
        groupMemberships = try container.decodeIfPresent([String: Set<UUID>].self, forKey: .groupMemberships) ?? [:]
        positionHistory = try container.decodeIfPresent([PositionHistoryRecord].self, forKey: .positionHistory) ?? []
        stockPriceAlerts = try container.decodeIfPresent([StockPriceAlert].self, forKey: .stockPriceAlerts) ?? []
        groupAverageAlerts = try container.decodeIfPresent([GroupAverageAlert].self, forKey: .groupAverageAlerts) ?? []
    }

    static let initial = PersistedState(
        items: [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
            WatchItem(code: "SZ399006", name: "创业板指", market: .cn)
        ],
        provider: .sina,
        refreshInterval: 5,
        colorPreference: .redUp,
        statusBarDisplayMode: .ticker,
        groups: [],
        groupMemberships: [:],
        positionHistory: [],
        stockPriceAlerts: [],
        groupAverageAlerts: []
    )
}

extension Optional where Wrapped == String {
    fileprivate var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
