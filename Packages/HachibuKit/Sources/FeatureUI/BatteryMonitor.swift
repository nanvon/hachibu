import AppKit
import BatteryCore
import Foundation
import Observation

/// 当前电池读数，供菜单栏、面板显示；修改系统充电上限也经由这里，完成后立即刷新读数。
/// 按 docs/v1技术设计.md 第 9、10 节安排采样；完整读写在 BatterySampler，快速 IOPS 读取单独执行。
@MainActor
@Observable
public final class BatteryMonitor {
    private static let panelOpenInterval: Duration = .seconds(10)
    private static let panelClosedInterval: Duration = .seconds(60)
    private static let panelClosedTolerance: Duration = .seconds(10)
    private static let healthInterval: Duration = .seconds(3600)
    /// 写分钟数据时，最近一次读取早于这个时长（例如刚唤醒）就先重新读取。
    /// 面板关闭时最长约 70 秒读取一次（60 秒加 10 秒 leeway）。
    private static let maxMinuteSampleAge: TimeInterval = 75
    /// 充电控制工具的 Bundle ID 前缀。本机 AlDente Pro 为 `com.apphousekitchen.aldente-pro`。
    private static let chargeControlAppPrefixes = ["com.apphousekitchen.aldente"]

    /// 最近一次读取结果。启动后第一次读取完成前为 nil。
    public private(set) var reading: BatteryReading?
    /// 最近一次 `system_profiler` 读到的健康信息。读取失败时保留上一次的值。
    public private(set) var health: BatteryHealthInfo?
    /// 正在修改系统充电上限。
    public private(set) var isWritingChargeLimit = false
    /// 最近一次修改失败，或读回的设置与修改不符。下一次修改开始时清除。
    public private(set) var chargeLimitWriteFailed = false
    /// AlDente 等充电控制工具正在运行。此时不提供充电上限控制，避免两套工具同时控制充电。
    public private(set) var isChargeControlAppRunning = false
    /// 菜单栏面板正在显示。面板关闭时停止功率流动画。
    public private(set) var isPanelVisible = false

    /// 能否修改系统充电上限（PowerUI 写入方法可用）。
    public var canWriteChargeLimit: Bool {
        sampler.canWriteChargeLimit
    }

    /// 每次读取完成后调用，读数没变也调用。提醒判定用。
    @ObservationIgnored public var onRead: (@MainActor (BatteryReading, Date) -> Void)?
    /// 每次 `system_profiler` 读取成功后调用，健康信息没变也调用。
    @ObservationIgnored public var onHealthRefresh: (@MainActor (BatteryHealthInfo) -> Void)?

    @ObservationIgnored private let sampler: BatterySampler
    @ObservationIgnored private let powerSourceReader: @Sendable () -> BatteryReading?
    @ObservationIgnored private var latestPowerSource: (reading: BatteryReading, date: Date)?
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var powerSourceTask: Task<Void, Never>?
    @ObservationIgnored private var immediateReadTask: Task<Void, Never>?
    @ObservationIgnored private var needsImmediateRead = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var minuteTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var powerSourceObserver: PowerSourceObserver?
    @ObservationIgnored private var notificationObservers: [any NSObjectProtocol] = []

    public init(
        sampler: BatterySampler,
        powerSourceReader: @escaping @Sendable () -> BatteryReading? = { IOKitBatteryDataSource.readPowerSource() }
    ) {
        self.sampler = sampler
        self.powerSourceReader = powerSourceReader
    }

    /// 开始采样。重复调用无效果。
    public func start() {
        guard readTask == nil else { return }

        powerSourceObserver = PowerSourceObserver { [weak self] in self?.powerSourceDidChange() }
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter)
        observe(.NSProcessInfoPowerStateDidChange, in: .default)
        // 用户在系统电池设置中修改上限后，切回主窗口时立即刷新。
        observe(NSApplication.didBecomeActiveNotification, in: .default)
        refreshChargeControlApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(name, in: NSWorkspace.shared.notificationCenter) { $0.refreshChargeControlApps() }
        }

        startReadLoop()
        startMinuteLoop()
        startHealthLoop()
    }

    /// 面板打开时每 10 秒读取一次，关闭时每 60 秒读取一次。
    public func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible {
            readNow()
        }
        if readTask != nil {
            startReadLoop()
        }
    }

    // MARK: - 定时

    private func startReadLoop() {
        readTask?.cancel()
        let interval = isPanelVisible ? Self.panelOpenInterval : Self.panelClosedInterval
        let tolerance = isPanelVisible ? nil : Self.panelClosedTolerance
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: tolerance)
                guard !Task.isCancelled else { return }
                await self?.read()
            }
        }
    }

    /// 独立的每分钟定时器：按整分钟写入当时最近一次读取的值。
    /// 每次按当前时间重新计算下一个整分钟，休眠唤醒后从实际时间继续，不补数据。
    private func startMinuteLoop() {
        minuteTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let nextMinute = (now / 60).rounded(.down) * 60 + 60
                // 定时器可能略早触发，延后 1 秒，保证落在下一分钟内。
                try? await Task.sleep(for: .seconds(nextMinute + 1 - now), tolerance: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.writeMinuteSample()
            }
        }
    }

    /// 启动时和之后每小时：运行 `system_profiler` 写每日数据，再聚合分钟数据。
    private func startHealthLoop() {
        healthTask = Task { [weak self] in
            // 每日数据要用当时的 IORegistry 读数，启动时先读一次。
            await self?.refreshPowerSource()
            await self?.read()
            while !Task.isCancelled {
                await self?.refreshHealth()
                try? await Task.sleep(for: Self.healthInterval, tolerance: .seconds(60))
            }
        }
    }

    // MARK: - 读写

    /// 事件刷新入口；快速读取不参与完整请求的排队与合并。
    func readNow() {
        Task { [weak self] in
            await self?.refreshPowerSource()
            self?.requestCompleteRead()
        }
    }

    private func requestCompleteRead() {
        // 两类 IOPS 通知可能同时到达；完整读取最多执行一个并保留一次待刷新请求。
        needsImmediateRead = true
        guard immediateReadTask == nil else { return }
        immediateReadTask = Task { [weak self] in
            while let self, self.needsImmediateRead {
                self.needsImmediateRead = false
                await self.read()
            }
            self?.immediateReadTask = nil
        }
    }

    private func powerSourceDidChange() {
        readNow()
        powerSourceTask?.cancel()
        powerSourceTask = Task { [weak self] in
            // 通知与 IOPS 缓存可能不同步；仅在事件后短时补读，不增加常驻轮询。
            for delay: Duration in [.milliseconds(250), .milliseconds(750), .seconds(2)] {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshPowerSource()
            }
        }
    }

    /// 独立于采样 actor，完整读取被 PowerUI 阻塞时仍能更新接电/充电状态。
    func refreshPowerSource() async {
        let reader = powerSourceReader
        let result = await Task.detached(priority: .userInitiated) {
            let date = Date()
            return (reading: reader(), date: date)
        }.value
        guard !Task.isCancelled, let powerSource = result.reading else { return }
        if let latestPowerSource, result.date < latestPowerSource.date { return }
        if let lastReadAt, result.date < lastReadAt { return }
        latestPowerSource = (powerSource, result.date)
        let updated = reading?.updatingPowerSource(from: powerSource) ?? powerSource
        if reading != updated { reading = updated }
        // 快速读数不更新完整采样的新鲜度，也不重复触发温度提醒。
    }

    func read() async {
        let result = await sampler.read()
        update(result.reading, at: result.date)
    }

    private func update(_ newReading: BatteryReading, at date: Date) {
        // 多个触发同时读取时可能乱序返回，只保留较新的结果。
        if let lastReadAt, date < lastReadAt { return }
        lastReadAt = date
        let updated: BatteryReading
        if let latestPowerSource, latestPowerSource.date > date {
            updated = newReading.updatingPowerSource(from: latestPowerSource.reading)
        } else {
            updated = newReading
        }
        if reading != updated { reading = updated }
        onRead?(updated, date)
    }

    /// 修改系统充电上限，完成后立即用读回的值刷新。上一次修改未完成时忽略。
    public func setChargeLimit(_ change: ChargeLimitChange) async {
        guard !isWritingChargeLimit else { return }
        isWritingChargeLimit = true
        chargeLimitWriteFailed = false
        let result = await sampler.writeChargeLimit(change)
        update(result.reading, at: result.date)
        chargeLimitWriteFailed = !result.applied
        isWritingChargeLimit = false
    }

    private func refreshChargeControlApps() {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return Self.chargeControlAppPrefixes.contains { bundleIdentifier.hasPrefix($0) }
        }
        if running != isChargeControlAppRunning {
            isChargeControlAppRunning = running
        }
    }

    private func writeMinuteSample() async {
        if lastReadAt.map({ Date().timeIntervalSince($0) > Self.maxMinuteSampleAge }) ?? true {
            await read()
        }
        await sampler.writeMinuteSample(at: Date())
    }

    private func refreshHealth() async {
        if let health = await sampler.refreshHealth(at: Date()) {
            if health != self.health {
                self.health = health
            }
            onHealthRefresh?(health)
        }
        await sampler.aggregateHistory(now: Date())
    }

    /// 收到通知时执行 `action`，默认立即读取一次。
    private func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        perform action: @escaping @MainActor (BatteryMonitor) -> Void = { $0.readNow() }
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        notificationObservers.append(observer)
    }
}

private extension BatteryReading {
    /// 只合并 IOPS 字段；功率、温度和遥测时间保留原值，等待完整采样。
    func updatingPowerSource(from fresh: BatteryReading) -> BatteryReading {
        guard case .battery(var snapshot) = self, case .battery(let powerSource) = fresh else { return fresh }
        snapshot.percent = powerSource.percent
        snapshot.isExternalPower = powerSource.isExternalPower
        snapshot.isCharging = powerSource.isCharging
        snapshot.timeToEmptyMinutes = powerSource.timeToEmptyMinutes
        snapshot.timeToFullMinutes = powerSource.timeToFullMinutes
        snapshot.lowPowerModeEnabled = powerSource.lowPowerModeEnabled
        if powerSource.isExternalPower == false { snapshot.adapter = nil }
        return .battery(snapshot)
    }
}
