// GRDB 数据库、采样写入、聚合、查询。表结构见 docs/v1技术设计.md 第 10 节。
// 不依赖 AppKit / SwiftUI，不包含界面文案。
import BatteryCore
import Foundation
import GRDB

/// 历史数据库。时间戳都存 UTC Unix 秒。
public final class HistoryStore: Sendable {
    /// 分钟数据保留时长，更早的按小时聚合后删除。
    public static let minuteRetention: TimeInterval = 7 * 24 * 3600

    let dbQueue: DatabaseQueue
    private let dailyCache = DailyHealthCache()

    /// 打开（必要时创建）数据库文件，并执行迁移。
    public convenience init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try self.init(dbQueue: DatabaseQueue(path: fileURL.path))
    }

    /// 内存数据库，用于测试。
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(dbQueue: DatabaseQueue())
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
        dbQueue.add(transactionObserver: dailyCache)
    }

    /// `~/Library/Application Support/<Bundle ID>/history.sqlite`。
    public static func defaultFileURL(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    // MARK: - 写入

    /// 本机采集的来源，迁移 v2 时写入 `sources`。
    public static let nativeSourceID: Int64 = 1

    /// 写入一分钟的样本，主键冲突时覆盖。只写 `minute_samples`；采样时用 `record(_:at:calendar:)`。
    public func write(_ sample: MinuteSample) async throws {
        try await dbQueue.write { db in
            try sample.insert(db, onConflict: .replace)
        }
    }

    /// 每分钟一次：写分钟样本，更新电池，把满充容量、设计容量、循环次数写进当天本机的每日数据，并记录事件。
    /// 在一个事务里执行。规则见 docs/v1技术设计.md 第 10 节。
    public func record(_ snapshot: BatterySnapshot, at date: Date, calendar: Calendar = .current) async throws {
        try await dbQueue.write { db in
            try MinuteSample(timestamp: date, snapshot: snapshot).insert(db, onConflict: .replace)
            let batteryID = try Self.resolveBattery(db, snapshot: snapshot, at: date)
            try Self.upsertNativeDaily(
                db,
                day: DailyHealth.day(for: date, calendar: calendar),
                batteryID: batteryID,
                fullChargeCapacityMAh: snapshot.fullChargeCapacityMAh,
                designCapacityMAh: snapshot.designCapacityMAh,
                cycleCount: snapshot.cycleCount,
                at: date
            )
            try Self.recordChargeLimit(db, snapshot.chargeLimit, at: date)
        }
    }

    /// 每次 `system_profiler` 读取后：把系统最大容量和健康状态写进当天本机的每日数据。
    /// `snapshot` 为当时最近一次完整读取，用来确定电池并一起更新满充容量等字段。
    public func record(
        _ health: BatteryHealthInfo,
        snapshot: BatterySnapshot,
        at date: Date,
        calendar: Calendar = .current
    ) async throws {
        try await dbQueue.write { db in
            let batteryID = try Self.resolveBattery(db, snapshot: snapshot, at: date)
            try Self.upsertNativeDaily(
                db,
                day: DailyHealth.day(for: date, calendar: calendar),
                batteryID: batteryID,
                fullChargeCapacityMAh: snapshot.fullChargeCapacityMAh,
                designCapacityMAh: snapshot.designCapacityMAh,
                cycleCount: snapshot.cycleCount,
                systemMaxCapacityPercent: health.systemMaximumCapacityPercent,
                healthCondition: health.condition?.rawValue,
                at: date
            )
        }
    }

    /// 把早于 `now − 7 天` 且整小时已结束的分钟数据按小时汇总进 `hourly_samples`，再删除这些分钟数据。
    /// 在一个事务里执行，重复执行结果相同。
    public func aggregateMinuteSamples(now: Date = Date()) async throws {
        let cutoff = UnixTime.floor(now.addingTimeInterval(-Self.minuteRetention), to: 3600)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO hourly_samples (\(Self.hourlyColumns))
                    \(Self.hourlySelect)
                    WHERE ts < ?
                    GROUP BY hour_ts
                    """,
                arguments: [cutoff]
            )
            try db.execute(sql: "DELETE FROM minute_samples WHERE ts < ?", arguments: [cutoff])
        }
    }

    // MARK: - 查询

    /// `[start, end)` 内的分钟样本，按时间排序。用于近期 1 小时、24 小时曲线。
    public func minuteSamples(from start: Date, to end: Date) async throws -> [MinuteSample] {
        try await dbQueue.read { db in
            try MinuteSample
                .filter(sql: "ts >= ? AND ts < ?", arguments: [UnixTime.seconds(start), UnixTime.seconds(end)])
                .order(sql: "ts")
                .fetchAll(db)
        }
    }

    /// `[start, end)` 内的分钟样本按小时汇总，按时间排序。用于近期 7 天曲线。没有分钟数据的小时没有结果。
    public func minuteSamplesByHour(from start: Date, to end: Date) async throws -> [HourlyAverage] {
        try await dbQueue.read { db in
            try HourlyAverage.fetchAll(
                db,
                sql: """
                    SELECT
                        (ts / 3600) * 3600 AS hour_ts,
                        COUNT(*) AS sample_count,
                        SUM(CASE WHEN is_external = 1 THEN 1 ELSE 0 END) AS external_minutes,
                        AVG(percent) AS percent_avg,
                        AVG(system_load_mw) AS system_load_avg_mw,
                        AVG(battery_power_mw) AS battery_power_avg_mw,
                        AVG(power_in_mw) AS power_in_avg_mw,
                        AVG(temperature_c) AS temperature_avg_c,
                        AVG(voltage_mv) AS voltage_avg_mv
                    FROM minute_samples
                    WHERE ts >= ? AND ts < ?
                    GROUP BY hour_ts
                    ORDER BY hour_ts
                    """,
                arguments: [UnixTime.seconds(start), UnixTime.seconds(end)]
            )
        }
    }

    /// 从 `firstDay`（含）开始的每日健康数据，按日期排序；`firstDay` 为 nil 时返回全部。用于长期曲线。
    /// 每天按字段合并各来源：本机的值优先，其次是最近一次导入的来源。
    public func dailyHealth(from firstDay: String? = nil) async throws -> [DailyHealth] {
        try await dbQueue.read { db in
            // data_version 覆盖其他连接的写入；本连接的变化由事务观察者失效。
            let version = try Int64.fetchOne(db, sql: "PRAGMA data_version")
            if firstDay == nil, dailyCache.dataVersion == version, let samples = dailyCache.samples {
                return samples
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.*, b.design_mah AS battery_design_mah
                    FROM daily_health d
                    LEFT JOIN batteries b ON b.id = d.battery_id
                    WHERE ? IS NULL OR d.day >= ?
                    ORDER BY d.day, d.source_id = ? DESC, d.source_id DESC
                    """,
                arguments: [firstDay, firstDay, Self.nativeSourceID]
            )
            let samples = Self.mergeDaily(rows)
            if firstDay == nil {
                dailyCache.samples = samples
                dailyCache.dataVersion = version
            }
            return samples
        }
    }

    /// 同一天的各行已按优先级排好：每个字段取第一个非 NULL 的值。设计容量跟随提供满充容量的那一行。
    private static func mergeDaily(_ rows: [Row]) -> [DailyHealth] {
        var result: [DailyHealth] = []
        var index = 0
        while index < rows.count {
            let day: String = rows[index]["day"]
            var end = index
            while end < rows.count, rows[end]["day"] == day {
                end += 1
            }
            let group = rows[index..<end]
            var usedImport = false

            func pick<Value: DatabaseValueConvertible>(_ column: String) -> Value? {
                for row in group {
                    if let value: Value = row[column] {
                        if row["source_id"] != nativeSourceID {
                            usedImport = true
                        }
                        return value
                    }
                }
                return nil
            }

            var health = DailyHealth(day: day)
            if let row = group.first(where: { ($0["full_charge_mah"] as Int?) != nil }) {
                health.fullChargeCapacityMAh = row["full_charge_mah"]
                health.designCapacityMAh = row["design_mah"] ?? row["battery_design_mah"]
                if row["source_id"] != nativeSourceID {
                    usedImport = true
                }
            }
            health.cycleCount = pick("cycle_count")
            health.systemMaxCapacityPercent = pick("system_max_capacity_pct")
            health.healthCondition = pick("health_condition")
            health.includesImportedData = usedImport
            result.append(health)
            index = end
        }
        return result
    }

    /// 所有来源中最早的一天。用于长期曲线标“未记录”。没有数据时为 nil。
    public func firstDailyHealthDay() async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT MIN(day) FROM daily_health")
        }
    }

    /// 某类事件，按时间排序。
    public func events(_ kind: BatteryEvent.Kind) async throws -> [BatteryEvent] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts, battery_id, value FROM battery_events WHERE kind = ? ORDER BY ts, id",
                arguments: [kind.rawValue]
            ).map { row in
                BatteryEvent(date: UnixTime.date(row["ts"]), kind: kind, batteryID: row["battery_id"], value: row["value"])
            }
        }
    }

    /// 最近一次分钟样本的时间。没有数据时为 nil。
    public func latestMinuteSampleTime() async throws -> Date? {
        try await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM minute_samples").map(UnixTime.date)
        }
    }

    /// 最早一条记录的时间：`minute_samples` 的最早采样时间和 `hourly_samples` 的最早小时起点中较早的一个。
    /// 用于近期曲线标“未记录”。没有数据时为 nil。
    public func firstSampleTime() async throws -> Date? {
        try await dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(t) FROM (
                        SELECT MIN(ts) AS t FROM minute_samples
                        UNION ALL
                        SELECT MIN(hour_ts) AS t FROM hourly_samples
                    )
                    """
            ).map(UnixTime.date)
        }
    }

    /// 侧栏底部的记录概况：本机每日数据最早的一天和天数，不含导入的数据。没有数据时为 nil。
    public func recordingSummary() async throws -> RecordingSummary? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT MIN(day) AS first_day, COUNT(*) AS day_count FROM daily_health WHERE source_id = ?",
                arguments: [Self.nativeSourceID]
            ),
                  let firstDay: String = row["first_day"]
            else { return nil }
            return RecordingSummary(firstDay: firstDay, dayCount: row["day_count"])
        }
    }

    /// 测试用。
    func hourlySamples() throws -> [HourlySample] {
        try dbQueue.read { db in
            try HourlySample.fetchAll(db, sql: "SELECT * FROM hourly_samples ORDER BY hour_ts")
        }
    }

    // MARK: - 电池、每日数据、事件

    /// 本机读数对应的电池 id。读到序列号时按哈希查找，没有就新建；读不到时用最近一次见到的电池；没有电池时为 nil。
    /// 新电池与上一次见到的电池不同时记 `battery_changed`。迁移前没有电池的本机每日数据归给第一次确定的电池。
    static func resolveBattery(_ db: Database, snapshot: BatterySnapshot, at date: Date) throws -> Int64? {
        let previous = try Int64.fetchOne(db, sql: "SELECT id FROM batteries ORDER BY last_seen_at DESC, id DESC LIMIT 1")
        guard let hash = snapshot.batterySerialHash else { return previous }

        let ts = UnixTime.seconds(date)
        let batteryID: Int64
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM batteries WHERE serial_sha256 = ?", arguments: [hash]) {
            batteryID = existing
            try db.execute(
                sql: """
                    UPDATE batteries SET
                        design_mah = COALESCE(?, design_mah),
                        design_cycle_count = COALESCE(?, design_cycle_count)
                    WHERE id = ?
                      AND (design_mah IS NOT COALESCE(?, design_mah)
                           OR design_cycle_count IS NOT COALESCE(?, design_cycle_count))
                    """,
                arguments: [snapshot.designCapacityMAh, snapshot.designCycleCount, batteryID, snapshot.designCapacityMAh, snapshot.designCycleCount]
            )
            try db.execute(
                sql: "UPDATE batteries SET first_seen_at = MIN(first_seen_at, ?), last_seen_at = MAX(last_seen_at, ?) WHERE id = ?",
                arguments: [ts, ts, batteryID]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO batteries (serial_sha256, design_mah, design_cycle_count, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [hash, snapshot.designCapacityMAh, snapshot.designCycleCount, ts, ts]
            )
            batteryID = db.lastInsertedRowID
        }

        if let previous, previous != batteryID {
            try db.execute(
                sql: "INSERT INTO battery_events (ts, kind, battery_id) VALUES (?, ?, ?)",
                arguments: [ts, BatteryEvent.Kind.batteryChanged.rawValue, batteryID]
            )
        }
        try db.execute(
            sql: "UPDATE daily_health SET battery_id = ? WHERE battery_id IS NULL AND source_id = ?",
            arguments: [batteryID, nativeSourceID]
        )
        return batteryID
    }

    /// 按字段 upsert 当天本机的每日数据：每个字段保留最后一个非 NULL 的值。所有字段都为 nil 时不写。
    static func upsertNativeDaily(
        _ db: Database,
        day: String,
        batteryID: Int64?,
        fullChargeCapacityMAh: Int?,
        designCapacityMAh: Int?,
        cycleCount: Int?,
        systemMaxCapacityPercent: Int? = nil,
        healthCondition: String? = nil,
        at date: Date
    ) throws {
        let values: [(any DatabaseValueConvertible)?] = [
            fullChargeCapacityMAh, designCapacityMAh, cycleCount, systemMaxCapacityPercent, healthCondition,
        ]
        guard values.contains(where: { $0 != nil }) else { return }
        try db.execute(
            sql: """
                INSERT INTO daily_health
                    (day, source_id, battery_id, full_charge_mah, design_mah, cycle_count,
                     system_max_capacity_pct, health_condition, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, source_id) DO UPDATE SET
                    battery_id = COALESCE(excluded.battery_id, battery_id),
                    full_charge_mah = COALESCE(excluded.full_charge_mah, full_charge_mah),
                    design_mah = COALESCE(excluded.design_mah, design_mah),
                    cycle_count = COALESCE(excluded.cycle_count, cycle_count),
                    system_max_capacity_pct = COALESCE(excluded.system_max_capacity_pct, system_max_capacity_pct),
                    health_condition = COALESCE(excluded.health_condition, health_condition),
                    updated_at = excluded.updated_at
                WHERE battery_id IS NOT COALESCE(excluded.battery_id, battery_id)
                   OR full_charge_mah IS NOT COALESCE(excluded.full_charge_mah, full_charge_mah)
                   OR design_mah IS NOT COALESCE(excluded.design_mah, design_mah)
                   OR cycle_count IS NOT COALESCE(excluded.cycle_count, cycle_count)
                   OR system_max_capacity_pct IS NOT COALESCE(excluded.system_max_capacity_pct, system_max_capacity_pct)
                   OR health_condition IS NOT COALESCE(excluded.health_condition, health_condition)
                """,
            arguments: [
                day, nativeSourceID, batteryID, fullChargeCapacityMAh, designCapacityMAh, cycleCount,
                systemMaxCapacityPercent, healthCondition, UnixTime.seconds(date),
            ]
        )
    }

    /// 系统充电上限与上一条 `charge_limit` 事件的值不同时记一条。开启时记上限，关闭时记 100；不支持或未知时不记。
    static func recordChargeLimit(_ db: Database, _ setting: ChargeLimitSetting?, at date: Date) throws {
        let value: Int
        switch setting {
        case .on(let percent): value = percent
        case .off: value = 100
        case .unsupported, nil: return
        }
        let kind = BatteryEvent.Kind.chargeLimit.rawValue
        let last = try Int.fetchOne(
            db,
            sql: "SELECT value FROM battery_events WHERE kind = ? ORDER BY ts DESC, id DESC LIMIT 1",
            arguments: [kind]
        )
        guard last != value else { return }
        try db.execute(
            sql: "INSERT INTO battery_events (ts, kind, value) VALUES (?, ?, ?)",
            arguments: [UnixTime.seconds(date), kind, value]
        )
    }

    // MARK: - 小时汇总

    private static let hourlyColumns = """
        hour_ts, sample_count, external_minutes, charging_minutes,
        percent_avg, percent_min, percent_max,
        system_load_avg_mw, system_load_min_mw, system_load_max_mw,
        battery_power_avg_mw, battery_power_min_mw, battery_power_max_mw,
        power_in_avg_mw, power_in_min_mw, power_in_max_mw,
        temperature_avg_c, temperature_min_c, temperature_max_c,
        voltage_avg_mv, voltage_min_mv, voltage_max_mv,
        amperage_avg_ma, amperage_min_ma, amperage_max_ma
        """

    /// SQLite 的 AVG、MIN、MAX 只统计非 NULL 的值，全部为 NULL 时结果为 NULL。
    private static let hourlySelect = """
        SELECT
            (ts / 3600) * 3600 AS hour_ts,
            COUNT(*) AS sample_count,
            SUM(CASE WHEN is_external = 1 THEN 1 ELSE 0 END) AS external_minutes,
            SUM(CASE WHEN is_charging = 1 THEN 1 ELSE 0 END) AS charging_minutes,
            AVG(percent), MIN(percent), MAX(percent),
            AVG(system_load_mw), MIN(system_load_mw), MAX(system_load_mw),
            AVG(battery_power_mw), MIN(battery_power_mw), MAX(battery_power_mw),
            AVG(power_in_mw), MIN(power_in_mw), MAX(power_in_mw),
            AVG(temperature_c), MIN(temperature_c), MAX(temperature_c),
            AVG(voltage_mv), MIN(voltage_mv), MAX(voltage_mv),
            AVG(amperage_ma), MIN(amperage_ma), MAX(amperage_ma)
        FROM minute_samples
        """
}

/// 只在 DatabaseQueue 的串行队列上访问，包含查询闭包和事务观察回调。
private final class DailyHealthCache: TransactionObserver, @unchecked Sendable {
    var samples: [DailyHealth]?
    var dataVersion: Int64?

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind {
        case .update(tableName: "batteries", columnNames: let columns):
            return columns.contains("design_mah")
        default:
            return eventKind.tableName == "daily_health" || eventKind.tableName == "batteries"
        }
    }

    func databaseDidChange(with event: DatabaseEvent) { samples = nil }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) { samples = nil }
}

public struct RecordingSummary: Sendable, Equatable {
    /// 本机每日数据最早的一天，`YYYY-MM-DD`。
    public var firstDay: String
    public var dayCount: Int

    public init(firstDay: String, dayCount: Int) {
        self.firstDay = firstDay
        self.dayCount = dayCount
    }
}
