import CoreFoundation
import Foundation

actor QuoteService {
    private let session: URLSession
    private var localClients: [String: LocalStockDBClient] = [:]

    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    init(session: URLSession = QuoteService.makeDefaultSession()) {
        self.session = session
    }

    func fetchQuotes(for items: [WatchItem], provider: QuoteProvider) async throws -> [Quote] {
        try await fetchQuotes(for: items, route: MarketDataRoute(
            mode: .localStockDB, provider: provider,
            stockDBHost: "127.0.0.1", stockDBPort: 7899
        ))
    }

    func search(_ keyword: String, provider: QuoteProvider) async throws -> [SearchSuggestion] {
        try await search(keyword, route: MarketDataRoute(
            mode: .localStockDB, provider: provider,
            stockDBHost: "127.0.0.1", stockDBPort: 7899
        ))
    }

    func fetchQuotes(for items: [WatchItem], route: MarketDataRoute) async throws -> [Quote] {
        if route.mode == .localStockDB {
            return try await localClient(for: route).fetchQuotes(for: items)
        }
        let groups = Dictionary(grouping: items.filter { $0.market == .cn }, by: \.market)
        return try await withThrowingTaskGroup(of: [Quote].self) { group in
            for (market, marketItems) in groups where !marketItems.isEmpty {
                group.addTask {
                    try await self.fetchQuotes(
                        codes: marketItems.map(\.code), market: market, provider: route.provider
                    )
                }
            }
            var result: [Quote] = []
            for try await quotes in group { result.append(contentsOf: quotes) }
            return result
        }
    }

    func search(_ keyword: String, route: MarketDataRoute) async throws -> [SearchSuggestion] {
        if route.mode == .localStockDB {
            return try await localClient(for: route).search(keyword)
        }
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urlString = route.provider == .sina
            ? "https://suggest3.sinajs.cn/suggest/key=\(encoded)"
            : "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q=\(encoded)"
        guard let url = URL(string: urlString) else { throw QuoteServiceError.invalidURL }
        let response = try await request(url, provider: route.provider)
        let suggestions = route.provider == .sina
            ? parseSinaSuggestions(response) : parseTencentSuggestions(response)
        return suggestions.filter { $0.market == .cn }
    }

    private func localClient(for route: MarketDataRoute) throws -> LocalStockDBClient {
        guard let url = route.localURL else { throw QuoteServiceError.invalidLocalEndpoint }
        let key = url.absoluteString
        if let client = localClients[key] { return client }
        let client = LocalStockDBClient(baseURL: url)
        localClients[key] = client
        return client
    }

    private func fetchQuotes(codes: [String], market: Market, provider: QuoteProvider) async throws -> [Quote] {
        var quotes: [Quote] = []
        for offset in stride(from: 0, to: codes.count, by: 500) {
            let chunk = Array(codes[offset..<min(offset + 500, codes.count)])
            let encodedCodes = chunk.map { apiCode($0, market: market, provider: provider) }
                .joined(separator: ",")
            let host = provider == .sina ? "https://hq.sinajs.cn/list=" : "https://qt.gtimg.cn/q="
            guard let url = URL(string: host + encodedCodes) else { throw QuoteServiceError.invalidURL }
            let response = try await request(url, provider: provider)
            quotes.append(contentsOf: QuoteParser.parse(response, provider: provider, market: market))
        }
        return quotes
    }

    private func request(_ url: URL, provider: QuoteProvider) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if provider == .sina { request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw QuoteServiceError.badResponse
        }
        guard let text = decodeChinese(data) else { throw QuoteServiceError.decodingFailed }
        return text
    }

    private func apiCode(_ rawCode: String, market: Market, provider: QuoteProvider) -> String {
        let code = rawCode.uppercased()
        switch (provider, market) {
        case (_, .cn): return code.lowercased()
        case (.sina, .hk): return "hk\(code)"
        case (.sina, .us): return "gb_\(code.lowercased())"
        case (.tencent, .hk): return "hk\(code)"
        case (.tencent, .us): return "us\(code)"
        }
    }

    private func decodeChinese(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: cfEncoding))
    }

    private func parseSinaSuggestions(_ response: String) -> [SearchSuggestion] {
        guard let first = response.firstIndex(of: "\""), let last = response.lastIndex(of: "\""), first < last else { return [] }
        let payload = response[response.index(after: first)..<last]
        return payload.split(separator: ";").compactMap { raw in
            let columns = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 5 else { return nil }
            switch columns[1] {
            case "11", "81": return SearchSuggestion(code: columns[3].uppercased(), name: columns[4], market: .cn)
            case "22":
                let code = columns[3].replacingOccurrences(of: "of", with: "")
                let prefix = ["15", "16", "18"].contains(where: code.hasPrefix) ? "SZ" : "SH"
                return SearchSuggestion(code: prefix + code, name: columns[4], market: .cn)
            case "31": return SearchSuggestion(code: columns[3].uppercased(), name: columns[4], market: .hk)
            case "41": return SearchSuggestion(code: columns[3].uppercased(), name: columns[4], market: .us)
            default: return nil
            }
        }
    }

    private func parseTencentSuggestions(_ response: String) -> [SearchSuggestion] {
        let payload = response.replacingOccurrences(of: "v_hint=\"", with: "").replacingOccurrences(of: "\"", with: "")
        return payload.split(separator: "^").compactMap { raw in
            let columns = raw.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else { return nil }
            let name = decodeUnicodeEscapes(columns[2])
            switch columns[0] {
            case "sh", "sz": return SearchSuggestion(code: columns[0].uppercased() + columns[1], name: name, market: .cn)
            case "hk": return SearchSuggestion(code: columns[1], name: name, market: .hk)
            case "us": return SearchSuggestion(code: columns[1].split(separator: ".").first.map(String.init)?.uppercased() ?? columns[1], name: name, market: .us)
            default: return nil
            }
        }
    }

    private func decodeUnicodeEscapes(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        let json = "\"\(escaped)\"".data(using: .utf8) ?? Data()
        return (try? JSONDecoder().decode(String.self, from: json)) ?? value
    }
}

enum QuoteServiceError: LocalizedError {
    case invalidURL
    case badResponse
    case decodingFailed
    case invalidLocalEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidURL: "行情地址无效"
        case .badResponse: "行情服务暂时不可用"
        case .decodingFailed: "行情数据解析失败"
        case .invalidLocalEndpoint: "StockDB IP 或端口无效"
        }
    }
}
