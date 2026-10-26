import BatteryCore
import Charts
import HistoryStore
import SwiftUI

/// 历史曲线页：近期固定 48 小时、长期显示全部历史，每组一行两张图。规则见 docs/v1技术设计.md 第 11 节。
struct HistoryPage: View {
    let model: HistoryModel

    var body: some View {
        if model.isAvailable {
            ScrollView {
                HistoryChartsContent(model: model)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            RecentSection(model: model)
            LongTermSection(model: model)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 近期

/// 电量、电池温度。
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
                Text("48 Hours", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let data = model.recent {
                let formatDate: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
                ChartGrid {
                    chart(Text("Battery Level", bundle: .module), data.percent, data: data, yScale: .fixed(0...100), style: .line(.brand), formatDate: formatDate) {
                        DisplayFormat.percent(Int($0.rounded()))
                    }
                    chart(Text("Battery Temperature", bundle: .module), data.temperatureCelsius, data: data, style: .line(.red), formatDate: formatDate) {
                        DisplayFormat.celsius($0)
                    }
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func chart(
        _ title: Text,
        _ series: ChartSeries,
        data: RecentChartData,
        yScale: MetricChart.YScale = .automatic(includesZero: false),
        style: MetricChart.Style,
        formatDate: @escaping (Date) -> String,
        formatValue: @escaping (Double) -> String
    ) -> MetricChart {
        MetricChart(
            title: title,
            series: series,
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
}

// MARK: - 长期

/// 系统最大容量、容量比、满充容量、循环次数。
private struct LongTermSection: View {
    let model: HistoryModel
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: Text("Long Term", bundle: .module)) {
                Text("All", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let data = model.longTerm {
                ChartGrid {
                    chart(Text("Maximum Capacity (System)", bundle: .module), data.maximumCapacityPercent, data: data) {
                        DisplayFormat.percent(Int($0.rounded()))
                    }
                    chart(Text("Full Charge / Design", bundle: .module), data.capacityRatioPercent, data: data) {
                        DisplayFormat.percent(ratio: $0 / 100)
                    }
                    chart(Text("Full Charge Capacity", bundle: .module), data.fullChargeCapacityMAh, data: data) {
                        "\(DisplayFormat.number(Int($0.rounded()))) mAh"
                    }
                    chart(Text("Cycle Count", bundle: .module), data.cycleCount, data: data) {
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
        _ series: ChartSeries,
        data: LongTermChartData,
        formatValue: @escaping (Double) -> String
    ) -> MetricChart {
        MetricChart(
            title: title,
            series: series,
            domain: data.domain,
            maxGap: data.maxGap,
            notRecorded: data.notRecorded,
            style: .line(.brand),
            formatValue: formatValue,
            formatDate: { $0.formatted(.dateTime.year().month(.abbreviated).day()) },
            hoverDate: $hoverDate
        )
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

// MARK: - 预览

#if DEBUG
/// 历史页的示例数据，写入内存数据库：最近 48 小时的分钟数据（每 4 小时交替使用电池和接电，中间有一段休眠缺口），
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
