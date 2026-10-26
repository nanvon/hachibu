import BatteryCore
import Foundation
import GRDB
import Testing
@testable import HistoryStore

/// 构造导入文件。`records` 每项为 (metric, time, value)。
private func importFile(
    app: String = "AlDente",
    version: String? = "1.39.3",
    records: [(String, String, Any)]
) throws -> Data {
    var source: [String: Any] = ["app": app]
    source["version"] = version
    let root: [String: Any] = [
        "format": "hachibu-import",
        "version": 1,
        "source": source,
        "records": records.map { ["metric": $0.0, "time": $0.1, "value": $0.2] },
    ]
    return try JSONSerialization.data(withJSONObject: root)
}

private func parse(_ records: [(String, String, Any)], calendar: Calendar = utc) throws -> HistoryImportFile {
    try HistoryImportFile.parse(importFile(records: records), calendar: calendar)
}

@Suite struct HistoryImportParsingTests {
    @Test func lastValuePerDayAndMetric() throws {
        let file = try parse([
            ("full_charge_mah", "2026-10-20T08:00:00Z", 7950),
            ("full_charge_mah", "2026-10-20T20:00:00.500Z", 7942),
            ("cycle_count", "2026-10-20T08:00:00Z", 68),
            ("system_max_capacity_pct", "2026-10-21T01:00:00+08:00", 95),
        ])
        #expect(file.sourceApp == "AlDente")
        #expect(file.sourceVersion == "1.39.3")
        #expect(file.recordCount == 4)
        // +08:00 的 01:00 是 UTC 的前一天 17:00。
        #expect(file.days == [
            HistoryImportFile.Day(day: "2026-10-20", fullChargeCapacityMAh: 7942, cycleCount: 68, systemMaxCapacityPercent: 95),
        ])
    }

    @Test func dayUsesCalendarTimeZone() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let file = try parse([("cycle_count", "2026-10-20T20:00:00Z", 68)], calendar: shanghai)
        #expect(file.firstDay == "2026-10-21")
        #expect(file.timeZone == "Asia/Shanghai")
    }

    @Test func importUsesGregorianDatesWithNonGregorianCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let file = try parse([("cycle_count", "2026-10-20T20:00:00Z", 68)], calendar: buddhist)
        #expect(file.firstDay == "2026-10-21")
        #expect(file.timeZone == "Asia/Shanghai")
    }

    @Test func invalidRecordsAreSkipped() throws {
        let file = try parse([
            ("cycle_count", "2026-10-20T08:00:00Z", 68),
            ("percent", "2026-10-20T08:00:00Z", 80),
            ("cycle_count", "2026-10-20T08:00:00", 68),
            ("cycle_count", "2026-10-20T08:00:00Z", "68"),
            ("cycle_count", "2026-10-20T08:00:00Z", true),
            ("cycle_count", "2026-10-20T08:00:00Z", 68.5),
            ("battery_serial", "2026-10-20T08:00:00Z", 12),
        ])
        #expect(file.recordCount == 1)
        #expect(file.skippedCount == 6)
        #expect(file.excludedCount == 0)
    }

    @Test func anomaliesAreExcluded() throws {
        let file = try parse([
            // AlDente 采集失效：同一秒内满充容量和循环次数同为 0。
            ("full_charge_mah", "2026-10-19T08:00:00.100Z", 0),
            ("cycle_count", "2026-10-19T08:00:00.900Z", 0),
            ("system_max_capacity_pct", "2026-10-19T08:00:00Z", 0),
            ("design_mah", "2026-10-19T08:00:00Z", -1),
            ("battery_serial", "2026-10-19T08:00:00Z", "  "),
            // 单独的循环次数 0 是新电池的正常读数。
            ("cycle_count", "2026-10-20T08:00:00Z", 0),
        ])
        #expect(file.excludedCount == 5)
        #expect(file.days == [HistoryImportFile.Day(day: "2026-10-20", cycleCount: 0)])
    }

    @Test func serialAppliesToFollowingDays() throws {
        let file = try parse([
            ("cycle_count", "2026-10-01T08:00:00Z", 60),
            ("battery_serial", "2026-10-02T08:00:00Z", "A"),
            ("cycle_count", "2026-10-02T07:00:00Z", 61),
            ("cycle_count", "2026-10-03T08:00:00Z", 62),
            ("battery_serial", "2026-10-04T08:00:00Z", "B"),
            ("cycle_count", "2026-10-04T07:00:00Z", 0),
        ])
        let a = BatterySnapshot.serialHash("A")
        let b = BatterySnapshot.serialHash("B")
        // 早于第一条序列号的日子归属第一条；当天有序列号时用当天的。
        #expect(file.days.map(\.serialHash) == [a, a, a, b])
        #expect(file.hasBatterySerial)
    }

    @Test func denseSerialRecordsUseLastSerialOfEachDay() throws {
        var records: [(String, String, Any)] = []
        for day in 1...28 {
            let date = String(format: "2026-02-%02d", day)
            records.append(("battery_serial", "\(date)T01:00:00Z", "old-\(day)"))
            records.append(("cycle_count", "\(date)T08:00:00Z", day))
            records.append(("battery_serial", "\(date)T23:00:00Z", "new-\(day)"))
        }
        let file = try parse(Array(records.reversed()))
        #expect(file.days.count == 28)
        #expect(file.days.map(\.serialHash) == (1...28).map { BatterySnapshot.serialHash("new-\($0)") })
        #expect(file.days.map(\.cycleCount) == Array(1...28))
    }

    @Test(arguments: [
        (#"[1, 2]"#, HistoryImportError.notJSON),
        ("not json", .notJSON),
        (#"{"format": "other", "version": 1, "source": {"app": "X"}, "records": []}"#, .unsupportedFormat),
        (#"{"format": "hachibu-import", "version": 2, "source": {"app": "X"}, "records": []}"#, .unsupportedVersion),
        (#"{"format": "hachibu-import", "version": 1, "source": {"app": " "}, "records": []}"#, .missingSourceApp),
        (#"{"format": "hachibu-import", "version": 1, "source": {"app": "X"}, "records": []}"#, .noValidRecords),
    ])
    func rejectedFiles(_ json: String, _ error: HistoryImportError) {
        #expect(throws: error) {
            try HistoryImportFile.parse(Data(json.utf8), calendar: utc)
        }
    }
}

@Suite struct HistoryImportStoreTests {
    private let nativeSnapshot = BatterySnapshot(
        fullChargeCapacityMAh: 7942,
        designCapacityMAh: 8694,
        cycleCount: 68,
        batterySerialHash: BatterySnapshot.serialHash("A")
    )

    /// 本机记录了 2026-10-20 的满充容量和循环次数，没有系统最大容量。
    private func nativeStore() async throws -> HistoryStore {
        let store = try HistoryStore.inMemory()
        try await store.record(nativeSnapshot, at: Date(timeIntervalSince1970: 1_792_454_400 + 3600), calendar: utc)
        return store
    }

    private let records: [(String, String, Any)] = [
        ("battery_serial", "2026-10-01T08:00:00Z", "A"),
        ("full_charge_mah", "2026-10-19T08:00:00Z", 7960),
        ("cycle_count", "2026-10-19T08:00:00Z", 67),
        ("full_charge_mah", "2026-10-20T08:00:00Z", 7000),
        ("cycle_count", "2026-10-20T08:00:00Z", 1),
        ("system_max_capacity_pct", "2026-10-20T08:00:00Z", 95),
    ]

    @Test func importMergesWithNativeData() async throws {
        let store = try await nativeStore()
        let file = try parse(records)
        let preview = try await store.previewImport(file)
        #expect(preview.overlappingNativeDays == 1)
        #expect(!preview.isDifferentBattery)

        try await store.importHistory(file)
        #expect(try await store.dailyHealth() == [
            // 导入的日子用本机电池的设计容量计算容量比。
            DailyHealth(day: "2026-10-19", fullChargeCapacityMAh: 7960, designCapacityMAh: 8694, cycleCount: 67, includesImportedData: true),
            // 本机已有的字段不被覆盖，只补系统最大容量。
            DailyHealth(day: "2026-10-20", systemMaxCapacityPercent: 95, fullChargeCapacityMAh: 7942, designCapacityMAh: 8694, cycleCount: 68, includesImportedData: true),
        ])
        #expect(try await store.recordingSummary() == RecordingSummary(firstDay: "2026-10-20", dayCount: 1))
        #expect(try await store.firstDailyHealthDay() == "2026-10-19")
        #expect(try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batteries") } == 1)
    }

    @Test func sameFileImportsOnce() async throws {
        let store = try await nativeStore()
        let file = try parse(records)
        try await store.importHistory(file)
        await #expect(throws: HistoryImportError.alreadyImported) {
            try await store.previewImport(file)
        }
        await #expect(throws: HistoryImportError.alreadyImported) {
            try await store.importHistory(file)
        }
    }

    @Test func laterImportWinsOverEarlierImport() async throws {
        let store = try HistoryStore.inMemory()
        try await store.importHistory(parse([("cycle_count", "2026-10-01T08:00:00Z", 10)]))
        try await store.importHistory(parse([("cycle_count", "2026-10-01T09:00:00Z", 11)]))
        #expect(try await store.dailyHealth().map(\.cycleCount) == [11])
    }

    @Test func cachedHistoryRefreshesAfterImportAndDeletion() async throws {
        let store = try await nativeStore()
        let original = try await store.dailyHealth()
        let sourceID = try await store.importHistory(parse(records))
        #expect(try await store.dailyHealth().count == 2)
        try await store.deleteImportedSource(id: sourceID)
        #expect(try await store.dailyHealth() == original)
    }

    @Test func cachedHistoryRefreshesWhenBatteryDesignChanges() async throws {
        let store = try await nativeStore()
        try await store.importHistory(parse(records))
        #expect(try await store.dailyHealth().first?.designCapacityMAh == 8694)
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE batteries SET design_mah = 9000")
        }
        #expect(try await store.dailyHealth().first?.designCapacityMAh == 9000)
    }

    @Test func differentBatteryIsReported() async throws {
        let store = try await nativeStore()
        let file = try parse([("battery_serial", "2026-10-01T08:00:00Z", "B"), ("cycle_count", "2026-10-01T08:00:00Z", 5)])
        #expect(try await store.previewImport(file).isDifferentBattery)

        try await store.importHistory(file)
        // 另一块电池没有设计容量，不能计算容量比。
        let day = try #require(try await store.dailyHealth().first)
        #expect(day.designCapacityMAh == nil)
    }

    @Test func importedBatteryCannotBecomeUnknownNativeBattery() async throws {
        let store = try HistoryStore.inMemory()
        let imported = try parse([
            ("battery_serial", "2026-10-01T08:00:00Z", "B"),
            ("design_mah", "2026-10-01T08:00:00Z", 6000),
            ("full_charge_mah", "2026-10-01T08:00:00Z", 5500),
        ])
        try await store.importHistory(imported)
        let date = Date(timeIntervalSince1970: 1_792_454_400 + 3600)
        try await store.record(BatterySnapshot(fullChargeCapacityMAh: 7942, cycleCount: 68), at: date, calendar: utc)
        let nativeBattery = try await store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT battery_id FROM daily_health WHERE source_id = 1")
        }
        #expect(nativeBattery == nil)
        #expect(try await store.dailyHealth().last?.designCapacityMAh == nil)
        let preview = try await store.previewImport(parse([
            ("battery_serial", "2026-10-02T08:00:00Z", "C"),
            ("cycle_count", "2026-10-02T08:00:00Z", 1),
        ]))
        #expect(!preview.isDifferentBattery)

        try await store.record(nativeSnapshot, at: date.addingTimeInterval(60), calendar: utc)
        #expect(try await store.events(.batteryChanged).isEmpty)
        let identified = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT b.serial_sha256 FROM batteries b JOIN daily_health d ON d.battery_id = b.id WHERE d.source_id = 1")
        }
        #expect(identified == BatterySnapshot.serialHash("A"))
    }

    @Test func newerImportedDatesDoNotChangeNativeIdentityOrImportWarning() async throws {
        let store = try await nativeStore()
        let file = try parse([
            ("battery_serial", "2099-10-01T08:00:00Z", "B"),
            ("cycle_count", "2099-10-01T08:00:00Z", 5),
        ])
        try await store.importHistory(file)
        let newFileForB = try parse([
            ("battery_serial", "2099-10-02T08:00:00Z", "B"),
            ("cycle_count", "2099-10-02T08:00:00Z", 6),
        ])
        #expect(try await store.previewImport(newFileForB).isDifferentBattery)
        let date = Date(timeIntervalSince1970: 1_792_454_400 + 7200)
        var missingSerial = nativeSnapshot
        missingSerial.batterySerialHash = nil
        try await store.record(missingSerial, at: date, calendar: utc)
        try await store.record(nativeSnapshot, at: date.addingTimeInterval(60), calendar: utc)
        #expect(try await store.events(.batteryChanged).isEmpty)
        let nativeHash = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT b.serial_sha256 FROM batteries b JOIN daily_health d ON d.battery_id = b.id WHERE d.source_id = 1")
        }
        #expect(nativeHash == BatterySnapshot.serialHash("A"))
    }

    @Test func deletingImportPreservesNativeIdentityWithoutDailyValues() async throws {
        let store = try HistoryStore.inMemory()
        let date = Date(timeIntervalSince1970: 1_792_454_400)
        try await store.record(BatterySnapshot(batterySerialHash: BatterySnapshot.serialHash("A")), at: date, calendar: utc)
        let id = try await store.importHistory(parse([("cycle_count", "2026-10-01T08:00:00Z", 5)]))
        try await store.deleteImportedSource(id: id)
        try await store.record(BatterySnapshot(fullChargeCapacityMAh: 7942), at: date.addingTimeInterval(60), calendar: utc)
        let nativeHash = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT b.serial_sha256 FROM batteries b JOIN daily_health d ON d.battery_id = b.id WHERE d.source_id = 1")
        }
        #expect(nativeHash == BatterySnapshot.serialHash("A"))
    }

    @Test func deleteRemovesImportedDataAndOrphanBatteries() async throws {
        let store = try await nativeStore()
        try await store.importHistory(parse([
            ("battery_serial", "2026-10-01T08:00:00Z", "B"),
            ("design_mah", "2026-10-01T08:00:00Z", 6000),
            ("full_charge_mah", "2026-10-01T08:00:00Z", 5500),
        ]))
        let sources = try await store.importedSources()
        #expect(sources.map(\.app) == ["AlDente"])
        #expect(sources.first?.firstDay == "2026-10-01")
        #expect(sources.first?.dayCount == 1)
        #expect(try await store.dailyHealth().first?.designCapacityMAh == 6000)

        try await store.deleteImportedSource(id: try #require(sources.first?.id))
        #expect(try await store.importedSources().isEmpty)
        #expect(try await store.dailyHealth().map(\.day) == ["2026-10-20"])
        // 本机电池保留，导入的另一块电池删除。
        #expect(try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batteries") } == 1)

        // 本机来源不能删除。
        try await store.deleteImportedSource(id: HistoryStore.nativeSourceID)
        #expect(try await store.dailyHealth().map(\.day) == ["2026-10-20"])
    }
}
