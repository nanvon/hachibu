import BatteryCore
import Foundation
import HistoryStore
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Sampling")

/// 硬件读取和数据库写入。何时调用由 BatteryMonitor 安排，规则见 docs/v1技术设计.md 第 9、10 节。
public actor BatterySampler {
    private let dataSource: any BatteryDataSource
    private let systemProfiler: any SystemProfilerSource
    /// 数据库打不开时为 nil：照常读取，不写库。
    private let store: HistoryStore?
    /// PowerUI 写入方法不可用时为 nil：只读显示系统充电上限。
    private let chargeLimitWriter: (any ChargeLimitWriter)?
    /// 最近一次完整读取的结果。分钟数据和每日数据都用它。
    private var latest: BatteryReading?

    /// 能否修改系统充电上限。
    public nonisolated var canWriteChargeLimit: Bool {
        chargeLimitWriter != nil
    }

    public init(
        dataSource: any BatteryDataSource = IOKitBatteryDataSource(),
        systemProfiler: any SystemProfilerSource = SystemProfilerReader(),
        chargeLimitWriter: (any ChargeLimitWriter)? = RoutedChargeLimitWriter(helper: { ChargeHelperService.readyClient() }),
        store: HistoryStore?
    ) {
        self.dataSource = dataSource
        self.systemProfiler = systemProfiler
        self.chargeLimitWriter = chargeLimitWriter
        self.store = store
    }

    /// 完整读取一次。失败时返回 nil，并停止用之前的读数写入新样本。
    func read() -> (reading: BatteryReading?, date: Date) {
        // IOPS 在完整读取的最开始采集；不能用 PowerUI 等调用结束的时间把旧状态标成新状态。
        let date = Date()
        do {
            let reading = BatteryReading(try dataSource.read())
            latest = reading
            return (reading, date)
        } catch {
            latest = nil
            logger.error("Failed to read battery: \(String(describing: error), privacy: .public)")
            return (nil, date)
        }
    }

    /// 修改系统充电上限，再完整读取一次。`applied` 表示写入成功且读回的设置已符合这次修改。
    func writeChargeLimit(_ change: ChargeLimitChange) async -> (reading: BatteryReading?, date: Date, applied: Bool) {
        var written = false
        if let chargeLimitWriter {
            do {
                // 同步等待系统服务的写入交给 Dispatch，避免占住 Swift 并发线程。
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try chargeLimitWriter.write(change) })
                    }
                }
                written = true
            } catch let error as ChargeLimitWriteError {
                logger.error("Failed to write charge limit: \(error.message, privacy: .public)")
            } catch {
                logger.error("Failed to write charge limit: \(String(describing: error), privacy: .public)")
            }
        }
        let result = read()
        guard case .battery(let snapshot)? = result.reading, written else {
            return (result.reading, result.date, false)
        }
        let applied = change.isApplied(to: snapshot.chargeLimit)
        if !applied {
            logger.error("Charge limit read back does not match \(String(describing: change), privacy: .public)")
        }
        return (result.reading, result.date, applied)
    }

    /// 在当前线程同步写入，不读回快照。只用于应用退出时恢复用户的上限，写入方法内部仍按 PowerUI 读回判断成功。
    nonisolated func writeChargeLimitImmediately(_ change: ChargeLimitChange) -> Bool {
        guard let chargeLimitWriter else { return false }
        do {
            try chargeLimitWriter.write(change)
            return true
        } catch {
            logger.error("Failed to write charge limit before exit: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 用最近一次读取的值写一行分钟数据，同时更新电池、当天的满充容量和循环次数、事件。没有电池或还没有读取时不写。
    func writeMinuteSample(at date: Date) async {
        guard let store, case .battery(let snapshot)? = latest else { return }
        do {
            try await store.record(snapshot, at: date)
        } catch {
            logger.error("Failed to write minute sample: \(String(describing: error), privacy: .public)")
        }
    }

    /// 运行 `system_profiler` 读取健康信息，再把系统最大容量和健康状态写进当天的每日数据。
    /// 没有电池时不运行；`system_profiler` 失败时返回 nil，不写库。满充容量、循环次数由每分钟的写入负责。
    func refreshHealth(at date: Date) async -> BatteryHealthInfo? {
        guard case .battery = latest else { return nil }

        let health: BatteryHealthInfo
        do {
            health = BatteryHealthInfo(systemProfilerPower: try await systemProfiler.readPowerData())
        } catch {
            logger.error("system_profiler failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        // 等待 system_profiler 期间可能有新的读取，用最新的 IORegistry 读数。
        if let store, case .battery(let snapshot)? = latest {
            do {
                try await store.record(health, snapshot: snapshot, at: date)
            } catch {
                logger.error("Failed to write daily sample: \(String(describing: error), privacy: .public)")
            }
        }
        return health
    }

    // MARK: - 充电接管记录（docs/v1技术设计.md 21.8）

    /// 记录系统策略时段的开始，返回 id；没有数据库或写入失败时为 nil。
    func beginPolicyPeriod(_ kind: ChargePolicyKind, at date: Date) async -> Int64? {
        await recording("begin policy period") { try await $0.beginChargePolicyPeriod(kind, at: date) }
    }

    func endPolicyPeriod(id: Int64, at date: Date) async {
        _ = await recording("end policy period") { try await $0.endChargePolicyPeriod(id: id, at: date) }
    }

    /// 启动时结束上次异常退出留下的时段。
    func endOpenPolicyPeriods(at date: Date) async {
        _ = await recording("end open policy periods") { try await $0.endOpenChargePolicyPeriods(at: date) }
    }

    func startCalibrationRun(_ kind: CalibrationStartKind, at date: Date, before: CalibrationHealth) async -> Int64? {
        let trigger: CalibrationTrigger = kind == .manual ? .manual : .afterSystemFullCharge
        return await recording("start calibration") {
            try await $0.startCalibrationRun(trigger: trigger, at: date, before: before)
        }
    }

    func finishCalibrationRun(id: Int64, ending: CalibrationEnding, at date: Date, after: CalibrationHealth?) async {
        let result: CalibrationResult = switch ending {
        case .completed: .completed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
        _ = await recording("finish calibration") {
            try await $0.finishCalibrationRun(id: id, result: result, at: date, after: after)
        }
    }

    func beginCalibrationStep(runID: Int64, step: CalibrationStep, at date: Date, percent: Int?) async -> Int64? {
        await recording("begin calibration step") {
            try await $0.beginCalibrationStep(runID: runID, step: step.rawValue, at: date, percent: percent)
        }
    }

    func finishCalibrationStep(id: Int64, completion: CalibrationStepCompletion, at date: Date, percent: Int?) async {
        let outcome: CalibrationStepOutcome = switch completion {
        case .reached: .reached
        case .alreadySatisfied: .alreadySatisfied
        case .skipped: .skipped
        }
        _ = await recording("finish calibration step") {
            try await $0.finishCalibrationStep(id: id, at: date, percent: percent, outcome: outcome)
        }
    }

    func beginCalibrationPause(runID: Int64, reason: CalibrationPauseReason, at date: Date) async -> Int64? {
        await recording("begin calibration pause") {
            try await $0.beginCalibrationPause(runID: runID, reason: reason.rawValue, at: date)
        }
    }

    func endCalibrationPause(id: Int64, at date: Date) async {
        _ = await recording("end calibration pause") { try await $0.endCalibrationPause(id: id, at: date) }
    }

    /// 最近 1 小时的分钟数据是否一直插电且电量 ≥ 99%（校准确认框判断起点用）。没有数据时为 false。
    func heldFull(since date: Date, until end: Date) async -> Bool {
        guard let store else { return false }
        do {
            let samples = try await store.minuteSamples(from: date, to: end)
            // 至少要有大半个小时的分钟数据，缺口太多时不判断为已满足。
            guard samples.count >= 45 else { return false }
            return samples.allSatisfy { $0.isExternalPower == true && ($0.percent ?? 0) >= CalibrationStep.holdMinimumPercent }
        } catch {
            logger.error("Failed to read minute samples: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func calibrationRuns(limit: Int) async -> [CalibrationRun] {
        await recording("read calibration runs") { try await $0.calibrationRuns(limit: limit) } ?? []
    }

    func lastFullChargeTime() async -> Date? {
        await recording("read last full charge") { try await $0.lastFullChargeTime() } ?? nil
    }

    private func recording<Value: Sendable>(
        _ label: String, _ operation: (HistoryStore) async throws -> Value
    ) async -> Value? {
        guard let store else { return nil }
        do {
            return try await operation(store)
        } catch {
            logger.error("Failed to \(label, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 把超过保留期的分钟数据聚合为小时数据。
    func aggregateHistory(now: Date) async {
        guard let store else { return }
        do {
            try await store.aggregateMinuteSamples(now: now)
        } catch {
            logger.error("Failed to aggregate minute samples: \(String(describing: error), privacy: .public)")
        }
    }
}
