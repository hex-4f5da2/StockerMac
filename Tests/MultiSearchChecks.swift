import Foundation

@main
enum MultiSearchChecks {
    static func main() async throws {
        let service = QuoteService()
        let expectations: [(String, String)] = [
            ("600000", "cn:SH600000"),
            ("00700", "hk:00700"),
            ("AAPL", "us:AAPL")
        ]

        for (keyword, expectedID) in expectations {
            let results = try await service.search(keyword, provider: .tencent)
            precondition(results.contains(where: { $0.id == expectedID }), "Missing \(expectedID) for \(keyword)")
        }
        print("Multi-search checks passed: CN/HK/US comma-separated keywords")
    }
}
