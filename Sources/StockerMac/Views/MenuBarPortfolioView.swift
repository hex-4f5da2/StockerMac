import SwiftUI

struct MenuBarPortfolioView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if store.positionRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "briefcase")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("还没有持仓").font(.headline)
                    Text("在主窗口填写成本价和持仓数量后，\n这里会显示实时行情。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("股票").frame(width: 142, alignment: .leading)
                        Text("现价").frame(width: 78, alignment: .leading)
                        Text("涨跌幅").frame(width: 74, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.positionRows) { row in
                                PositionTickerRow(row: row)
                                if row.id != store.positionRows.last?.id { Divider().padding(.leading, 14) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }

            Divider()

            HStack {
                Circle()
                    .fill(store.isAutoRefreshEnabled ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.isAutoRefreshEnabled ? "每 \(Int(store.refreshInterval)) 秒自动更新" : "自动刷新已暂停")
                Spacer()
                Text(store.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "等待更新")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 360)
        .task { store.start() }
    }
}

private struct PositionTickerRow: View {
    let row: QuoteRow

    var body: some View {
        HStack(spacing: 10) {
            Text(row.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 142, alignment: .leading)

            if row.quote == nil {
                ProgressView().controlSize(.small).frame(width: 162, alignment: .leading)
            } else {
                TrendText(value: row.percentage, text: Formatters.price(row.current))
                    .fontWeight(.medium).frame(width: 78, alignment: .leading)
                TrendText(value: row.percentage, text: Formatters.percent(row.percentage))
                    .fontWeight(.semibold).frame(width: 74, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
