import AppKit
import Charts
import SwiftUI

struct KLineWindowView: View {
    let itemID: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let row = store.allRows.first(where: { $0.id == itemID }) {
            KLineContentView(row: row)
                .id(row.id)
        } else {
            ContentUnavailableView(
                "股票已不在自选列表",
                systemImage: "chart.xyaxis.line",
                description: Text("请从主窗口重新选择一只股票")
            )
            .frame(minWidth: 720, minHeight: 500)
        }
    }
}

private struct KLineContentView: View {
    let row: QuoteRow
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: KLineViewModel
    @State private var selectedCandle: KLineCandle?
    @State private var scrollPosition = 0

    init(row: QuoteRow) {
        self.row = row
        _model = StateObject(wrappedValue: KLineViewModel(item: row.item))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !overviewMetrics.isEmpty {
                overviewGrid
            }
            Divider()
            controls
            content
            Divider()
            footer
        }
        .frame(
            minWidth: 720,
            minHeight: model.period == .day ? 620 : 500,
            alignment: .top
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.period) {
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(5, store.refreshInterval)))
                guard !Task.isCancelled,
                      store.isAutoRefreshEnabled,
                      MarketSession.isOpen(row.item.market) else { continue }
                await model.load()
            }
        }
        .onChange(of: model.candles) { _, candles in
            selectedCandle = nil
            scrollPosition = model.period.usesTradingDayAxis || model.period == .fiveDay
                ? 0
                : max(0, candles.count - visibleCandleCount)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(row.item.market.shortTitle)
                .font(.caption.bold())
                .foregroundStyle(StockerTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(StockerTheme.accent.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(row.item.code)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            if let quote = row.quote {
                VStack(alignment: .trailing, spacing: 3) {
                    TrendText(value: quote.percentage, text: Formatters.price(quote.current))
                        .font(.title.bold())
                    TrendText(
                        value: quote.percentage,
                        text: "\(Formatters.signed(quote.change))  \(Formatters.percent(quote.percentage))"
                    )
                    .font(.callout.weight(.medium))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                Picker("周期", selection: Binding(
                    get: { model.period },
                    set: { model.select($0) }
                )) {
                    ForEach(model.availablePeriods) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: max(90, CGFloat(model.availablePeriods.count) * 68))
            }

            if row.item.market != .cn {
                Text("分钟周期仅支持 A 股")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.period.usesDateOnly {
                Text("前复权")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await model.load() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.isRefreshing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var overviewGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 5),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(overviewMetrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(metric.trend.map {
                            Color.stockerTrend($0, preference: chartColorPreference)
                        } ?? .primary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.candles.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载 K 线…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.candles.isEmpty {
            ContentUnavailableView {
                Label(
                    model.errorMessage == nil ? "暂无 K 线数据" : "K 线加载失败",
                    systemImage: model.errorMessage == nil ? "chart.xyaxis.line" : "exclamationmark.triangle"
                )
            } description: {
                Text(model.errorMessage ?? "该股票在当前周期没有可显示的数据")
            } actions: {
                Button("重试") { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                candleSummary
                if model.period == .timeShare {
                    timeShareLegend
                }
                if model.period == .day {
                    movingAverageLegend
                }
                if let errorMessage = model.errorMessage {
                    errorBanner(errorMessage)
                }
                candleChart
                if model.period == .day {
                    macdLegend
                    macdChart
                    timelineNavigator
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var candleSummary: some View {
        let candle = selectedCandle ?? model.candles.last
        return HStack(spacing: 22) {
            if let candle {
                KLineStat(label: "时间", value: formattedTimestamp(candle.timestamp))
                KLineStat(label: "开", value: Formatters.price(candle.opening))
                KLineStat(label: "高", value: Formatters.price(candle.high))
                KLineStat(label: "低", value: Formatters.price(candle.low))
                KLineStat(label: "收", value: Formatters.price(candle.close))
                KLineStat(label: "成交量", value: Formatters.compact(candle.volume))
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text("\(message)，当前保留上一次数据")
            Spacer()
            Button("重试") { Task { await model.load() } }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var candleChart: some View {
        let referenceCandidate = model.overview?.previousClose ?? row.quote?.close ?? 0
        let intradayReference = model.period == .timeShare && referenceCandidate > 0
            ? referenceCandidate
            : nil
        let fixedPriceRange = intradayReference.map { reference in
            (reference * 0.9)...(reference * 1.1)
        }
        let metrics = ChartMetrics(
            candles: model.candles,
            fixedPriceRange: fixedPriceRange
        )
        let movingAverages = dayMovingAverages
        return Chart {
            ForEach(Array(model.candles.enumerated()), id: \.element.id) { index, candle in
                let xPosition = xPosition(for: candle, index: index)

                BarMark(
                    x: .value("交易位置", xPosition),
                    yStart: .value("成交量基线", metrics.volumeBase),
                    yEnd: .value("成交量", metrics.volumeY(candle.volume)),
                    width: .fixed(candleWidth)
                )
                .foregroundStyle(trendColor(for: candle).opacity(0.32))

                if model.period == .timeShare {
                    AreaMark(
                        x: .value("交易位置", xPosition),
                        yStart: .value("价格区域下沿", metrics.priceFloor),
                        yEnd: .value("价格", candle.close)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [chartAccentColor.opacity(0.34), chartAccentColor.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value("交易位置", xPosition),
                        y: .value("价格", candle.close),
                        series: .value("分时线", "价格")
                    )
                    .foregroundStyle(chartAccentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)

                    if let averagePrice = candle.averagePrice {
                        LineMark(
                            x: .value("交易位置", xPosition),
                            y: .value("均价", averagePrice),
                            series: .value("分时线", "均价")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    }
                } else if model.period == .fiveDay {
                    LineMark(
                        x: .value("交易位置", xPosition),
                        y: .value("价格", candle.close),
                        series: .value("五日线", "价格")
                    )
                    .foregroundStyle(chartAccentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                } else {
                    RuleMark(
                        x: .value("交易位置", xPosition),
                        yStart: .value("最低", candle.low),
                        yEnd: .value("最高", candle.high)
                    )
                    .foregroundStyle(trendColor(for: candle))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                    RectangleMark(
                        x: .value("交易位置", xPosition),
                        yStart: .value("实体下沿", min(candle.opening, candle.close)),
                        yEnd: .value(
                            "实体上沿",
                            max(candle.opening, candle.close) + (candle.opening == candle.close ? metrics.dojiHeight : 0)
                        ),
                        width: .fixed(candleWidth)
                    )
                    .foregroundStyle(trendColor(for: candle))
                }
            }

            if model.period == .day {
                ForEach(movingAverages) { average in
                    ForEach(average.points) { point in
                        LineMark(
                            x: .value("交易位置", point.index),
                            y: .value(average.title, point.value),
                            series: .value("均线", average.title)
                        )
                        .foregroundStyle(average.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.25))
                        .interpolationMethod(.linear)
                    }
                }
            }

            RuleMark(y: .value("成交量分隔", metrics.volumeDivider))
                .foregroundStyle(.secondary.opacity(0.28))
                .lineStyle(StrokeStyle(lineWidth: 0.7))
                .annotation(position: .bottom, alignment: .leading) {
                    Text("成交量")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            if let current = row.quote?.current, current > 0 {
                RuleMark(y: .value("现价", current))
                    .foregroundStyle(chartAccentColor.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .trailing, alignment: .center) {
                        Text(Formatters.price(current))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(chartAccentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.background, in: Capsule())
                    }
            }

            if let intradayReference {
                RuleMark(y: .value("昨收", intradayReference))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            if let selectedXPosition {
                RuleMark(x: .value("选中位置", selectedXPosition))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: 0...xDomainUpperBound)
        .chartYScale(domain: metrics.volumeBase...metrics.priceCeiling)
        .chartYAxis {
            if let intradayReference {
                AxisMarks(position: .leading, values: metrics.priceAxisValues) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                    AxisTick()
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(Formatters.price(price))
                        }
                    }
                }
                AxisMarks(position: .trailing, values: metrics.priceAxisValues) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(intradayPercentageLabel(
                                price: price,
                                reference: intradayReference
                            ))
                        }
                    }
                }
            } else {
                AxisMarks(position: .trailing, values: metrics.priceAxisValues) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                    AxisTick()
                    AxisValueLabel()
                }
            }
        }
        .chartXAxis {
            if model.period.usesTradingDayAxis {
                AxisMarks(values: IntradayTradingAxis.tickValues) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisTick()
                    AxisValueLabel {
                        if let position = value.as(Int.self) {
                            Text(IntradayTradingAxis.label(at: position))
                                .offset(x: position == IntradayTradingAxis.upperBound ? -18 : 0)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisTick()
                    AxisValueLabel {
                        if let index = value.as(Int.self),
                           model.candles.indices.contains(index) {
                            Text(axisLabel(model.candles[index].timestamp))
                        }
                    }
                }
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleCandleSpan)
        .chartScrollPosition(x: $scrollPosition)
        .scrollIndicators(.never, axes: .horizontal)
        .background(ChartHorizontalScrollerHider())
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let x = location.x - frame.origin.x
                            guard x >= 0, x <= frame.width,
                                  let index: Int = proxy.value(atX: x) else { return }
                            selectedCandle = candle(at: index)
                        case .ended:
                            selectedCandle = nil
                        }
                    }
            }
        }
        .frame(height: model.period == .day ? 245 : 330)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.displayName)\(model.period.title)行情图")
        .accessibilityValue(chartAccessibilitySummary)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("行情：腾讯财经")
            if row.item.market != .cn {
                Text("·")
                Label("可能存在延时", systemImage: "clock.badge.exclamationmark")
            }
            if let lastUpdated = model.lastUpdated {
                Text("· 更新于 \(lastUpdated.formatted(date: .omitted, time: .standard))")
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText).fontWeight(.medium)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var overviewMetrics: [OverviewMetric] {
        let quote = row.quote
        let previousClose = model.overview?.previousClose ?? quote?.close ?? 0
        let basic: [(String, Double)] = [
            ("今开", model.overview?.opening ?? quote?.opening ?? 0),
            ("昨收", previousClose),
            ("最高", model.overview?.high ?? quote?.high ?? 0),
            ("最低", model.overview?.low ?? quote?.low ?? 0)
        ]
        var metrics = basic.compactMap { label, value -> OverviewMetric? in
            guard value > 0 else { return nil }
            return OverviewMetric(
                label: label,
                value: Formatters.price(value),
                trend: label == "昨收" ? 0 : value - previousClose
            )
        }

        if let volume = model.overview?.volume {
            metrics.append(OverviewMetric(
                label: "成交量",
                value: formatVolume(volume),
                trend: nil
            ))
        }
        if let amount = model.overview?.amount {
            metrics.append(OverviewMetric(
                label: "成交额",
                value: formatLargeNumber(amount),
                trend: nil
            ))
        }
        if let turnoverRate = model.overview?.turnoverRate {
            metrics.append(OverviewMetric(
                label: "换手率",
                value: "\(Formatters.price(turnoverRate))%",
                trend: nil
            ))
        }
        if let priceEarningsRatio = model.overview?.priceEarningsRatio {
            metrics.append(OverviewMetric(
                label: "市盈率",
                value: Formatters.price(priceEarningsRatio),
                trend: nil
            ))
        }
        if let totalMarketValue = model.overview?.totalMarketValue {
            metrics.append(OverviewMetric(
                label: "总市值",
                value: formatLargeNumber(totalMarketValue),
                trend: nil
            ))
        }
        return metrics
    }

    private func formatVolume(_ volume: Double) -> String {
        if row.item.market == .cn {
            return "\(Formatters.price(volume / 10_000))万手"
        }
        return "\(Formatters.compact(volume))股"
    }

    private func formatLargeNumber(_ value: Double) -> String {
        if value >= 100_000_000 {
            return "\(Formatters.price(value / 100_000_000))亿"
        }
        if value >= 10_000 {
            return "\(Formatters.price(value / 10_000))万"
        }
        return Formatters.price(value)
    }

    private func intradayPercentageLabel(price: Double, reference: Double) -> String {
        guard reference > 0 else { return "0%" }
        let percentage = (price / reference - 1) * 100
        if abs(percentage) < 0.01 {
            return "0%"
        }
        return String(format: "%+.0f%%", percentage)
    }

    private var macdChart: some View {
        Chart {
            ForEach(macdPoints) { point in
                BarMark(
                    x: .value("交易位置", point.index),
                    yStart: .value("零轴", 0),
                    yEnd: .value("MACD", point.histogram),
                    width: .fixed(4)
                )
                .foregroundStyle(Color.stockerTrend(
                    point.histogram,
                    preference: chartColorPreference
                ).opacity(0.82))

                LineMark(
                    x: .value("交易位置", point.index),
                    y: .value("DIF", point.dif),
                    series: .value("MACD 线", "DIF")
                )
                .foregroundStyle(difColor)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("交易位置", point.index),
                    y: .value("DEA", point.dea),
                    series: .value("MACD 线", "DEA")
                )
                .foregroundStyle(deaColor)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.linear)
            }

            RuleMark(y: .value("零轴", 0))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 0.7))
        }
        .chartXScale(domain: 0...xDomainUpperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel()
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleCandleSpan)
        .chartScrollPosition(x: $scrollPosition)
        .scrollIndicators(.never, axes: .horizontal)
        .background(ChartHorizontalScrollerHider())
        .frame(height: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.displayName) MACD")
        .accessibilityValue(macdAccessibilitySummary)
    }

    private var timelineNavigator: some View {
        HStack(spacing: 10) {
            Text(timelineStartLabel)
                .frame(width: 58, alignment: .leading)

            Slider(
                value: timelineScrollBinding,
                in: 0...Double(max(1, maximumScrollPosition)),
                step: 1
            )
            .tint(StockerTheme.accent)
            .disabled(maximumScrollPosition == 0)
            .accessibilityLabel("日 K 时间轴")

            Text(timelineEndLabel)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }

    private var visibleCandleCount: Int {
        switch model.period {
        case .timeShare: 240
        case .fiveDay: 240
        case .oneMinute: 240
        case .fiveMinute: 48
        case .fifteenMinute: 16
        case .thirtyMinute: 8
        case .sixtyMinute: 4
        case .oneTwentyMinute: 2
        case .day: 60
        case .week: 52
        case .month: 60
        case .year: 10
        }
    }

    private var visibleCandleSpan: Int {
        if model.period.usesTradingDayAxis {
            return IntradayTradingAxis.upperBound
        }
        return max(1, min(visibleCandleCount, model.candles.count))
    }

    private var maximumScrollPosition: Int {
        max(0, model.candles.count - visibleCandleCount)
    }

    private var timelineScrollBinding: Binding<Double> {
        Binding(
            get: {
                Double(min(max(0, scrollPosition), maximumScrollPosition))
            },
            set: { value in
                scrollPosition = min(
                    maximumScrollPosition,
                    max(0, Int(value.rounded()))
                )
                selectedCandle = nil
            }
        )
    }

    private var timelineStartLabel: String {
        guard !model.candles.isEmpty else { return "" }
        return axisLabel(model.candles[visibleStartIndex].timestamp)
    }

    private var timelineEndLabel: String {
        guard !model.candles.isEmpty else { return "" }
        let endIndex = min(
            model.candles.count - 1,
            visibleStartIndex + visibleCandleCount - 1
        )
        return axisLabel(model.candles[endIndex].timestamp)
    }

    private var visibleStartIndex: Int {
        min(max(0, scrollPosition), maximumScrollPosition)
    }

    private var xDomainUpperBound: Int {
        model.period.usesTradingDayAxis
            ? IntradayTradingAxis.upperBound
            : max(1, model.candles.count - 1)
    }

    private var candleWidth: CGFloat {
        switch model.period {
        case .timeShare: 1
        case .fiveDay: 2
        case .oneMinute: 2
        case .fiveMinute: 7
        case .fifteenMinute: 10
        case .thirtyMinute: 14
        case .sixtyMinute: 18
        case .oneTwentyMinute: 24
        case .day, .week, .month, .year: 5
        }
    }

    private var statusText: String {
        if !store.isAutoRefreshEnabled { return "自动刷新已暂停" }
        if !MarketSession.isOpen(row.item.market) { return "非交易时段" }
        return "实时更新中"
    }

    private var chartAccessibilitySummary: String {
        guard let latest = model.candles.last else { return "暂无数据" }
        return "共 \(model.candles.count) 个数据点，最新价格 \(Formatters.price(latest.close))"
    }

    private var macdAccessibilitySummary: String {
        guard let latest = macdPoints.last else { return "暂无数据" }
        return "柱 \(Formatters.signed(latest.histogram))，DIF \(Formatters.signed(latest.dif))，DEA \(Formatters.signed(latest.dea))"
    }

    private var statusColor: Color {
        if !store.isAutoRefreshEnabled { return .orange }
        return MarketSession.isOpen(row.item.market) ? .green : .secondary
    }

    private func trendColor(for candle: KLineCandle) -> Color {
        .stockerTrend(candle.change, preference: chartColorPreference)
    }

    private var chartAccentColor: Color {
        StockerTheme.accent
    }

    private var chartColorPreference: ColorSchemePreference {
        store.colorPreference == .monochrome ? .redUp : store.colorPreference
    }

    private var selectedXPosition: Int? {
        guard let selectedCandle else { return nil }
        guard let index = model.candles.firstIndex(where: { $0.id == selectedCandle.id }) else {
            return nil
        }
        return xPosition(for: selectedCandle, index: index)
    }

    private var movingAverageLegend: some View {
        HStack(spacing: 18) {
            ForEach(dayMovingAverages) { average in
                if let latest = average.points.last?.value {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(average.color)
                            .frame(width: 7, height: 7)
                        Text("\(average.title) \(Formatters.price(latest))")
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private var macdLegend: some View {
        let latest = macdPoints.last
        return HStack(spacing: 16) {
            Text("MACD")
                .fontWeight(.semibold)
            if let latest {
                indicatorLegendItem(
                    title: "柱 \(Formatters.signed(latest.histogram))",
                    color: .stockerTrend(latest.histogram, preference: chartColorPreference)
                )
                indicatorLegendItem(
                    title: "DIF \(Formatters.signed(latest.dif))",
                    color: difColor
                )
                indicatorLegendItem(
                    title: "DEA \(Formatters.signed(latest.dea))",
                    color: deaColor
                )
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 5)
    }

    private func indicatorLegendItem(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title).monospacedDigit()
        }
    }

    private var timeShareLegend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 5) {
                Circle()
                    .fill(chartAccentColor)
                    .frame(width: 7, height: 7)
                Text("价格")
            }
            if let averagePrice = model.candles.last?.averagePrice {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                    Text("均价 \(Formatters.price(averagePrice))")
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private var dayMovingAverages: [MovingAverageLine] {
        guard model.period == .day else { return [] }
        let specifications: [(period: Int, color: Color)] = [
            (5, .orange),
            (10, .purple),
            (30, Color(red: 0.30, green: 0.47, blue: 0.98)),
            (60, Color(red: 0.08, green: 0.18, blue: 0.42))
        ]

        return specifications.map { specification in
            var rollingTotal = 0.0
            var points: [MovingAveragePoint] = []
            for index in model.candles.indices {
                rollingTotal += model.candles[index].close
                if index >= specification.period {
                    rollingTotal -= model.candles[index - specification.period].close
                }
                if index >= specification.period - 1 {
                    points.append(MovingAveragePoint(
                        index: index,
                        value: rollingTotal / Double(specification.period)
                    ))
                }
            }
            return MovingAverageLine(
                period: specification.period,
                color: specification.color,
                points: points
            )
        }
    }

    private var macdPoints: [MACDPoint] {
        guard model.period == .day else { return [] }
        let fastMultiplier = 2.0 / 13.0
        let slowMultiplier = 2.0 / 27.0
        let signalMultiplier = 2.0 / 10.0
        var fastEMA: Double?
        var slowEMA: Double?
        var signal = 0.0
        var points: [MACDPoint] = []

        for index in model.candles.indices {
            let close = model.candles[index].close
            fastEMA = fastEMA.map { close * fastMultiplier + $0 * (1 - fastMultiplier) } ?? close
            slowEMA = slowEMA.map { close * slowMultiplier + $0 * (1 - slowMultiplier) } ?? close
            let dif = (fastEMA ?? close) - (slowEMA ?? close)
            signal = index == 0 ? dif : dif * signalMultiplier + signal * (1 - signalMultiplier)
            points.append(MACDPoint(
                index: index,
                dif: dif,
                dea: signal,
                histogram: 2 * (dif - signal)
            ))
        }
        return points
    }

    private var difColor: Color {
        .orange
    }

    private var deaColor: Color {
        .cyan
    }

    private func candle(at position: Int) -> KLineCandle? {
        guard !model.candles.isEmpty else { return nil }
        return model.candles.enumerated().min {
            abs(xPosition(for: $0.element, index: $0.offset) - position)
                < abs(xPosition(for: $1.element, index: $1.offset) - position)
        }?.element
    }

    private func xPosition(for candle: KLineCandle, index: Int) -> Int {
        guard model.period.usesTradingDayAxis else { return index }
        return IntradayTradingAxis.position(for: candle.timestamp)
    }

    private func formattedTimestamp(_ date: Date) -> String {
        if model.period.usesDateOnly {
            return date.formatted(.dateTime.year().month().day())
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    private func axisLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }

}

private struct MovingAveragePoint: Identifiable {
    let index: Int
    let value: Double
    var id: Int { index }
}

private struct OverviewMetric: Identifiable {
    let label: String
    let value: String
    let trend: Double?
    var id: String { label }
}

private struct ChartHorizontalScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleUpdate(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleUpdate(from: nsView)
    }

    private func scheduleUpdate(from view: NSView) {
        DispatchQueue.main.async {
            hideHorizontalScrollers(near: view)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            hideHorizontalScrollers(near: view)
        }
    }

    private func hideHorizontalScrollers(near view: NSView) {
        var ancestor = view.superview
        for _ in 0..<5 {
            guard let current = ancestor else { return }
            let scrollViews = descendants(of: current).compactMap { $0 as? NSScrollView }
            if !scrollViews.isEmpty {
                for scrollView in scrollViews {
                    scrollView.hasHorizontalScroller = false
                    scrollView.horizontalScroller?.isHidden = true
                    scrollView.autohidesScrollers = true
                }
                return
            }
            ancestor = current.superview
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

private struct MACDPoint: Identifiable {
    let index: Int
    let dif: Double
    let dea: Double
    let histogram: Double
    var id: Int { index }
}

private struct MovingAverageLine: Identifiable {
    let period: Int
    let color: Color
    let points: [MovingAveragePoint]

    var id: Int { period }
    var title: String { "MA\(period)" }
}

private struct KLineStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

private struct ChartMetrics {
    let priceFloor: Double
    let volumeBase: Double
    let volumeDivider: Double
    let priceCeiling: Double
    let priceAxisValues: [Double]
    let dojiHeight: Double
    private let maxVolume: Double
    private let volumeHeight: Double

    init(
        candles: [KLineCandle],
        fixedPriceRange: ClosedRange<Double>? = nil
    ) {
        let minimum = fixedPriceRange?.lowerBound ?? candles.map(\.low).min() ?? 0
        let maximum = fixedPriceRange?.upperBound ?? candles.map(\.high).max() ?? 1
        let priceRange = max(maximum - minimum, maximum * 0.01, 0.01)
        priceFloor = minimum
        maxVolume = max(candles.map(\.volume).max() ?? 0, 1)
        volumeBase = minimum - priceRange * 0.34
        volumeDivider = minimum - priceRange * 0.06
        volumeHeight = priceRange * 0.24
        priceCeiling = maximum + priceRange * 0.06
        dojiHeight = priceRange * 0.002
        priceAxisValues = (0...4).map { minimum + priceRange * Double($0) / 4 }
    }

    func volumeY(_ volume: Double) -> Double {
        volumeBase + max(0, volume) / maxVolume * volumeHeight
    }
}
