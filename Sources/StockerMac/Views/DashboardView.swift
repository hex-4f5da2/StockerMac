import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SummaryCard(title: "持仓市值", value: Formatters.compact(store.summary.marketValue), subtitle: "跨市场未换汇", icon: "chart.pie.fill")
                    SummaryCard(title: "今日盈亏", value: Formatters.signed(store.summary.dayProfit), subtitle: "按最新涨跌额", icon: "sun.max.fill", trend: store.summary.dayProfit)
                    SummaryCard(title: "累计盈亏", value: Formatters.signed(store.summary.totalProfit), subtitle: "相对持仓成本", icon: "waveform.path.ecg", trend: store.summary.totalProfit)
                    SummaryCard(title: "持仓标的", value: "\(store.summary.positionCount)", subtitle: "共 \(store.rows.count) 只自选", icon: "briefcase.fill")
                }
                .padding(16)
            }

            Divider()

            if store.rows.isEmpty {
                ContentUnavailableView("还没有自选股", systemImage: "star", description: Text("点击工具栏的 + 搜索并添加股票"))
            } else {
                QuoteTable()
            }
        }
        .navigationTitle(store.selectedCollectionTitle)
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    var trend: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(StockerTheme.accent)
                .frame(width: 34, height: 34)
                .background(StockerTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let trend { TrendText(value: trend, text: value).font(.title3.bold()) }
                else { Text(value).font(.title3.bold()).monospacedDigit() }
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 142, alignment: .leading)
        .stockerCard()
    }
}

private struct QuoteTable: View {
    @EnvironmentObject private var store: AppStore
    @State private var sortOrder = [KeyPathComparator(\QuoteRow.displayName)]

    private var sortedRows: [QuoteRow] {
        store.rows.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedRows, selection: $store.selectedID, sortOrder: $sortOrder) {
            TableColumn("股票", value: \.displayName) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.displayName).fontWeight(.semibold).lineLimit(1)
                    Text("\(row.item.code) · \(row.item.market.shortTitle)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .contextMenu {
                    if !store.groups.isEmpty {
                        Menu("加入分组") {
                            ForEach(store.groups) { group in
                                Button {
                                    store.toggleMembership(itemID: row.id, groupID: group.id)
                                } label: {
                                    Label(group.name, systemImage: store.belongsToGroup(itemID: row.id, groupID: group.id) ? "checkmark" : "folder")
                                }
                            }
                        }
                        Divider()
                    }
                    Button("删除自选", role: .destructive) { store.remove(row.id) }
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn("现价", value: \.current) { row in
                if let quote = row.quote {
                    TrendText(value: quote.percentage, text: Formatters.price(quote.current)).fontWeight(.medium)
                } else { ProgressView().controlSize(.small) }
            }
            .width(min: 75, ideal: 90)

            TableColumn("涨跌幅", value: \.percentage) { row in
                TrendText(value: row.percentage, text: Formatters.percent(row.percentage))
                    .fontWeight(.semibold)
            }
            .width(min: 75, ideal: 85)

            TableColumn("持仓市值", value: \.marketValue) { row in
                Text(row.hasPosition ? Formatters.compact(row.marketValue) : "—")
                    .monospacedDigit().foregroundStyle(row.hasPosition ? .primary : .tertiary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("盈亏", value: \.totalProfit) { row in
                if row.hasPosition { TrendText(value: row.totalProfit, text: Formatters.signed(row.totalProfit)) }
                else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 75, ideal: 95)
        }
        .alternatingRowBackgrounds(.enabled)
    }
}
