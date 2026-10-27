import Charts
import SwiftUI

/// 一个指标的历史曲线：上方是指标名和大号读数，下方卡片里是曲线和渐变面积。
/// 读数平时显示最新点；悬停时显示选中采样时刻的值，缺失显示“—”。同组的几张图共享 `hoverDate`。
/// 样式见 docs/v1技术设计.md 19.3。
struct MetricChart: View {
    enum YScale: Equatable {
        case fixed(ClosedRange<Double>)
        case automatic(includesZero: Bool)
        /// 纵轴跨度不小于 `span`，不足时在数据两侧补齐，不超过 `upperLimit`。避免小幅波动被放大成剧烈起伏。
        case minimumSpan(Double, upperLimit: Double?)
    }

    enum Style: Equatable {
        /// 单色曲线。
        case line(Color)
        /// 正值绿色、负值橙色，面积以 0 为基线。用于电池功率。
        case signed
    }

    let title: Text
    let series: ChartSeries
    var hoverPoints: [ChartPoint] = []
    let domain: ClosedRange<Date>
    /// 悬停时只取这个距离内的点。
    let maxGap: TimeInterval
    var bands: [Range<Date>] = []
    var notRecorded: Range<Date>?
    var threshold: Double?
    var yScale: YScale = .automatic(includesZero: false)
    let style: Style
    let formatValue: (Double) -> String
    let formatDate: (Date) -> String
    var chartHeight: CGFloat = 200
    @Binding var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 4)
            MetricChartCard(
                series: series, threshold: threshold, hoverPoints: hoverPoints,
                domain: domain, maxGap: maxGap, bands: bands, notRecorded: notRecorded,
                yScale: yScale, style: style, height: chartHeight, hoverDate: $hoverDate
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 读数

    private var hoveredPoint: ChartPoint? {
        guard let hoverDate else { return nil }
        return series.reading(at: hoverDate)
    }

    private var header: some View {
        let shown = series.reading(at: hoverDate)
        return HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    legendDot
                    title
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: shown.map { formatValue($0.value) } ?? DisplayFormat.missing)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if let shownDate = hoverDate ?? shown?.date {
                Text(verbatim: formatDate(shownDate))
                    .font(.system(size: 11.5))
                    .fontWeight(hoveredPoint == nil ? .regular : .medium)
                    .foregroundStyle(hoveredPoint == nil ? HierarchicalShapeStyle.tertiary : .primary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var legendDot: some View {
        switch style {
        case .line(let color):
            Circle().fill(color).frame(width: 8, height: 8)
        case .signed:
            // 左半绿、右半橙。
            Circle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.5),
                        .init(color: .orange, location: 0.5),
                        .init(color: .orange, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: 8, height: 8)
        }
    }
}

/// 曲线卡片：曲线、悬停叠层和底色。电池健康块直接使用，读数由外部显示。
struct MetricChartCard: View {
    let series: ChartSeries
    /// 有值时它是主线，`series` 画成细线作为每日读数。
    var trend: ChartSeries?
    /// 虚线水平参考线，用于温度提醒阈值。
    var threshold: Double?
    var hoverPoints: [ChartPoint] = []
    let domain: ClosedRange<Date>
    let maxGap: TimeInterval
    var bands: [Range<Date>] = []
    var notRecorded: Range<Date>?
    var yScale: MetricChart.YScale = .automatic(includesZero: false)
    var integerYTicks = false
    let style: MetricChart.Style
    var height: CGFloat = 200
    @Binding var hoverDate: Date?

    var body: some View {
        MetricPlot(
            series: series, trend: trend, threshold: threshold, domain: domain,
            bands: bands, notRecorded: notRecorded, yScale: yScale, integerYTicks: integerYTicks, style: style
        )
        .equatable()
        .chartOverlay { proxy in
            MetricChartInteraction(
                proxy: proxy, points: series.points, hoverPoints: hoverPoints.isEmpty ? series.points : hoverPoints,
                maxGap: maxGap, style: style, hoverDate: $hoverDate
            )
        }
        .frame(height: height)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape.fill(.background.opacity(0.7))
            shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}

/// 曲线不读取悬停状态，只在数据、刻度或样式变化时重新构造 Charts 内容。
private struct MetricPlot: View, Equatable {
    let series: ChartSeries
    let trend: ChartSeries?
    let threshold: Double?
    let domain: ClosedRange<Date>
    let bands: [Range<Date>]
    let notRecorded: Range<Date>?
    let yScale: MetricChart.YScale
    let integerYTicks: Bool
    let style: MetricChart.Style
    private let interpolation: InterpolationMethod = .monotone
    private static let bandColor = Color.green.opacity(0.05)
    private static let lineWidth: CGFloat = 2
    /// 有趋势线时，每日读数画成细线。
    private static let dailyLineWidth: CGFloat = 1
    private static let dailyLineOpacity = 0.35
    private static let referenceDash: [CGFloat] = [4, 3]
    private static let notRecordedLabelMinFraction = 0.12

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.series.plotID == rhs.series.plotID && lhs.trend?.plotID == rhs.trend?.plotID
            && lhs.threshold == rhs.threshold
            && lhs.domain == rhs.domain && lhs.bands == rhs.bands && lhs.notRecorded == rhs.notRecorded
            && lhs.yScale == rhs.yScale && lhs.integerYTicks == rhs.integerYTicks && lhs.style == rhs.style
    }

    var body: some View { scaledChart }

    /// 参与纵轴范围的点：曲线和趋势线。
    private var valueRange: ClosedRange<Double>? {
        let values = series.plotPoints.map(\.value) + (trend?.plotPoints.map(\.value) ?? [])
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }

    /// `minimumSpan` 补齐后的纵轴范围：先向两侧平均扩展，超过上限的部分移到下侧。
    private func paddedRange(span: Double, upperLimit: Double?) -> ClosedRange<Double>? {
        guard let range = valueRange else { return nil }
        let padding = max(0, span - (range.upperBound - range.lowerBound)) / 2
        var low = range.lowerBound - padding
        var high = range.upperBound + padding
        if let upperLimit, high > upperLimit, range.upperBound <= upperLimit {
            low -= high - upperLimit
            high = upperLimit
        }
        return low...high
    }

    @ViewBuilder
    private var scaledChart: some View {
        switch yScale {
        case .fixed(let range):
            chart.chartYScale(domain: range)
        case .minimumSpan(let span, let upperLimit):
            if let range = paddedRange(span: span, upperLimit: upperLimit) {
                chart.chartYScale(domain: range)
            } else {
                chart
            }
        case .automatic(let includesZero):
            chart.chartYScale(domain: .automatic(includesZero: includesZero))
        }
    }

    private var chart: some View {
        Chart {
            ForEach(bands, id: \.lowerBound) { band in
                RectangleMark(xStart: .value("Start", band.lowerBound), xEnd: .value("End", band.upperBound))
                    .foregroundStyle(Self.bandColor)
            }
            if let notRecorded {
                RectangleMark(xStart: .value("Start", notRecorded.lowerBound), xEnd: .value("End", notRecorded.upperBound))
                    .foregroundStyle(Color.secondary.opacity(0.08))
                    .annotation(position: .overlay) {
                        if showsNotRecordedLabel(notRecorded) {
                            Text("Not Recorded", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            if let threshold {
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: Self.referenceDash))
            }
            switch style {
            case .line(let color):
                if let trend {
                    ForEach(series.plotPoints) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Segment", "d\(point.segment)"))
                            .interpolationMethod(interpolation)
                            .lineStyle(StrokeStyle(lineWidth: Self.dailyLineWidth, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(color.opacity(Self.dailyLineOpacity))
                    }
                    lineMarks(trend.plotPoints, series: { "t\($0.segment)" }, color: color)
                } else {
                    lineMarks(series.plotPoints, series: { "\($0.segment)" }, color: color)
                }
            case .signed:
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(HistoryChartBuilder.signedRuns(series.plotPoints)) { run in
                    lineMarks(run.points, series: { _ in "\(run.id)" }, color: run.isPositive ? .green : .orange)
                }
            }

        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(anchor: .center)
            }
        }
        .chartYAxis {
            if integerYTicks {
                AxisMarks(values: .stride(by: max(1, ceil((valueRange.map { $0.upperBound - $0.lowerBound } ?? 0) / 4)))) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.1))
                    if let number = value.as(Double.self) {
                        AxisValueLabel(anchor: .leading) { Text(number.formatted(.number.precision(.fractionLength(0)))) }
                    }
                }
            } else {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.1))
                    AxisValueLabel(anchor: .leading)
                }
            }
        }
        .overlay {
            if series.points.isEmpty {
                Text("No Data", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ChartContentBuilder
    private func lineMarks(
        _ points: [ChartPoint],
        series: @escaping (ChartPoint) -> String,
        color: Color
    ) -> some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value),
                series: .value("Segment", series(point))
            )
            .interpolationMethod(interpolation)
            .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(color)
        }
    }

    private func showsNotRecordedLabel(_ range: Range<Date>) -> Bool {
        let total = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard total > 0 else { return false }
        return range.upperBound.timeIntervalSince(range.lowerBound) / total >= Self.notRecordedLabelMinFraction
    }
}

/// 悬停标记作为独立叠层绘制，不把高频鼠标事件传进曲线的 ChartContent。
private struct MetricChartInteraction: View {
    let proxy: ChartProxy
    let points: [ChartPoint]
    let hoverPoints: [ChartPoint]
    let maxGap: TimeInterval
    let style: MetricChart.Style
    @Binding var hoverDate: Date?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let hoverDate,
                   let plotAnchor = proxy.plotFrame,
                   let x = proxy.position(forX: hoverDate) {
                    let frame = geometry[plotAnchor]
                    Path { path in
                        path.move(to: CGPoint(x: frame.minX + x, y: frame.minY))
                        path.addLine(to: CGPoint(x: frame.minX + x, y: frame.maxY))
                    }
                    .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                    if let point = HistoryChartBuilder.nearest(in: points, to: hoverDate, within: 0),
                       let y = proxy.position(forY: point.value) {
                        Circle()
                            .fill(pointColor(point))
                            .frame(width: 8, height: 8)
                            .position(x: frame.minX + x, y: frame.minY + y)
                    }
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        let selection: Date?
                        switch phase {
                        case .active(let location):
                            guard let plotAnchor = proxy.plotFrame else { return }
                            let frame = geometry[plotAnchor]
                            guard frame.contains(location) else {
                                if hoverDate != nil { hoverDate = nil }
                                return
                            }
                            let date: Date? = proxy.value(atX: location.x - frame.minX)
                            selection = date.flatMap {
                                HistoryChartBuilder.nearest(in: hoverPoints, to: $0, within: maxGap)?.date
                            }
                        case .ended:
                            selection = nil
                        }
                        if selection != hoverDate { hoverDate = selection }
                    }
            }
        }
    }

    private func pointColor(_ point: ChartPoint) -> Color {
        switch style {
        case .line(let color): color
        case .signed: point.value >= 0 ? .green : .orange
        }
    }
}
