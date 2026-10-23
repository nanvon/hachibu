import Foundation
import Testing
@testable import FeatureUI
@testable import HistoryStore

@Suite struct AlDenteChartTests {
    @Test func parsesUTCMillisecondsAndReportsInvalidTimesAndInexactIntegers() {
        let series = AlDenteChartSeries(records: [
            record("valid", "2026-10-23T00:00:00.125", .real(-1.5)),
            record("invalid-day", "2026-02-30T00:00:00.000", .integer(80)),
            record("invalid-format", "2026-10-23", .integer(80)),
            record("integer", "2026-10-23T00:01:00.000", .integer(Int64.max)),
        ], table: .chargingPower)
        #expect(series.points.count == 1)
        #expect(series.points.first?.date == Date(timeIntervalSince1970: 1_792_713_600.125))
        #expect(series.points.first?.value == -1.5)
        #expect(series.points.first?.sourceValue == "-1.5")
        #expect(series.invalidTimestampCount == 2)
        #expect(series.unplottableValueCount == 1)
    }

    @Test func rangesEndAtLatestSourceTimeAndIncludeTheirBoundary() {
        let series = AlDenteChartSeries(records: [
            record("old", "2025-01-01T00:00:00.000"),
            record("before", "2026-10-21T23:59:59.999"),
            record("boundary", "2026-10-22T00:00:00.000"),
            record("last", "2026-10-23T00:00:00.000"),
        ], table: .batteryPercentage)
        let day = series.chart(range: .day)
        #expect(day.sourcePointCount == 2)
        #expect(day.points.map(\.id) == ["boundary", "last"])
        #expect(day.domain?.upperBound == series.points.last?.date)
        #expect(day.domain?.upperBound.timeIntervalSince(day.domain!.lowerBound) == 86_400)
        #expect(series.chart(range: .week).sourcePointCount == 3)
        #expect(series.chart(range: .year).sourcePointCount == 3)
        #expect(series.chart(range: .all).sourcePointCount == 4)
    }

    @Test func keepsSinglePointsVisibleAndEmptySeriesHasNoDomain() {
        let series = AlDenteChartSeries(records: [record("only", "2026-10-23T00:00:00.000")], table: .batteryDesignCap)
        let all = series.chart(range: .all)
        #expect(all.points.count == 1)
        #expect(all.domain!.upperBound > all.domain!.lowerBound)
        #expect(all.domain!.contains(series.points[0].date))
        #expect(AlDenteChartSeries(records: [], table: .batteryTemp).chart(range: .all).domain == nil)
    }

    @Test func breaksOnlyBeyondTheGapThresholdAndSeparatesDuplicateTimes() {
        let records = [
            record("a", "2026-10-23T00:00:00.000"),
            record("b", "2026-10-23T00:03:00.000"),
            record("c", "2026-10-23T00:06:00.001"),
            record("d", "2026-10-23T00:07:00.000", .integer(81)),
            record("e", "2026-10-23T00:07:00.000", .integer(82)),
            record("f", "2026-10-23T00:08:00.000"),
        ]
        let series = AlDenteChartSeries(records: Array(records.reversed()), table: .batteryPercentage)
        #expect(series.points.map(\.id) == ["a", "b", "c", "d", "e", "f"])
        #expect(series.points[0].segment == series.points[1].segment)
        #expect(series.points[1].segment != series.points[2].segment)
        #expect(Set(series.points.dropFirst(2).map(\.segment)).count == 4)
        #expect(series.duplicateTimestampCount == 2)
        let daily = AlDenteChartSeries(records: [
            record("a", "2026-10-01T00:00:00.000"), record("b", "2026-10-04T00:00:00.000"),
            record("c", "2026-10-07T00:00:00.001"),
        ], table: .batteryMaxCap)
        #expect(daily.points.map(\.segment) == [0, 0, 1])
    }

    @Test func denseChartsRetainExtremesAndDoNotJoinSeparateSegments() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date(timeIntervalSince1970: 1_792_713_600)
        let records = (0..<6000).map { index in
            let seconds = index < 3000 ? index : index + 1000
            let timestamp = String(formatter.string(from: start.addingTimeInterval(Double(seconds))).dropLast())
            let value: Double = index == 111 ? -1234 : index == 5998 ? 9876 : 80
            return record(String(index), timestamp, .real(value))
        }
        let series = AlDenteChartSeries(records: records, table: .batteryTemp)
        let chart = series.chart(range: .all)
        #expect(chart.sourcePointCount == 6000)
        #expect(chart.points.count < 6000)
        #expect(chart.points.first?.id == "0")
        #expect(chart.points.last?.id == "5999")
        #expect(chart.points.map(\.value).min() == -1234)
        #expect(chart.points.map(\.value).max() == 9876)
        #expect(Set(chart.points.map(\.segment)) == [0, 1])
        #expect(chart.points.contains { $0.id == "2999" })
        #expect(chart.points.contains { $0.id == "3000" })
        #expect(series.points.count == 6000)
        let drawnIDs = Set(chart.points.map(\.id))
        let omitted = try #require(series.points.first { !drawnIDs.contains($0.id) })
        #expect(chart.nearest(to: omitted.date, within: 0)?.id == omitted.id)
        let gap = start.addingTimeInterval(3500)
        #expect(chart.nearest(to: gap, within: 90) == nil)
    }

    @Test func detailOnlyMetricsAreNotTreatedAsContinuousMeasurements() {
        #expect(!AlDenteTable.lastCalibration.supportsChart)
        #expect(!AlDenteTable.batterySerial.supportsChart)
        #expect(!AlDenteTable.macOSbatteryCondition.supportsChart)
        #expect(AlDenteTable.allCases.filter(\.supportsChart).count == 10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_ALDENTE_VALIDATION_FILE"] != nil))
    func fullLocalExportBuildsAllNumericChartsWithoutDiscardingSourceValues() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HACHIBU_ALDENTE_VALIDATION_FILE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let archive = try AlDenteArchive(data: data)
        let store = try HistoryStore.inMemory()
        _ = try await store.importAlDenteArchive(archive)
        for summary in archive.tables where summary.table.supportsChart {
            let records = try await store.alDenteRecords(importIdentifier: archive.identifier, table: summary.table)
            let series = AlDenteChartSeries(records: records, table: summary.table)
            let chart = series.chart(range: .all)
            #expect(records.count == summary.recordCount)
            #expect(chart.sourcePointCount == summary.recordCount)
            #expect(chart.invalidTimestampCount == 0)
            #expect(chart.unplottableValueCount == 0)
            let originalValues = records.compactMap { record -> Double? in
                switch record.value {
                case .integer(let value): Double(exactly: value)
                case .real(let value): value
                case .text: nil
                }
            }
            #expect(chart.points.map(\.value).min() == originalValues.min())
            #expect(chart.points.map(\.value).max() == originalValues.max())
        }
        #expect(try await store.alDenteArchiveData(identifier: archive.identifier) == data)
    }
}

private func record(_ id: String, _ timestamp: String, _ value: AlDenteValue = .integer(80)) -> AlDenteHistoryRecord {
    AlDenteHistoryRecord(id: id, sourceID: 1, timestamp: timestamp, value: value)
}
