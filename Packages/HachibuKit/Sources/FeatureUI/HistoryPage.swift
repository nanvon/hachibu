import HistoryStore
import SwiftUI

/// 历史曲线页：近期、长期两组，各自独立的时间范围。规则见 docs/v1技术设计.md 第 11 节。
struct HistoryPage: View {
    let model: HistoryModel

    var body: some View {
        if model.isAvailable {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    RecentSection(model: model)
                    LongTermSection(model: model)
                    HistoryRecordsSection(model: model)
                }
                .padding(24)
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

private struct RecentSection: View {
    let model: HistoryModel
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: Text("Recent", bundle: .module)) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green.opacity(0.2))
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
                MetricChart(
                    title: Text("Battery Level", bundle: .module),
                    points: data.percent,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    bands: data.pluggedIn,
                    notRecorded: data.notRecorded,
                    yScale: .fixed(0...100),
                    color: .brand,
                    formatValue: { DisplayFormat.percent(Int(exactly: $0.rounded())) },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                MetricChart(
                    title: Text("System Power", bundle: .module),
                    points: data.systemPowerWatts,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    bands: data.pluggedIn,
                    notRecorded: data.notRecorded,
                    yScale: .automatic(includesZero: true),
                    color: .orange,
                    formatValue: { DisplayFormat.watts(milliwatts: Int(exactly: ($0 * 1000).rounded())) },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                MetricChart(
                    title: Text("Temperature", bundle: .module),
                    points: data.temperatureCelsius,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    bands: data.pluggedIn,
                    notRecorded: data.notRecorded,
                    color: .red,
                    formatValue: { DisplayFormat.celsius($0) },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                if !data.chargeLimit.isEmpty {
                    MetricChart(
                        title: Text("Charge Limit History", bundle: .module),
                        points: data.chargeLimit, domain: data.domain, maxGap: data.maxGap,
                        interpolation: .stepEnd, color: .brand,
                        formatValue: { DisplayFormat.percent(Int(exactly: $0.rounded())) },
                        formatDate: formatDate, hoverDate: $hoverDate
                    )
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private static func title(_ range: RecentRange) -> Text {
        switch range {
        case .hour: Text("1 Hour", bundle: .module)
        case .day: Text("24 Hours", bundle: .module)
        case .week: Text("7 Days", bundle: .module)
        case .month: Text("30 Days", bundle: .module)
        case .all: Text("All", bundle: .module)
        }
    }

    private static func dateFormatter(_ range: RecentRange) -> (Date) -> String {
        switch range {
        case .hour: { $0.formatted(.dateTime.hour().minute()) }
        case .day: { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        case .week, .month: { $0.formatted(.dateTime.month(.abbreviated).day().hour()) }
        case .all: { $0.formatted(.dateTime.year().month(.abbreviated).day().hour()) }
        }
    }
}

// MARK: - 长期

private struct LongTermSection: View {
    let model: HistoryModel
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                let formatDate: (Date) -> String = { $0.formatted(.dateTime.year().month(.abbreviated).day()) }
                MetricChart(
                    title: Text("Maximum Capacity", bundle: .module),
                    points: data.maximumCapacityPercent,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    notRecorded: data.notRecorded,
                    color: .brand,
                    formatValue: { DisplayFormat.percent(Int(exactly: $0.rounded())) },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                MetricChart(
                    title: Text("Full Charge Capacity", bundle: .module),
                    points: data.fullChargeCapacityMAh,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    notRecorded: data.notRecorded,
                    color: .brand,
                    formatValue: { "\(DisplayFormat.number(Int(exactly: $0.rounded()))) mAh" },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                // stepEnd 在后一个点处跳变，台阶落在数值变化的那一天。
                MetricChart(
                    title: Text("Cycle Count", bundle: .module),
                    points: data.cycleCount,
                    domain: data.domain,
                    maxGap: data.maxGap,
                    notRecorded: data.notRecorded,
                    interpolation: .stepEnd,
                    color: .brand,
                    formatValue: { DisplayFormat.number(Int(exactly: $0.rounded())) },
                    formatDate: formatDate,
                    hoverDate: $hoverDate
                )
                if !data.designCapacityMAh.isEmpty {
                    MetricChart(
                        title: Text("Design Capacity", bundle: .module),
                        points: data.designCapacityMAh, domain: data.domain, maxGap: data.maxGap,
                        color: .brand,
                        formatValue: { "\(DisplayFormat.number(Int(exactly: $0.rounded()))) mAh" },
                        formatDate: formatDate, hoverDate: $hoverDate
                    )
                }
            } else {
                LoadingPlaceholder()
            }
        }
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

private struct SectionHeader<Accessory: View>: View {
    let title: Text
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            title
                .font(.headline)
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
