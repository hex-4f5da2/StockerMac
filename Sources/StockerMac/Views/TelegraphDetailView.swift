import StockerCore
import SwiftUI

struct TelegraphDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var vm: TelegraphViewModel

    var body: some View {
        Group {
            if let message = vm.message(byID: vm.selectedMessageID ?? "") {
                detail(message)
            } else {
                ContentUnavailableView(
                    "选择一条电报",
                    systemImage: "newspaper",
                    description: Text("从左侧消息流中选择内容查看全文")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detail(_ message: TelegraphMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataHeader(message)

                Text(message.displayTitle)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !message.displayBody.isEmpty {
                    Text(message.displayBody)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if message.truncated {
                    Label("正文较长，当前内容已截断", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !message.stockList.isEmpty {
                    relatedStocks(message.stockList)
                }

                if !message.categories.isEmpty {
                    categorySection(message.categories)
                }

                if let url = message.url, let destination = URL(string: url) {
                    Divider()
                    Link(destination: destination) {
                        HStack {
                            Label("查看原文", systemImage: "safari")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(StockerTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Color.primary.opacity(0.012))
    }

    private func metadataHeader(_ message: TelegraphMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(message.source.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())

                if message.isRed {
                    Text("重要")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(StockerTheme.accent, in: Capsule())
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Label(fullTimeString(message.ctime), systemImage: "clock")
                if message.readingNum > 0 {
                    Label("\(message.readingNum) 阅读", systemImage: "eye")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func relatedStocks(_ stocks: [SecurityID]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Label("关联股票", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(stocks, id: \.rawValue) { security in
                    stockButton(security)
                }
            }
        }
    }

    private func stockButton(_ security: SecurityID) -> some View {
        let isInWatchlist = store.watchlistCodes.contains(security)
        return Button {
            if isInWatchlist {
                openQuote(security)
            } else {
                store.isSearchPresented = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isInWatchlist ? "star.fill" : "plus.circle")
                    .font(.caption2)
                Text(security.code)
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(StockerTheme.accent.opacity(isInWatchlist ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(isInWatchlist ? StockerTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
        .help(isInWatchlist ? "打开行情" : "添加到自选")
    }

    private func categorySection(_ categories: Set<TelegraphCategory>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容标签")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(TelegraphCategory.allCases.filter { categories.contains($0) }, id: \.self) { category in
                    Text(category.title)
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.065), in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func openQuote(_ security: SecurityID) {
        let market: Market
        switch security.market {
        case .cn: market = .cn
        case .hk: market = .hk
        case .us: market = .us
        }
        guard let item = store.items.first(where: { $0.market == market && $0.code == security.code }) else { return }
        store.selectAll()
        store.selectedMarket = market
        store.selectedID = item.id
    }

    private func fullTimeString(_ timeInterval: TimeInterval) -> String {
        Date(timeIntervalSince1970: timeInterval)
            .formatted(.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }
}
