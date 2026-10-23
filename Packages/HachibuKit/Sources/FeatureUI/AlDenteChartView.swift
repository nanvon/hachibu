import Charts
import HistoryStore
import SwiftUI

struct AlDenteChartView: View {
    let data: AlDenteChartData
    let table: AlDenteTable
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let point = nearestPoint ?? data.points.last {
                HStack {
                    Text(verbatim: point.sourceValue).fontWeight(.semibold)
                    Text(verbatim: timestamp(point.date)).foregroundStyle(.secondary)
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }
            if let domain = data.domain {
                chart(domain: domain)
                    .frame(minHeight: 160)
            } else {
                Text("No source records can be plotted. You can still inspect every original record.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("\(data.points.count) plotted points from \(data.sourcePointCount) records in this range", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            if data.points.count < data.sourcePointCount {
                Text("Dense curves retain the first, last, minimum, and maximum points in each time bucket and segment. All original records remain available.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if data.invalidTimestampCount > 0 || data.unplottableValueCount > 0 {
                Text("Not plotted in this table: \(data.invalidTimestampCount) invalid timestamps and \(data.unplottableValueCount) values that cannot be represented exactly. Original records are unchanged.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if data.duplicateTimestampCount > 0 {
                Text("\(data.duplicateTimestampCount) records share timestamps and are shown as separate points. Inspect Original Records for all values.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Chart times are UTC. Ranges end at the latest plottable record in the selected table. Gaps stay disconnected; values are not converted or cleaned.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            if table.isUnverifiedPower {
                Text("Power values use the original AlDente scale. The unit and measurement source have not been verified; these are not Hachibu power measurements.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: data.domain) { hoverDate = nil }
    }

    private func chart(domain: ClosedRange<Date>) -> some View {
        Chart {
            if table != .batteryDesignCap {
                ForEach(data.points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Value", point.value),
                             series: .value("Segment", point.segment))
                        .interpolationMethod(table == .batteryCycles || table == .chargeLimit ? .stepEnd : .linear)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color)
                }
            }
            ForEach(data.points) { point in
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .symbolSize(table == .batteryDesignCap ? 30 : 8)
                    .foregroundStyle(color)
            }
            if let point = nearestPoint {
                RuleMark(x: .value("Time", point.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .symbolSize(30)
                    .foregroundStyle(color)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: axisDateStyle)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            hoverDate = proxy.value(atX: x, as: Date.self)
                        case .ended: hoverDate = nil
                        }
                    }
            }
        }
    }

    private var nearestPoint: AlDenteChartPoint? {
        guard let hoverDate else { return nil }
        let visualTolerance = data.domain.map { $0.upperBound.timeIntervalSince($0.lowerBound) / 500 } ?? 1
        return data.nearest(to: hoverDate, within: max(visualTolerance, max(1, table.chartMaxGap / 2)))
    }

    private var color: Color {
        if table == .batteryTemp { return .red }
        return table.isUnverifiedPower ? .orange : .brand
    }

    private var axisDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return style
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS 'UTC'"
        return formatter.string(from: date)
    }
}
