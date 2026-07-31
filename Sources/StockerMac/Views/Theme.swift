import SwiftUI

enum StockerTheme {
    static let accent = Color(red: 0.27, green: 0.53, blue: 0.96)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color(nsColor: .separatorColor).opacity(0.55)
}

extension View {
    func stockerCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(StockerTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(StockerTheme.subtle, lineWidth: 0.7)
            }
    }
}

struct TrendText: View {
    let value: Double
    let text: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(Color.stockerTrend(value, preference: store.colorPreference))
    }
}

extension Color {
    static func stockerTrend(_ value: Double, preference: ColorSchemePreference) -> Color {
        guard preference != .monochrome else { return .primary }
        if value == 0 { return .secondary }
        let up: Color = preference == .redUp ? .red : .green
        let down: Color = preference == .redUp ? .green : .red
        return value > 0 ? up : down
    }
}

enum Formatters {
    static func price(_ value: Double) -> String {
        if value >= 1000 {
            return value.formatted(.number.precision(.fractionLength(2)))
        }
        return value.formatted(.number.precision(.fractionLength(2...4)))
    }

    static func signed(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(2)))
    }

    static func percent(_ value: Double) -> String { signed(value) + "%" }

    static func unsignedPercent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "%"
    }

    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(2)))
    }
}
