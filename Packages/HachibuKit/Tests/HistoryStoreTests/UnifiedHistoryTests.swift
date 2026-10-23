import Foundation
import GRDB
import Testing
@testable import HistoryStore

@Suite struct UnifiedHistoryTests {
    private var timestamp: Date { HistoryStore.historyTimestampFormatter().date(from: "2026-10-22T08:13:43.766")! }

    @Test func importFeedsExistingHistoryQueriesAndRetainsEveryMetric() async throws {
        let store = try HistoryStore.inMemory()
        let archive = try AlDenteArchive(data: archiveFixture())
        _ = try await store.importAlDenteArchive(archive)
        let minutes = try await store.minuteSamples(from: timestamp.addingTimeInterval(-60), to: timestamp.addingTimeInterval(60))
        let sample = try #require(minutes.first)
        #expect(sample.percent == 0)
        #expect(sample.temperatureCelsius == -1.5)
        #expect(sample.chargeLimitPercent == 0)
        #expect(sample.isExternalPower == nil)
        #expect(sample.isCharging == nil)
        #expect(sample.systemLoadMW == nil)
        #expect(sample.batteryPowerMW == nil)
        #expect(sample.powerInMW == nil)
        let daily = try #require(try await store.dailySamples().first)
        #expect(daily.fullChargeCapacityMAh == 0)
        #expect(daily.systemMaxCapacityPercent == 0)
        #expect(daily.designCapacityMAh == 0)
        #expect(daily.cycleCount == 0)
        #expect(daily.day == DailySample.day(for: timestamp))
        let page = try await store.historyRecords()
        #expect(page.totalCount == 13)
        #expect(Set(page.records.map(\.metric)) == Set(HistoryMetric.allCases))
        #expect(try await store.recordingSummary()?.firstDay == daily.day)
        #expect(try await store.firstSampleTime() == MinuteSample(timestamp: timestamp).timestamp)
        #expect(try await store.latestMinuteSampleTime() == MinuteSample(timestamp: timestamp).timestamp)
        _ = try await store.importAlDenteArchive(archive)
        #expect(try await store.historyRecords().totalCount == 13)
    }

    @Test func nativeValuesWinAndImportsFillOnlyMissingFields() async throws {
        let store = try HistoryStore.inMemory()
        let native = MinuteSample(timestamp: timestamp, percent: 75, isExternalPower: true,
            isCharging: false, systemLoadMW: 12000)
        try await store.write(native)
        try await store.write(DailySample(day: DailySample.day(for: timestamp), fullChargeCapacityMAh: 8000, updatedAt: timestamp))
        _ = try await store.importAlDenteArchive(AlDenteArchive(data: archiveFixture()))
        let merged = try #require(try await store.minuteSamples(from: timestamp.addingTimeInterval(-60), to: timestamp.addingTimeInterval(60)).first)
        #expect(merged.percent == 75)
        #expect(merged.temperatureCelsius == -1.5)
        #expect(merged.systemLoadMW == 12000)
        #expect(merged.isExternalPower == true)
        let daily = try #require(try await store.dailySamples().first)
        #expect(daily.fullChargeCapacityMAh == 8000)
        #expect(daily.cycleCount == 0)
        let stored = try await store.dbQueue.read { db in try MinuteSample.fetchAll(db) }
        #expect(stored == [native])
        try await store.write(MinuteSample(timestamp: timestamp, percent: 90, temperatureCelsius: 30))
        let refreshed = try #require(try await store.minuteSamples(from: timestamp.addingTimeInterval(-60), to: timestamp.addingTimeInterval(60)).first)
        #expect(refreshed.percent == 90)
        #expect(refreshed.temperatureCelsius == 30)
    }

    @Test func latestValueIsChosenIndependentlyForEachMetricAndLocalDay() async throws {
        let store = try HistoryStore.inMemory()
        let archive = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryPercentage") { table in
                table["rows"] = [
                    ["id": 9, "timestamp": "2026-10-22T08:13:01.000", "value": 70],
                    ["id": 1, "timestamp": "2026-10-22T08:13:59.000", "value": 80],
                ]
                table["rowCount"] = 2
            }
            editTable(&root, "batteryCycles") { table in
                table["rows"] = [["id": 1, "timestamp": "2026-10-22T23:30:00.000", "value": 123]]
            }
        })
        _ = try await store.importAlDenteArchive(archive)
        #expect(try await store.minuteSamples(from: timestamp.addingTimeInterval(-60), to: timestamp.addingTimeInterval(60)).first?.percent == 80)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let localCalendar = calendar
        let days = try await store.dbQueue.read { db in
            try HistoryStore.mergedDailySamples(in: db, calendar: localCalendar)
        }
        #expect(days.first?.cycleCount == nil)
        #expect(days.last?.day == "2026-10-23")
        #expect(days.last?.cycleCount == 123)
        #expect(days.last?.fullChargeCapacityMAh == nil)
    }

    @Test func invalidTimesAndInexactIntegersRemainInDetailsWithoutBecomingChartValues() async throws {
        let store = try HistoryStore.inMemory()
        let archive = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryPercentage") { table in
                table["rows"] = [["id": 1, "timestamp": "invalid", "value": 70]]
            }
            editTable(&root, "batteryCycles") { table in
                table["rows"] = [["id": 1, "timestamp": "2026-10-22T08:13:43.766", "value": Int64.max]]
            }
        })
        _ = try await store.importAlDenteArchive(archive)
        let records = try await store.historyRecords(metric: .percent)
        #expect(records.records.first?.date == nil)
        #expect(records.records.first?.originalTimestamp == "invalid")
        #expect(records.records.first?.value == .integer(70))
        #expect(try await store.dailySamples().first?.cycleCount == nil)
        #expect(try await store.historyRecords(metric: .cycleCount).records.first?.value == .integer(Int64.max))
        #expect(try await store.historyRecords(offset: -1, limit: 0).limit == 1)
    }

    @Test func oldImportsAreMigratedAutomaticallyAndMigrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try HistoryStore.migrator.migrate(queue, upTo: "aldenteRawImports")
        let archive = try AlDenteArchive(data: archiveFixture())
        try queue.write { db in
            try db.execute(sql: "INSERT INTO minute_samples(ts, percent) VALUES (60, 88)")
            for record in archive.records {
                try db.execute(sql: """
                    INSERT INTO aldente_records(id, source_table, source_id, timestamp, value_type, value)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [record.identifier, record.table.rawValue, record.sourceID,
                        record.timestamp, record.table.valueType, record.value])
            }
        }
        try HistoryStore.migrator.migrate(queue)
        try HistoryStore.migrator.migrate(queue)
        let count = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_records") }
        #expect(count == 13)
        let native = try queue.read { db in try Int.fetchOne(db, sql: "SELECT percent FROM minute_samples WHERE ts = 60") }
        #expect(native == 88)
    }

    @Test func aggregationAndReopenKeepImportedHistoryAndExistingHourlyValues() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(MinuteSample(timestamp: timestamp, percent: 77, chargeLimitPercent: 80,
            isExternalPower: true, temperatureCelsius: 32))
        try await store.aggregateMinuteSamples(now: timestamp.addingTimeInterval(10 * 86400))
        _ = try await store.importAlDenteArchive(AlDenteArchive(data: archiveFixture()))
        let hours = try await store.minuteSamplesByHour(from: timestamp.addingTimeInterval(-3600), to: timestamp.addingTimeInterval(3600))
        #expect(hours.count == 1)
        #expect(hours.first?.percentAverage == 77)
        #expect(hours.first?.chargeLimitPercent == 80)
        #expect(hours.first?.temperatureAverageCelsius == 32)
        try await store.aggregateMinuteSamples(now: timestamp.addingTimeInterval(11 * 86400))
        #expect(try await store.historyRecords().totalCount == 13)
        #expect(try await store.minuteSamplesByHour(from: timestamp.addingTimeInterval(-3600), to: timestamp.addingTimeInterval(3600)) == hours)
    }

    @Test func failedNormalizationRollsBackTheEntireImport() async throws {
        let store = try HistoryStore.inMemory()
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_history BEFORE INSERT ON history_records
                BEGIN SELECT RAISE(ABORT, 'injected normalization failure'); END
                """)
        }
        await #expect(throws: (any Error).self) {
            try await store.importAlDenteArchive(AlDenteArchive(data: archiveFixture()))
        }
        let counts = try await store.dbQueue.read { db in
            try ["aldente_imports", "aldente_records", "aldente_import_records", "history_records"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")
            }
        }
        #expect(counts == [0, 0, 0, 0])
    }

    @Test func detailsCombineNewSamplesAndHistoryWithoutMixingPowerUnits() async throws {
        let store = try HistoryStore.inMemory()
        _ = try await store.importAlDenteArchive(AlDenteArchive(data: archiveFixture()))
        try await store.write(MinuteSample(timestamp: timestamp, systemLoadMW: 12000))
        let power = try await store.historyRecords(metric: .systemPower)
        #expect(power.totalCount == 2)
        #expect(power.records.contains { $0.value == .integer(12000) && $0.unit == "mW" && !$0.isUnitUnverified })
        #expect(power.records.contains { $0.value == .real(-1.5) && $0.unit == nil && $0.isUnitUnverified })
        for day in ["2026-10-20", "2026-10-21"] {
            try await store.write(DailySample(day: day, cycleCount: 123, updatedAt: timestamp))
        }
        let cycles = try await store.historyRecords(metric: .cycleCount)
        #expect(cycles.totalCount == 3)
        #expect(Set(cycles.records.map(\.id)).count == 3)
        let first = try await store.historyRecords(limit: 7)
        let next = try await store.historyRecords(offset: 7, limit: 7)
        #expect(Set((first.records + next.records).map(\.id)).count == 14)
    }
}
