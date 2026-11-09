import Foundation
import GRDB
import Testing
@testable import HistoryStore

/// 2026-10-20 00:00:00 UTC，整小时。
private let base = Date(timeIntervalSince1970: 1_792_454_400)

private func at(_ minutes: Int, seconds: Double = 0) -> Date {
    base.addingTimeInterval(TimeInterval(minutes * 60) + seconds)
}

@Suite struct ChargePolicyPeriodTests {
    @Test func migrationCreatesTables() async throws {
        let store = try HistoryStore.inMemory()
        let tables = try await store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for name in ["charge_policy_periods", "calibration_runs", "calibration_steps", "calibration_pauses"] {
            #expect(tables.contains(name))
        }
    }

    @Test func beginAndEnd() async throws {
        let store = try HistoryStore.inMemory()
        let id = try await store.beginChargePolicyPeriod(.optimizedCharging, at: at(10, seconds: 30.9))
        var periods = try await store.chargePolicyPeriods(from: at(0), to: at(100))
        #expect(periods == [ChargePolicyPeriod(id: id, kind: .optimizedCharging, start: at(10, seconds: 30))])

        try await store.endChargePolicyPeriod(id: id, at: at(20))
        // 已结束的不再更新。
        try await store.endChargePolicyPeriod(id: id, at: at(30))
        periods = try await store.chargePolicyPeriods(from: at(0), to: at(100))
        #expect(periods.first?.end == at(20))
    }

    @Test func overlapQuery() async throws {
        let store = try HistoryStore.inMemory()
        let before = try await store.beginChargePolicyPeriod(.otherTool, at: at(0))
        try await store.endChargePolicyPeriod(id: before, at: at(10))
        let inside = try await store.beginChargePolicyPeriod(.systemCalibration, at: at(20))
        try await store.endChargePolicyPeriod(id: inside, at: at(30))
        let open = try await store.beginChargePolicyPeriod(.fullChargeOverride, at: at(40))
        let after = try await store.beginChargePolicyPeriod(.temporaryFullCharge, at: at(100))

        // [15, 50)：只有 inside 和进行中的 open。
        let periods = try await store.chargePolicyPeriods(from: at(15), to: at(50))
        #expect(periods.map(\.id) == [inside, open])
        // 边界：结束时间等于 from、开始时间等于 to 都不重叠。
        let edge = try await store.chargePolicyPeriods(from: at(10), to: at(100))
        #expect(edge.map(\.id) == [inside, open])
        #expect(!edge.map(\.id).contains(before))
        #expect(!edge.map(\.id).contains(after))
    }

    @Test func endOpenPeriods() async throws {
        let store = try HistoryStore.inMemory()
        let closed = try await store.beginChargePolicyPeriod(.otherTool, at: at(0))
        try await store.endChargePolicyPeriod(id: closed, at: at(5))
        _ = try await store.beginChargePolicyPeriod(.optimizedCharging, at: at(10))
        _ = try await store.beginChargePolicyPeriod(.fullChargeOverride, at: at(11))

        try await store.endOpenChargePolicyPeriods(at: at(60))
        let periods = try await store.chargePolicyPeriods(from: at(0), to: at(120))
        #expect(periods.map(\.end) == [at(5), at(60), at(60)])
    }

    @Test func unknownKindIsSkipped() async throws {
        let store = try HistoryStore.inMemory()
        let start = UnixTime.seconds(at(1))
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO charge_policy_periods (kind, start_ts) VALUES ('future_kind', ?)",
                arguments: [start]
            )
        }
        let known = try await store.beginChargePolicyPeriod(.otherTool, at: at(2))
        let periods = try await store.chargePolicyPeriods(from: at(0), to: at(10))
        #expect(periods.map(\.id) == [known])
    }
}

@Suite struct CalibrationRecordTests {
    @Test func fullFlow() async throws {
        let store = try HistoryStore.inMemory()
        let before = CalibrationHealth(fullChargeMAh: 5000, systemMaxCapacityPct: 95, cycleCount: 200)
        let run = try await store.startCalibrationRun(trigger: .afterSystemFullCharge, at: at(0), before: before)

        var runs = try await store.calibrationRuns()
        #expect(runs == [CalibrationRun(id: run, startedAt: at(0), trigger: .afterSystemFullCharge, before: before)])

        let step1 = try await store.beginCalibrationStep(runID: run, step: 1, at: at(0), percent: 100)
        try await store.finishCalibrationStep(id: step1, at: at(1), percent: 100, outcome: .alreadySatisfied)
        let step2 = try await store.beginCalibrationStep(runID: run, step: 2, at: at(1), percent: 100)
        let pause = try await store.beginCalibrationPause(runID: run, reason: "power_removed", at: at(5))
        try await store.endCalibrationPause(id: pause, at: at(8))
        // 已结束的不再更新。
        try await store.endCalibrationPause(id: pause, at: at(9))
        try await store.finishCalibrationStep(id: step2, at: at(30), percent: 20, outcome: .reached)

        let steps = try await store.calibrationSteps(runID: run)
        #expect(steps == [
            CalibrationStepRecord(
                id: step1, runID: run, step: 1, startedAt: at(0), endedAt: at(1),
                startPercent: 100, endPercent: 100, outcome: .alreadySatisfied
            ),
            CalibrationStepRecord(
                id: step2, runID: run, step: 2, startedAt: at(1), endedAt: at(30),
                startPercent: 100, endPercent: 20, outcome: .reached
            ),
        ])
        let pauses = try await store.calibrationPauses(runID: run)
        #expect(pauses == [CalibrationPauseRecord(id: pause, runID: run, start: at(5), end: at(8), reason: "power_removed")])

        // after 为 nil 的结束。
        try await store.finishCalibrationRun(id: run, result: .cancelled, at: at(40), after: nil)
        runs = try await store.calibrationRuns()
        #expect(runs.first?.result == .cancelled)
        #expect(runs.first?.endedAt == at(40))
        #expect(runs.first?.after == nil)

        // 带 after 的结束。
        let after = CalibrationHealth(fullChargeMAh: 5100)
        try await store.finishCalibrationRun(id: run, result: .completed, at: at(50), after: after)
        runs = try await store.calibrationRuns()
        #expect(runs.first?.result == .completed)
        #expect(runs.first?.after == after)
    }

    @Test func orderingAndLimit() async throws {
        let store = try HistoryStore.inMemory()
        let a = try await store.startCalibrationRun(trigger: .manual, at: at(0), before: CalibrationHealth())
        let b = try await store.startCalibrationRun(trigger: .manual, at: at(100), before: CalibrationHealth())
        let c = try await store.startCalibrationRun(trigger: .manual, at: at(50), before: CalibrationHealth())

        #expect(try await store.calibrationRuns().map(\.id) == [b, c, a])
        #expect(try await store.calibrationRuns(limit: 2).map(\.id) == [b, c])
    }

    @Test func overlapQuery() async throws {
        let store = try HistoryStore.inMemory()
        let old = try await store.startCalibrationRun(trigger: .manual, at: at(0), before: CalibrationHealth())
        try await store.finishCalibrationRun(id: old, result: .completed, at: at(10), after: nil)
        let inside = try await store.startCalibrationRun(trigger: .manual, at: at(30), before: CalibrationHealth())
        try await store.finishCalibrationRun(id: inside, result: .completed, at: at(40), after: nil)
        let open = try await store.startCalibrationRun(trigger: .manual, at: at(60), before: CalibrationHealth())
        let future = try await store.startCalibrationRun(trigger: .manual, at: at(200), before: CalibrationHealth())

        let runs = try await store.calibrationRuns(overlapping: at(20), at(100))
        #expect(runs.map(\.id) == [inside, open])
        #expect(!runs.map(\.id).contains(old))
        #expect(!runs.map(\.id).contains(future))
    }

    @Test func deletingRunCascades() async throws {
        let store = try HistoryStore.inMemory()
        let run = try await store.startCalibrationRun(trigger: .manual, at: at(0), before: CalibrationHealth())
        _ = try await store.beginCalibrationStep(runID: run, step: 1, at: at(0), percent: nil)
        _ = try await store.beginCalibrationPause(runID: run, reason: "x", at: at(1))

        try await store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM calibration_runs WHERE id = ?", arguments: [run])
        }
        #expect(try await store.calibrationSteps(runID: run).isEmpty)
        #expect(try await store.calibrationPauses(runID: run).isEmpty)
    }

    @Test func unknownStringsFallBack() async throws {
        let store = try HistoryStore.inMemory()
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO calibration_runs (id, started_at, trigger, result) VALUES (1, 100, 'future_trigger', 'future_result')"
            )
            try db.execute(
                sql: "INSERT INTO calibration_steps (run_id, step, started_at, outcome) VALUES (1, 1, 100, 'future_outcome')"
            )
        }
        let run = try #require(try await store.calibrationRuns().first)
        #expect(run.trigger == .manual)
        #expect(run.result == nil)
        #expect(run.after == nil)
        let step = try #require(try await store.calibrationSteps(runID: 1).first)
        #expect(step.outcome == nil)
    }
}

@Suite struct LastFullChargeTimeTests {
    @Test func noData() async throws {
        let store = try HistoryStore.inMemory()
        #expect(try await store.lastFullChargeTime() == nil)
    }

    @Test func belowFullIgnored() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(MinuteSample(timestamp: at(0), percent: 99))
        #expect(try await store.lastFullChargeTime() == nil)
    }

    @Test func minuteOnly() async throws {
        let store = try HistoryStore.inMemory()
        try await store.write(MinuteSample(timestamp: at(0), percent: 100))
        try await store.write(MinuteSample(timestamp: at(5), percent: 100))
        try await store.write(MinuteSample(timestamp: at(9), percent: 90))
        #expect(try await store.lastFullChargeTime() == at(5))
    }

    @Test func hourlyOnly() async throws {
        let store = try HistoryStore.inMemory()
        try await insertHourly(store, hour: 3600, max: 100)
        try await insertHourly(store, hour: 7200, max: 97)
        #expect(try await store.lastFullChargeTime() == Date(timeIntervalSince1970: 3600))
    }

    @Test func takesLarger() async throws {
        let store = try HistoryStore.inMemory()
        let hour = UnixTime.seconds(base)
        try await insertHourly(store, hour: hour, max: 100)
        try await store.write(MinuteSample(timestamp: at(90), percent: 100))
        #expect(try await store.lastFullChargeTime() == at(90))

        // 小时数据更晚时取小时数据。
        try await insertHourly(store, hour: hour + 7200, max: 100)
        #expect(try await store.lastFullChargeTime() == at(120))
    }

    private func insertHourly(_ store: HistoryStore, hour: Int64, max: Int) async throws {
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO hourly_samples (hour_ts, sample_count, external_minutes, percent_max) VALUES (?, 60, 0, ?)",
                arguments: [hour, max]
            )
        }
    }
}
