import Foundation

enum Market: String, Codable, CaseIterable, Identifiable, Sendable {
    case cn
    case hk
    case us

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

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sidebarID: String { "group:\(id.uuidString)" }
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

struct PersistedState: Codable, Sendable {
    var items: [WatchItem]
    var provider: QuoteProvider
    var refreshInterval: Double
    var colorPreference: ColorSchemePreference
    var statusBarDisplayMode: StatusBarDisplayMode
    var groups: [StockGroup]
    var groupMemberships: [String: Set<UUID>]

    init(
        items: [WatchItem],
        provider: QuoteProvider,
        refreshInterval: Double,
        colorPreference: ColorSchemePreference,
        statusBarDisplayMode: StatusBarDisplayMode = .ticker,
        groups: [StockGroup] = [],
        groupMemberships: [String: Set<UUID>] = [:]
    ) {
        self.items = items
        self.provider = provider
        self.refreshInterval = refreshInterval
        self.colorPreference = colorPreference
        self.statusBarDisplayMode = statusBarDisplayMode
        self.groups = groups
        self.groupMemberships = groupMemberships
    }

    private enum CodingKeys: String, CodingKey {
        case items, provider, refreshInterval, colorPreference, statusBarDisplayMode, groups, groupMemberships
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
    }

    static let initial = PersistedState(
        items: [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn),
            WatchItem(code: "SZ399006", name: "创业板指", market: .cn),
            WatchItem(code: "00700", name: "腾讯控股", market: .hk),
            WatchItem(code: "AAPL", name: "苹果", market: .us)
        ],
        provider: .sina,
        refreshInterval: 10,
        colorPreference: .redUp,
        statusBarDisplayMode: .ticker,
        groups: [],
        groupMemberships: [:]
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
