import Foundation

// MARK: - 数据源

public enum TelegraphSource: String, Codable, CaseIterable, Sendable, Hashable {
    case cls
    case eastmoney
    case jin10

    public var title: String {
        switch self {
        case .cls: "财联社"
        case .eastmoney: "东方财富"
        case .jin10: "金十 A股"
        }
    }

    public var shortTitle: String {
        switch self {
        case .cls: "财联社"
        case .eastmoney: "东财"
        case .jin10: "金十A股"
        }
    }

    public var usesTimePagination: Bool { self != .eastmoney }
    public var supportsImportance: Bool { self != .eastmoney }

    /// 外链白名单 host（仅允许打开这些域名下的 https 链接）
    public var allowedHosts: Set<String> {
        switch self {
        case .cls: ["cls.cn", "www.cls.cn"]
        case .eastmoney: ["eastmoney.com", "finance.eastmoney.com", "wap.eastmoney.com"]
        case .jin10: ["jin10.com", "flash.jin10.com", "www.jin10.com"]
        }
    }

    /// 存储文件名前缀
    var filePrefix: String {
        switch self {
        case .cls: "telegraph-cls"
        case .eastmoney: "telegraph-em"
        case .jin10: "telegraph-jin10"
        }
    }
}

// MARK: - 市场与证券标识

public enum SecurityMarket: String, Codable, CaseIterable, Sendable, Hashable {
    case cn, hk, us
}

/// 统一证券标识：provider 股票列表与自选股快照使用同一格式（如 CN:600000 / HK:00700 / US:AAPL）
public struct SecurityID: Codable, Hashable, Sendable {
    public let market: SecurityMarket
    public let code: String

    public init(market: SecurityMarket, code: String) {
        self.market = market
        self.code = code
    }

    public var rawValue: String { "\(market.rawValue.uppercased()):\(code)" }

    /// 从财联社/东财原始股票字段宽松解析（剥前缀 SH/SZ/BJ/hk/gb_/us 后按形态归类）
    public static func parse(_ raw: String) -> SecurityID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }

        // 金十等来源使用 600000.SH / 300750.SZ / 430047.BJ。
        let suffixParts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if suffixParts.count == 2 {
            let code = String(suffixParts[0])
            switch suffixParts[1] {
            case "SH", "SZ", "BJ": return numeric(code, market: .cn)
            case "HK": return numeric(code, market: .hk)
            case "US": return alphanumeric(code, market: .us)
            default: break
            }
        }

        if trimmed.hasPrefix("SH") || trimmed.hasPrefix("SZ") || trimmed.hasPrefix("BJ") {
            let code = String(trimmed.dropFirst(2))
            return numeric(code, market: .cn)
        }
        if trimmed.hasPrefix("HK") {
            return numeric(String(trimmed.dropFirst(2)), market: .hk)
        }
        if trimmed.hasPrefix("GB_") || trimmed.hasPrefix("US") {
            let code = String(trimmed.dropFirst(trimmed.hasPrefix("GB_") ? 3 : 2))
            return alphanumeric(code, market: .us)
        }
        if trimmed.allSatisfy(\.isNumber) {
            // 6 位数字视为 A 股代码；1–5 位视为港股代码（如 00700 / 700 / 9988）
            switch trimmed.count {
            case 6: return .init(market: .cn, code: trimmed)
            case 1...5: return .init(market: .hk, code: trimmed)
            default: return nil
            }
        }
        return alphanumeric(trimmed, market: .us)
    }

    private static func numeric(_ code: String, market: SecurityMarket) -> SecurityID? {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return SecurityID(market: market, code: digits)
    }

    private static func alphanumeric(_ code: String, market: SecurityMarket) -> SecurityID? {
        let cleaned = code.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return nil }
        return SecurityID(market: market, code: cleaned)
    }
}

// MARK: - 分类

public enum TelegraphCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case red      // 加红
    case company  // 公司
    case market   // 看盘
    case hkUs     // 港美股
    case fund     // 基金
    case reminder // 提醒

    public var title: String {
        switch self {
        case .red: "重要"
        case .company: "公司"
        case .market: "看盘"
        case .hkUs: "港美股"
        case .fund: "基金"
        case .reminder: "提醒"
        }
    }
}

// MARK: - 通知级别

public enum TelegraphNotificationLevel: String, Codable, CaseIterable, Sendable, Hashable {
    case all            // 全部
    case redOnly        // 仅加红
    case redOrWatchlist // 加红 + 自选股
    case off            // 关

    public var title: String {
        switch self {
        case .all: "全部"
        case .redOnly: "仅重要"
        case .redOrWatchlist: "重要 + 自选股"
        case .off: "关"
        }
    }

    public var requiresAuthorization: Bool { self != .off }
}

// MARK: - 消息

public struct TelegraphMessage: Identifiable, Codable, Hashable, Sendable {
    /// 统一身份：`source:remoteID`，避免跨源冲突
    public let id: String
    public let source: TelegraphSource
    /// 秒级 Unix 时间戳
    public let ctime: TimeInterval
    public let title: String
    /// 完整正文（字段级超限才截断，截断时 truncated=true）
    public let content: String
    public let truncated: Bool
    public let isRed: Bool
    /// 持久化规范化分类，过滤只基于它（重启不丢分类）
    public let categories: Set<TelegraphCategory>
    public let stockList: [SecurityID]
    public let readingNum: Int
    /// 源站原文链接（仅 https 且 host 在白名单内）
    public let url: String?
    /// 财联社重要等级（A/B/C），用于调试与未来扩展
    public let level: String?

    public init(
        id: String,
        source: TelegraphSource,
        ctime: TimeInterval,
        title: String,
        content: String,
        truncated: Bool = false,
        isRed: Bool,
        categories: Set<TelegraphCategory>,
        stockList: [SecurityID] = [],
        readingNum: Int = 0,
        url: String? = nil,
        level: String? = nil
    ) {
        self.id = id
        self.source = source
        self.ctime = ctime
        self.title = title
        self.content = content
        self.truncated = truncated
        self.isRed = isRed
        self.categories = categories
        self.stockList = stockList
        self.readingNum = readingNum
        self.url = url
        self.level = level
    }
}

// MARK: - 展示文本

public extension TelegraphMessage {
    /// 统一处理来源常见的「标题为空、正文以【标题】开头」格式。
    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("【"), let closing = content.firstIndex(of: "】") {
            let start = content.index(after: content.startIndex)
            let heading = String(content[start..<closing]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty { return heading }
        }
        return String(content.prefix(36))
    }

    /// 去掉正文开头重复出现的【标题】，列表、详情和通知共用同一份干净正文。
    var displayBody: String {
        var body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("【"), let closing = body.firstIndex(of: "】") {
            let afterHeading = body.index(after: closing)
            let remainder = String(body[afterHeading...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { body = remainder }
        } else {
            let heading = displayTitle
            if !heading.isEmpty, body.hasPrefix(heading) {
                body.removeFirst(heading.count)
                body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        return body == displayTitle ? "" : body
    }

    func summary(limit: Int) -> String {
        let text = displayBody.isEmpty ? displayTitle : displayBody
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - 水位线

/// 会话/读取水位线：记录某一时刻及其已见 id 集合（同秒碰撞安全）
public struct TelegraphMarker: Codable, Hashable, Sendable {
    public var ctime: TimeInterval
    public var ids: Set<String>

    public init(ctime: TimeInterval, ids: Set<String> = []) {
        self.ctime = ctime
        self.ids = ids
    }

    /// 消息是否严格新于该水位线
    public func isNewer(than message: TelegraphMessage) -> Bool {
        message.ctime > ctime || (message.ctime == ctime && !ids.contains(message.id))
    }
}

/// 每条消息的通知处理结果（sent/suppressed 推进水位线，failed 重试）
public enum TelegraphNotificationOutcome: Sendable, Hashable {
    case sent
    case suppressed
    case failed
}

// MARK: - 协调器状态

public enum TelegraphCoordinatorState: String, Sendable {
    case idle
    case bootstrapping
    case backfilling
    case polling
    case paused
    case failed
}
