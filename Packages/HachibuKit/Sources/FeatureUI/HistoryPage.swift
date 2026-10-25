import Charts
import SwiftUI

/// 历史曲线页：近期、长期两组，各自独立的时间范围，每组一行两张图。规则见 docs/v1技术设计.md 第 11 节。
struct HistoryPage: View {
    let model: HistoryModel

    var body: some View {
        if model.isAvailable {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    RecentSection(model: model)
                    LongTermSection(model: model)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - 近期

/// 电量、电池温度、系统功率、电池功率、充电器输入功率、电池电压。
private struct RecentSection: View {
    let model: HistoryModel
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: Text("Recent", bundle: .module)) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.22))
                        .frame(width: 12, height: 10)
                    Text("Plugged In", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(selection: Binding(get: { model.recentRange }, set: { model.setRecentRange($0) })) {
                    ForEach(RecentRange.allCases, id: \.self) { range in
                        Self.title(range).tag(range)
                    }
                } label: {
                    Text("Time Range", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let data = model.recent {
                let formatDate = Self.dateFormatter(model.recentRange)
                ChartGrid {
                    chart(Text("Battery Level", bundle: .module), data.percent, data: data, yScale: .fixed(0...100), style: .line(.brand), formatDate: formatDate) {
                        DisplayFormat.percent(Int($0.rounded()))
                    }
                    chart(Text("Battery Temperature", bundle: .module), data.temperatureCelsius, data: data, style: .line(.red), formatDate: formatDate) {
                        DisplayFormat.celsius($0)
                    }
                    chart(Text("System Power", bundle: .module), data.systemPowerWatts, data: data, yScale: .automatic(includesZero: true), style: .line(.systemPower), formatDate: formatDate) {
                        DisplayFormat.watts(milliwatts: Self.milliwatts($0))
                    }
                    chart(Text("Battery Power (Charging +, Draining −)", bundle: .module), data.batteryPowerWatts, data: data, yScale: .automatic(includesZero: true), style: .signed, formatDate: formatDate) {
                        DisplayFormat.signedWatts(milliwatts: Self.milliwatts($0))
                    }
                    chart(Text("Charger Input Power", bundle: .module), data.powerInWatts, data: data, yScale: .automatic(includesZero: true), style: .line(.green), formatDate: formatDate) {
                        DisplayFormat.watts(milliwatts: Self.milliwatts($0))
                    }
                    chart(Text("Battery Voltage", bundle: .module), data.voltageVolts, data: data, style: .line(.teal), formatDate: formatDate) {
                        DisplayFormat.volts(millivolts: Int(($0 * 1000).rounded()), fractionLength: 2)
                    }
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func chart(
        _ title: Text,
        _ points: [ChartPoint],
        data: RecentChartData,
        yScale: MetricChart.YScale = .automatic(includesZero: false),
        style: MetricChart.Style,
        formatDate: @escaping (Date) -> String,
        formatValue: @escaping (Double) -> String
    ) -> MetricChart {
        MetricChart(
            title: title,
            points: points,
            domain: data.domain,
            maxGap: data.maxGap,
            bands: data.pluggedIn,
            notRecorded: data.notRecorded,
            yScale: yScale,
            style: style,
            formatValue: formatValue,
            formatDate: formatDate,
            hoverDate: $hoverDate
        )
    }

    private static func milliwatts(_ watts: Double) -> Int {
        Int((watts * 1000).rounded())
    }

    private static func title(_ range: RecentRange) -> Text {
        switch range {
        case .hour: Text("1 Hour", bundle: .module)
        case .day: Text("24 Hours", bundle: .module)
        case .week: Text("7 Days", bundle: .module)
        }
    }

    private static func dateFormatter(_ range: RecentRange) -> (Date) -> String {
        switch range {
        case .hour: { $0.formatted(.dateTime.hour().minute()) }
        case .day: { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        case .week: { $0.formatted(.dateTime.month(.abbreviated).day().hour()) }
        }
    }
}

// MARK: - 长期

/// 系统最大容量、容量比、满充容量、循环次数。
private struct LongTermSection: View {
    let model: HistoryModel
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: Text("Long Term", bundle: .module)) {
                Picker(selection: Binding(get: { model.longTermRange }, set: { model.setLongTermRange($0) })) {
                    ForEach(LongTermRange.allCases, id: \.self) { range in
                        Self.title(range).tag(range)
                    }
                } label: {
                    Text("Time Range", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let data = model.longTerm {
                ChartGrid {
                    // 系统最大容量是整数百分比，和循环次数一样画阶梯线。stepEnd 在后一个点处跳变，台阶落在数值变化的那一天。
                    chart(Text("Maximum Capacity (System)", bundle: .module), data.maximumCapacityPercent, data: data, interpolation: .stepEnd) {
                        DisplayFormat.percent(Int($0.rounded()))
                    }
                    chart(Text("Capacity Ratio (Full Charge / Design)", bundle: .module), data.capacityRatioPercent, data: data) {
                        DisplayFormat.percent(ratio: $0 / 100)
                    }
                    chart(Text("Full Charge Capacity", bundle: .module), data.fullChargeCapacityMAh, data: data) {
                        "\(DisplayFormat.number(Int($0.rounded()))) mAh"
                    }
                    chart(Text("Cycle Count", bundle: .module), data.cycleCount, data: data, interpolation: .stepEnd) {
                        DisplayFormat.number(Int($0.rounded()))
                    }
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func chart(
        _ title: Text,
        _ points: [ChartPoint],
        data: LongTermChartData,
        interpolation: InterpolationMethod = .linear,
        formatValue: @escaping (Double) -> String
    ) -> MetricChart {
        MetricChart(
            title: title,
            points: points,
            domain: data.domain,
            maxGap: data.maxGap,
            notRecorded: data.notRecorded,
            interpolation: interpolation,
            style: .line(.brand),
            formatValue: formatValue,
            formatDate: { $0.formatted(.dateTime.year().month(.abbreviated).day()) },
            hoverDate: $hoverDate
        )
    }

    private static func title(_ range: LongTermRange) -> Text {
        switch range {
        case .month: Text("30 Days", bundle: .module)
        case .year: Text("1 Year", bundle: .module)
        case .all: Text("All", bundle: .module)
        }
    }
}

// MARK: - 通用

/// 一行两张图。
private struct ChartGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), alignment: .top)],
            alignment: .leading,
            spacing: 22
        ) {
            content
        }
    }
}

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
    }
}

private struct LoadingPlaceholder: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}
