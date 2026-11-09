import BatteryCore
import Foundation
import HistoryStore
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")

/// 充电上限管理的设置，由 App 层按 `AppSettings` 同步给 BatteryMonitor。规则见 docs/v1技术设计.md 21.1、21.8。
public struct ChargeControlConfiguration: Sendable, Equatable {
    public var mode: ChargeControlMode
    /// 接管模式的目标上限（%），100 表示关闭。
    public var target: Int
    /// 退出 Hachibu 后保留当前上限，不恢复系统设置。
    public var keepsLimitOnQuit: Bool
    /// 系统充满后接着完成校准（从第 3 步开始），否则放电回上限。
    public var continuesCalibrationAfterSystemFullCharge: Bool

    public init(
        mode: ChargeControlMode = .followSystem,
        target: Int = 80,
        keepsLimitOnQuit: Bool = false,
        continuesCalibrationAfterSystemFullCharge: Bool = false
    ) {
        self.mode = mode
        self.target = min(max(target, ManagedChargeLimit.targetRange.lowerBound), ManagedChargeLimit.targetRange.upperBound)
        self.keepsLimitOnQuit = keepsLimitOnQuit
        self.continuesCalibrationAfterSystemFullCharge = continuesCalibrationAfterSystemFullCharge
    }
}

/// 接管模式的提醒，由 App 层按通知设置转成系统通知。规则见 docs/v1技术设计.md 21.7。
public enum ChargeControlNotice: Sendable, Equatable {
    case calibrationCompleted
    /// 校准自动暂停（拔电、其他工具、写入失败、后台组件不可用、上次退出时未完成）。
    case calibrationPaused(CalibrationPauseReason)
    /// 接管模式下写入上限失败。
    case limitNotApplied(limit: Int)
    case systemCalibrationStarted
}

/// 校准在数据库中的记录 id，跟随进度一起保存。
struct CalibrationRecordIDs: Equatable {
    var run: Int64?
    var step: Int64?
    var pause: Int64?
}

extension BatteryMonitor {
    static let managedOriginalKey = "managedChargeOriginal"
    static let calibrationProgressKey = "calibrationProgress"
    /// 同一个上限值写入后，这么久内不因读回不一致而重写（21.2）。
    static let managedRewriteDelay: TimeInterval = 60
    /// 面板打开时 `pmset -g battlimit` 的最短间隔；关闭时随完整读取（约 60 秒）。
    static let registrationInterval: TimeInterval = 10
    /// 保持步骤的计时只在其他字段变化或超过这个间隔时保存。
    static let calibrationSaveInterval: TimeInterval = 60

    // MARK: - 状态

    /// helper 可以写入低于 80% 的上限。
    var canWriteBelowThreshold: Bool {
        helperService.isReady
    }

    /// 接管模式下系统应处于的上限（%），100 为关闭。跟随系统设置时为 nil。
    public var managedDesiredLimit: Int? {
        guard chargeControl.mode == .managed else { return nil }
        return ManagedChargeLimit.desiredLimit(
            target: chargeControl.target, hold: chargeLimitHold,
            calibrationLimit: calibration.flatMap(CalibrationEngine.requestedLimit),
            canWriteBelowThreshold: canWriteBelowThreshold
        )
    }

    /// 接管模式下实际使用的目标：后台组件未批准时不低于 80%。
    var effectiveManagedTarget: Int {
        canWriteBelowThreshold ? chargeControl.target : max(chargeControl.target, ManagedChargeLimit.helperThreshold)
    }

    /// 接管模式下上限是否已生效，面板说明行和设置页“当前状态”用。
    public var managedLimitState: ManagedLimitState? {
        guard chargeControl.mode == .managed, let desired = managedDesiredLimit, case .battery(let snapshot)? = reading else { return nil }
        let requested = ManagedChargeLimit.desiredLimit(
            target: chargeControl.target, hold: chargeLimitHold,
            calibrationLimit: calibration.flatMap(CalibrationEngine.requestedLimit), canWriteBelowThreshold: true
        )
        return ManagedLimitState.resolve(
            desired: desired, target: effectiveManagedTarget, requested: requested, snapshot: snapshot,
            registration: registration, isOtherToolRunning: isChargeControlAppRunning
        )
    }

    /// 系统正在充满（校准或强制充满）且电量已到 99%，可以趁现在完成校准（21.5）。
    public var canOfferCalibrationAfterSystemFullCharge: Bool {
        guard chargeControl.mode == .managed, calibration == nil, case .battery(let snapshot)? = reading,
              let percent = snapshot.percent else { return false }
        return snapshot.isSystemFullChargeActive && percent >= CalibrationStep.holdMinimumPercent
    }

    /// `pmset -g battlimit` 原文，诊断导出用。
    public var registrationRawOutput: String? { registrationOutput }

    // MARK: - 启动

    func loadChargeControlState() {
        managedOriginal = holdDefaults.data(forKey: Self.managedOriginalKey)
            .flatMap { try? JSONDecoder().decode(ChargeLimitSetting.self, from: $0) }
        if let progress = holdDefaults.data(forKey: Self.calibrationProgressKey)
            .flatMap({ try? JSONDecoder().decode(CalibrationProgress.self, from: $0) }) {
            // 上次退出或崩溃时校准还在进行：等用户选择继续或放弃。
            calibration = CalibrationEngine.pauseForRelaunch(progress)
            calibrationRecordIDs = CalibrationRecordIDs(
                run: progress.runID, step: progress.stepRecordID, pause: progress.pauseRecordID
            )
            saveCalibration(force: true)
        }
    }

    func startChargeControl() {
        let sampler = sampler
        Task { await sampler.endOpenPolicyPeriods(at: Date()) }
        helperService.refresh()
        helperRefreshedAt = Date()
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChargeHelper.leaseRenewInterval, tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.renewLeaseIfNeeded()
            }
        }
        logger.info("Charge control mode \(self.chargeControl.mode.rawValue, privacy: .public)")
    }

    // MARK: - 设置变化

    func chargeControlDidChange(from old: ChargeControlConfiguration) {
        let snapshot: BatterySnapshot? = if case .battery(let snapshot)? = reading { snapshot } else { nil }
        if old.mode != chargeControl.mode {
            logger.info("Mode \(old.mode.rawValue, privacy: .public) -> \(self.chargeControl.mode.rawValue, privacy: .public)")
            // 两种模式对“保持当前电量”的用户上限理解不同，切换时丢弃，按新模式重新判断。
            if chargeLimitHold != nil { setChargeLimitHold(nil) }
            managedLastWrite = nil
            managedAppliedLimit = nil
            hasRevertedExternalChange = false
            externalChangeRevertedAt = nil
            if chargeControl.mode == .managed {
                enterManagedMode(snapshot: snapshot)
            } else if calibration != nil {
                finishCalibration(.cancelled)
            }
        } else if old.target != chargeControl.target, chargeControl.mode == .managed {
            logger.info("Target \(old.target, privacy: .public) -> \(self.chargeControl.target, privacy: .public)")
            managedLastWrite = nil
            if let hold = chargeLimitHold {
                // 新目标低于临时值时继续保持，只更新恢复时写回的值；否则直接写入新目标。
                if chargeControl.target < hold.heldLimit {
                    setChargeLimitHold(ChargeLimitHold(userLimit: chargeControl.target, heldLimit: hold.heldLimit))
                } else {
                    setChargeLimitHold(nil)
                }
            }
        }
        publishChargeControl()
    }

    /// 进入接管：保存系统当前的设置（已存在时不覆盖），再写入目标。
    private func enterManagedMode(snapshot: BatterySnapshot?) {
        guard managedOriginal == nil else { return }
        guard let current = snapshot?.chargeLimit, current != .unsupported else { return }
        // “保持当前电量”期间系统里是临时值，原值是保存的用户上限。
        let original: ChargeLimitSetting = snapshot?.chargeLimitHold.map { .on(percent: $0.userLimit) } ?? current
        setManagedOriginal(original)
        logger.info("Saved original \(String(describing: original), privacy: .public)")
    }

    func setManagedOriginal(_ original: ChargeLimitSetting?) {
        managedOriginal = original
        if let original, let data = try? JSONEncoder().encode(original) {
            holdDefaults.set(data, forKey: Self.managedOriginalKey)
        } else {
            holdDefaults.removeObject(forKey: Self.managedOriginalKey)
        }
    }

    func otherToolDidChange(_ running: Bool) {
        restoredForOtherTool = false
        logger.info("Other charge control tool running: \(running, privacy: .public)")
        updatePolicyPeriod(.otherTool, active: running && chargeControl.mode == .managed)
        if !running { managedLastWrite = nil }
    }

    /// 重新判断并刷新界面。
    func publishChargeControl() {
        evaluateChargeControl()
    }

    // MARK: - 判断

    /// 每次读数更新、写入结束、设置变化后调用：记录系统策略，推进校准，接管模式下写回目标，最后判断“保持当前电量”。
    func evaluateChargeControl() {
        guard case .battery(let snapshot)? = reading else { return }
        trackPolicies(snapshot)
        refreshHelperIfNeeded()
        evaluateCalibration(snapshot)
        guard !isWritingChargeLimit else { return }
        switch chargeControl.mode {
        case .managed:
            if evaluateManagedLimit(snapshot) { return }
        case .followSystem:
            if let original = managedOriginal {
                restoreManagedOriginal(original, snapshot: snapshot)
                return
            }
        }
        evaluateChargeLimitHold()
    }

    /// 接管模式下读回与系统应处于的上限不同时写入。返回 true 表示已处理，不再判断“保持当前电量”。
    private func evaluateManagedLimit(_ snapshot: BatterySnapshot) -> Bool {
        guard canWriteChargeLimit, let current = snapshot.chargeLimit, current != .unsupported else { return true }
        if managedOriginal == nil { enterManagedMode(snapshot: snapshot) }

        if isChargeControlAppRunning {
            // 两套工具不同时控制充电：先还给系统，工具退出后重新接管。
            if !restoredForOtherTool, let original = managedOriginal, let change = ManagedChargeLimit.restoreChange(for: original),
               !ManagedChargeLimit.isApplied(ManagedChargeLimit.limit(of: original) ?? 100, to: current) {
                restoredForOtherTool = true
                logger.info("Restoring original for other tool")
                startManagedWrite(change, limit: ManagedChargeLimit.limit(of: original) ?? 100)
            }
            return true
        }

        // 系统策略优先于整个接管流程，包括“保持当前电量”的自动写入。
        if let policy = snapshot.activeChargePolicies.first {
            logger.debug("Skipping write during \(policy.rawValue, privacy: .public)")
            return true
        }

        if let hold = chargeLimitHold {
            // 保持期间系统里是临时值，交给“保持当前电量”判断；被别处改过时丢弃，按目标写回。
            if current == .on(percent: hold.heldLimit), calibration == nil { return false }
            setChargeLimitHold(nil)
        }

        guard let desired = managedDesiredLimit else { return true }
        if ManagedChargeLimit.isApplied(desired, to: current) {
            if managedAppliedLimit != desired {
                managedAppliedLimit = desired
                logger.info("Applied \(desired, privacy: .public)")
            }
            managedWriteFailed = false
            return calibration != nil
        }

        if isChargeLimitHoldPaused { return true }
        if let last = managedLastWrite, last.limit == desired, Date().timeIntervalSince(last.date) < Self.managedRewriteDelay {
            return true
        }

        if managedAppliedLimit == desired, !hasRevertedExternalChange {
            // 生效后又被改了：用户在系统设置里改，或其他工具改。改回并提示一次。
            hasRevertedExternalChange = true
            externalChangeRevertedAt = Date()
            logger.info("Limit changed elsewhere to \(String(describing: current), privacy: .public); reverting to \(desired, privacy: .public)")
        } else {
            logger.info("Writing \(desired, privacy: .public) (read back \(String(describing: current), privacy: .public))")
        }
        startManagedWrite(ManagedChargeLimit.change(for: desired), limit: desired)
        return true
    }

    private func startManagedWrite(_ change: ChargeLimitChange, limit: Int) {
        managedLastWrite = (limit, Date())
        isWritingChargeLimit = true
        Task { [weak self] in
            guard let self else { return }
            let applied = await self.runChargeLimitWrites([change])
            if applied {
                self.managedWriteFailed = false
            } else {
                self.managedWriteFailed = true
                logger.error("Failed to apply \(limit, privacy: .public)")
                self.onChargeControlNotice?(.limitNotApplied(limit: limit))
            }
        }
    }

    /// 跟随系统设置时还留着接管前的原值（切回跟随、上次退出时恢复失败）：恢复后清除。
    private func restoreManagedOriginal(_ original: ChargeLimitSetting, snapshot: BatterySnapshot) {
        guard canWriteChargeLimit, !isChargeControlAppRunning, let current = snapshot.chargeLimit,
              let limit = ManagedChargeLimit.limit(of: original), let change = ManagedChargeLimit.restoreChange(for: original)
        else {
            if original == .unsupported { setManagedOriginal(nil) }
            return
        }
        if ManagedChargeLimit.isApplied(limit, to: current) {
            logger.info("Restored original \(String(describing: original), privacy: .public)")
            setManagedOriginal(nil)
            return
        }
        guard snapshot.systemChargeState != .temporaryFullCharge, !isChargeLimitHoldPaused else { return }
        if let last = managedLastWrite, last.limit == limit, Date().timeIntervalSince(last.date) < Self.managedRewriteDelay { return }
        logger.info("Restoring original \(String(describing: original), privacy: .public)")
        startManagedWrite(change, limit: limit)
    }

    // MARK: - 退出

    /// 接管模式（或还留着原值）时同步恢复。返回 true 表示已处理，不再走“保持当前电量”的恢复。
    func restoreManagedLimitBeforeExit() -> Bool {
        if let progress = calibration {
            calibration = CalibrationEngine.pauseForRelaunch(progress)
            saveCalibration(force: true)
        }
        guard chargeControl.mode == .managed || managedOriginal != nil else { return false }
        guard canWriteChargeLimit, !isChargeControlAppRunning, case .battery(let snapshot)? = reading,
              let current = snapshot.chargeLimit else { return true }
        // 临时充满期间写入可能打断它，保留原值，下次启动时处理。
        if snapshot.systemChargeState == .temporaryFullCharge { return true }

        if chargeControl.mode == .managed, chargeControl.keepsLimitOnQuit {
            let target = effectiveManagedTarget
            if !ManagedChargeLimit.isApplied(target, to: current) {
                guard sampler.writeChargeLimitImmediately(ManagedChargeLimit.change(for: target)) else { return true }
            }
            setChargeLimitHold(nil)
            if target < ManagedChargeLimit.helperThreshold, let client = ChargeHelperService.readyClient() {
                // 不再续约，helper 也不自动恢复。
                do { try client.renewLease(seconds: 0) } catch {
                    logger.error("Failed to keep limit: \(String(describing: error), privacy: .public)")
                }
            }
            logger.info("Kept limit \(target, privacy: .public) after quit")
            return true
        }

        guard let original = managedOriginal, let limit = ManagedChargeLimit.limit(of: original),
              let change = ManagedChargeLimit.restoreChange(for: original) else { return true }
        if !ManagedChargeLimit.isApplied(limit, to: current) {
            guard sampler.writeChargeLimitImmediately(change) else {
                logger.error("Failed to restore original before exit")
                return true
            }
        }
        setManagedOriginal(nil)
        setChargeLimitHold(nil)
        logger.info("Restored original \(String(describing: original), privacy: .public) before exit")
        return true
    }

    // MARK: - 登记和 helper

    /// 读 `pmset -g battlimit`。面板打开时最短 10 秒一次；写入后立即读。
    func refreshRegistration(force: Bool) {
        guard registrationTask == nil else { return }
        if !force, let last = registrationReadAt, Date().timeIntervalSince(last) < Self.registrationInterval { return }
        registrationReadAt = Date()
        registrationTask = Task { [weak self] in
            if force { try? await Task.sleep(for: .seconds(1)) }
            let result = await ChargeLimitRegistrationReader.read()
            guard let self else { return }
            self.registrationTask = nil
            self.registrationOutput = result.output
            if result.registration != self.registration {
                logger.info("Registration \(result.registration.map { "\($0.limits)" } ?? "unknown", privacy: .public)")
                self.registration = result.registration
            }
        }
    }

    private func refreshHelperIfNeeded() {
        if let last = helperRefreshedAt, Date().timeIntervalSince(last) < 30 { return }
        helperRefreshedAt = Date()
        helperService.refresh()
    }

    /// 系统上限低于 80% 或校准进行中时续约；校准期间始终保留超时恢复。
    func renewLeaseIfNeeded() {
        guard chargeControl.mode == .managed, case .battery(let snapshot)? = reading else { return }
        let below = if case .on(let percent)? = snapshot.chargeLimit { percent < ManagedChargeLimit.helperThreshold } else { false }
        guard below || calibration != nil, let client = ChargeHelperService.readyClient() else { return }
        let seconds = chargeControl.keepsLimitOnQuit && calibration == nil ? 0 : Int(ChargeHelper.leaseTimeout)
        Task.detached {
            do {
                try client.renewLease(seconds: seconds)
            } catch {
                logger.error("Failed to renew lease: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 先经 helper 释放、读回确认，再移除后台组件。调用前由设置页把低于 80% 的目标改成 80%。
    /// 返回 false 表示释放失败，helper 保留。
    @discardableResult
    public func removeChargeHelper() async -> Bool {
        guard !isWritingChargeLimit else { return false }
        // 标记可能在系统充满或外部改值后仍存在，不能只靠当前上限判断是否需要释放。
        let status = await helperService.helperStatus()
        if helperService.state == .enabled, status == nil { return false }
        if status?.isMarkerCorrupt == true { return false }
        if calibration != nil { finishCalibration(.cancelled) }
        let below = if case .battery(let snapshot)? = reading, let percent = snapshot.chargeLimitPercent {
            percent < ManagedChargeLimit.helperThreshold
        } else { false }
        if status?.hasMarker == true || below {
            guard case .battery(let snapshot)? = reading, snapshot.activeChargePolicies.isEmpty,
                  let client = ChargeHelperService.readyClient() else { return false }
            isWritingChargeLimit = true
            let released = await Task.detached { () -> Bool in
                do { try client.release(); return true }
                catch { logger.error("Release before removing helper failed: \(String(describing: error), privacy: .public)"); return false }
            }.value
            guard released else { isWritingChargeLimit = false; return false }
            let target = chargeControl.mode == .managed
                ? chargeControl.target : (ManagedChargeLimit.limit(of: managedOriginal) ?? ManagedChargeLimit.helperThreshold)
            guard await runChargeLimitWrites([ManagedChargeLimit.change(for: max(target, ManagedChargeLimit.helperThreshold))]) else {
                logger.error("Release before removing helper failed; keeping helper")
                return false
            }
            let confirmation = await ChargeLimitRegistrationReader.read()
            guard confirmation.registration?.registers(max(target, ManagedChargeLimit.helperThreshold)) == true
                    || (snapshot.isExternalPower == false && confirmation.registration?.limits.isEmpty == true)
            else { return false }
        }
        await helperService.unregister()
        let removed = helperService.state == .notRegistered
        if removed { logger.info("Helper removed") }
        return removed
    }

    /// 最近的校准记录，按开始时间降序。
    public func calibrationHistory(limit: Int = 10) async -> [CalibrationRun] {
        await sampler.calibrationRuns(limit: limit)
    }

    /// 系统上次充满（电量 100%）的时间。
    public func lastFullChargeDate() async -> Date? {
        await sampler.lastFullChargeTime()
    }

    // MARK: - 系统策略

    private func trackPolicies(_ snapshot: BatterySnapshot) {
        let active = Set(snapshot.activeChargePolicies)
        let wasFullCharge = policyPeriods[.systemCalibration] != nil || policyPeriods[.fullChargeOverride] != nil
        for policy in ChargePolicy.allCases {
            updatePolicyPeriod(policy.kind, active: active.contains(policy))
        }
        let isFullCharge = snapshot.isSystemFullChargeActive
        if wasFullCharge, !isFullCharge {
            // 系统充满结束：写一次并读回确认；选了“接着完成校准”时从第 3 步开始。
            managedLastWrite = nil
            if chargeControl.mode == .managed, chargeControl.continuesCalibrationAfterSystemFullCharge, calibration == nil,
               let percent = snapshot.percent, percent >= CalibrationStep.holdMinimumPercent {
                logger.info("System full charge ended; continuing with calibration")
                startCalibration(from: .dischargeToLow, kind: .afterSystemFullCharge, earlierCompletion: .alreadySatisfied)
            }
        }
    }

    func updatePolicyPeriod(_ kind: ChargePolicyKind, active: Bool) {
        let sampler = sampler
        if active, policyPeriods[kind] == nil {
            logger.info("Policy started: \(kind.rawValue, privacy: .public)")
            let date = Date()
            policyPeriods[kind] = Task { await sampler.beginPolicyPeriod(kind, at: date) }
            if kind == .systemCalibration { onChargeControlNotice?(.systemCalibrationStarted) }
        } else if !active, let task = policyPeriods.removeValue(forKey: kind) {
            logger.info("Policy ended: \(kind.rawValue, privacy: .public)")
            let date = Date()
            Task {
                if let id = await task.value { await sampler.endPolicyPeriod(id: id, at: date) }
            }
        }
    }

    // MARK: - 校准

    /// 确认框的默认起点（21.6）。
    public func suggestedCalibrationStart() async -> CalibrationStep {
        guard case .battery(let snapshot)? = reading else { return .chargeToFull }
        let now = Date()
        let heldFull = snapshot.percent == 100 ? await sampler.heldFull(since: now.addingTimeInterval(-3600), until: now) : false
        return CalibrationEngine.suggestedStart(percent: snapshot.percent, heldFullForLastHour: heldFull)
    }

    /// 开始校准。只在接管模式下可用；放电步骤需要后台组件，未批准时暂停在那一步。
    public func startCalibration(
        from step: CalibrationStep, kind: CalibrationStartKind = .manual,
        earlierCompletion: CalibrationStepCompletion = .alreadySatisfied
    ) {
        guard chargeControl.mode == .managed, calibration == nil else { return }
        let percent: Int? = if case .battery(let snapshot)? = reading { snapshot.percent } else { nil }
        if chargeLimitHold != nil { setChargeLimitHold(nil) }
        let result = CalibrationEngine.start(kind, from: step, earlierCompletion: earlierCompletion, at: Date(), percent: percent)
        logger.info("Calibration started at step \(step.rawValue, privacy: .public) (\(kind.rawValue, privacy: .public))")
        applyCalibration(result, startKind: kind)
        managedLastWrite = nil
        evaluateChargeControl()
    }

    public func pauseCalibration() {
        guard let progress = calibration else { return }
        calibration = CalibrationEngine.setUserPaused(true, progress)
        saveCalibration(force: true)
        managedLastWrite = nil
        evaluateChargeControl()
    }

    /// 继续：同时结束“上次退出时未完成”的暂停。
    public func resumeCalibration() {
        guard let progress = calibration else { return }
        calibration = CalibrationEngine.setUserPaused(false, progress)
        saveCalibration(force: true)
        managedLastWrite = nil
        evaluateChargeControl()
    }

    public func skipCalibrationStep() {
        guard let progress = calibration else { return }
        applyCalibration(CalibrationEngine.skip(progress, at: Date(), percent: currentPercent))
        managedLastWrite = nil
        evaluateChargeControl()
    }

    public func redoCalibrationStep() {
        guard let progress = calibration else { return }
        applyCalibration(CalibrationEngine.redo(progress, at: Date(), percent: currentPercent))
        managedLastWrite = nil
        evaluateChargeControl()
    }

    /// 取消立即回到目标上限。`abandoned` 为 true 表示退出后放弃，记为中断。
    public func cancelCalibration(abandoned: Bool = false) {
        finishCalibration(abandoned ? .interrupted : .cancelled)
        managedLastWrite = nil
        evaluateChargeControl()
    }

    private var currentPercent: Int? {
        if case .battery(let snapshot)? = reading { snapshot.percent } else { nil }
    }

    private func finishCalibration(_ ending: CalibrationEnding) {
        guard calibration != nil else { return }
        logger.info("Calibration finished: \(ending.rawValue, privacy: .public)")
        applyCalibration(CalibrationEngine.Result(progress: nil, events: [.finished(ending)]))
    }

    private func evaluateCalibration(_ snapshot: BatterySnapshot) {
        guard let progress = calibration else { return }
        guard chargeControl.mode == .managed else {
            finishCalibration(.cancelled)
            return
        }
        let input = CalibrationInput(
            now: Date(), snapshot: snapshot, isOtherToolRunning: isChargeControlAppRunning,
            canWriteBelowThreshold: canWriteBelowThreshold,
            isWriteFailing: managedWriteFailed && isChargeLimitHoldPaused,
            isTargetApplied: ManagedChargeLimit.isApplied(effectiveManagedTarget, to: snapshot.chargeLimit)
        )
        let result = CalibrationEngine.evaluate(progress, input: input)
        if result.progress == progress, result.events.isEmpty { return }
        applyCalibration(result)
    }

    private func applyCalibration(_ result: CalibrationEngine.Result, startKind: CalibrationStartKind? = nil) {
        let structural = result.progress?.step != calibration?.step || result.progress?.pauseReason != calibration?.pauseReason
            || result.progress == nil || calibration == nil || !result.events.isEmpty
        calibration = result.progress
        saveCalibration(force: structural)
        guard !result.events.isEmpty else { return }
        for event in result.events {
            logger.info("Calibration \(String(describing: event), privacy: .public)")
            switch event {
            case .finished(.completed): onChargeControlNotice?(.calibrationCompleted)
            case .paused(let reason) where reason != .user && reason != .systemPolicy:
                onChargeControlNotice?(.calibrationPaused(reason))
            default: break
            }
        }
        recordCalibration(result.events, startKind: startKind)
    }

    func saveCalibration(force: Bool) {
        guard let progress = calibration else {
            holdDefaults.removeObject(forKey: Self.calibrationProgressKey)
            calibrationSavedAt = nil
            return
        }
        if !force, let saved = calibrationSavedAt, Date().timeIntervalSince(saved) < Self.calibrationSaveInterval { return }
        var stored = progress
        stored.runID = calibrationRecordIDs.run
        stored.stepRecordID = calibrationRecordIDs.step
        stored.pauseRecordID = calibrationRecordIDs.pause
        if let data = try? JSONEncoder().encode(stored) {
            holdDefaults.set(data, forKey: Self.calibrationProgressKey)
            calibrationSavedAt = Date()
        }
    }

    /// 按顺序写数据库：上一批写完再写下一批，记录 id 保存在 `calibrationRecordIDs`。
    private func recordCalibration(_ events: [CalibrationEvent], startKind: CalibrationStartKind?) {
        let date = Date()
        let snapshot: BatterySnapshot? = if case .battery(let snapshot)? = reading { snapshot } else { nil }
        let healthValue = CalibrationHealth(
            fullChargeMAh: snapshot?.fullChargeCapacityMAh,
            systemMaxCapacityPct: health?.systemMaximumCapacityPercent,
            cycleCount: snapshot?.cycleCount
        )
        let percent = snapshot?.percent
        let sampler = sampler
        let previous = calibrationRecordTask
        let restoredIDs = calibrationRecordIDs
        let startedAt = calibration?.startedAt
        calibrationRecordTask = Task { [weak self] in
            // 取消后立即重开时，上一批仍必须使用原 run 的 id，不能被新进度清空。
            var ids = await previous?.value ?? restoredIDs
            if let startKind {
                ids = CalibrationRecordIDs(run: await sampler.startCalibrationRun(startKind, at: date, before: healthValue))
            }
            for event in events {
                switch event {
                case .stepStarted(let step):
                    if let run = ids.run { ids.step = await sampler.beginCalibrationStep(runID: run, step: step, at: date, percent: percent) }
                case .stepFinished(_, let completion):
                    if let step = ids.step { await sampler.finishCalibrationStep(id: step, completion: completion, at: date, percent: percent) }
                    ids.step = nil
                case .paused(let reason):
                    if let run = ids.run { ids.pause = await sampler.beginCalibrationPause(runID: run, reason: reason, at: date) }
                case .resumed:
                    if let pause = ids.pause { await sampler.endCalibrationPause(id: pause, at: date) }
                    ids.pause = nil
                case .finished(let ending):
                    if let pause = ids.pause { await sampler.endCalibrationPause(id: pause, at: date) }
                    if let step = ids.step {
                        await sampler.finishCalibrationStep(id: step, completion: .skipped, at: date, percent: percent)
                    }
                    if let run = ids.run {
                        await sampler.finishCalibrationRun(
                            id: run, ending: ending, at: date, after: ending == .completed ? healthValue : nil
                        )
                    }
                    ids = CalibrationRecordIDs()
                }
            }
            if let self, self.calibration?.startedAt == startedAt {
                self.calibrationRecordIDs = ids
                self.saveCalibration(force: true)
            }
            return ids
        }
    }
}

extension ChargePolicy {
    var kind: ChargePolicyKind {
        switch self {
        case .systemCalibration: .systemCalibration
        case .fullChargeOverride: .fullChargeOverride
        case .temporaryFullCharge: .temporaryFullCharge
        case .optimizedCharging: .optimizedCharging
        }
    }
}
