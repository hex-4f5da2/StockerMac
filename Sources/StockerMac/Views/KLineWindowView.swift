import AppKit
import Charts
import SwiftUI

struct KLineWindowView: View {
    let route: KLineRoute
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let row = store.allRows.first(where: { $0.id == route.item.id })
            ?? QuoteRow(item: route.item, quote: nil)
        KLineContentView(row: row)
            .id(row.id)
    }
}

private struct KLineContentView: View {
    let row: QuoteRow
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: KLineViewModel
    @State private var selectedCandle: KLineCandle?
    @State private var scrollPosition = 0
    /// 区间涨幅：点击第一根设起点，再点一根设终点（或默认到最新）
    @State private var rangeStartIndex: Int?
    @State private var rangeEndIndex: Int?
    /// 日/周/月/年 K 可视蜡烛数（滚轮/触控板缩放，默认 50 根贴近主流软件观感）
    @State private var zoomedVisibleCount = 50.0
    @State private var klineWindow: NSWindow?
    @State private var zoomEventMonitor: Any?
    /// 主图区域全局 frame（缩放时以鼠标所在 K 线为锚点）
    @State private var chartGlobalFrame: CGRect = .zero
    /// 窗口每次创建时强制默认尺寸（macOS 会记忆旧 frame，覆盖 defaultSize）
    @State private var didApplyDefaultSize = false

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
            minWidth: 600,
            minHeight: model.period == .day ? 700 : 660,
            alignment: .top
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { window in
            klineWindow = window
            if !didApplyDefaultSize, let window {
                didApplyDefaultSize = true
                window.setContentSize(NSSize(width: 640, height: 700))
                // 等 SwiftUI 完成本轮窗口尺寸约束后再定位，避免窗口二次增高时向上漂移。
                DispatchQueue.main.async {
                    KLineWindowPlacement.place(window, centeredOver: MainWindowRegistry.window)
                }
            }
        })
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
            rangeStartIndex = nil
            rangeEndIndex = nil
            scrollPosition = model.period.usesTradingDayAxis || model.period == .fiveDay
                ? 0
                : max(0, candles.count - visibleCandleCount)
        }
        .onChange(of: model.period) { _, _ in
            zoomedVisibleCount = 50
        }
        .onAppear(perform: installZoomMonitor)
        .onDisappear(perform: removeZoomMonitor)
    }

    // MARK: 时间轴缩放（滚轮向上放大 / 向下缩小，触控板捏合缩放，以鼠标所在 K 线为锚点）

    private func installZoomMonitor() {
        guard zoomEventMonitor == nil else { return }
        zoomEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            // 仅日/周/月/年 K（非分时/分钟轴），且事件发生在本窗口
            guard !model.period.usesTradingDayAxis, event.window === klineWindow else { return event }
            // 鼠标所在 K 线作为缩放锚点（不在主图区域内时回退到可视区中心）
            let anchorIndex = candleIndexUnderMouse()
            if event.type == .scrollWheel, event.deltaY != 0 {
                applyZoom(factor: event.deltaY > 0 ? 0.88 : 1.12, anchorIndex: anchorIndex)
                return nil
            }
            if event.type == .magnify, event.magnification != 0 {
                applyZoom(factor: 1.0 / (1.0 + Double(event.magnification)), anchorIndex: anchorIndex)
                return nil
            }
            return event
        }
    }

    /// 鼠标当前位置对应的 K 线序号（chartGlobalFrame 为 top-left 全局坐标）
    private func candleIndexUnderMouse() -> Int? {
        guard !chartGlobalFrame.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation  // bottom-left 屏幕坐标
        guard let screen = klineWindow?.screen ?? NSScreen.main else { return nil }
        let globalPoint = CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)  // top-left
        guard chartGlobalFrame.contains(globalPoint) else { return nil }
        let ratio = (globalPoint.x - chartGlobalFrame.minX) / chartGlobalFrame.width
        return scrollPosition + Int(ratio * Double(visibleCandleCount))
    }

    /// 区间选择：第一次点击设起点，第二次点击设终点（自动按时间排序），再点起点取消
    private func handleRangeTap(at index: Int) {
        guard !model.period.usesTradingDayAxis else { return }
        guard model.candles.indices.contains(index) else { return }
        if let start = rangeStartIndex {
            if index == start {
                rangeStartIndex = nil
                rangeEndIndex = nil
            } else {
                rangeStartIndex = min(start, index)
                rangeEndIndex = max(start, index)
                selectedCandle = model.candles[max(start, index)]
            }
        } else {
            rangeStartIndex = index
            rangeEndIndex = nil
            selectedCandle = model.candles[index]
        }
    }

    private func removeZoomMonitor() {
        if let monitor = zoomEventMonitor {
            NSEvent.removeMonitor(monitor)
            zoomEventMonitor = nil
        }
    }

    /// 缩放并以选中/鼠标所在的 K 线为锚点（保持该根不动），范围 15...150 根
    private func applyZoom(factor: Double, anchorIndex: Int?) {
        let oldCount = Double(visibleCandleCount)
        let newCount = min(150, max(15, zoomedVisibleCount * factor))
        let anchor: Double
        // 优先以选中的 K 线作为锚点（chart proxy 取值精确，且区间选择后鼠标移开仍能保持居中）；
        // 否则回退到鼠标所在 K 线；最后回退到可视区中心。
        if let selected = selectedCandle,
           let selectedIndex = model.candles.firstIndex(where: { $0.id == selected.id }) {
            anchor = Double(selectedIndex)
        } else if let anchorIndex {
            anchor = Double(anchorIndex)
        } else {
            anchor = Double(scrollPosition) + oldCount / 2
        }
        let anchorOffset = min(1, max(0, (anchor - Double(scrollPosition)) / oldCount))
        zoomedVisibleCount = newCount
        let newStart = anchor - anchorOffset * newCount
        let maxScroll = max(0, model.candles.count - Int(newCount))
        scrollPosition = min(maxScroll, max(0, Int(newStart.rounded())))
        // 不清除 selectedCandle：保留选中，后续缩放始终以选中点为中心
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(row.item.market.shortTitle)
                .font(.caption.bold())
                .foregroundStyle(StockerTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StockerTheme.accent.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(row.item.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            if let quote = row.quote {
                VStack(alignment: .trailing, spacing: 2) {
                    TrendText(value: quote.percentage, text: Formatters.price(quote.current))
                        .font(.title3.bold())
                    TrendText(
                        value: quote.percentage,
                        text: "\(Formatters.signed(quote.change))  \(Formatters.percent(quote.percentage))"
                    )
                    .font(.caption.weight(.medium))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var overviewGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 5),
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(overviewMetrics) { metric in
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(metric.trend.map {
                            Color.stockerTrend($0, preference: chartColorPreference)
                        } ?? .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
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
                if let dayChange = dayChangePercent(for: candle) {
                    KLineStat(label: "涨跌幅", value: Formatters.percent(dayChange), trend: dayChange)
                }
                KLineStat(label: "成交量", value: Formatters.compact(candle.volume))
            }
            if let rangeInfo = selectedRangeInfo {
                Divider().frame(height: 22)
                KLineStat(
                    label: "区间涨幅",
                    value: Formatters.percent(rangeInfo.percentage),
                    trend: rangeInfo.percentage
                )
                Text("\(rangeInfo.startLabel) → \(rangeInfo.endLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    /// 区间涨幅：起点（前一根收盘或首根开盘）→ 终点收盘；未设终点时到最新一根
    private var selectedRangeInfo: (percentage: Double, startLabel: String, endLabel: String)? {
        guard let start = rangeStartIndex,
              model.candles.indices.contains(start) else { return nil }
        let end = min(rangeEndIndex ?? (model.candles.count - 1), model.candles.count - 1)
        guard end > start else { return nil }
        let startCandle = model.candles[start]
        let endCandle = model.candles[end]
        let base = start > 0 ? model.candles[start - 1].close : (startCandle.opening > 0 ? startCandle.opening : startCandle.close)
        guard base > 0 else { return nil }
        return (
            (endCandle.close / base - 1) * 100,
            axisLabel(startCandle.timestamp),
            axisLabel(endCandle.timestamp)
        )
    }

    /// 当日涨跌幅：相对前一根收盘（日/周/月/年周期有意义；分时/分钟周期按开收差）
    private func dayChangePercent(for candle: KLineCandle) -> Double? {
        if model.period.usesTradingDayAxis || model.period == .fiveDay {
            guard candle.opening > 0 else { return nil }
            return (candle.close / candle.opening - 1) * 100
        }
        guard let index = model.candles.firstIndex(where: { $0.id == candle.id }),
              index > 0,
              model.candles[index - 1].close > 0 else { return nil }
        return (candle.close / model.candles[index - 1].close - 1) * 100
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
        // 分时 y 轴动态高度：以昨收为中心，范围跟随当日高低点（上限为涨跌幅限制）
        // 波动大时自动放大、波动小时收紧，当日波动清晰可见
        let fixedPriceRange = intradayReference.map { reference in
            let limit = priceLimitPercent(for: row.item.code)
            let maxHalf = reference * limit
            let dayLow = model.candles.map(\.low).min() ?? reference
            let dayHigh = model.candles.map(\.high).max() ?? reference
            let deviation = max(abs(dayHigh - reference), abs(reference - dayLow))
            let half = min(maxHalf, max(deviation * 1.12, reference * 0.004))
            return (reference - half)...(reference + half)
        }
        let metrics = ChartMetrics(
            candles: model.candles,
            fixedPriceRange: fixedPriceRange
        )
        let movingAverages = dayMovingAverages
        return GeometryReader { geometry in
            let chartWidth = max(0, geometry.size.width)
            let candleWidth = candleWidth(chartWidth: chartWidth)
            // 主图高度固定 400pt：不随窗口宽度联动（否则拖宽窗口会导致窗口被撑大，frame 被记忆）
            let mainChartHeight = 400.0
            Chart {
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

            if let rangeStartIndex,
               model.candles.indices.contains(rangeStartIndex) {
                RuleMark(x: .value("区间起点", xPosition(for: model.candles[rangeStartIndex], index: rangeStartIndex)))
                    .foregroundStyle(.blue.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            if let rangeEndIndex,
               model.candles.indices.contains(rangeEndIndex) {
                RuleMark(x: .value("区间终点", xPosition(for: model.candles[rangeEndIndex], index: rangeEndIndex)))
                    .foregroundStyle(.blue.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
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
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
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
                    .onAppear { chartGlobalFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.size) { _, _ in
                        chartGlobalFrame = geometry.frame(in: .global)
                    }
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
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        let x = location.x - frame.origin.x
                        guard x >= 0, x <= frame.width,
                              let index: Int = proxy.value(atX: x) else { return }
                        handleRangeTap(at: index)
                    }
            }
        }
        .frame(height: mainChartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.displayName)\(model.period.title)行情图")
        .accessibilityValue(chartAccessibilitySummary)
        }
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

    /// A 股涨跌幅限制：300/301/302（创业板）、688/689（科创板）±20%；8/4 开头（北交所）±30%；其余 ±10%
    private func priceLimitPercent(for code: String) -> Double {
        let normalized = code.uppercased()
        if normalized.hasPrefix("300") || normalized.hasPrefix("301") || normalized.hasPrefix("302")
            || normalized.hasPrefix("688") || normalized.hasPrefix("689") {
            return 0.20
        }
        if normalized.hasPrefix("8") || normalized.hasPrefix("4") {
            return 0.30
        }
        return 0.10
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
        .frame(height: 95)
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

            if !model.period.usesTradingDayAxis {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.tertiary)
                    .help("滚轮或触控板捏合缩放时间轴；点击 K 线两次可查看区间涨幅")
            }
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
        case .day, .week, .month, .year:
            Int(zoomedVisibleCount.rounded())
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

    /// 蜡烛宽度：分时柱宽占格 92%（雪球风格紧密粘连）；其余固定；日/周/月/年按可视格宽自适应（约 62%）
    private func candleWidth(chartWidth: CGFloat) -> CGFloat {
        switch model.period {
        case .timeShare: return max(1, chartWidth / 240 * 0.92)
        case .fiveDay: return 2
        case .oneMinute: return max(1, chartWidth / 240 * 0.92)
        case .fiveMinute: return 7
        case .fifteenMinute: return 10
        case .thirtyMinute: return 14
        case .sixtyMinute: return 18
        case .oneTwentyMinute: return 24
        case .day, .week, .month, .year:
            let plotWidth = max(1, chartWidth - 70)  // 扣除 y 轴宽度
            let slot = plotWidth / CGFloat(max(1, visibleCandleCount))
            return min(16, max(3, slot * 0.62))
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

/// 获取当前视图所属的 NSWindow（供滚轮缩放事件判断窗口归属）
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// K 线窗口以主窗口中心点对齐，并始终约束在当前屏幕的可见区域内。
private enum KLineWindowPlacement {
    @MainActor
    static func place(_ window: NSWindow, centeredOver mainWindow: NSWindow?) {
        guard let mainWindow,
              mainWindow !== window,
              let screen = mainWindow.screen ?? window.screen ?? NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = preferredOrigin(
            windowSize: window.frame.size,
            mainFrame: mainWindow.frame,
            visibleFrame: visibleFrame
        )
        window.setFrameOrigin(origin)
    }

    static func preferredOrigin(
        windowSize: NSSize,
        mainFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let centeredX = mainFrame.midX - windowSize.width / 2
        let centeredY = mainFrame.midY - windowSize.height / 2
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
        let originX = min(max(centeredX, visibleFrame.minX), maximumX)
        let originY = min(max(centeredY, visibleFrame.minY), maximumY)

        return NSPoint(x: originX, y: originY)
    }
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
    var trend: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let trend {
                TrendText(value: trend, text: value)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            } else {
                Text(value).font(.callout.weight(.medium)).monospacedDigit()
            }
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
        // 成交量条带加高（主图:成交量 ≈ 2.6:1，贴近主流软件 3:1）
        volumeBase = minimum - priceRange * 0.40
        volumeDivider = minimum - priceRange * 0.08
        volumeHeight = priceRange * 0.30
        // 分时图固定 ±涨跌幅区间时不外扩；日 K 按可视区间留 6% 上边距
        priceCeiling = fixedPriceRange == nil ? maximum + priceRange * 0.06 : maximum
        dojiHeight = priceRange * 0.002
        priceAxisValues = (0...4).map { minimum + priceRange * Double($0) / 4 }
    }

    func volumeY(_ volume: Double) -> Double {
        volumeBase + max(0, volume) / maxVolume * volumeHeight
    }
}
