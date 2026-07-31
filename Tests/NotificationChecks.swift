import Foundation

@main
enum NotificationChecks {
    static func main() throws {
        precondition(AlertRules.priceDirection(currentPrice: 100, targetPrice: 105) == .risesTo)
        precondition(AlertRules.priceDirection(currentPrice: 100, targetPrice: 95) == .fallsTo)
        precondition(AlertRules.priceDirection(currentPrice: 100, targetPrice: 100) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = AlertRules.endOfDay(containing: now, calendar: calendar)
        let priceAlert = StockPriceAlert(
            itemID: "us:AAPL",
            targetPrice: 105,
            direction: .risesTo,
            createdAt: now,
            expiresAt: expiry
        )
        precondition(!priceAlert.isTriggered(by: 104.99))
        precondition(priceAlert.isTriggered(by: 105))
        precondition(priceAlert.isValid(at: expiry.addingTimeInterval(-1)))
        precondition(!priceAlert.isValid(at: expiry))

        let groupAlert = GroupAverageAlert(
            groupID: UUID(),
            referencePercentage: 0.35,
            updatedAt: now
        )
        precondition(groupAlert.movement(from: 1.34) == nil)
        precondition(groupAlert.movement(from: 1.35) == 1)
        precondition(groupAlert.movement(from: -0.65) == -1)

        let restored = try JSONDecoder().decode(
            StockPriceAlert.self,
            from: JSONEncoder().encode(priceAlert)
        )
        precondition(restored == priceAlert)
        print("Notification checks passed: direction, threshold, expiry and persistence")
    }
}
