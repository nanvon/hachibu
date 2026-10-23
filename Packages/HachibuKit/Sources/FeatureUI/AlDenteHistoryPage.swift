import HistoryStore
import SwiftUI

/// 窗口与保存对话框由 AppKit 管理；本页独立展示来源曲线和原始记录。
public struct AlDenteHistoryPage: View {
    private let model: AlDenteHistoryModel
    private let onExport: @MainActor (String) async -> Void
    @State private var isExporting = false

    public init(model: AlDenteHistoryModel, onExport: @escaping @MainActor (String) async -> Void) {
        self.model = model
        self.onExport = onExport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imported AlDente History", bundle: .module)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await model.reload() }
                } label: {
                    Text("Refresh", bundle: .module)
                }
                .disabled(model.isLoading)
            }
            if let error = model.errorMessage {
                Text(verbatim: error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !model.imports.isEmpty {
                archivePicker
                if let batch = model.selectedImport {
                    Text("\(batch.recordCount) source records", bundle: .module)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "SHA-256: \(batch.id)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                tablePicker
                if model.selectedTable.supportsChart {
                    presentationPicker
                } else {
                    Text("Calibration, battery condition, and battery identifiers are shown as original records.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summary = model.selectedSummary {
                    Text(verbatim: "\(summary.firstTimestamp ?? "—") → \(summary.lastTimestamp ?? "—")")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if model.isShowingChart {
                    if let data = model.chartData {
                        AlDenteChartView(data: data, table: model.selectedTable)
                    } else {
                        Spacer()
                    }
                } else {
                    records
                    pagination
                    Text("Source timestamps and values are shown without timezone or unit conversion. Text values are quoted; an empty string appears as \"\". Records are ordered by the original timestamp, newest first.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !model.isLoading, model.errorMessage == nil {
                ContentUnavailableView {
                    Label {
                        Text("No Imported Archives", bundle: .module)
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                } description: {
                    Text("Import an AlDente history file in Settings → Historical Data.", bundle: .module)
                }
            }
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 800, minHeight: 540)
    }

    private var presentationPicker: some View {
        HStack {
            Picker(selection: Binding(
                get: { model.presentation },
                set: { value in Task { await model.setPresentation(value) } }
            )) {
                Text("Chart", bundle: .module).tag(AlDenteHistoryPresentation.chart)
                Text("Original Records", bundle: .module).tag(AlDenteHistoryPresentation.records)
            } label: {
                Text("Display", bundle: .module)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            if model.isShowingChart {
                Picker(selection: Binding(
                    get: { model.chartRange },
                    set: { value in Task { await model.setChartRange(value) } }
                )) {
                    ForEach(AlDenteChartRange.allCases, id: \.self) { range in
                        range.title.tag(range)
                    }
                } label: {
                    Text("Time Range", bundle: .module)
                }
                .frame(maxWidth: 240)
            }
        }
        .disabled(model.isLoading)
    }

    private var archivePicker: some View {
        HStack {
            Picker(selection: Binding(
                get: { model.selectedImportID ?? "" },
                set: { identifier in Task { await model.selectImport(identifier) } }
            )) {
                ForEach(model.imports) { batch in
                    Text(verbatim: "\(batch.importedAt.formatted(date: .abbreviated, time: .standard)) · AlDente \(batch.sourceVersion) (\(batch.sourceBuild)) · \(batch.id.prefix(8))")
                        .tag(batch.id)
                }
            } label: {
                Text("Import Batch", bundle: .module)
            }
            .disabled(model.isLoading)
            Button {
                guard let identifier = model.selectedImportID else { return }
                isExporting = true
                Task {
                    defer { isExporting = false }
                    await onExport(identifier)
                }
            } label: {
                Text("Export Original File…", bundle: .module)
            }
            .disabled(isExporting || model.isLoading || model.selectedImportID == nil)
        }
    }

    private var tablePicker: some View {
        Picker(selection: Binding(
            get: { model.selectedTable },
            set: { table in Task { await model.selectTable(table) } }
        )) {
            ForEach(AlDenteTable.allCases, id: \.self) { table in
                let count = model.tables.first { $0.table == table }?.recordCount ?? 0
                Text(verbatim: "\(table.localizedTitle) · \(table.rawValue) (\(count))")
                    .tag(table)
            }
        } label: {
            Text("Source Table", bundle: .module)
        }
        .disabled(model.isLoading)
    }

    private var records: some View {
        Table(model.page?.records ?? []) {
            TableColumn(String(localized: "Source ID", bundle: .module)) { record in
                Text(verbatim: String(record.sourceID)).monospacedDigit().textSelection(.enabled)
            }
            .width(min: 70, ideal: 90, max: 140)
            TableColumn(String(localized: "Original Timestamp", bundle: .module)) { record in
                Text(verbatim: record.timestamp).monospaced().textSelection(.enabled)
            }
            .width(min: 220, ideal: 250, max: 320)
            TableColumn(String(localized: "Original Value", bundle: .module)) { record in
                Text(verbatim: record.value.sourceDescription).monospaced().textSelection(.enabled)
            }
        }
        .overlay {
            if let page = model.page, page.totalCount == 0 {
                Text("This source table has no records.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pagination: some View {
        HStack {
            if let page = model.page {
                let first = page.records.isEmpty ? 0 : page.offset + 1
                Text("\(first)–\(page.offset + page.records.count) of \(page.totalCount) records", bundle: .module)
                    .monospacedDigit()
            }
            Spacer()
            Button { Task { await model.previousPage() } } label: {
                Text("Previous Page", bundle: .module)
            }
            .disabled(model.isLoading || (model.page?.offset ?? 0) == 0)
            Button { Task { await model.nextPage() } } label: {
                Text("Next Page", bundle: .module)
            }
            .disabled(model.isLoading || model.page == nil
                || (model.page.map { $0.offset + $0.records.count >= $0.totalCount } ?? true))
        }
    }
}

extension AlDenteChartRange {
    var title: Text {
        switch self {
        case .day: Text("24 Hours", bundle: .module)
        case .week: Text("7 Days", bundle: .module)
        case .month: Text("30 Days", bundle: .module)
        case .year: Text("1 Year", bundle: .module)
        case .all: Text("All", bundle: .module)
        }
    }
}

extension AlDenteTable {
    var localizedTitle: String {
        switch self {
        case .batteryCycles: String(localized: "Cycle Count", bundle: .module)
        case .batteryDesignCap: String(localized: "Design Capacity", bundle: .module)
        case .batteryMaxCap: String(localized: "Full Charge Capacity", bundle: .module)
        case .batteryPercentage: String(localized: "Battery Level", bundle: .module)
        case .batterySerial: String(localized: "Battery Identifier", bundle: .module)
        case .batteryTemp: String(localized: "Temperature", bundle: .module)
        case .chargeLimit: String(localized: "Charge Limit History", bundle: .module)
        case .chargingPower: String(localized: "Battery Power", bundle: .module)
        case .lastCalibration: String(localized: "Calibration Records", bundle: .module)
        case .macOSbatteryCondition: String(localized: "Battery Condition", bundle: .module)
        case .macOSbatteryMaxCap: String(localized: "System Maximum Capacity", bundle: .module)
        case .systemLoad: String(localized: "System Power", bundle: .module)
        case .systemPowerIn: String(localized: "Input Power", bundle: .module)
        }
    }
}
