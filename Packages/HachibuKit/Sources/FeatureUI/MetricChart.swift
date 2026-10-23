import Charts
import SwiftUI

/// 一个指标的历史曲线：标题行显示最新点的读数，下方是曲线和渐变面积。
/// 悬停时在曲线上方用气泡显示最近一个点的读数。同组的几张图共享 `hoverDate`，一起显示同一时刻的竖线和读数。
/// 样式见 docs/v1技术设计.md 19.3。
struct MetricChart: View {
    enum YScale {
        case fixed(ClosedRange<Double>)
        case automatic(includesZero: Bool)
    }

    let title: Text
    let points: [ChartPoint]
    let domain: ClosedRange<Date>
    /// 悬停时只取这个距离内的点。
    let maxGap: TimeInterval
    var bands: [Range<Date>] = []
    var notRecorded: Range<Date>?
    var yScale: YScale = .automatic(includesZero: false)
    var interpolation: InterpolationMethod = .linear
    let color: Color
    let formatValue: (Double) -> String
    let formatDate: (Date) -> String
    @Binding var hoverDate: Date?

    private static let bandColor = Color.green.opacity(0.1)
    private static let lineWidth: CGFloat = 2
    /// “未记录”区间窄于横轴的这个比例时不显示文字，只画底色。
    private static let notRecordedLabelMinFraction = 0.12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                readout
                    .font(.callout)
                    .monospacedDigit()
            }
            scaledChart
                .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hoveredPoint: ChartPoint? {
        guard let hoverDate else { return nil }
        return HistoryChartBuilder.nearest(in: points, to: hoverDate, within: maxGap)
    }

    /// 面积填充的下边界：固定刻度取下限，自动刻度取数据最小值（包含 0 时取 0）。
    /// 不用 AreaMark 默认的 0 基线，以免把不含 0 的纵轴撑到 0。
    private var areaBaseline: Double {
        switch yScale {
        case .fixed(let range):
            return range.lowerBound
        case .automatic(let includesZero):
            let minValue = points.lazy.map(\.value).min() ?? 0
            return includesZero ? min(0, minValue) : minValue
        }
    }

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom)
    }

    private var readout: some View {
        HStack(spacing: 6) {
            if let point = points.last {
                Text(verbatim: formatValue(point.value))
                Text(verbatim: formatDate(point.date))
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: DisplayFormat.missing)
                    .foregroundStyle(.secondary)
            }
        }
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
            let baseline = areaBaseline
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Baseline", baseline),
                    yEnd: .value("Value", point.value),
                    series: .value("Segment", point.segment)
                )
                .interpolationMethod(interpolation)
                .foregroundStyle(areaGradient)
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.value),
                    series: .value("Segment", point.segment)
                )
                .interpolationMethod(interpolation)
                .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(color)
            }
            if let point = hoveredPoint {
                RuleMark(x: .value("Time", point.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .foregroundStyle(color)
                    .symbolSize(30)
                    .annotation(
                        position: .top,
                        spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        HoverBubble(value: formatValue(point.value), date: formatDate(point.date))
                    }
            }
        }
        .chartXScale(domain: domain)
        .overlay {
            if points.isEmpty {
                Text("No Data", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geometry[plotFrame].origin.x
                            hoverDate = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
    }

    private func showsNotRecordedLabel(_ range: Range<Date>) -> Bool {
        let total = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard total > 0 else { return false }
        return range.upperBound.timeIntervalSince(range.lowerBound) / total >= Self.notRecordedLabelMinFraction
    }
}

/// 悬停读数气泡：macOS 26+ 为玻璃，更早系统为 `.regularMaterial`。
private struct HoverBubble: View {
    let value: String
    let date: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: value)
                .fontWeight(.semibold)
            Text(verbatim: date)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .panelGlass(in: Capsule())
    }
}
