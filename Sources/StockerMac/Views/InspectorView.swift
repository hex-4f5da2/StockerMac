import SwiftUI

struct InspectorView: View {
    let row: QuoteRow?
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var costText = ""
    @State private var quantityText = ""
    @State private var priceAlertText = ""
    @State private var isConfirmingClearPosition = false

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(row)
                        if let quote = row.quote {
                            sessionCard(quote)
                        }
                        positionCard(row)
                        priceAlertCard(row)
                        groupCard(row)
                        if let quote = row.quote { updateInfo(quote) }
                    }
                    .padding(18)
                }
                .onAppear { syncInputs(row) }
                .onChange(of: row.item) { _, _ in syncInputs(row) }
            } else {
                ContentUnavailableView("选择一只股票", systemImage: "cursorarrow.click.2", description: Text("查看价格区间并编辑持仓"))
            }
        }
        .alert("确认清仓 \(row?.displayName ?? "当前股票")？", isPresented: $isConfirmingClearPosition) {
            Button("取消", role: .cancel) {}
            Button("清仓", role: .destructive) {
                if let row { store.clearPosition(id: row.id) }
            }
        } message: {
            Text("只会结清这只股票的持仓，自选和分组不会删除，本次持仓数据会保存到清仓历史。")
        }
    }

    private func header(_ row: QuoteRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.item.market.shortTitle).font(.caption.bold()).foregroundStyle(StockerTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StockerTheme.accent.opacity(0.12), in: Capsule())
                Spacer()
                Button {
                    openWindow(id: "kline", value: KLineRoute(item: row.item))
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .buttonStyle(.plain)
                .help("查看 K 线")
                Button(role: .destructive) { store.remove(row.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("删除自选")
            }
            Text(row.displayName).font(.title2.bold())
            Text(row.item.code).font(.callout).foregroundStyle(.secondary)
            if let quote = row.quote {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TrendText(value: quote.percentage, text: Formatters.price(quote.current)).font(.largeTitle.bold())
                    TrendText(value: quote.percentage, text: "\(Formatters.signed(quote.change))  \(Formatters.percent(quote.percentage))")
                }
            } else if store.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("价格刷新中…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Label("价格暂不可用", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionCard(_ quote: Quote) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今日价格").font(.headline)
            if quote.high > quote.low {
                GeometryReader { proxy in
                    let progress = max(0, min(1, (quote.current - quote.low) / (quote.high - quote.low)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 7)
                        Capsule().fill(StockerTheme.accent).frame(width: max(7, proxy.size.width * progress), height: 7)
                    }
                }
                .frame(height: 8)
            }
            HStack {
                Stat(label: "最低", value: Formatters.price(quote.low))
                Spacer()
                Stat(label: "开盘", value: Formatters.price(quote.opening))
                Spacer()
                Stat(label: "最高", value: Formatters.price(quote.high), alignment: .trailing)
            }
        }
        .stockerCard()
    }

    private func positionCard(_ row: QuoteRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("我的持仓").font(.headline)
                Spacer()
                if row.hasPosition { Text(row.item.market.currency).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                TextField("成本价", text: $costText).textFieldStyle(.roundedBorder)
                TextField("数量", text: $quantityText).textFieldStyle(.roundedBorder)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计盈亏").font(.caption).foregroundStyle(.secondary)
                    TrendText(value: row.totalProfit, text: Formatters.signed(row.totalProfit)).font(.headline)
                }
                Spacer()
                if row.hasPosition {
                    Button("清仓", role: .destructive) {
                        isConfirmingClearPosition = true
                    }
                }
                Button("保存") {
                    store.updatePosition(
                        id: row.id,
                        costPrice: Double(costText) ?? 0,
                        quantity: Double(quantityText) ?? 0
                    )
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .stockerCard()
    }

    private func groupCard(_ row: QuoteRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("所属分组").font(.headline)
                Spacer()
                Text(store.groupIDs(for: row.id).isEmpty ? "未分组" : "已加入 \(store.groupIDs(for: row.id).count) 个")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.groups.isEmpty {
                Label("在左侧边栏点击 + 新建分组", systemImage: "folder.badge.plus")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(store.groups) { group in
                        Toggle(isOn: Binding(
                            get: { store.belongsToGroup(itemID: row.id, groupID: group.id) },
                            set: { _ in store.toggleMembership(itemID: row.id, groupID: group.id) }
                        )) {
                            Text(group.name)
                                .lineLimit(1)
                                .help(group.name)
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .stockerCard()
    }

    private func priceAlertCard(_ row: QuoteRow) -> some View {
        let activeAlert = store.priceAlert(for: row.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("价格提醒").font(.headline)
                Spacer()
                Text("仅当日有效").font(.caption).foregroundStyle(.secondary)
            }
            if let activeAlert {
                Label(
                    "\(activeAlert.direction.title) \(Formatters.price(activeAlert.targetPrice)) 时通知",
                    systemImage: "bell.fill"
                )
                .font(.callout)
                .foregroundStyle(StockerTheme.accent)
            }
            HStack {
                TextField("输入目标价格", text: $priceAlertText)
                    .textFieldStyle(.roundedBorder)
                if activeAlert != nil {
                    Button("清除") {
                        store.clearPriceAlert(itemID: row.id)
                        priceAlertText = ""
                    }
                }
                Button(activeAlert == nil ? "设置提醒" : "更新提醒") {
                    if let target = Double(priceAlertText),
                       store.setPriceAlert(itemID: row.id, targetPrice: target) {
                        syncAlertInput(row)
                    }
                }
                .disabled(!canSetPriceAlert(for: row))
            }
            Text("将根据当前价自动设置为“涨到”或“跌到”，触发一次后自动清除。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .stockerCard()
    }

    private func updateInfo(_ quote: Quote) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text("行情时间 \(quote.updatedAt)")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func syncInputs(_ row: QuoteRow) {
        costText = row.item.costPrice == 0 ? "" : String(row.item.costPrice)
        quantityText = row.item.quantity == 0 ? "" : String(row.item.quantity)
        syncAlertInput(row)
    }

    private func syncAlertInput(_ row: QuoteRow) {
        priceAlertText = store.priceAlert(for: row.id).map { String($0.targetPrice) } ?? ""
    }

    private func canSetPriceAlert(for row: QuoteRow) -> Bool {
        guard let target = Double(priceAlertText), let current = row.quote?.current else { return false }
        return AlertRules.priceDirection(currentPrice: current, targetPrice: target) != nil
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}
