import Foundation
import HistoryStore
import SwiftUI

/// 历史页中的完整明细，没有来源或批次选择。无法转换的记录仍能查看原值。
struct HistoryRecordsSection: View {
    let model: HistoryModel

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Picker(selection: Binding(
                    get: { model.recordMetric },
                    set: { metric in Task { await model.selectRecordMetric(metric) } }
                )) {
                    Text("All Metrics", bundle: .module).tag(Optional<HistoryMetric>.none)
                    ForEach(HistoryMetric.allCases, id: \.self) { metric in
                        Text(verbatim: metric.title).tag(Optional(metric))
                    }
                } label: {
                    Text("Metric", bundle: .module)
                }
                if let error = model.recordError {
                    Text(verbatim: error).foregroundStyle(.red)
                    Button { Task { await model.loadRecords(offset: model.records?.offset ?? 0) } } label: {
                        Text("Retry", bundle: .module)
                    }
                }
                Table(model.records?.records ?? []) {
                    TableColumn(String(localized: "Metric", bundle: .module)) { record in
                        Text(verbatim: record.metric.title)
                    }
                    TableColumn(String(localized: "Recorded At", bundle: .module)) { record in
                        Text(verbatim: record.date?.formatted(date: .abbreviated, time: .standard) ?? record.originalTimestamp)
                            .textSelection(.enabled)
                            .help(record.originalTimestamp)
                    }
                    TableColumn(String(localized: "Value", bundle: .module)) { record in
                        Text(verbatim: Self.displayValue(record)).textSelection(.enabled)
                    }
                }
                .frame(height: 300)
                HStack {
                    if let page = model.records {
                        let first = page.records.isEmpty ? 0 : page.offset + 1
                        Text("\(first)–\(page.offset + page.records.count) of \(page.totalCount) records", bundle: .module)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button { Task { await model.loadRecords(offset: max(0, (model.records?.offset ?? 0) - 200)) } } label: {
                        Text("Previous Page", bundle: .module)
                    }
                    .disabled((model.records?.offset ?? 0) == 0)
                    Button { Task { await model.loadRecords(offset: (model.records?.offset ?? 0) + 200) } } label: {
                        Text("Next Page", bundle: .module)
                    }
                    .disabled(model.records.map { $0.offset + $0.records.count >= $0.totalCount } ?? true)
                }
                Text("All original values are preserved. Power records without a verified unit are shown here without conversion. Records without a valid time remain available here and are excluded from charts.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        } label: {
            Text("Historical Records", bundle: .module).font(.headline)
        }
    }

    static func displayValue(_ record: HistoryRecord) -> String {
        if record.metric == .calibration, case .real(let seconds) = record.value,
           seconds >= Date.distantPast.timeIntervalSince1970, seconds <= Date.distantFuture.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: seconds)
            return "\(date.formatted(date: .abbreviated, time: .standard)) (\(record.value.description))"
        }
        if record.isUnitUnverified {
            return String(localized: "\(record.value.description) (unit unverified)", bundle: .module)
        }
        return record.value.description + (record.unit.map { " \($0)" } ?? "")
    }
}

extension HistoryMetric {
    var title: String {
        switch self {
        case .percent: String(localized: "Battery Level", bundle: .module)
        case .temperature: String(localized: "Temperature", bundle: .module)
        case .cycleCount: String(localized: "Cycle Count", bundle: .module)
        case .fullChargeCapacity: String(localized: "Full Charge Capacity", bundle: .module)
        case .designCapacity: String(localized: "Design Capacity", bundle: .module)
        case .maximumCapacity: String(localized: "System Maximum Capacity", bundle: .module)
        case .chargeLimit: String(localized: "Charge Limit History", bundle: .module)
        case .batteryPower: String(localized: "Battery Power", bundle: .module)
        case .systemPower: String(localized: "System Power", bundle: .module)
        case .inputPower: String(localized: "Input Power", bundle: .module)
        case .calibration: String(localized: "Calibration Records", bundle: .module)
        case .condition: String(localized: "Battery Condition", bundle: .module)
        case .batteryIdentifier: String(localized: "Battery Identifier", bundle: .module)
        }
    }
}
