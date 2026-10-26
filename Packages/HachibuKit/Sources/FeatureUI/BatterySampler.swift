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
        chargeLimitWriter: (any ChargeLimitWriter)? = PowerUIChargeLimitWriter(),
        store: HistoryStore?
    ) {
        self.dataSource = dataSource
        self.systemProfiler = systemProfiler
        self.chargeLimitWriter = chargeLimitWriter
        self.store = store
    }

    /// 完整读取一次，返回结果和读取时间。
    func read() -> (reading: BatteryReading, date: Date) {
        // IOPS 在完整读取的最开始采集；不能用 PowerUI 等调用结束的时间把旧状态标成新状态。
        let date = Date()
        let reading = BatteryReading(dataSource.read())
        latest = reading
        return (reading, date)
    }

    /// 修改系统充电上限，再完整读取一次。`applied` 表示写入成功且读回的设置已符合这次修改。
    func writeChargeLimit(_ change: ChargeLimitChange) -> (reading: BatteryReading, date: Date, applied: Bool) {
        var written = false
        if let chargeLimitWriter {
            do {
                try chargeLimitWriter.write(change)
                written = true
            } catch let error as ChargeLimitWriteError {
                logger.error("Failed to write charge limit: \(error.message, privacy: .public)")
            } catch {
                logger.error("Failed to write charge limit: \(String(describing: error), privacy: .public)")
            }
        }
        let result = read()
        guard case .battery(let snapshot) = result.reading, written else {
            return (result.reading, result.date, false)
        }
        let applied = change.isApplied(to: snapshot.chargeLimit)
        if !applied {
            logger.error("Charge limit read back does not match \(String(describing: change), privacy: .public)")
        }
        return (result.reading, result.date, applied)
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
