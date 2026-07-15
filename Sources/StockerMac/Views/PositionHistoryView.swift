import SwiftUI

struct PositionHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.positionHistory.isEmpty {
                    ContentUnavailableView(
                        "还没有清仓历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("清仓后，持仓成本、数量、清仓价和时间会保存在这里。")
                    )
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Label("共 \(store.positionHistory.count) 条记录", systemImage: "archivebox")
                            Spacer()
                            Text("历史记录仅保存在本机")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(16)

                        Divider()

                        Table(store.positionHistory) {
                            TableColumn("股票") { record in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.displayName).fontWeight(.semibold).lineLimit(1)
                                    Text("\(record.code) · \(record.market.shortTitle)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .width(min: 130, ideal: 170)

                            TableColumn("清仓时间") { record in
                                Text(record.closedAt.formatted(date: .abbreviated, time: .shortened))
                                    .monospacedDigit()
                            }
                            .width(min: 135, ideal: 155)

                            TableColumn("成本价") { record in
                                Text(Formatters.price(record.costPrice)).monospacedDigit()
                            }
                            .width(min: 70, ideal: 85)

                            TableColumn("数量") { record in
                                Text(record.quantity.formatted(.number.precision(.fractionLength(0...4))))
                                    .monospacedDigit()
                            }
                            .width(min: 65, ideal: 80)

                            TableColumn("清仓价") { record in
                                Text(record.closedPrice.map(Formatters.price) ?? "—")
                                    .monospacedDigit()
                                    .foregroundStyle(record.closedPrice == nil ? .secondary : .primary)
                            }
                            .width(min: 70, ideal: 85)

                            TableColumn("盈亏") { record in
                                if let profit = record.profit {
                                    TrendText(value: profit, text: Formatters.signed(profit))
                                } else {
                                    Text("—").foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 75, ideal: 95)
                        }
                        .alternatingRowBackgrounds(.enabled)
                    }
                }
            }
            .navigationTitle("清仓历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }
}
