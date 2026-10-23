import BatteryCore
import Foundation
import Testing
@testable import HistoryStore

/// 2026-10-20 00:00:00 UTC，整小时。
private let base = Date(timeIntervalSince1970: 1_792_454_400)

private func minute(_ offset: Int) -> Date {
    base.addingTimeInterval(TimeInterval(offset * 60))
}

@Suite struct MinuteSampleTests {
    @Test func writeAndRead() async throws {
        let store = try HistoryStore.inMemory()
        let sample = MinuteSample(
            timestamp: minute(1).addingTimeInterval(42),
            percent: 80,
            isExternalPower: true,
            isCharging: false,
            systemLoadMW: 14514,
            batteryPowerMW: -1200,
            powerInMW: 14514,
            temperatureCelsius: 26.69,
            voltageMV: 12244,
            amperageMA: -98
        )
        #expect(sample.timestamp == minute(1))

        try await store.write(sample)
        let samples = try await store.minuteSamples(from: minute(0), to: minute(2))
        #expect(samples == [sample])
    }

    @Test func missingValuesStoredAsNull() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(MinuteSample(timestamp: minute(0)))
        let samples = try await store.minuteSamples(from: minute(0), to: minute(1))
        #expect(samples == [MinuteSample(timestamp: minute(0))])

        let nulls = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM minute_samples WHERE percent IS NULL AND temperature_c IS NULL")
        }
        #expect(nulls == 1)
    }

    @Test func replacesSameMinute() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(MinuteSample(timestamp: minute(0), percent: 70))
        try await store.write(MinuteSample(timestamp: minute(0).addingTimeInterval(30), percent: 71))
        let samples = try await store.minuteSamples(from: minute(0), to: minute(1))
        #expect(samples.map(\.percent) == [71])
    }

    @Test func rangeIsHalfOpenAndSorted() async throws {
        let store = try HistoryStore.inMemory()
        for offset in [3, 1, 2, 0] {
            try await store.write(MinuteSample(timestamp: minute(offset), percent: offset))
        }
        let samples = try await store.minuteSamples(from: minute(1), to: minute(3))
        #expect(samples.map(\.percent) == [1, 2])
        #expect(try await store.latestMinuteSampleTime() == minute(3))
        #expect(try await store.firstSampleTime() == minute(0))
    }

    @Test func fromSnapshot() {
        let snapshot = BatterySnapshot(
            percent: 80,
            isExternalPower: true,
            isCharging: false,
            voltageMV: 12244,
            amperageMA: 0,
            batteryPowerMW: 0,
            powerInMW: 14514,
            systemLoadMW: 14000,
            temperatureCelsius: 26.69
        )
        let sample = MinuteSample(timestamp: minute(5), snapshot: snapshot)
        #expect(sample == MinuteSample(
            timestamp: minute(5),
            percent: 80,
            isExternalPower: true,
            isCharging: false,
            systemLoadMW: 14000,
            batteryPowerMW: 0,
            powerInMW: 14514,
            temperatureCelsius: 26.69,
            voltageMV: 12244,
            amperageMA: 0
        ))
    }

    @Test func emptyStore() async throws {
        let store = try HistoryStore.inMemory()
        #expect(try await store.latestMinuteSampleTime() == nil)
        #expect(try await store.firstSampleTime() == nil)
        #expect(try await store.recordingSummary() == nil)
    }
}

@Suite struct AggregationTests {
    /// 第 0 小时：3 个样本，2 个接电，温度一个 NULL；第 1 小时：1 个样本，全部指标 NULL。
    private func seed(_ store: HistoryStore) async throws {
        try await store.write(MinuteSample(timestamp: minute(0), percent: 60, isExternalPower: true, systemLoadMW: 10000, temperatureCelsius: 30))
        try await store.write(MinuteSample(timestamp: minute(1), percent: 62, isExternalPower: true, systemLoadMW: 20000))
        try await store.write(MinuteSample(timestamp: minute(59), percent: 64, isExternalPower: false, systemLoadMW: 15000, temperatureCelsius: 32))
        try await store.write(MinuteSample(timestamp: minute(60)))
    }

    private let firstHour = HourlySample(
        hour: base,
        sampleCount: 3,
        externalMinutes: 2,
        percentAverage: 62,
        percentMin: 60,
        percentMax: 64,
        systemLoadAverageMW: 15000,
        systemLoadMaxMW: 20000,
        temperatureAverageCelsius: 31,
        temperatureMaxCelsius: 32
    )

    private let secondHour = HourlySample(hour: base.addingTimeInterval(3600), sampleCount: 1, externalMinutes: 0)

    @Test func groupByHour() async throws {
        let store = try HistoryStore.inMemory()
        try await seed(store)
        let hours = try await store.minuteSamplesByHour(from: base, to: minute(120))
        #expect(hours == [firstHour, secondHour])
    }

    @Test func aggregatesOnlyFinishedHoursOlderThanRetention() async throws {
        let store = try HistoryStore.inMemory()
        try await seed(store)

        // now − 7 天落在第 1 小时中间：只有第 0 小时整小时结束且早于该时间。
        let now = minute(90).addingTimeInterval(HistoryStore.minuteRetention)
        try await store.aggregateMinuteSamples(now: now)

        #expect(try store.hourlySamples() == [firstHour])
        let remaining = try await store.minuteSamples(from: base, to: minute(120))
        #expect(remaining.map(\.timestamp) == [minute(60)])
        // 最早的分钟数据已聚合删除，取小时数据的起点。
        #expect(try await store.firstSampleTime() == base)
    }

    @Test func aggregationIsIdempotent() async throws {
        let store = try HistoryStore.inMemory()
        try await seed(store)
        let now = minute(120).addingTimeInterval(HistoryStore.minuteRetention)
        try await store.aggregateMinuteSamples(now: now)
        try await store.aggregateMinuteSamples(now: now)

        #expect(try store.hourlySamples() == [firstHour, secondHour])
        #expect(try await store.minuteSamples(from: base, to: minute(120)).isEmpty)
    }

    @Test func nothingToAggregate() async throws {
        let store = try HistoryStore.inMemory()
        try await seed(store)
        try await store.aggregateMinuteSamples(now: minute(120))
        #expect(try store.hourlySamples().isEmpty)
        #expect(try await store.minuteSamples(from: base, to: minute(120)).count == 4)
    }
}

@Suite struct DailySampleTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    @Test func localDay() {
        let lateEvening = base.addingTimeInterval(-3600)
        #expect(DailySample.day(for: lateEvening, calendar: utc) == "2026-10-19")
        #expect(DailySample.day(for: lateEvening, calendar: shanghai) == "2026-10-20")
    }

    @Test func fromHealthAndSnapshot() {
        let sample = DailySample(
            date: base,
            health: BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good),
            snapshot: BatterySnapshot(fullChargeCapacityMAh: 7942, designCapacityMAh: 8694, cycleCount: 68),
            calendar: utc
        )
        #expect(sample == DailySample(
            day: "2026-10-20",
            systemMaxCapacityPercent: 95,
            fullChargeCapacityMAh: 7942,
            designCapacityMAh: 8694,
            cycleCount: 68,
            updatedAt: base
        ))
    }

    @Test func upsertKeepsLastValuePerDay() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(DailySample(day: "2026-10-20", systemMaxCapacityPercent: 96, cycleCount: 67, updatedAt: base))
        try await store.write(DailySample(day: "2026-10-20", systemMaxCapacityPercent: 95, updatedAt: base.addingTimeInterval(3600)))

        let samples = try await store.dailySamples()
        #expect(samples == [DailySample(day: "2026-10-20", systemMaxCapacityPercent: 95, updatedAt: base.addingTimeInterval(3600))])
    }

    @Test func rangeAndSummary() async throws {
        let store = try HistoryStore.inMemory()
        for day in ["2026-10-21", "2026-09-30", "2026-10-01"] {
            try await store.write(DailySample(day: day, updatedAt: base))
        }

        #expect(try await store.dailySamples().map(\.day) == ["2026-09-30", "2026-10-01", "2026-10-21"])
        #expect(try await store.dailySamples(from: "2026-10-01").map(\.day) == ["2026-10-01", "2026-10-21"])
        #expect(try await store.recordingSummary() == RecordingSummary(firstDay: "2026-09-30", dayCount: 3))
    }
}

@Suite struct MigrationTests {
    @Test func fileDatabaseReopens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.sqlite")

        try await HistoryStore(fileURL: url).write(MinuteSample(timestamp: minute(0), percent: 50))
        let reopened = try HistoryStore(fileURL: url)
        #expect(try await reopened.minuteSamples(from: base, to: minute(1)).map(\.percent) == [50])

        let migrations = try await reopened.dbQueue.read { db in
            try HistoryStore.migrator.appliedIdentifiers(db)
        }
        #expect(migrations == ["v1", "aldenteRawImports"])
    }
}
