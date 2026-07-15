import Foundation

enum QuoteParser {
    static func parse(_ response: String, provider: QuoteProvider, market: Market) -> [Quote] {
        switch provider {
        case .sina: parseSina(response, market: market)
        case .tencent: parseTencent(response, market: market)
        }
    }

    static func parseSina(_ response: String, market: Market) -> [Quote] {
        response.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let equal = line.firstIndex(of: "="),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else { return nil }

            let variable = String(line[line.index(line.startIndex, offsetBy: 11)..<equal])
            let payload = String(line[line.index(after: firstQuote)..<lastQuote])
            let fields = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

            switch market {
            case .cn:
                guard fields.count >= 32 else { return nil }
                return makeQuote(
                    code: variable.uppercased(), name: fields[0], market: market,
                    current: number(fields[3]), opening: number(fields[1]), close: number(fields[2]),
                    high: number(fields[4]), low: number(fields[5]),
                    percentage: nil, updatedAt: "\(fields[30]) \(fields[31])"
                )
            case .hk:
                guard fields.count >= 19 else { return nil }
                return makeQuote(
                    code: String(variable.dropFirst(2)).uppercased(), name: fields[1], market: market,
                    current: number(fields[6]), opening: number(fields[2]), close: number(fields[3]),
                    high: number(fields[4]), low: number(fields[5]),
                    percentage: number(fields[8]), updatedAt: "\(fields[17]) \(fields[18])"
                )
            case .us:
                guard fields.count >= 27 else { return nil }
                return makeQuote(
                    code: String(variable.dropFirst(3)).uppercased(), name: fields[0], market: market,
                    current: number(fields[1]), opening: number(fields[5]), close: number(fields[26]),
                    high: number(fields[6]), low: number(fields[7]),
                    percentage: number(fields[2]), updatedAt: fields[3]
                )
            }
        }
    }

    static func parseTencent(_ response: String, market: Market) -> [Quote] {
        response.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let equal = line.firstIndex(of: "="),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else { return nil }

            let variable = String(line[line.index(line.startIndex, offsetBy: 2)..<equal])
            let payload = String(line[line.index(after: firstQuote)..<lastQuote])
            let fields = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 35 else { return nil }

            let code: String
            switch market {
            case .cn: code = variable.uppercased()
            case .hk: code = String(variable.dropFirst(2)).uppercased()
            case .us: code = String(variable.dropFirst(2)).uppercased()
            }

            return makeQuote(
                code: code, name: fields[1], market: market,
                current: number(fields[3]), opening: number(fields[5]), close: number(fields[4]),
                high: number(fields[33]), low: number(fields[34]),
                percentage: number(fields[32]), updatedAt: fields[30]
            )
        }
    }

    private static func makeQuote(
        code: String, name: String, market: Market,
        current: Double, opening: Double, close: Double,
        high: Double, low: Double, percentage: Double?, updatedAt: String
    ) -> Quote? {
        guard current.isFinite, current > 0, close.isFinite, !code.isEmpty, !name.isEmpty else { return nil }
        let change = rounded(current - close)
        let computedPercentage = close == 0 ? 0 : rounded((current - close) / close * 100)
        return Quote(
            code: code, name: name, market: market,
            current: current, opening: opening, close: close, low: low, high: high,
            change: change, percentage: rounded(percentage ?? computedPercentage), updatedAt: updatedAt
        )
    }

    private static func number(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "--", trimmed != "-" else { return 0 }
        return Double(trimmed) ?? 0
    }

    private static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 100).rounded() / 100
    }
}
