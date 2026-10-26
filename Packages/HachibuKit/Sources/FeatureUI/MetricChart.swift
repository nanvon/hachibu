import Charts
import SwiftUI

/// 一个指标的历史曲线：上方是指标名和大号读数，下方卡片里是曲线和渐变面积。
/// 读数平时显示最新点；悬停时显示选中采样时刻的值，缺失显示“—”。同组的几张图共享 `hoverDate`。
/// 样式见 docs/v1技术设计.md 19.3。
struct MetricChart: View {
    enum YScale: Equatable {
        case fixed(ClosedRange<Double>)
        case automatic(includesZero: Bool)
    }

    enum Style: Equatable {
        /// 单色曲线加同色渐变面积。
        case line(Color)
        /// 正值绿色、负值橙色，面积以 0 为基线。用于电池功率。
        case signed
    }

    let title: Text
    let series: ChartSeries
    var hoverPoints: [ChartPoint] = []
    private var points: [ChartPoint] { series.points }
    let domain: ClosedRange<Date>
    /// 悬停时只取这个距离内的点。
    let maxGap: TimeInterval
    var bands: [Range<Date>] = []
    var notRecorded: Range<Date>?
    var yScale: YScale = .automatic(includesZero: false)
    let style: Style
    let formatValue: (Double) -> String
    let formatDate: (Date) -> String
    @Binding var hoverDate: Date?

    private static let chartHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 4)
            MetricPlot(series: series, domain: domain, bands: bands, notRecorded: notRecorded, yScale: yScale, style: style)
                .equatable()
                .chartOverlay { proxy in
                    MetricChartInteraction(
                        proxy: proxy, points: points, hoverPoints: hoverPoints.isEmpty ? points : hoverPoints,
                        maxGap: maxGap, style: style, hoverDate: $hoverDate
                    )
                }
                .frame(height: Self.chartHeight)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    shape.fill(.background.opacity(0.7))
                    shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
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

/// 曲线不读取悬停状态，只在数据、刻度或样式变化时重新构造 Charts 内容。
private struct MetricPlot: View, Equatable {
    let series: ChartSeries
    let domain: ClosedRange<Date>
    let bands: [Range<Date>]
    let notRecorded: Range<Date>?
    let yScale: MetricChart.YScale
    let style: MetricChart.Style
    private let interpolation: InterpolationMethod = .monotone
    private static let bandColor = Color.green.opacity(0.09)
    private static let lineWidth: CGFloat = 2
    private static let notRecordedLabelMinFraction = 0.12

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.series.plotID == rhs.series.plotID && lhs.domain == rhs.domain
            && lhs.bands == rhs.bands && lhs.notRecorded == rhs.notRecorded
            && lhs.yScale == rhs.yScale && lhs.style == rhs.style
    }

    var body: some View { scaledChart }

    /// 面积填充的下边界：固定刻度取下限，自动刻度取数据最小值（包含 0 时取 0）。
    /// 不用 AreaMark 默认的 0 基线，以免把不含 0 的纵轴撑到 0。
    private var areaBaseline: Double {
        switch yScale {
        case .fixed(let range):
            return range.lowerBound
        case .automatic(let includesZero):
            let minValue = series.plotPoints.lazy.map(\.value).min() ?? 0
            return includesZero ? min(0, minValue) : minValue
        }
    }

    private static func areaGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var scaledChart: some View {
        switch yScale {
        case .fixed(let range):
            chart.chartYScale(domain: range)
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
            switch style {
            case .line(let color):
                lineMarks(series.plotPoints, series: { "\($0.segment)" }, baseline: areaBaseline, color: color)
            case .signed:
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(HistoryChartBuilder.signedRuns(series.plotPoints)) { run in
                    lineMarks(run.points, series: { _ in "\(run.id)" }, baseline: 0, color: run.isPositive ? .green : .orange)
                }
            }

        }
        .chartXScale(domain: domain)
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
        baseline: Double,
        color: Color
    ) -> some ChartContent {
        ForEach(points) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Baseline", baseline),
                yEnd: .value("Value", point.value),
                series: .value("Segment", series(point))
            )
            .interpolationMethod(interpolation)
            .foregroundStyle(Self.areaGradient(color))
        }
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
