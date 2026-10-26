import AppKit
import BatteryCore
import Foundation
import Observation

/// 当前电池读数，供菜单栏、面板显示；修改系统充电上限也经由这里，完成后立即刷新读数。
/// 按 docs/v1技术设计.md 第 9、10 节安排采样；完整读写在 BatterySampler，快速 IOPS 读取和 SMC 读取（5.1）单独执行。
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
    /// SMC 读取间隔：修改充电上限或插拔电源后每秒、面板打开时每 5 秒读全部 key；面板关闭时只读 `CHSC`。
    private static let smcFastInterval: Duration = .seconds(1)
    private static let smcPanelInterval: Duration = .seconds(5)
    private static let smcChargingInterval: Duration = .milliseconds(1500)
    private static let smcChargingTolerance: Duration = .milliseconds(500)
    /// 读不到 `CHSC` 时（如其他机型）面板关闭期间不再高频读取，靠完整读取时的 SMC 读取。
    private static let smcUnavailableInterval: Duration = .seconds(60)
    /// 超过这个时长没有更新的 SMC 读数不再叠加，退回 IOPS / IORegistry。
    private static let smcDisplayMaxAge: TimeInterval = 90
    private static let smcChargingMaxAge: TimeInterval = 10
    /// 修改充电上限或插拔电源后加快读取 10 秒；期间 `CHSC` 变化就延长到变化后 3 秒，最长 20 秒。
    private static let stateChangeBoostDuration: TimeInterval = 10
    private static let stateChangeBoostSettle: TimeInterval = 3
    private static let stateChangeBoostLimit: TimeInterval = 20
    /// “保持当前电量”自动写入失败后，这么久内不再自动写入。
    private static let chargeLimitHoldRetryDelay: TimeInterval = 60
    private static let chargeLimitHoldKey = "chargeLimitHold"
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
    /// 菜单栏面板正在显示。决定读取间隔。
    public private(set) var isPanelVisible = false

    /// 电量高于上限时“保持当前电量”。由 App 层按 `AppSettings.chargeAboveLimitAction` 设置，规则见 docs/v1技术设计.md 第 6 节。
    @ObservationIgnored public var holdsChargeAboveLimit = false {
        didSet {
            if holdsChargeAboveLimit != oldValue { evaluateChargeLimitHold() }
        }
    }

    /// 能否修改系统充电上限（PowerUI 写入方法可用）。
    public var canWriteChargeLimit: Bool {
        sampler.canWriteChargeLimit
    }

    /// 每次读取完成后调用，失败传 nil。提醒判定用，失败时中断温度持续计时。
    @ObservationIgnored public var onRead: (@MainActor (BatteryReading?, Date) async -> Void)?
    /// 每次 `system_profiler` 读取成功后调用，健康信息没变也调用。
    @ObservationIgnored public var onHealthRefresh: (@MainActor (BatteryHealthInfo) async -> Void)?

    @ObservationIgnored private let sampler: BatterySampler
    @ObservationIgnored private let powerSourceReader: @Sendable () -> BatteryReading?
    @ObservationIgnored private let smcReader: @Sendable (SMCReadScope) -> SMCReadings?
    /// IOPS 快速读取与完整采样合并后的读数，未叠加 SMC。
    @ObservationIgnored private var baseReading: BatteryReading?
    @ObservationIgnored private var smcDisplay: (readings: SMCReadings, date: Date)?
    @ObservationIgnored private var smcDisplayReadAt: Date?
    @ObservationIgnored private var smcCharging: (isCharging: Bool, date: Date)?
    @ObservationIgnored private var smcChargingReadAt: Date?
    @ObservationIgnored private var isSMCChargingAvailable = true
    @ObservationIgnored private var stateChangeBoost: (start: Date, end: Date)?
    @ObservationIgnored private var smcTask: Task<Void, Never>?
    /// 保持当前电量期间的用户上限和临时值，保存在 `holdDefaults`。
    @ObservationIgnored private var chargeLimitHold: ChargeLimitHold?
    @ObservationIgnored private let holdDefaults: UserDefaults
    /// 启动时已有保存的状态：第一次读到系统上限时先恢复。
    @ObservationIgnored private var restoresChargeLimitHoldFirst: Bool
    @ObservationIgnored private var chargeLimitHoldPausedUntil: Date?
    @ObservationIgnored private var latestPowerSource: (reading: BatteryReading, date: Date)?
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var chargeLimitHoldTracker = ChargeLimitHoldTracker()
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
        powerSourceReader: @escaping @Sendable () -> BatteryReading? = { IOKitBatteryDataSource.readPowerSource() },
        smcReader: @escaping @Sendable (SMCReadScope) -> SMCReadings? = { SMCReader.shared.read($0) },
        holdDefaults: UserDefaults = .standard
    ) {
        self.sampler = sampler
        self.powerSourceReader = powerSourceReader
        self.smcReader = smcReader
        self.holdDefaults = holdDefaults
        let hold = holdDefaults.data(forKey: Self.chargeLimitHoldKey)
            .flatMap { try? JSONDecoder().decode(ChargeLimitHold.self, from: $0) }
        chargeLimitHold = hold
        restoresChargeLimitHoldFirst = hold != nil
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
        startSMCLoop()
        startMinuteLoop()
        startHealthLoop()
    }

    /// 面板打开时每 10 秒完整读取一次、每 5 秒读 SMC 和 IOPS；关闭时每 60 秒完整读取一次、每 1.5 秒读 `CHSC`。
    public func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible {
            readNow()
        }
        if readTask != nil {
            startReadLoop()
            startSMCLoop()
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
                // 面板打开时 SMC 由每 5 秒的读取负责。
                if self?.isPanelVisible == false {
                    await self?.refreshSMC(.display)
                }
            }
        }
    }

    /// SMC 读取不经过采样 actor，PowerUI 写入或数据库写入期间照常进行。
    private func startSMCLoop() {
        smcTask?.cancel()
        smcTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let (interval, tolerance) = self?.smcInterval else { return }
                try? await Task.sleep(for: interval, tolerance: tolerance)
                guard !Task.isCancelled else { return }
                await self?.smcTick()
            }
        }
    }

    private var isFastSMCReading: Bool {
        isPanelVisible || isStateChangeBoosting
    }

    private var isStateChangeBoosting: Bool {
        stateChangeBoost.map { Date() < $0.end } == true
    }

    private var smcInterval: (Duration, Duration?) {
        if isStateChangeBoosting { return (Self.smcFastInterval, nil) }
        if isPanelVisible { return (Self.smcPanelInterval, nil) }
        if !isSMCChargingAvailable { return (Self.smcUnavailableInterval, Self.panelClosedTolerance) }
        return (Self.smcChargingInterval, Self.smcChargingTolerance)
    }

    func smcTick() async {
        guard case .battery? = baseReading else { return }
        if isFastSMCReading {
            await refreshSMC(.display)
            // 面板上的电量和剩余时间来自 IOPS，与 SMC 同时刷新。
            if isPanelVisible { await refreshPowerSource() }
            return
        }
        let previous = latestSMCCharging
        await refreshSMC(.charging)
        if let previous, let current = latestSMCCharging, previous != current {
            // 充电状态变化后立即更新功率等读数和插电状态。
            await refreshSMC(.display)
            await refreshPowerSource()
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
            await self?.refreshSMC(.display)
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
            await self?.refreshSMC(.display)
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

    /// 独立于采样 actor，完整读取被 PowerUI 阻塞时仍能更新插电/充电状态。
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
        let wasExternalPower = baseReading?.isExternalPower
        baseReading = baseReading?.updatingPowerSource(from: powerSource) ?? powerSource
        // 插拔电源后充电器几秒内开始供电，功率和充电状态要等约一分钟才由 IOPS 报告，这段时间加快读 SMC。
        if let wasExternalPower, let isExternalPower = powerSource.isExternalPower, wasExternalPower != isExternalPower {
            startStateChangeBoost()
        }
        publish()
        // 快速读数不更新完整采样的新鲜度，也不重复触发温度提醒。
    }

    /// 读 SMC，结果叠加到界面读数上。不更新完整采样的新鲜度，不触发温度提醒，不写库。
    func refreshSMC(_ scope: SMCReadScope) async {
        let reader = smcReader
        let result = await Task.detached(priority: .userInitiated) {
            let date = Date()
            return (readings: reader(scope), date: date)
        }.value
        guard !Task.isCancelled else { return }
        let previous = latestSMCCharging
        switch scope {
        case .display:
            if let smcDisplayReadAt, result.date < smcDisplayReadAt { return }
            smcDisplayReadAt = result.date
            smcDisplay = result.readings.map { ($0, result.date) }
            isSMCChargingAvailable = result.readings?.isCharging != nil
        case .charging:
            if let smcChargingReadAt, result.date < smcChargingReadAt { return }
            smcChargingReadAt = result.date
            smcCharging = result.readings?.isCharging.map { ($0, result.date) }
            isSMCChargingAvailable = smcCharging != nil
        }
        if let previous, let current = latestSMCCharging, previous != current {
            extendStateChangeBoost()
        }
        publish()
    }

    /// 最近一次读到的 `CHSC`。
    private var latestSMCCharging: Bool? {
        let display = smcDisplay.flatMap { display in
            display.readings.isCharging.map { (isCharging: $0, date: display.date) }
        }
        guard let charging = smcCharging else { return display?.isCharging }
        guard let display, display.date > charging.date else { return charging.isCharging }
        return display.isCharging
    }

    /// 把 SMC 读数叠加到 `baseReading` 上：先叠加全部 key 的结果，再叠加更新的 `CHSC`；过期的不用。
    private func publish() {
        guard var updated = baseReading else { return }
        if case .battery(var snapshot) = updated {
            let now = Date()
            if let smcDisplay, now.timeIntervalSince(smcDisplay.date) <= Self.smcDisplayMaxAge {
                snapshot = snapshot.applying(smcDisplay.readings)
            }
            if let smcCharging, now.timeIntervalSince(smcCharging.date) <= Self.smcChargingMaxAge,
               smcDisplay.map({ smcCharging.date > $0.date }) ?? true {
                snapshot.isCharging = smcCharging.isCharging
            }
            snapshot.chargeLimitHold = chargeLimitHold
            chargeLimitHoldTracker.apply(to: &snapshot)
            updated = .battery(snapshot)
        }
        if reading != updated { reading = updated }
        evaluateChargeLimitHold()
    }

    private func startStateChangeBoost() {
        let now = Date()
        stateChangeBoost = (now, now.addingTimeInterval(Self.stateChangeBoostDuration))
        if readTask != nil { startSMCLoop() }
    }

    private func extendStateChangeBoost() {
        guard let boost = stateChangeBoost, Date() < boost.end else { return }
        let end = min(
            max(boost.end, Date().addingTimeInterval(Self.stateChangeBoostSettle)),
            boost.start.addingTimeInterval(Self.stateChangeBoostLimit)
        )
        stateChangeBoost = (boost.start, end)
    }

    func read() async {
        let result = await sampler.read()
        await update(result.reading, at: result.date)
    }

    private func update(_ newReading: BatteryReading?, at date: Date) async {
        // 多个触发同时读取时可能乱序返回，只保留较新的结果。
        if let lastReadAt, date < lastReadAt { return }
        guard let newReading else {
            await onRead?(nil, date)
            return
        }
        lastReadAt = date
        let updated: BatteryReading
        if let latestPowerSource, latestPowerSource.date > date {
            updated = newReading.updatingPowerSource(from: latestPowerSource.reading)
        } else {
            updated = newReading
        }
        baseReading = updated
        publish()
        await onRead?(reading, date)
    }

    /// 修改系统充电上限，完成后立即用读回的值刷新。上一次修改未完成时忽略。
    /// 保持当前电量期间：改成低于临时值的档位只更新保存的用户上限；关闭前先写回用户上限。
    public func setChargeLimit(_ change: ChargeLimitChange) async {
        guard !isWritingChargeLimit else { return }
        var changes = [change]
        if let hold = chargeLimitHold {
            switch change {
            case .limit(let percent) where percent < hold.heldLimit:
                setChargeLimitHold(ChargeLimitHold(userLimit: percent, heldLimit: hold.heldLimit))
                publish()
                return
            case .disable:
                // 系统重新开启时恢复关闭前的值，不能让它记住临时值。
                changes = [.limit(hold.userLimit), .disable]
            default:
                break
            }
        }
        isWritingChargeLimit = true
        _ = await runChargeLimitWrites(changes)
    }

    /// 依次写入，任一次失败就停止。调用前已设置 `isWritingChargeLimit`。
    private func runChargeLimitWrites(_ changes: [ChargeLimitChange]) async -> Bool {
        chargeLimitWriteFailed = false
        var applied = true
        for change in changes {
            let result = await sampler.writeChargeLimit(change)
            await update(result.reading, at: result.date)
            if !result.applied {
                applied = false
                break
            }
        }
        chargeLimitWriteFailed = !applied
        if !applied {
            chargeLimitHoldPausedUntil = Date().addingTimeInterval(Self.chargeLimitHoldRetryDelay)
        }
        isWritingChargeLimit = false
        // 充电器 1–3 秒内开始或停止充电，IOPS / IORegistry 要等约一分钟才报告，这段时间加快读 SMC。
        startStateChangeBoost()
        await refreshSMC(.display)
        return applied
    }

    /// 按当前读数决定是否开始保持、恢复或丢弃保存的值。写入期间不判断；写入成功或失败后，
    /// 读回的系统上限不再等于临时值时由 `.forget` 清除保存的值。
    private func evaluateChargeLimitHold() {
        guard !isWritingChargeLimit, case .battery(let snapshot)? = reading else { return }
        let action = ChargeLimitHold.action(
            current: chargeLimitHold,
            snapshot: snapshot,
            isEnabled: holdsChargeAboveLimit && canWriteChargeLimit && !isChargeControlAppRunning,
            restoresFirst: restoresChargeLimitHoldFirst
        )
        let change: ChargeLimitChange
        switch action {
        case .none:
            return
        case .forget:
            setChargeLimitHold(nil)
            publish()
            return
        case .hold(let hold):
            guard !isChargeLimitHoldPaused else { return }
            // 先保存再写入，崩溃后下次启动也能恢复。
            setChargeLimitHold(hold)
            change = .limit(hold.heldLimit)
        case .restore(let hold):
            guard !isChargeLimitHoldPaused else { return }
            change = .limit(hold.userLimit)
        }
        isWritingChargeLimit = true
        // 恢复成功后系统上限不再等于临时值，写入结束时的判断走 `.forget` 清除保存的值；
        // 这里不再单独清除，以免清掉随后重新开始保持时保存的值。
        Task { [weak self] in
            _ = await self?.runChargeLimitWrites([change])
        }
    }

    private var isChargeLimitHoldPaused: Bool {
        chargeLimitHoldPausedUntil.map { Date() < $0 } ?? false
    }

    private func setChargeLimitHold(_ hold: ChargeLimitHold?) {
        chargeLimitHold = hold
        if let hold, let data = try? JSONEncoder().encode(hold) {
            holdDefaults.set(data, forKey: Self.chargeLimitHoldKey)
        } else {
            holdDefaults.removeObject(forKey: Self.chargeLimitHoldKey)
            restoresChargeLimitHoldFirst = false
        }
    }

    /// 应用退出前同步写回用户设置的上限。系统上限已不是临时值时只丢弃保存的值；
    /// 写入失败（如 PowerUI 正忙）时保留，下次启动时恢复。
    public func restoreChargeLimitBeforeExit() {
        guard let hold = chargeLimitHold, case .battery(let snapshot)? = reading, let limit = snapshot.chargeLimit else { return }
        if limit == .on(percent: hold.heldLimit) {
            guard sampler.writeChargeLimitImmediately(.limit(hold.userLimit)) else { return }
        }
        setChargeLimitHold(nil)
    }

    private func refreshChargeControlApps() {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return Self.chargeControlAppPrefixes.contains { bundleIdentifier.hasPrefix($0) }
        }
        if running != isChargeControlAppRunning {
            isChargeControlAppRunning = running
            evaluateChargeLimitHold()
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
            await onHealthRefresh?(health)
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
    var isExternalPower: Bool? {
        if case .battery(let snapshot) = self { snapshot.isExternalPower } else { nil }
    }

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
