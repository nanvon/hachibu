import Charts
import SwiftUI

/// 一个指标的历史曲线：标题行显示悬停点（未悬停时为最新点）的读数，下方是曲线。
/// 同组的几张图共享 `hoverDate`，悬停时一起显示同一时刻的读数。
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

    private static let bandColor = Color.blue.opacity(0.1)
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
                .frame(height: 120)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var displayedPoint: ChartPoint? {
        guard let hoverDate else { return points.last }
        return HistoryChartBuilder.nearest(in: points, to: hoverDate, within: maxGap)
    }

    private var readout: some View {
        HStack(spacing: 6) {
            if let point = displayedPoint {
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
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.value),
                    series: .value("Segment", point.segment)
                )
                .interpolationMethod(interpolation)
                .foregroundStyle(color)
            }
            if hoverDate != nil, let point = displayedPoint {
                RuleMark(x: .value("Time", point.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .foregroundStyle(color)
                    .symbolSize(30)
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
