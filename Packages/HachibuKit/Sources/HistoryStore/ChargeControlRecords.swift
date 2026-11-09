// 系统策略时段和电池校准记录。表结构见 docs/v1技术设计.md 第 10 节和第 21.8 节。
import Foundation
import GRDB

/// 系统策略时段的类型。
public enum ChargePolicyKind: String, Sendable, CaseIterable {
    case systemCalibration = "system_calibration"
    case fullChargeOverride = "full_charge_override"
    case temporaryFullCharge = "temporary_full_charge"
    case optimizedCharging = "optimized_charging"
    case otherTool = "other_tool"
}

/// `charge_policy_periods` 的一行。`end` 为 nil 表示进行中。
public struct ChargePolicyPeriod: Sendable, Equatable {
    public var id: Int64
    public var kind: ChargePolicyKind
    public var start: Date
    public var end: Date?

    public init(id: Int64, kind: ChargePolicyKind, start: Date, end: Date? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }
}

public enum CalibrationTrigger: String, Sendable {
    case manual
    case afterSystemFullCharge = "after_system_full_charge"
}

public enum CalibrationResult: String, Sendable {
    case completed, cancelled, interrupted
}

public enum CalibrationStepOutcome: String, Sendable {
    case reached
    case alreadySatisfied = "already_satisfied"
    case skipped
}

/// 校准前后记录的电池健康数据，缺失的为 nil。
public struct CalibrationHealth: Sendable, Equatable {
    public var fullChargeMAh: Int?
    public var systemMaxCapacityPct: Int?
    public var cycleCount: Int?

    public init(fullChargeMAh: Int? = nil, systemMaxCapacityPct: Int? = nil, cycleCount: Int? = nil) {
        self.fullChargeMAh = fullChargeMAh
        self.systemMaxCapacityPct = systemMaxCapacityPct
        self.cycleCount = cycleCount
    }
}

/// `calibration_runs` 的一行。`result` 为 nil 表示进行中；`after` 三项都为 NULL 时为 nil。
public struct CalibrationRun: Sendable, Equatable {
    public var id: Int64
    public var startedAt: Date
    public var endedAt: Date?
    public var trigger: CalibrationTrigger
    public var result: CalibrationResult?
    public var before: CalibrationHealth
    public var after: CalibrationHealth?

    public init(
        id: Int64,
        startedAt: Date,
        endedAt: Date? = nil,
        trigger: CalibrationTrigger,
        result: CalibrationResult? = nil,
        before: CalibrationHealth = CalibrationHealth(),
        after: CalibrationHealth? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trigger = trigger
        self.result = result
        self.before = before
        self.after = after
    }
}

/// `calibration_steps` 的一行，`step` 为 1–6。
public struct CalibrationStepRecord: Sendable, Equatable {
    public var id: Int64
    public var runID: Int64
    public var step: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var startPercent: Int?
    public var endPercent: Int?
    public var outcome: CalibrationStepOutcome?

    public init(
        id: Int64,
        runID: Int64,
        step: Int,
        startedAt: Date,
        endedAt: Date? = nil,
        startPercent: Int? = nil,
        endPercent: Int? = nil,
        outcome: CalibrationStepOutcome? = nil
    ) {
        self.id = id
        self.runID = runID
        self.step = step
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.outcome = outcome
    }
}

/// `calibration_pauses` 的一行。`end` 为 nil 表示进行中。
public struct CalibrationPauseRecord: Sendable, Equatable {
    public var id: Int64
    public var runID: Int64
    public var start: Date
    public var end: Date?
    public var reason: String

    public init(id: Int64, runID: Int64, start: Date, end: Date? = nil, reason: String) {
        self.id = id
        self.runID = runID
        self.start = start
        self.end = end
        self.reason = reason
    }
}

// MARK: - 接口

extension HistoryStore {
    // MARK: 系统策略时段

    /// 开始一个系统策略时段，返回 id。
    public func beginChargePolicyPeriod(_ kind: ChargePolicyKind, at date: Date) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO charge_policy_periods (kind, start_ts) VALUES (?, ?)",
                arguments: [kind.rawValue, UnixTime.seconds(date)]
            )
            return db.lastInsertedRowID
        }
    }

    /// 结束一个时段，只更新进行中的行。
    public func endChargePolicyPeriod(id: Int64, at date: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE charge_policy_periods SET end_ts = ? WHERE id = ? AND end_ts IS NULL",
                arguments: [UnixTime.seconds(date), id]
            )
        }
    }

    /// 结束所有进行中的时段。App 启动时调用，处理上次异常退出留下的。
    public func endOpenChargePolicyPeriods(at date: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE charge_policy_periods SET end_ts = ? WHERE end_ts IS NULL",
                arguments: [UnixTime.seconds(date)]
            )
        }
    }

    /// 与 `[from, to)` 重叠的时段，按开始时间升序。不认识的类型跳过。
    public func chargePolicyPeriods(from: Date, to: Date) async throws -> [ChargePolicyPeriod] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, start_ts, end_ts FROM charge_policy_periods
                    WHERE start_ts < ? AND (end_ts IS NULL OR end_ts > ?)
                    ORDER BY start_ts, id
                    """,
                arguments: [UnixTime.seconds(to), UnixTime.seconds(from)]
            ).compactMap { row in
                guard let kind = ChargePolicyKind(rawValue: row["kind"]) else { return nil }
                return ChargePolicyPeriod(
                    id: row["id"],
                    kind: kind,
                    start: UnixTime.date(row["start_ts"]),
                    end: (row["end_ts"] as Int64?).map(UnixTime.date)
                )
            }
        }
    }

    // MARK: 校准记录

    /// 开始一次校准，返回 id。
    public func startCalibrationRun(
        trigger: CalibrationTrigger,
        at date: Date,
        before: CalibrationHealth
    ) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO calibration_runs
                        (started_at, trigger, before_full_charge_mah, before_system_max_capacity_pct, before_cycle_count)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UnixTime.seconds(date), trigger.rawValue,
                    before.fullChargeMAh, before.systemMaxCapacityPct, before.cycleCount,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// 结束一次校准，写入结果和校准后的健康数据。
    public func finishCalibrationRun(
        id: Int64,
        result: CalibrationResult,
        at date: Date,
        after: CalibrationHealth?
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE calibration_runs SET
                        ended_at = ?, result = ?,
                        after_full_charge_mah = ?, after_system_max_capacity_pct = ?, after_cycle_count = ?
                    WHERE id = ?
                    """,
                arguments: [
                    UnixTime.seconds(date), result.rawValue,
                    after?.fullChargeMAh, after?.systemMaxCapacityPct, after?.cycleCount,
                    id,
                ]
            )
        }
    }

    /// 开始校准的一个步骤（1–6），返回 id。
    public func beginCalibrationStep(runID: Int64, step: Int, at date: Date, percent: Int?) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO calibration_steps (run_id, step, started_at, start_percent) VALUES (?, ?, ?, ?)",
                arguments: [runID, step, UnixTime.seconds(date), percent]
            )
            return db.lastInsertedRowID
        }
    }

    public func finishCalibrationStep(
        id: Int64,
        at date: Date,
        percent: Int?,
        outcome: CalibrationStepOutcome
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE calibration_steps SET ended_at = ?, end_percent = ?, outcome = ? WHERE id = ?",
                arguments: [UnixTime.seconds(date), percent, outcome.rawValue, id]
            )
        }
    }

    /// 开始一次校准暂停，返回 id。
    public func beginCalibrationPause(runID: Int64, reason: String, at date: Date) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO calibration_pauses (run_id, start_ts, reason) VALUES (?, ?, ?)",
                arguments: [runID, UnixTime.seconds(date), reason]
            )
            return db.lastInsertedRowID
        }
    }

    /// 结束暂停，只更新未结束的行。
    public func endCalibrationPause(id: Int64, at date: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE calibration_pauses SET end_ts = ? WHERE id = ? AND end_ts IS NULL",
                arguments: [UnixTime.seconds(date), id]
            )
        }
    }

    /// 校准记录，按开始时间降序。`limit` 为 nil 时返回全部。
    public func calibrationRuns(limit: Int? = nil) async throws -> [CalibrationRun] {
        try await dbQueue.read { db in
            var sql = "SELECT * FROM calibration_runs ORDER BY started_at DESC, id DESC"
            var arguments = StatementArguments()
            if let limit {
                sql += " LIMIT ?"
                arguments = [limit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.calibrationRun)
        }
    }

    /// 与 `[start, end)` 重叠的校准记录，按开始时间升序。进行中的视为一直持续。
    public func calibrationRuns(overlapping start: Date, _ end: Date) async throws -> [CalibrationRun] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM calibration_runs
                    WHERE started_at < ? AND (ended_at IS NULL OR ended_at > ?)
                    ORDER BY started_at, id
                    """,
                arguments: [UnixTime.seconds(end), UnixTime.seconds(start)]
            ).map(Self.calibrationRun)
        }
    }

    /// 某次校准的步骤，按开始时间升序。
    public func calibrationSteps(runID: Int64) async throws -> [CalibrationStepRecord] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM calibration_steps WHERE run_id = ? ORDER BY started_at, id",
                arguments: [runID]
            ).map { row in
                CalibrationStepRecord(
                    id: row["id"],
                    runID: row["run_id"],
                    step: row["step"],
                    startedAt: UnixTime.date(row["started_at"]),
                    endedAt: (row["ended_at"] as Int64?).map(UnixTime.date),
                    startPercent: row["start_percent"],
                    endPercent: row["end_percent"],
                    outcome: (row["outcome"] as String?).flatMap(CalibrationStepOutcome.init(rawValue:))
                )
            }
        }
    }

    /// 某次校准的暂停，按开始时间升序。
    public func calibrationPauses(runID: Int64) async throws -> [CalibrationPauseRecord] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM calibration_pauses WHERE run_id = ? ORDER BY start_ts, id",
                arguments: [runID]
            ).map { row in
                CalibrationPauseRecord(
                    id: row["id"],
                    runID: row["run_id"],
                    start: UnixTime.date(row["start_ts"]),
                    end: (row["end_ts"] as Int64?).map(UnixTime.date),
                    reason: row["reason"]
                )
            }
        }
    }

    // MARK: 满电时间

    /// 最近一次电量达到 100% 的时间：分钟数据中 `percent >= 100` 的最大时间戳，
    /// 和小时数据中 `percent_max >= 100` 的最大小时起点，取较大者。都没有时为 nil。
    public func lastFullChargeTime() async throws -> Date? {
        try await dbQueue.read { db in
            let minute = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM minute_samples WHERE percent >= 100")
            let hour = try Int64.fetchOne(db, sql: "SELECT MAX(hour_ts) FROM hourly_samples WHERE percent_max >= 100")
            return [minute, hour].compactMap { $0 }.max().map(UnixTime.date)
        }
    }

    private static func calibrationRun(_ row: Row) -> CalibrationRun {
        let after = CalibrationHealth(
            fullChargeMAh: row["after_full_charge_mah"],
            systemMaxCapacityPct: row["after_system_max_capacity_pct"],
            cycleCount: row["after_cycle_count"]
        )
        let hasAfter = after.fullChargeMAh != nil || after.systemMaxCapacityPct != nil || after.cycleCount != nil
        return CalibrationRun(
            id: row["id"],
            startedAt: UnixTime.date(row["started_at"]),
            endedAt: (row["ended_at"] as Int64?).map(UnixTime.date),
            trigger: (row["trigger"] as String?).flatMap(CalibrationTrigger.init(rawValue:)) ?? .manual,
            result: (row["result"] as String?).flatMap(CalibrationResult.init(rawValue:)),
            before: CalibrationHealth(
                fullChargeMAh: row["before_full_charge_mah"],
                systemMaxCapacityPct: row["before_system_max_capacity_pct"],
                cycleCount: row["before_cycle_count"]
            ),
            after: hasAfter ? after : nil
        )
    }
}
