import Foundation
import HistoryStore
import Testing
@testable import FeatureUI

@Suite @MainActor struct AlDenteHistoryModelTests {
    @Test func emptyStoreFinishesLoading() async throws {
        let model = AlDenteHistoryModel(store: try HistoryStore.inMemory())
        await model.reload()
        #expect(model.imports.isEmpty)
        #expect(model.selectedImportID == nil)
        #expect(model.page == nil)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    @Test func changingSourceResetsPaginationAndReloadFindsNewImports() async throws {
        let store = try HistoryStore.inMemory()
        let first = try modelArchive(version: "first")
        _ = try await store.importAlDenteArchive(first)
        let model = AlDenteHistoryModel(store: store)
        await model.reload()
        #expect(model.selectedImportID == first.identifier)
        #expect(model.tables.count == 13)
        #expect(model.page?.records.count == 200)
        #expect(model.isShowingChart)
        #expect(model.chartData?.sourcePointCount == 201) // 曲线不能只加载明细的第一页。
        await model.setChartRange(.day)
        #expect(model.chartRange == .day)
        #expect(model.chartData?.sourcePointCount == 201)
        await model.setPresentation(.records)
        #expect(model.chartData == nil)
        await model.nextPage()
        #expect(model.page?.offset == 200)
        #expect(model.page?.records.count == 1)
        await model.previousPage()
        #expect(model.page?.offset == 0)
        await model.nextPage()
        await model.selectTable(.batterySerial)
        #expect(model.page?.offset == 0)
        #expect(model.page?.records.first?.value == .text("fixture-device"))
        await model.setPresentation(.chart)
        #expect(!model.isShowingChart)
        #expect(model.chartData == nil)
        let second = try modelArchive(version: "second")
        _ = try await store.importAlDenteArchive(second)
        await model.reload()
        #expect(model.imports.count == 2)
        #expect(model.selectedImportID == first.identifier)
        await model.selectImport(second.identifier)
        #expect(model.selectedImportID == second.identifier)
        #expect(model.page?.offset == 0)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    @Test func displaysEmptyTextNegativeZeroAndFullPrecision() {
        #expect(AlDenteValue.text("").sourceDescription == "\"\"")
        #expect(AlDenteValue.text("a\nb").sourceDescription == "\"a\\nb\"")
        #expect(AlDenteValue.integer(Int64.max).sourceDescription == "9223372036854775807")
        #expect(AlDenteValue.real(-0.0).sourceDescription == "-0.0")
        let value = 108.873723456789
        #expect(Double(AlDenteValue.real(value).sourceDescription)?.bitPattern == value.bitPattern)
    }
}

/// 仅使用合成记录，避免将本机序列号或其他来源历史写入测试。
private func modelArchive(version: String) throws -> AlDenteArchive {
    var tables: [String: Any] = [:]
    var schema: [[String: Any]] = []
    for table in AlDenteTable.allCases {
        let type: String
        let value: Any
        switch table {
        case .batterySerial, .macOSbatteryCondition:
            type = "TEXT"; value = "fixture-device"
        case .batteryTemp, .chargingPower, .lastCalibration, .systemLoad, .systemPowerIn:
            type = "REAL"; value = 1.5
        default:
            type = "INTEGER"; value = 80
        }
        let columns: [[String: Any]] = ["id", "timestamp", "value"].enumerated().map { index, name in
            ["position": index, "name": name, "type": index == 0 ? "INTEGER" : index == 1 ? "TEXT" : type,
             "notNull": 1, "default": NSNull(), "primaryKey": index == 0 ? 1 : 0]
        }
        let rows: [[String: Any]] = (1...(table == .batteryCycles ? 201 : 1)).map { id in
            ["id": id, "timestamp": "2026-10-23T00:00:00.000", "value": value]
        }
        tables[table.rawValue] = ["columns": columns, "rowCount": rows.count, "rows": rows]
        schema.append(["type": "table", "name": table.rawValue, "table": table.rawValue, "sql": "fixture"])
    }
    return try AlDenteArchive(data: JSONSerialization.data(withJSONObject: [
        "format": "hachibu.aldente.raw", "formatVersion": 1,
        "source": ["app": "AlDente", "bundleIdentifier": "com.apphousekitchen.aldente-pro",
                   "version": version, "build": "fixture"],
        "schema": schema, "tables": tables,
    ]))
}
