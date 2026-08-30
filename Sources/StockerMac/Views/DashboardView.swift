import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var percentageSortMode: QuotePercentageSortMode
    @State private var watchlistSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            if store.showingPositionsOnly {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        SummaryCard(title: "持仓市值", value: Formatters.compact(store.summary.marketValue), subtitle: "跨市场未换汇", icon: "chart.pie.fill")
                        SummaryCard(title: "今日盈亏", value: Formatters.signed(store.summary.dayProfit), subtitle: "按最新涨跌额", icon: "sun.max.fill", trend: store.summary.dayProfit)
                        SummaryCard(title: "累计盈亏", value: Formatters.signed(store.summary.totalProfit), subtitle: "相对持仓成本", icon: "waveform.path.ecg", trend: store.summary.totalProfit)
                        SummaryCard(title: "持仓标的", value: "\(store.summary.positionCount)", subtitle: "当前持仓数量", icon: "briefcase.fill")
                    }
                    .padding(16)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(store.marketIndexRows) { row in
                        MarketIndexCard(row: row)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }

            Divider()

            if isShowingAllWatchlist {
                watchlistSearchField
                Divider()
            }

            if store.rows.isEmpty {
                if store.showingPositionsOnly {
                    ContentUnavailableView(
                        "还没有持仓",
                        systemImage: "briefcase",
                        description: Text("选择一只自选股并填写成本价和持仓数量")
                    )
                } else {
                    ContentUnavailableView("还没有自选股", systemImage: "star", description: Text("点击工具栏的 + 搜索并添加股票"))
                }
            } else if visibleRows.isEmpty {
                ContentUnavailableView.search(text: normalizedWatchlistSearchText)
            } else {
                QuoteTable(rows: visibleRows, percentageSortMode: $percentageSortMode)
            }
        }
        .navigationTitle(store.selectedCollectionTitle)
        .onChange(of: isShowingAllWatchlist) { _, isShowing in
            if !isShowing {
                watchlistSearchText = ""
            }
        }
    }

    private var watchlistSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索自选股名称或代码", text: $watchlistSearchText)
                .textFieldStyle(.plain)
            if !watchlistSearchText.isEmpty {
                Button {
                    watchlistSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isShowingAllWatchlist: Bool {
        store.selectedMarket == nil
            && !store.showingPositionsOnly
            && !store.showingUngroupedOnly
            && store.selectedGroupID == nil
    }

    private var normalizedWatchlistSearchText: String {
        watchlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleRows: [QuoteRow] {
        guard isShowingAllWatchlist, !normalizedWatchlistSearchText.isEmpty else {
            return store.rows
        }
        return store.rows.filter { row in
            row.displayName.localizedCaseInsensitiveContains(normalizedWatchlistSearchText)
                || row.item.code.localizedCaseInsensitiveContains(normalizedWatchlistSearchText)
        }
    }
}

private struct MarketIndexCard: View {
    let row: QuoteRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(StockerTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(StockerTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(row.item.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if row.quote != nil {
                TrendText(value: row.percentage, text: Formatters.price(row.current))
                    .font(.headline.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                TrendText(
                    value: row.percentage,
                    text: "\(Formatters.signed(row.change))  \(Formatters.percent(row.percentage))"
                )
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 35, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stockerCard(padding: 10)
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
    let rows: [QuoteRow]
    @Binding var percentageSortMode: QuotePercentageSortMode

    private var sortedRows: [QuoteRow] {
        percentageSortMode.sorted(rows)
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = QuoteTableColumnWidths(
                total: max(620, geometry.size.width - 40),
                includesPositions: store.showingPositionsOnly,
                includesSubgroups: store.selectedGroupID != nil
            )

            ScrollView {
                // 用 VStack（非 LazyVStack）：窗口隐藏/恢复后 LazyVStack 懒加载会失效导致列表空白
                VStack(spacing: 0) {
                    quoteTableHeader(widths: widths)
                    ForEach(Array(sortedRows.enumerated()), id: \.element.id) { index, row in
                        quoteTableRow(row, index: index, widths: widths)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func quoteTableHeader(widths: QuoteTableColumnWidths) -> some View {
        HStack(spacing: 0) {
            Text("股票")
                .frame(width: widths.stock, alignment: .leading)
            Text("现价")
                .frame(width: widths.price, alignment: .leading)
            QuotePercentageSortMenu(
                selection: $percentageSortMode,
                title: "涨跌幅"
            )
            .frame(width: widths.change, alignment: .leading)
            if store.selectedGroupID != nil {
                Text("所属细分")
                    .frame(width: widths.subgroup, alignment: .leading)
            }
            if store.showingPositionsOnly {
                Text("持仓市值")
                    .frame(width: widths.marketValue, alignment: .leading)
                Text("盈亏")
                    .frame(width: widths.profit, alignment: .leading)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.65)
        }
    }

    private func quoteTableRow(
        _ row: QuoteRow,
        index: Int,
        widths: QuoteTableColumnWidths
    ) -> some View {
        let isSelected = store.selectedID == row.id

        return Button {
            store.selectedID = row.id
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.displayName).fontWeight(.semibold).lineLimit(1)
                    Text("\(row.item.code) · \(row.item.market.shortTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: widths.stock, alignment: .leading)

                Group {
                    if let quote = row.quote {
                        TrendText(
                            value: quote.percentage,
                            text: Formatters.price(quote.current)
                        )
                        .fontWeight(.medium)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .monospacedDigit()
                .frame(width: widths.price, alignment: .leading)

                Group {
                    if row.quote != nil {
                        TrendText(
                            value: row.percentage,
                            text: Formatters.percent(row.percentage)
                        )
                        .fontWeight(.semibold)
                    } else {
                        Text("-").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .frame(width: widths.change, alignment: .leading)

                if store.selectedGroupID != nil {
                    let subgroupText = subgroupNames(for: row.id).joined(separator: "、")
                    Text(subgroupText.isEmpty ? "-" : subgroupText)
                        .font(.caption)
                        .foregroundStyle(subgroupText.isEmpty ? Color.secondary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: widths.subgroup, alignment: .leading)
                        .help(subgroupText)
                }

                if store.showingPositionsOnly {
                    Text(Formatters.compact(row.marketValue))
                        .monospacedDigit()
                        .frame(width: widths.marketValue, alignment: .leading)

                    Group {
                        TrendText(
                            value: row.totalProfit,
                            text: Formatters.signed(row.totalProfit)
                        )
                    }
                    .monospacedDigit()
                    .frame(width: widths.profit, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(
                isSelected
                    ? StockerTheme.accent.opacity(0.09)
                    : (index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.018))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(StockerTheme.accent)
                        .frame(width: 3, height: 30)
                        .padding(.leading, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !store.groupSections.isEmpty {
                Menu("加入分组") {
                    ForEach(store.groupSections) { section in
                        if section.children.isEmpty {
                            membershipToggle(section.group, itemID: row.id)
                        } else {
                            Menu(section.group.name) {
                                membershipToggle(section.group, itemID: row.id)
                                ForEach(section.children) { child in
                                    membershipToggle(child, itemID: row.id)
                                }
                            }
                        }
                    }
                }
                Divider()
            }
            Button("删除自选", role: .destructive) {
                store.remove(row.id)
            }
        }
    }

    @ViewBuilder
    private func membershipToggle(_ group: StockGroup, itemID: String) -> some View {
        Button {
            store.toggleMembership(itemID: itemID, groupID: group.id)
        } label: {
            Label(
                group.name,
                systemImage: store.belongsToGroup(itemID: itemID, groupID: group.id) ? "checkmark" : "folder"
            )
        }
    }

    /// 当前分组上下文（选中二级时以其父级为范围）下，该股票所属的二级分组名。
    private func subgroupNames(for itemID: String) -> [String] {
        guard let selectedGroupID = store.selectedGroupID else { return [] }
        let primaryID = store.parentGroup(of: selectedGroupID)?.id ?? selectedGroupID
        return store.subgroupNames(for: itemID, underPrimary: primaryID)
    }
}

private struct QuoteTableColumnWidths {
    let stock: CGFloat
    let price: CGFloat
    let change: CGFloat
    let subgroup: CGFloat
    let marketValue: CGFloat
    let profit: CGFloat

    init(total: CGFloat, includesPositions: Bool, includesSubgroups: Bool = false) {
        if includesPositions {
            stock = total * 0.34
            price = total * 0.16
            change = total * 0.18
            marketValue = total * 0.17
            profit = total - stock - price - change - marketValue
            subgroup = 0
        } else if includesSubgroups {
            stock = total * 0.34
            price = total * 0.18
            change = total * 0.18
            subgroup = total - stock - price - change
            marketValue = 0
            profit = 0
        } else {
            stock = total * 0.42
            price = total * 0.24
            change = total - stock - price
            subgroup = 0
            marketValue = 0
            profit = 0
        }
    }
}
