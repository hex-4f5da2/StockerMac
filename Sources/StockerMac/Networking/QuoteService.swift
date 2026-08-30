import CoreFoundation
import Foundation

actor QuoteService {
    private let session: URLSession
    private let local = LocalStockDBClient.shared

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
        _ = provider // 保留字段仅用于兼容旧设置；Mac 行情统一由本地 StockDB 提供。
        return try await local.fetchQuotes(for: items)
    }

    func search(_ keyword: String, provider: QuoteProvider) async throws -> [SearchSuggestion] {
        _ = provider
        return try await local.search(keyword)
    }

    private func fetchQuotes(codes: [String], market: Market, provider: QuoteProvider) async throws -> [Quote] {
        let encodedCodes = codes.map { apiCode($0, market: market, provider: provider) }.joined(separator: ",")
        let host = provider == .sina ? "https://hq.sinajs.cn/list=" : "https://qt.gtimg.cn/q="
        guard let url = URL(string: host + encodedCodes) else { throw QuoteServiceError.invalidURL }
        let response = try await request(url, provider: provider)
        return QuoteParser.parse(response, provider: provider, market: market)
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: "行情地址无效"
        case .badResponse: "行情服务暂时不可用"
        case .decodingFailed: "行情数据解析失败"
        }
    }
}
