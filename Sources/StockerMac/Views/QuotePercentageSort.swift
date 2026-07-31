import SwiftUI

enum QuotePercentageSortMode: String, CaseIterable, Identifiable {
    case original
    case gainersFirst
    case declinersFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "原顺序"
        case .gainersFirst: "涨幅优先"
        case .declinersFirst: "跌幅优先"
        }
    }

    var menuTitle: String {
        self == .original ? "取消排序（原顺序）" : title
    }

    var systemImage: String {
        switch self {
        case .original: "arrow.up.arrow.down"
        case .gainersFirst: "arrow.down"
        case .declinersFirst: "arrow.up"
        }
    }

    func sorted(_ rows: [QuoteRow]) -> [QuoteRow] {
        guard self != .original else { return rows }

        return rows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.quote, rhs.element.quote) {
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case let (.some(lhsQuote), .some(rhsQuote)):
                guard lhsQuote.percentage != rhsQuote.percentage else {
                    return lhs.offset < rhs.offset
                }
                switch self {
                case .original:
                    return lhs.offset < rhs.offset
                case .gainersFirst:
                    return lhsQuote.percentage > rhsQuote.percentage
                case .declinersFirst:
                    return lhsQuote.percentage < rhsQuote.percentage
                }
            }
        }
        .map(\.element)
    }
}

struct QuotePercentageSortMenu: View {
    @Binding var selection: QuotePercentageSortMode
    var title = "涨跌幅"

    var body: some View {
        Menu {
            ForEach(QuotePercentageSortMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Label(
                        mode.menuTitle,
                        systemImage: selection == mode ? "checkmark" : mode.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: selection.systemImage)
                    .font(.caption2)
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("按最新涨跌幅实时排序；选择“取消排序”恢复原有顺序")
        .accessibilityLabel("涨跌幅排序")
        .accessibilityValue(selection.title)
    }
}
