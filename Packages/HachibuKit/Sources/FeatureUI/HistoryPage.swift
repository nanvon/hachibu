import BatteryCore
import Charts
import HistoryStore
import SwiftUI

/// 历史曲线页：上方电池健康（全部历史，三个指标切换一张图），下方最近 48 小时（电量、电池温度）。
/// 规则见 docs/v1技术设计.md 第 11 节。
struct HistoryPage: View {
    let model: HistoryModel
    /// 温度提醒阈值，温度曲线接近它时画参考线。
    var temperatureThreshold: Int?

    var body: some View {
        if model.isAvailable {
            ScrollView {
                HistoryChartsContent(model: model, temperatureThreshold: temperatureThreshold)
            }
            .navigationSubtitle(lastUpdatedText)
        } else {
            ContentUnavailableView {
                Label {
                    Text("History Unavailable", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text("The history database could not be opened.", bundle: .module)
            }
        }
    }

    /// “最近更新 HH:mm”，显示在工具栏标题下方。
    private var lastUpdatedText: Text {
        guard let lastUpdated = model.lastUpdated else { return Text(verbatim: "") }
        return Text("Last updated \(lastUpdated.formatted(date: .omitted, time: .shortened))", bundle: .module)
    }
}

/// 与页面共用的图表内容；渲染测试直接渲染内容，避开 ImageRenderer 无法绘制的 AppKit 滚动容器。
struct HistoryChartsContent: View {
    let model: HistoryModel
    var temperatureThreshold: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HealthSection(model: model)
            RecentSection(model: model, temperatureThreshold: temperatureThreshold)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 电池健康

private enum HealthMetric: CaseIterable, Hashable {
    case fullCharge, maximumCapacity, cycleCount
}

/// 全部历史的每日数据：标题下一句变化趋势，左侧三个指标兼做切换，右侧一张图显示选中的指标。
/// 悬停时三个指标的数值一起换成悬停那天的值。
private struct HealthSection: View {
    let model: HistoryModel
    @State private var selection: HealthMetric = .fullCharge
    @State private var hoverDate: Date?

    private static let tabColumnWidth: CGFloat = 216
    private static let chartHeight: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: Text("Battery Health", bundle: .module)) {
                    if let data = model.longTerm, let range = recordRange(data) {
                        SectionCaption(text: Text(verbatim: range))
                    }
                }
                if let data = model.longTerm {
                    trendText(data.trend)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let data = model.longTerm {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(HealthMetric.allCases, id: \.self) { metric in
                            HealthMetricTab(isSelected: metric == selection, isLead: metric == .fullCharge) {
                                selection = metric
                            } label: {
                                label(metric)
                            } value: {
                                value(metric, data: data)
                            } detail: {
                                detail(metric, data: data)
                            }
                        }
                    }
                    .frame(width: Self.tabColumnWidth)

                    VStack(alignment: .leading, spacing: 8) {
                        chartHeader(data)
                            .padding(.horizontal, 4)
                        chart(data)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func recordRange(_ data: LongTermChartData) -> String? {
        guard let last = data.hoverPoints.last?.date else { return nil }
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
        return "\(data.domain.lowerBound.formatted(style)) – \(last.formatted(style))"
    }

    private func trendText(_ trend: HealthTrend?) -> Text {
        guard let trend else {
            return Text("Trends appear after 60 days of records.", bundle: .module)
        }
        let change = "\(abs(trend.fullChargeChangeMAh)) mAh"
        let ratio = DisplayFormat.percent(ratio: abs(trend.fullChargeChangeRatio))
        let capacity: Text = if trend.fullChargeChangeMAh < 0 {
            Text("Over \(trend.months) months, the 30-day average full charge capacity fell by \(change) (\(ratio)).", bundle: .module)
        } else if trend.fullChargeChangeMAh > 0 {
            Text("Over \(trend.months) months, the 30-day average full charge capacity rose by \(change) (\(ratio)).", bundle: .module)
        } else {
            Text("Over \(trend.months) months, the 30-day average full charge capacity held steady.", bundle: .module)
        }
        guard let first = trend.firstCycleCount, let last = trend.lastCycleCount, last > first else { return capacity }
        // 中文两句之间不加空格，由字符串目录里的“%@ %@”处理。
        return Text("\(capacity) \(Text("Cycle count went from \(first) to \(last).", bundle: .module))", bundle: .module)
    }

    // MARK: 切换项

    private func label(_ metric: HealthMetric) -> Text {
        switch metric {
        case .fullCharge: Text("Full Charge Capacity", bundle: .module)
        case .maximumCapacity: Text("Maximum Capacity (System)", bundle: .module)
        case .cycleCount: Text("Cycle Count", bundle: .module)
        }
    }

    private func series(_ metric: HealthMetric, data: LongTermChartData) -> ChartSeries {
        switch metric {
        case .fullCharge: data.fullChargeCapacityMAh
        case .maximumCapacity: data.maximumCapacityPercent
        case .cycleCount: data.cycleCount
        }
    }

    private func value(_ metric: HealthMetric, data: LongTermChartData) -> (String, String?) {
        let reading = series(metric, data: data).reading(at: hoverDate).map { Int($0.value.rounded()) }
        switch metric {
        case .fullCharge: return (DisplayFormat.number(reading), reading == nil ? nil : "mAh")
        case .maximumCapacity: return (DisplayFormat.percent(reading), nil)
        case .cycleCount: return (DisplayFormat.number(reading), nil)
        }
    }

    private func detail(_ metric: HealthMetric, data: LongTermChartData) -> Text? {
        switch metric {
        case .fullCharge:
            guard let ratio = data.capacityRatioPercent.reading(at: hoverDate)?.value else { return nil }
            return Text("\(DisplayFormat.percent(ratio: ratio / 100)) of design capacity", bundle: .module)
        case .maximumCapacity:
            return Text("Matches System Settings", bundle: .module)
        case .cycleCount:
            guard let rate = data.cyclesPerMonth else { return nil }
            return Text("\(rate.formatted(.number.precision(.fractionLength(1)))) cycles per month on average", bundle: .module)
        }
    }

    // MARK: 图

    private func chartHeader(_ data: LongTermChartData) -> some View {
        let shownDate = hoverDate ?? series(selection, data: data).points.last?.date
        return HStack(spacing: 14) {
            if selection == .fullCharge {
                LegendItem(text: Text("Daily", bundle: .module)) {
                    Capsule().fill(Color.brand.opacity(0.35)).frame(width: 14, height: 1)
                }
                LegendItem(text: Text("14-Day Average", bundle: .module)) {
                    Capsule().fill(Color.brand).frame(width: 14, height: 2)
                }
            }
            Spacer(minLength: 8)
            if let shownDate {
                Text(verbatim: shownDate.formatted(.dateTime.year().month(.abbreviated).day()))
                    .font(.system(size: 11.5))
                    .fontWeight(hoverDate == nil ? .regular : .medium)
                    .foregroundStyle(hoverDate == nil ? HierarchicalShapeStyle.tertiary : .primary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .frame(height: 16)
    }

    @ViewBuilder
    private func chart(_ data: LongTermChartData) -> some View {
        switch selection {
        case .fullCharge:
            // 纵轴至少跨设计容量的 10%，避免几十 mAh 的日常波动显得像大幅衰减。
            let span = Double(data.designCapacityMAh ?? 5000) * 0.1
            card(data.fullChargeCapacityMAh, trend: data.fullChargeTrend, data: data, yScale: .minimumSpan(span, upperLimit: nil))
        case .maximumCapacity:
            card(data.maximumCapacityPercent, data: data, yScale: .minimumSpan(10, upperLimit: 100))
        case .cycleCount:
            card(data.cycleCount, data: data, yScale: .automatic(includesZero: false), integerYTicks: true)
        }
    }

    private func card(
        _ series: ChartSeries,
        trend: ChartSeries? = nil,
        data: LongTermChartData,
        yScale: MetricChart.YScale,
        integerYTicks: Bool = false
    ) -> MetricChartCard {
        MetricChartCard(
            series: series,
            trend: trend,
            hoverPoints: data.hoverPoints,
            domain: data.domain,
            maxGap: data.maxGap,
            notRecorded: data.notRecorded,
            yScale: yScale,
            integerYTicks: integerYTicks,
            style: .line(.brand),
            height: Self.chartHeight,
            hoverDate: $hoverDate
        )
    }
}

/// 电池健康块左侧的一个指标：选中时有中性灰底。满充容量是这一块的主读数，字号最大。
private struct HealthMetricTab: View {
    let isSelected: Bool
    let isLead: Bool
    let action: () -> Void
    let label: Text
    let value: (String, String?)
    let detail: Text?
    @State private var isHovered = false

    init(
        isSelected: Bool,
        isLead: Bool,
        action: @escaping () -> Void,
        label: () -> Text,
        value: () -> (String, String?),
        detail: () -> Text?
    ) {
        self.isSelected = isSelected
        self.isLead = isLead
        self.action = action
        self.label = label()
        self.value = value()
        self.detail = detail()
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                label
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: value.0)
                        .font(.system(size: isLead ? 28 : 22, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    if let unit = value.1 {
                        Text(verbatim: unit)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                (detail ?? Text(verbatim: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.07 : isHovered ? 0.035 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 最近 48 小时

/// 电量、电池温度，图下方是 48 小时的统计。
private struct RecentSection: View {
    let model: HistoryModel
    let temperatureThreshold: Int?
    @State private var hoverDate: Date?

    /// 48 小时最高温度不低于“阈值 − 5 °C”时才画阈值线，否则纵轴会被撑开、把温度曲线压扁。
    private static let thresholdVisibleMargin = 5.0
    private static let chartHeight: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: Text("Last 48 Hours", bundle: .module)) {
                LegendItem(text: Text("Plugged In", bundle: .module)) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.22))
                        .frame(width: 12, height: 10)
                }
                if let data = model.recent, threshold(data) != nil {
                    LegendItem(text: Text("Alert Threshold", bundle: .module)) {
                        DashedLegendLine(color: .orange)
                    }
                }
            }

            if let data = model.recent {
                let formatDate: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        chart(
                            Text("Battery Level", bundle: .module), data.percent, data: data,
                            yScale: .fixed(0...100), style: .line(.brand), formatDate: formatDate
                        ) {
                            DisplayFormat.percent(Int($0.rounded()))
                        }
                        StatRow {
                            StatItem(label: Text("Plugged In", bundle: .module), value: DisplayFormat.duration(minutes: data.stats.pluggedInMinutes))
                            StatItem(label: Text("Of Which Charging", bundle: .module), value: DisplayFormat.duration(minutes: data.stats.chargingMinutes))
                            StatItem(label: Text("Not Recorded", bundle: .module), value: DisplayFormat.duration(minutes: data.stats.notRecordedMinutes))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        chart(
                            Text("Battery Temperature", bundle: .module), data.temperatureCelsius, data: data,
                            threshold: threshold(data), style: .line(.red), formatDate: formatDate
                        ) {
                            DisplayFormat.celsius($0)
                        }
                        StatRow {
                            StatItem(
                                label: Text("Highest", bundle: .module),
                                value: DisplayFormat.celsius(data.stats.highestTemperature?.value),
                                detail: data.stats.highestTemperature?.date.formatted(date: .omitted, time: .shortened)
                            )
                            StatItem(label: Text("Average", bundle: .module), value: DisplayFormat.celsius(data.stats.averageTemperature))
                            StatItem(
                                label: Text("Lowest", bundle: .module),
                                value: DisplayFormat.celsius(data.stats.lowestTemperature?.value),
                                detail: data.stats.lowestTemperature?.date.formatted(date: .omitted, time: .shortened)
                            )
                        }
                    }
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func threshold(_ data: RecentChartData) -> Double? {
        guard let temperatureThreshold, let highest = data.stats.highestTemperature?.value,
              highest >= Double(temperatureThreshold) - Self.thresholdVisibleMargin
        else { return nil }
        return Double(temperatureThreshold)
    }

    private func chart(
        _ title: Text,
        _ series: ChartSeries,
        data: RecentChartData,
        threshold: Double? = nil,
        yScale: MetricChart.YScale = .automatic(includesZero: false),
        style: MetricChart.Style,
        formatDate: @escaping (Date) -> String,
        formatValue: @escaping (Double) -> String
    ) -> MetricChart {
        MetricChart(
            title: title,
            series: series,
            hoverPoints: data.hoverPoints,
            domain: data.domain,
            maxGap: data.maxGap,
            bands: data.pluggedIn,
            notRecorded: data.notRecorded,
            threshold: threshold,
            yScale: yScale,
            style: style,
            formatValue: formatValue,
            formatDate: formatDate,
            chartHeight: Self.chartHeight,
            hoverDate: $hoverDate
        )
    }
}

/// 图下方一行三项统计，等宽三列。
private struct StatRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content
        }
        .padding(.horizontal, 4)
    }
}

private struct StatItem: View {
    let label: Text
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            label
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 通用

private struct SectionHeader<Accessory: View>: View {
    let title: Text
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            title
                .font(.system(size: 20, weight: .bold))
            Spacer(minLength: 8)
            accessory
        }
        .lineLimit(1)
    }
}

private struct SectionCaption: View {
    let text: Text

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct LegendItem<Swatch: View>: View {
    let text: Text
    @ViewBuilder let swatch: Swatch

    var body: some View {
        HStack(spacing: 6) {
            swatch
            text
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashedLegendLine: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: 14, y: 0.5))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .frame(width: 14, height: 1)
    }
}

private struct LoadingPlaceholder: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - 预览

#if DEBUG
/// 历史页的示例数据，写入内存数据库：最近 48 小时的分钟数据（每 4 小时交替使用电池和插电，中间有一段休眠缺口），
/// 以及 120 天的每日数据。
@MainActor
private enum HistoryPreviewData {
    static func model() -> HistoryModel {
        let store = try? HistoryStore.inMemory()
        let model = HistoryModel(store: store)
        if let store {
            Task {
                try? await fill(store, now: Date())
                model.start()
            }
        }
        return model
    }

    private static func fill(_ store: HistoryStore, now: Date) async throws {
        var level = 80.0
        for minute in 0..<2880 {
            let date = now.addingTimeInterval(TimeInterval(minute - 2879) * 60)
            let isExternal = (minute / 240) % 2 == 1
            let load = 7000 + 3000 * sin(Double(minute) / 25)
            let isCharging = isExternal && level < 80
            let battery = isCharging ? 30000 : isExternal ? 0 : -load
            // 约 70 Wh 的电池：每分钟变化 W ÷ 60 ÷ 70 × 100 个百分点。
            level = min(100, max(5, level + battery / 1000 / 60 / 70 * 100))
            // 模拟一段 30 分钟的休眠缺口。
            guard !(900..<930).contains(minute) else { continue }
            let voltage = 11400 + level * 12
            try await store.write(MinuteSample(
                timestamp: date,
                percent: Int(level.rounded()),
                isExternalPower: isExternal,
                isCharging: isCharging,
                systemLoadMW: Int(load),
                batteryPowerMW: Int(battery),
                powerInMW: isExternal ? Int(load + battery) : 0,
                temperatureCelsius: 28 + (isCharging ? 6 : 0) + load / 3000,
                voltageMV: Int(voltage),
                amperageMA: Int(battery / voltage * 1000)
            ))
        }

        for day in 0..<120 {
            let date = now.addingTimeInterval(TimeInterval(day - 119) * 86400)
            try await store.record(
                BatteryHealthInfo(systemMaximumCapacityPercent: day < 70 ? 96 : 95, condition: .good),
                snapshot: BatterySnapshot(
                    fullChargeCapacityMAh: 8090 - day + (day % 7) * 4,
                    designCapacityMAh: 8694,
                    cycleCount: 28 + day / 3
                ),
                at: date
            )
        }
    }
}

#Preview("History") {
    NavigationStack {
        HistoryPage(model: HistoryPreviewData.model())
    }
    .frame(width: 1000, height: 780)
}

#Preview("History Unavailable") {
    HistoryPage(model: HistoryModel(store: nil))
        .frame(width: 1000, height: 400)
}
#endif
