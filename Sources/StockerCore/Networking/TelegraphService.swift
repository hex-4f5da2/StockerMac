import CryptoKit
import Foundation

// MARK: - 协议（Sendable，供测试注入 fake）

public protocol TelegraphServiceProviding: Sendable {
    /// 拉取一页消息。`anchor` 为 nil 表示最新页；否则从锚点向更旧翻页。
    func fetchPage(_ source: TelegraphSource, anchor: TelegraphFetchAnchor?) async throws -> [TelegraphMessage]
    /// 拉取当前最新一页（带源内最新 id 判定用）
    func fetchLatest(_ source: TelegraphSource) async throws -> [TelegraphMessage]
}

/// 分页锚点：财联社/金十用时间戳，东财用页码
public struct TelegraphFetchAnchor: Sendable, Hashable {
    public var olderThanCtime: TimeInterval?
    public var page: Int?

    public init(olderThanCtime: TimeInterval? = nil, page: Int? = nil) {
        self.olderThanCtime = olderThanCtime
        self.page = page
    }
}

public enum TelegraphServiceError: LocalizedError, Sendable {
    case invalidURL
    case badResponse
    case oversizedResponse
    case decodingFailed
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "电报接口地址无效"
        case .badResponse: "电报接口暂时不可用"
        case .oversizedResponse: "电报响应过大，已拒绝"
        case .decodingFailed: "电报数据解析失败"
        case .providerError(let msg): "电报服务返回错误：\(msg)"
        }
    }
}

// MARK: - 服务实现

public actor TelegraphService: TelegraphServiceProviding {
    /// rn=50：财联社 /api/cache 在 rn<=20 时翻页（last_time）不推进，50 时有效（实测）
    public static let pageSize = 50
    private static let maxResponseBytes = 2 * 1024 * 1024
    private static let maxFieldLength = 8_000

    private let session: URLSession
    private let clsSigner: CLSSignature

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    public init(session: URLSession = TelegraphService.makeDefaultSession(), clsSigner: CLSSignature = .live) {
        self.session = session
        self.clsSigner = clsSigner
    }

    public func fetchLatest(_ source: TelegraphSource) async throws -> [TelegraphMessage] {
        if source == .jin10 {
            return try await fetchJin10Page(olderThan: nil, scanPages: 8)
        }
        return try await fetchPage(source, anchor: nil)
    }

    public func fetchPage(_ source: TelegraphSource, anchor: TelegraphFetchAnchor?) async throws -> [TelegraphMessage] {
        switch source {
        case .cls:
            let params = CLSParams(
                lastTime: anchor?.olderThanCtime,
                pageSize: Self.pageSize
            )
            return try await fetchCLSPage(params: params)
        case .eastmoney:
            let page = anchor?.page ?? 1
            return try await fetchEastmoneyPage(page: page)
        case .jin10:
            return try await fetchJin10Page(olderThan: anchor?.olderThanCtime, scanPages: 1)
        }
    }

    // MARK: 财联社

    private func fetchCLSPage(params: CLSParams) async throws -> [TelegraphMessage] {
        // 主接口 /api/cache（网页 30s 轮询同款；get_roll_list 已被服务端风控 10012）
        // 最新页: last_time=当前时间戳；翻页: last_time=最老 ctime（闭区间，靠 id 去重）
        let base = "https://www.cls.cn/api/cache"
        var query: [String: String] = [
            "app": "CailianpressWeb",
            "os": "web",
            "sv": "8.7.9",
            "name": "telegraph",
            "rn": String(params.pageSize),
            "last_time": String(Int(params.lastTime ?? Date().timeIntervalSince1970)),
        ]
        query["sign"] = clsSigner.sign(params: query)

        guard var components = URLComponents(string: base) else { throw TelegraphServiceError.invalidURL }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw TelegraphServiceError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.cls.cn/telegraph", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data = try await perform(request)
        return try CLSDTO.parse(data: data)
    }

    // MARK: 东方财富

    private func fetchEastmoneyPage(page: Int) async throws -> [TelegraphMessage] {
        let urlString = "https://newsapi.eastmoney.com/kuaixun/v1/getlist_102_ajaxResult_50_\(page)_.html"
        guard let url = URL(string: urlString) else { throw TelegraphServiceError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://kuaixun.eastmoney.com/", forHTTPHeaderField: "Referer")

        let data = try await perform(request)
        return try EastmoneyDTO.parse(data: data)
    }

    // MARK: 金十 A股

    private func fetchJin10Page(olderThan: TimeInterval?, scanPages: Int) async throws -> [TelegraphMessage] {
        var cursor = olderThan ?? jin10InitialCursor()
        var messages: [TelegraphMessage] = []
        var seenIDs = Set<String>()

        for _ in 0..<max(1, scanPages) {
            guard var components = URLComponents(string: "https://flash-api.jin10.com/get_flash_list") else {
                throw TelegraphServiceError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "channel", value: "-8200"),
                URLQueryItem(name: "vip", value: "1"),
                URLQueryItem(name: "max_time", value: Self.jin10TimeString(cursor)),
            ]
            guard let url = components.url else { throw TelegraphServiceError.invalidURL }

            var request = URLRequest(url: url, timeoutInterval: 12)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.jin10.com/", forHTTPHeaderField: "Referer")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("bVBF4FyRTn5NJF5n", forHTTPHeaderField: "x-app-id")
            request.setValue("1.0.0", forHTTPHeaderField: "x-version")

            let parsed = try Jin10DTO.parsePage(data: await perform(request))
            for message in parsed.messages where seenIDs.insert(message.id).inserted {
                messages.append(message)
            }
            guard let nextCursor = parsed.nextCursor, nextCursor < cursor else { break }
            cursor = nextCursor
            if messages.count >= 20 { break }
        }
        return messages.sorted { $0.ctime > $1.ctime }
    }

    /// 周末或开盘前直接从最近交易日收盘附近开始，避免先翻大量全球快讯。
    private func jin10InitialCursor(now: Date = Date()) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        guard weekday == 1 || weekday == 7 || hour < 9 else { return now.timeIntervalSince1970 }

        var day = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        while [1, 7].contains(calendar.component(.weekday, from: day)) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        let close = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: day) ?? day
        return close.timeIntervalSince1970
    }

    private static func jin10TimeString(_ timeInterval: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: timeInterval))
    }

    // MARK: 公共

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TelegraphServiceError.badResponse
        }
        guard data.count <= Self.maxResponseBytes else {
            throw TelegraphServiceError.oversizedResponse
        }
        return data
    }

    // MARK: 字段防护

    static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        return String(value.prefix(maxFieldLength))
    }
}

// MARK: - 财联社签名（sign = md5(hex(sha1(参数按字典序扁平串)))）

public struct CLSSignature: Sendable {
    public func sign(params: [String: String]) -> String {
        let flat = params.keys
            .sorted { $0.uppercased() <= $1.uppercased() }
            .map { "\($0)=\(params[$0] ?? "")" }
            .joined(separator: "&")
        // 网页前端实现：sha1(flat) 的原始字节 → md5 → hex
        // （对齐 rusha digest 默认返回 ArrayBuffer 的行为，实测签名返回 errno:0）
        let sha1 = Insecure.SHA1.hash(data: Data(flat.utf8))
        let sha1Raw = Data(sha1)
        return Insecure.MD5.hash(data: sha1Raw).map { String(format: "%02x", $0) }.joined()
    }

    public static let live = CLSSignature()
}

private struct CLSParams {
    let lastTime: TimeInterval?
    let pageSize: Int
}

// MARK: - 财联社 DTO

enum CLSDTO {
    struct Response: Decodable {
        struct Data: Decodable {
            let roll_data: [Item]
        }
        struct Item: Decodable {
            let id: Int?
            let ctime: TimeInterval?
            let title: String?
            let content: String?
            let brief: String?
            let level: String?
            let reading_num: Int?
            let category: Int?
            let stock_list: [String]?
            let shareurl: String?
        }
        let errno: Int?
        let msg: String?
        let data: Data?
    }

    static func parse(data: Data) throws -> [TelegraphMessage] {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TelegraphServiceError.decodingFailed
        }
        guard let errno = decoded.errno else { throw TelegraphServiceError.decodingFailed }
        guard errno == 0 else {
            throw TelegraphServiceError.providerError(decoded.msg ?? "errno=\(errno)")
        }
        guard let items = decoded.data?.roll_data else { throw TelegraphServiceError.decodingFailed }

        return items.compactMap { item in
            guard let id = item.id else { return nil }
            let ctime = item.ctime ?? 0
            let title = TelegraphService.bounded(item.title) ?? ""
            let content = TelegraphService.bounded(item.content) ?? item.brief.flatMap(TelegraphService.bounded) ?? ""
            let stockList = (item.stock_list ?? []).compactMap(SecurityID.parse)
            // 加红判定：category==1（网页「加红」分类）或重要等级 A
            let isRed = item.category == 1 || item.level == "A"
            var categories = TelegraphClassifier.classify(title: title, content: content)
            if isRed { categories.insert(.red) }
            return TelegraphMessage(
                id: "cls:\(id)",
                source: .cls,
                ctime: ctime,
                title: title,
                content: content,
                isRed: isRed,
                categories: categories,
                stockList: stockList,
                readingNum: item.reading_num ?? 0,
                url: safeURL(item.shareurl, source: .cls),
                level: item.level
            )
        }
    }

    static func safeURL(_ raw: String?, source: TelegraphSource) -> String? {
        guard let raw, raw.hasPrefix("https://"),
              let host = URL(string: raw)?.host else { return nil }
        let hostAllowed = source.allowedHosts.contains { candidate in
            host == candidate || host.hasSuffix("." + candidate)
        }
        return hostAllowed ? raw : nil
    }
}

// MARK: - 东方财富 DTO

enum EastmoneyDTO {
    struct Response: Decodable {
        struct Item: Decodable {
            let id: String?
            let title: String?
            let digest: String?
            let showtime: String?
            let column: String?
            let url_w: String?
            let type: String?
        }
        let LivesList: [Item]?
    }

    static func parse(data: Data) throws -> [TelegraphMessage] {
        // JSONP：仅剥离精确 wrapper `var ajaxResult=(...)`（可选尾部 `;`）
        guard var text = String(data: data, encoding: .utf8) else {
            throw TelegraphServiceError.decodingFailed
        }
        let prefix = "var ajaxResult="
        guard text.hasPrefix(prefix) else { throw TelegraphServiceError.decodingFailed }
        text.removeFirst(prefix.count)
        if text.hasSuffix(";") { text.removeLast() }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        } catch {
            throw TelegraphServiceError.decodingFailed
        }
        let items = decoded.LivesList ?? []
        return items.compactMap { item in
            guard let id = item.id else { return nil }
            let title = TelegraphService.bounded(item.title) ?? ""
            let content = TelegraphService.bounded(item.digest) ?? ""
            let ctime = parseShowtime(item.showtime)
            // 东财无「加红」概念；内容分类用同一智能分类器
            let categories = TelegraphClassifier.classify(title: title, content: content)
            return TelegraphMessage(
                id: "eastmoney:\(id)",
                source: .eastmoney,
                ctime: ctime,
                title: title,
                content: content,
                isRed: false,
                categories: categories,
                stockList: [],
                readingNum: 0,
                url: safeURL(item.url_w, source: .eastmoney),
                level: item.type
            )
        }
    }

    /// "2026-08-08 09:42:00" → 秒级 Unix 时间戳
    static func parseShowtime(_ value: String?) -> TimeInterval {
        guard let value, value.count >= 19 else { return 0 }
        let iso = value.replacingOccurrences(of: " ", with: "T") + "+08:00"
        guard let date = ISO8601DateFormatter().date(from: iso) else { return 0 }
        return date.timeIntervalSince1970
    }

    static func safeURL(_ raw: String?, source: TelegraphSource) -> String? {
        guard let raw, raw.hasPrefix("https://"),
              let host = URL(string: raw)?.host else { return nil }
        let hostAllowed = source.allowedHosts.contains { candidate in
            host == candidate || host.hasSuffix("." + candidate)
        }
        return hostAllowed ? raw : nil
    }
}

// MARK: - 金十 A股 DTO

enum Jin10DTO {
    struct Response: Decodable {
        struct Item: Decodable {
            struct Payload: Decodable {
                let content: String?
                let title: String?
                let source_link: String?
            }
            struct Extras: Decodable {
                let ad: Bool?
            }
            struct Remark: Decodable {
                let symbol: String?
                let type: String?
            }
            struct Kind: Decodable {
                let id: Int?
            }

            let channel: [Int]?
            let data: Payload?
            let extras: Extras?
            let id: String?
            let important: Int?
            let kinds: [Kind]?
            let remark: [Remark]?
            let time: String?
            let type: Int?
        }

        let status: Int?
        let message: String?
        let data: [Item]?
    }

    static func parse(data: Data) throws -> [TelegraphMessage] {
        try parsePage(data: data).messages
    }

    static func parsePage(data: Data) throws -> (messages: [TelegraphMessage], nextCursor: TimeInterval?) {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TelegraphServiceError.decodingFailed
        }
        guard decoded.status == 200 else {
            throw TelegraphServiceError.providerError(decoded.message ?? "status=\(decoded.status ?? -1)")
        }

        let messages: [TelegraphMessage] = (decoded.data ?? []).compactMap { item in
            // kinds.id=14 仍会被复用于部分宏观、期货标签，需结合境内频道
            // 或明确的 A股市场关键词，避免把海外数据等泛财经快讯混进来。
            guard isAStockItem(item),
                  item.extras?.ad != true,
                  let id = item.id else { return nil }

            let title = cleanHTML(TelegraphService.bounded(item.data?.title) ?? "")
            let content = cleanHTML(TelegraphService.bounded(item.data?.content) ?? "")
            guard !title.isEmpty || !content.isEmpty else { return nil }

            let isRed = item.important == 1
            var categories = TelegraphClassifier.classify(title: title, content: content)
            if isRed { categories.insert(.red) }

            var seenStocks = Set<SecurityID>()
            let stockList = (item.remark ?? []).compactMap { remark -> SecurityID? in
                guard remark.type == "quotes", let symbol = remark.symbol,
                      let security = SecurityID.parse(symbol), seenStocks.insert(security).inserted else { return nil }
                return security
            }

            let fallbackURL = "https://flash.jin10.com/detail/\(id)"
            let sourceURL = safeURL(item.data?.source_link) ?? fallbackURL
            return TelegraphMessage(
                id: "jin10:\(id)",
                source: .jin10,
                ctime: parseTime(item.time),
                title: title,
                content: content,
                isRed: isRed,
                categories: categories,
                stockList: stockList,
                readingNum: 0,
                url: sourceURL,
                level: isRed ? "important" : item.type.map(String.init)
            )
        }
        let nextCursor = decoded.data?.last.flatMap { parseTime($0.time) }
        return (messages, nextCursor == 0 ? nil : nextCursor)
    }

    private static func isAStockItem(_ item: Response.Item) -> Bool {
        guard item.kinds?.contains(where: { $0.id == 14 }) == true else { return false }

        if item.channel?.contains(where: { $0 == 4 || $0 == 5 }) == true {
            return true
        }

        let text = [item.data?.title, item.data?.content]
            .compactMap { $0 }
            .joined(separator: " ")
        let marketKeywords = [
            "A股", "上证", "沪指", "沪市", "沪深", "深证", "深成指", "深市",
            "创业板", "科创50", "北证", "富时中国A50"
        ]
        return marketKeywords.contains(where: text.contains)
    }

    static func parseTime(_ value: String?) -> TimeInterval {
        guard let value, value.count >= 19 else { return 0 }
        let iso = value.replacingOccurrences(of: " ", with: "T") + "+08:00"
        return ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0
    }

    static func cleanHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeURL(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("https://"), let host = URL(string: raw)?.host else { return nil }
        let allowed = TelegraphSource.jin10.allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        return allowed ? raw : nil
    }
}
