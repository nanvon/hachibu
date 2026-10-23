import Foundation
import HistoryStore
import Observation

/// 独立来源档案的只读浏览数据，不参与 Hachibu 历史曲线计算。
@MainActor
@Observable
public final class AlDenteHistoryModel {
    private(set) var imports: [AlDenteImportSummary] = []
    private(set) var selectedImportID: String?
    private(set) var selectedTable: AlDenteTable = .batteryCycles
    private(set) var tables: [AlDenteTableSummary] = []
    private(set) var page: AlDenteRecordPage?
    private(set) var presentation: AlDenteHistoryPresentation = .chart
    private(set) var chartRange: AlDenteChartRange = .all
    private(set) var chartData: AlDenteChartData?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var chartCache: (identifier: String, table: AlDenteTable, series: AlDenteChartSeries)?
    private var offset = 0

    public init(store: HistoryStore) {
        self.store = store
    }

    var selectedImport: AlDenteImportSummary? {
        imports.first { $0.id == selectedImportID }
    }

    var selectedSummary: AlDenteTableSummary? {
        tables.first { $0.table == selectedTable }
    }

    var isShowingChart: Bool { presentation == .chart && selectedTable.supportsChart }

    func setPresentation(_ presentation: AlDenteHistoryPresentation) async {
        self.presentation = presentation
        await loadSelection()
    }

    func setChartRange(_ range: AlDenteChartRange) async {
        chartRange = range
        await loadSelection()
    }

    public func reload() async {
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        page = nil
        chartData = nil
        defer { if request == generation { isLoading = false } }
        do {
            let imports = try await store.alDenteImports()
            guard request == generation, !Task.isCancelled else { return }
            self.imports = imports
            if !imports.contains(where: { $0.id == selectedImportID }) {
                selectedImportID = imports.first?.id
                offset = 0
            }
            await loadSelection()
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = Self.errorDescription(error)
        }
    }

    func selectImport(_ identifier: String) async {
        guard imports.contains(where: { $0.id == identifier }) else { return }
        selectedImportID = identifier
        offset = 0
        await loadSelection()
    }

    func selectTable(_ table: AlDenteTable) async {
        selectedTable = table
        offset = 0
        await loadSelection()
    }

    func nextPage() async {
        guard let page, page.offset + page.records.count < page.totalCount else { return }
        offset = page.offset + page.limit
        await loadSelection()
    }

    func previousPage() async {
        guard let page, page.offset > 0 else { return }
        offset = max(0, page.offset - page.limit)
        await loadSelection()
    }

    private func loadSelection() async {
        generation += 1
        let request = generation
        let identifier = selectedImportID
        let table = selectedTable
        let offset = offset
        let range = chartRange
        let wantsChart = isShowingChart
        isLoading = true
        errorMessage = nil
        page = nil
        chartData = nil
        tables = []
        defer { if request == generation { isLoading = false } }
        guard let identifier else { return }
        do {
            let tables = try await store.alDenteTableSummaries(importIdentifier: identifier)
            let page = try await store.alDenteRecordPage(importIdentifier: identifier, table: table, offset: offset)
            var series: AlDenteChartSeries?
            var chart: AlDenteChartData?
            if wantsChart {
                let loaded: AlDenteChartSeries
                if let cached = chartCache, cached.identifier == identifier, cached.table == table {
                    loaded = cached.series
                } else {
                    let records = try await store.alDenteRecords(importIdentifier: identifier, table: table)
                    loaded = await Task.detached(priority: .userInitiated) {
                        AlDenteChartSeries(records: records, table: table)
                    }.value
                }
                series = loaded
                chart = await Task.detached(priority: .userInitiated) { loaded.chart(range: range) }.value
            }
            guard request == generation, !Task.isCancelled else { return }
            self.tables = tables
            self.page = page
            self.chartData = chart
            if let series { chartCache = (identifier, table, series) }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = Self.errorDescription(error)
        }
    }

    private static func errorDescription(_ error: any Error) -> String {
        switch error {
        case AlDenteHistoryError.archiveNotFound:
            String(localized: "The imported archive could not be found.", bundle: .module)
        case AlDenteHistoryError.invalidStoredRecord:
            String(localized: "A stored source record is invalid. The original archive has not been changed.", bundle: .module)
        default: error.localizedDescription
        }
    }
}

extension AlDenteValue {
    /// 浮点使用可往返的十进制表示；文本带引号及转义，空字符串不会显示成缺失值。
    var sourceDescription: String {
        switch self {
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .text(let value): String(reflecting: value)
        }
    }
}
