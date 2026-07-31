import Foundation

@main
enum QuoteSortingChecks {
    static func main() {
        let originalRows = [
            row(code: "A", percentage: 1.2),
            row(code: "B", percentage: nil),
            row(code: "C", percentage: -2.5),
            row(code: "D", percentage: 1.2)
        ]

        precondition(
            QuotePercentageSortMode.original.sorted(originalRows).map(\.item.code)
                == ["A", "B", "C", "D"]
        )
        precondition(
            QuotePercentageSortMode.gainersFirst.sorted(originalRows).map(\.item.code)
                == ["A", "D", "C", "B"]
        )
        precondition(
            QuotePercentageSortMode.declinersFirst.sorted(originalRows).map(\.item.code)
                == ["C", "A", "D", "B"]
        )

        let refreshedRows = [
            row(code: "A", percentage: -3.0),
            row(code: "B", percentage: 2.0),
            row(code: "C", percentage: -1.0),
            row(code: "D", percentage: 0.5)
        ]
        precondition(
            QuotePercentageSortMode.gainersFirst.sorted(refreshedRows).map(\.item.code)
                == ["B", "D", "C", "A"]
        )

        print("Quote sorting checks passed: original order, stable ties, missing quotes and live updates")
    }

    private static func row(code: String, percentage: Double?) -> QuoteRow {
        let item = WatchItem(code: code, name: code, market: .us)
        let quote = percentage.map {
            Quote(
                code: code,
                name: code,
                market: .us,
                current: 100,
                opening: 100,
                close: 100,
                low: 100,
                high: 100,
                change: $0,
                percentage: $0,
                updatedAt: ""
            )
        }
        return QuoteRow(item: item, quote: quote)
    }
}
