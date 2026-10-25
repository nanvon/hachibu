// GRDB 数据库、采样写入、聚合、查询。表结构见 docs/v1技术设计.md 第 10 节。
// 不依赖 AppKit / SwiftUI，不包含界面文案。
import Foundation
import GRDB

/// 历史数据库。时间戳都存 UTC Unix 秒。
public final class HistoryStore: Sendable {
    /// 分钟数据保留时长，更早的按小时聚合后删除。
    public static let minuteRetention: TimeInterval = 7 * 24 * 3600

    let dbQueue: DatabaseQueue

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

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// `~/Library/Application Support/<Bundle ID>/history.sqlite`。
    public static func defaultFileURL(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    // MARK: - 写入

    /// 写入一分钟的样本，主键冲突时覆盖。
    public func write(_ sample: MinuteSample) async throws {
        try await dbQueue.write { db in
            try sample.insert(db, onConflict: .replace)
        }
    }

    /// 按日期 upsert，一天保留最后的值。
    public func write(_ sample: DailySample) async throws {
        try await dbQueue.write { db in
            try sample.insert(db, onConflict: .replace)
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

    /// 从 `firstDay`（含）开始的每日样本，按日期排序；`firstDay` 为 nil 时返回全部。用于长期曲线。
    public func dailySamples(from firstDay: String? = nil) async throws -> [DailySample] {
        try await dbQueue.read { db in
            var request = DailySample.order(sql: "day")
            if let firstDay {
                request = request.filter(sql: "day >= ?", arguments: [firstDay])
            }
            return try request.fetchAll(db)
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

    /// 侧栏底部的记录概况：`daily_samples` 最早的一天和行数。没有数据时为 nil。
    public func recordingSummary() async throws -> RecordingSummary? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT MIN(day) AS first_day, COUNT(*) AS day_count FROM daily_samples"),
                  let firstDay: String = row["first_day"]
            else { return nil }
            return RecordingSummary(firstDay: firstDay, dayCount: row["day_count"])
        }
    }

    /// 测试用。
    func hourlySamples() throws -> [HourlySample] {
        try dbQueue.read { db in
            try HourlySample.order(sql: "hour_ts").fetchAll(db)
        }
    }

    // MARK: - 小时汇总

    private static let hourlyColumns = """
        hour_ts, sample_count, external_minutes,
        percent_avg, percent_min, percent_max,
        system_load_avg_mw, system_load_max_mw,
        temperature_avg_c, temperature_max_c
        """

    /// SQLite 的 AVG、MIN、MAX 只统计非 NULL 的值，全部为 NULL 时结果为 NULL。
    private static let hourlySelect = """
        SELECT
            (ts / 3600) * 3600 AS hour_ts,
            COUNT(*) AS sample_count,
            SUM(CASE WHEN is_external = 1 THEN 1 ELSE 0 END) AS external_minutes,
            AVG(percent) AS percent_avg,
            MIN(percent) AS percent_min,
            MAX(percent) AS percent_max,
            AVG(system_load_mw) AS system_load_avg_mw,
            MAX(system_load_mw) AS system_load_max_mw,
            AVG(temperature_c) AS temperature_avg_c,
            MAX(temperature_c) AS temperature_max_c
        FROM minute_samples
        """
}

public struct RecordingSummary: Sendable, Equatable {
    /// `daily_samples` 最早的一天，`YYYY-MM-DD`。
    public var firstDay: String
    public var dayCount: Int

    public init(firstDay: String, dayCount: Int) {
        self.firstDay = firstDay
        self.dayCount = dayCount
    }
}
