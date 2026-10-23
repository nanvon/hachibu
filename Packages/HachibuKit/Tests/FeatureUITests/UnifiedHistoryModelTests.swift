import Foundation
import HistoryStore
import Testing
@testable import FeatureUI

@Suite @MainActor struct UnifiedHistoryModelTests {
    @Test func importedHistoryAndNativeMeasurementsAppearInTheSamePage() async throws {
        let store = try HistoryStore.inMemory()
        let model = HistoryModel(store: store)
        await model.reload()
        #expect(model.records?.totalCount == 0)
        let timestamp = Date(timeIntervalSince1970: 978_307_200)
        _ = try await store.importAlDenteArchive(unifiedArchive())
        try await store.write(MinuteSample(timestamp: Date().addingTimeInterval(-120), percent: 90, temperatureCelsius: 30))
        try await store.write(DailySample(day: DailySample.day(for: Date()), cycleCount: 150, updatedAt: Date()))
        await model.reloadAfterImport()
        #expect(model.recentRange == .all)
        #expect(model.longTermRange == .all)
        #expect(model.recent?.percent.first?.value == 80)
        #expect(model.recent?.percent.last?.value == 90)
        #expect(model.longTerm?.cycleCount.first?.value == 80)
        #expect(model.longTerm?.cycleCount.last?.value == 150)
        #expect(model.summary?.firstDay == DailySample.day(for: timestamp))
        #expect(model.records?.totalCount == 16)
        await model.selectRecordMetric(.calibration)
        #expect(model.records?.totalCount == 1)
        #expect(model.records?.records.first?.metric == .calibration)
        #expect(model.recordError == nil)
    }

    @Test func allRangeIncludesTheFirstPartialHourAndKeepsGaps() {
        let first = Date(timeIntervalSince1970: 978_307_243)
        let now = first.addingTimeInterval(10 * 86400)
        let hour = Date(timeIntervalSince1970: 978_307_200)
        let data = HistoryChartBuilder.recent(hourlySamples: [
            HourlySample(hour: hour, sampleCount: 1, externalMinutes: 0, percentAverage: 70, chargeLimitPercent: 80),
            HourlySample(hour: hour.addingTimeInterval(5 * 86400), sampleCount: 1, externalMinutes: 0, percentAverage: 75),
        ], range: .all, now: now, firstRecordedAt: first)
        #expect(data.domain.lowerBound == hour)
        #expect(data.percent.count == 2)
        #expect(data.percent.first?.segment != data.percent.last?.segment)
        #expect(data.pluggedIn.isEmpty)
        #expect(data.chargeLimit.first?.value == 80)
    }

    @Test func exactValuesAndTextRemainReadable() {
        #expect(HistoryValue.integer(Int64.max).description == "9223372036854775807")
        #expect(HistoryValue.real(-0.0).description == "-0.0")
        #expect(HistoryValue.text("").description == "\"\"")
        #expect(HistoryValue.text("a\nb").description == "\"a\\nb\"")
    }
}

private func unifiedArchive() throws -> AlDenteArchive {
    let prompt = try AlDenteExportGuide.prompt(localization: "en")
    let start = try #require(prompt.range(of: "```json\n", options: .backwards))
    let end = try #require(prompt.range(of: "\n```", range: start.upperBound..<prompt.endIndex))
    var root = try #require(JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
    var tables = try #require(root["tables"] as? [String: [String: Any]])
    for name in Array(tables.keys) {
        var table = try #require(tables[name])
        let columns = try #require(table["columns"] as? [[String: Any]])
        let value: Any = columns[2]["type"] as? String == "TEXT" ? "fixture" : 80
        table["rows"] = [["id": 1, "timestamp": "2001-01-01T00:00:00.000", "value": value]]
        table["rowCount"] = 1
        tables[name] = table
    }
    root["tables"] = tables
    return try AlDenteArchive(data: JSONSerialization.data(withJSONObject: root))
}
