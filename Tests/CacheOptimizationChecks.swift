import Foundation

@main
enum CacheOptimizationChecks {
    static func main() async throws {
        // 1. 验证 QuoteService 默认 session 的 urlCache 为 nil
        let quoteSession = QuoteService.makeDefaultSession()
        assert(quoteSession.configuration.urlCache == nil, "QuoteService session must disable urlCache")
        assert(quoteSession.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        // 2. 验证 KLineService 默认 session 的 urlCache 为 nil
        let klineSession = KLineService.makeDefaultSession()
        assert(klineSession.configuration.urlCache == nil, "KLineService session must disable urlCache")
        assert(klineSession.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        // 3. 验证 TelegraphService 默认 session 的 urlCache 为 nil
        let telegraphSession = TelegraphService.makeDefaultSession()
        assert(telegraphSession.configuration.urlCache == nil, "TelegraphService session must disable urlCache")

        // 4. 验证 CacheManager 缓存读取与清理
        let sizeStringBefore = CacheManager.formattedCacheSize()
        print("Current cache size: \(sizeStringBefore)")
        CacheManager.clearCache()
        let sizeStringAfter = CacheManager.formattedCacheSize()
        print("Cache size after clear: \(sizeStringAfter)")

        // 5. 验证 QuoteService 正常工作（通过 fetchQuotes 发起请求）
        let quoteService = QuoteService()
        let testItems = [
            WatchItem(code: "SH000001", name: "上证指数", market: .cn)
        ]
        let quotes = try await quoteService.fetchQuotes(for: testItems, provider: .sina)
        assert(!quotes.isEmpty, "Quotes fetched successfully with ephemeral session")
        print("Quote fetch check passed. Quote: \(quotes[0].name) \(quotes[0].current)")

        print("All cache optimization checks passed successfully!")
    }
}
