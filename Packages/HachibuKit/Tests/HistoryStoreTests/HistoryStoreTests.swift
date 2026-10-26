import BatteryCore
import Foundation
import GRDB
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
    /// 第 0 小时：3 个样本，2 个插电、1 个充电，温度一个 NULL；第 1 小时：1 个样本，全部指标 NULL。
    private func seed(_ store: HistoryStore) async throws {
        try await store.write(MinuteSample(timestamp: minute(0), percent: 60, isExternalPower: true, isCharging: true, systemLoadMW: 10000, batteryPowerMW: 2000, powerInMW: 12000, temperatureCelsius: 30, amperageMA: 160))
        try await store.write(MinuteSample(timestamp: minute(1), percent: 62, isExternalPower: true, isCharging: false, systemLoadMW: 20000, batteryPowerMW: -1000))
        try await store.write(MinuteSample(timestamp: minute(59), percent: 64, isExternalPower: false, systemLoadMW: 15000, temperatureCelsius: 32, voltageMV: 12000))
        try await store.write(MinuteSample(timestamp: minute(60)))
    }

    private let firstHour = HourlySample(
        hour: base,
        sampleCount: 3,
        externalMinutes: 2,
        chargingMinutes: 1,
        percent: .init(average: 62, min: 60, max: 64),
        systemLoadMW: .init(average: 15000, min: 10000, max: 20000),
        batteryPowerMW: .init(average: 500, min: -1000, max: 2000),
        powerInMW: .init(average: 12000, min: 12000, max: 12000),
        temperatureCelsius: .init(average: 31, min: 30, max: 32),
        voltageMV: .init(average: 12000, min: 12000, max: 12000),
        amperageMA: .init(average: 160, min: 160, max: 160)
    )

    private let secondHour = HourlySample(hour: base.addingTimeInterval(3600), sampleCount: 1, externalMinutes: 0, chargingMinutes: 0)

    @Test func groupByHour() async throws {
        let store = try HistoryStore.inMemory()
        try await seed(store)
        let hours = try await store.minuteSamplesByHour(from: base, to: minute(120))
        #expect(hours == [
            HourlyAverage(
                hour: base,
                sampleCount: 3,
                externalMinutes: 2,
                percent: 62,
                systemLoadMW: 15000,
                batteryPowerMW: 500,
                powerInMW: 12000,
                temperatureCelsius: 31,
                voltageMV: 12000
            ),
            HourlyAverage(hour: base.addingTimeInterval(3600), sampleCount: 1, externalMinutes: 0),
        ])
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

let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-20 的第 `hours` 小时（UTC）。
private func hour(_ hours: Int) -> Date {
    base.addingTimeInterval(TimeInterval(hours * 3600))
}

private func snapshot(
    serial: String? = "SERIAL-A",
    fullCharge: Int? = 7942,
    design: Int? = 8694,
    cycles: Int? = 68,
    chargeLimit: ChargeLimitSetting? = nil
) -> BatterySnapshot {
    BatterySnapshot(
        percent: 80,
        fullChargeCapacityMAh: fullCharge,
        designCapacityMAh: design,
        cycleCount: cycles,
        designCycleCount: 1000,
        batterySerialHash: serial.flatMap(BatterySnapshot.serialHash),
        chargeLimit: chargeLimit
    )
}

private func batteryCount(_ store: HistoryStore) throws -> Int {
    try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batteries") ?? 0 }
}

@Suite struct DailyHealthTests {
    private let shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    @Test func localDay() {
        let lateEvening = base.addingTimeInterval(-3600)
        #expect(DailyHealth.day(for: lateEvening, calendar: utc) == "2026-10-19")
        #expect(DailyHealth.day(for: lateEvening, calendar: shanghai) == "2026-10-20")
    }

    @Test func storedDaysUseGregorianYearsWithNonGregorianSystemCalendar() async throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = shanghai.timeZone
        let date = base.addingTimeInterval(-3600)
        #expect(DailyHealth.day(for: date, calendar: buddhist) == "2026-10-20")
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(), at: date, calendar: buddhist)
        try await store.record(snapshot(), at: date.addingTimeInterval(60), calendar: shanghai)
        #expect(try await store.dailyHealth().map(\.day) == ["2026-10-20"])
        #expect(try await store.recordingSummary()?.dayCount == 1)
    }

    @Test func minuteRecordWritesSampleAndDailyCapacity() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(), at: minute(3).addingTimeInterval(20), calendar: utc)

        #expect(try await store.minuteSamples(from: base, to: minute(10)).map(\.timestamp) == [minute(3)])
        #expect(try await store.dailyHealth() == [
            DailyHealth(day: "2026-10-20", fullChargeCapacityMAh: 7942, designCapacityMAh: 8694, cycleCount: 68),
        ])
    }

    @Test func healthRecordAddsSystemFields() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(), at: hour(1), calendar: utc)
        try await store.record(
            BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good),
            snapshot: snapshot(),
            at: hour(2),
            calendar: utc
        )
        #expect(try await store.dailyHealth() == [
            DailyHealth(
                day: "2026-10-20",
                systemMaxCapacityPercent: 95,
                fullChargeCapacityMAh: 7942,
                designCapacityMAh: 8694,
                cycleCount: 68,
                healthCondition: "Good"
            ),
        ])
    }

    @Test func missingFieldsKeepEarlierValues() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(
            BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good),
            snapshot: snapshot(cycles: 67),
            at: hour(1),
            calendar: utc
        )
        // 稍后满充容量读不到、循环次数变了、system_profiler 没有值：只更新循环次数。
        try await store.record(snapshot(fullCharge: nil, cycles: 68), at: hour(2), calendar: utc)
        try await store.record(
            BatteryHealthInfo(systemMaximumCapacityPercent: nil, condition: nil),
            snapshot: snapshot(fullCharge: nil, design: nil, cycles: nil),
            at: hour(3),
            calendar: utc
        )

        let day = try #require(try await store.dailyHealth().first)
        #expect(day.fullChargeCapacityMAh == 7942)
        #expect(day.cycleCount == 68)
        #expect(day.systemMaxCapacityPercent == 95)
        #expect(day.healthCondition == "Good")
    }

    @Test func nothingWrittenWithoutValues() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(fullCharge: nil, design: nil, cycles: nil), at: hour(1), calendar: utc)
        #expect(try await store.dailyHealth().isEmpty)
        #expect(try await store.recordingSummary() == nil)
        // 分钟数据照常写。
        #expect(try await store.latestMinuteSampleTime() == hour(1))
    }

    @Test func rangeAndSummary() async throws {
        let store = try HistoryStore.inMemory()
        for offset in [1, -20, -19] {
            try await store.record(snapshot(), at: base.addingTimeInterval(TimeInterval(offset * 86400)), calendar: utc)
        }
        #expect(try await store.dailyHealth().map(\.day) == ["2026-09-30", "2026-10-01", "2026-10-21"])
        #expect(try await store.dailyHealth(from: "2026-10-01").map(\.day) == ["2026-10-01", "2026-10-21"])
        #expect(try await store.recordingSummary() == RecordingSummary(firstDay: "2026-09-30", dayCount: 3))
        #expect(try await store.firstDailyHealthDay() == "2026-09-30")
    }
}

@Suite struct BatteryTests {
    @Test func sameSerialIsOneBattery() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(), at: hour(1), calendar: utc)
        try await store.record(snapshot(design: 8700), at: hour(2), calendar: utc)
        #expect(try batteryCount(store) == 1)
        let design = try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT design_mah FROM batteries") }
        #expect(design == 8700)
        #expect(try await store.events(.batteryChanged).isEmpty)
    }

    @Test func missingSerialUsesLastBattery() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(), at: hour(1), calendar: utc)
        try await store.record(snapshot(serial: nil), at: base.addingTimeInterval(86400), calendar: utc)
        #expect(try batteryCount(store) == 1)
        let unassigned = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_health WHERE battery_id IS NULL")
        }
        #expect(unassigned == 0)
    }

    @Test func newSerialRecordsBatteryChange() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(snapshot(serial: "SERIAL-A"), at: hour(1), calendar: utc)
        try await store.record(snapshot(serial: "SERIAL-B"), at: hour(2), calendar: utc)
        try await store.record(snapshot(serial: "SERIAL-B"), at: hour(3), calendar: utc)

        #expect(try batteryCount(store) == 2)
        let events = try await store.events(.batteryChanged)
        #expect(events.map(\.date) == [hour(2)])
        #expect(events.first?.batteryID == 2)
    }

    @Test func chargeLimitChangesAreRecorded() async throws {
        let store = try HistoryStore.inMemory()
        let settings: [ChargeLimitSetting?] = [.on(percent: 80), .on(percent: 80), nil, .unsupported, .off, .on(percent: 85)]
        for (offset, setting) in settings.enumerated() {
            try await store.record(snapshot(chargeLimit: setting), at: minute(offset), calendar: utc)
        }
        let events = try await store.events(.chargeLimit)
        #expect(events.map(\.value) == [80, 100, 85])
        #expect(events.map(\.date) == [minute(0), minute(4), minute(5)])
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
        #expect(migrations == ["v1", "v2", "v3"])
    }

    /// v1 的每日数据转入 `daily_health`，没有电池；第一次确定电池时归给它。旧的小时行新增列为 NULL。
    @Test func v1DataMovesToV2() async throws {
        let queue = try DatabaseQueue()
        try HistoryStore.migrator.migrate(queue, upTo: "v1")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO daily_samples (day, system_max_capacity_pct, full_charge_mah, design_mah, cycle_count, updated_at)
                VALUES ('2026-10-01', 96, 8000, 8694, 60, 100), ('2026-10-02', NULL, 7990, 8694, NULL, 200)
                """)
            try db.execute(sql: """
                INSERT INTO hourly_samples (hour_ts, sample_count, external_minutes, percent_avg, temperature_max_c)
                VALUES (0, 60, 30, 70.5, 31)
                """)
        }

        let store = try HistoryStore(dbQueue: queue)
        #expect(try await store.dailyHealth() == [
            DailyHealth(day: "2026-10-01", systemMaxCapacityPercent: 96, fullChargeCapacityMAh: 8000, designCapacityMAh: 8694, cycleCount: 60),
            DailyHealth(day: "2026-10-02", fullChargeCapacityMAh: 7990, designCapacityMAh: 8694),
        ])
        #expect(try store.hourlySamples() == [
            HourlySample(
                hour: Date(timeIntervalSince1970: 0),
                sampleCount: 60,
                externalMinutes: 30,
                percent: .init(average: 70.5),
                temperatureCelsius: .init(max: 31)
            ),
        ])
        let tableExists = try await queue.read { db in try db.tableExists("daily_samples") }
        #expect(!tableExists)

        try await store.record(snapshot(), at: base, calendar: utc)
        let unassigned = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_health WHERE battery_id IS NULL")
        }
        #expect(unassigned == 0)
        #expect(try await store.events(.batteryChanged).isEmpty)
    }

    @Test func v3OnlyRestoresNativeBatteryIdentityFromNativeRecords() async throws {
        let queue = try DatabaseQueue()
        try HistoryStore.migrator.migrate(queue, upTo: "v2")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO batteries (id, serial_sha256, first_seen_at, last_seen_at)
                VALUES (1, 'native', 100, 100), (2, 'imported', 200, 9999999999), (3, 'event-only', 300, 300);
                INSERT INTO daily_health (day, source_id, battery_id, cycle_count, updated_at)
                VALUES ('2026-10-01', 1, 1, 60, 100);
                INSERT INTO battery_events (ts, kind, battery_id) VALUES (300, 'battery_changed', 3);
                """)
        }
        let store = try HistoryStore(dbQueue: queue)
        let nativeID = try await queue.read { db in try HistoryStore.latestNativeBatteryID(db) }
        #expect(nativeID == 3)
        let importedNativeTime = try await queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT last_native_seen_at FROM batteries WHERE id = 2")
        }
        #expect(importedNativeTime == nil)
        try await store.record(snapshot(serial: nil), at: base, calendar: utc)
        let recordedBattery = try await queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT battery_id FROM daily_health WHERE day = '2026-10-20' AND source_id = 1")
        }
        #expect(recordedBattery == 3)
    }
}

private final class DailyQueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@Suite struct DailyHealthCacheTests {
    private func tracedStore() throws -> (HistoryStore, DailyQueryCounter) {
        let counter = DailyQueryCounter()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.contains("SELECT d.*") {
                    counter.increment()
                }
            }
        }
        return (try HistoryStore(dbQueue: DatabaseQueue(configuration: configuration)), counter)
    }

    @Test func unchangedMinuteWritesDoNotReloadAllDailyRows() async throws {
        let (store, queries) = try tracedStore()
        let snapshot = BatterySnapshot(
            fullChargeCapacityMAh: 8000, designCapacityMAh: 8694, cycleCount: 10,
            batterySerialHash: BatterySnapshot.serialHash("cache-test")
        )
        try await store.record(snapshot, at: base)
        let original = try await store.dailyHealth()
        for offset in 1...5 {
            try await store.record(snapshot, at: minute(offset))
            #expect(try await store.dailyHealth() == original)
        }
        #expect(queries.count == 1)
        try await store.record(BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good), snapshot: snapshot, at: minute(6))
        #expect(try await store.dailyHealth().first?.systemMaxCapacityPercent == 95)
        #expect(queries.count == 2)
        // 带起始日期的查询不覆盖完整历史缓存。
        #expect(try await store.dailyHealth(from: "2099-01-01").isEmpty)
        #expect(try await store.dailyHealth().count == 1)
        #expect(queries.count == 3)
    }

    @Test func anotherConnectionInvalidatesCachedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(fileURL: path)
        try await store.record(BatterySnapshot(cycleCount: 10), at: base)
        #expect(try await store.dailyHealth().first?.cycleCount == 10)
        let other = try DatabaseQueue(path: path.path)
        try await other.write { db in
            try db.execute(sql: "UPDATE daily_health SET cycle_count = 11")
        }
        #expect(try await store.dailyHealth().first?.cycleCount == 11)
    }

    @Test func rollbackKeepsCachedResultCorrect() async throws {
        enum Rollback: Error { case requested }
        let (store, _) = try tracedStore()
        try await store.record(BatterySnapshot(cycleCount: 10), at: base)
        let original = try await store.dailyHealth()
        do {
            try await store.dbQueue.write { db in
                try db.execute(sql: "UPDATE daily_health SET cycle_count = 99")
                throw Rollback.requested
            }
        } catch Rollback.requested {}
        #expect(try await store.dailyHealth() == original)
    }
}
