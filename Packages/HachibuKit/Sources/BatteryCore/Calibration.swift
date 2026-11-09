import Foundation

/// 电池校准的步骤。每一步用条件定义，每次读数都按当前状态重新判断。规则见 docs/v1技术设计.md 21.6。
public enum CalibrationStep: Int, Sendable, Equatable, Codable, CaseIterable, Comparable {
    case chargeToFull = 1
    case holdFull = 2
    case dischargeToLow = 3
    case rechargeToFull = 4
    case holdFullAgain = 5
    case restoreLimit = 6

    /// 保持步骤需要累计的时长（暂定 1 小时，不提供修改）。
    public static let holdDuration: TimeInterval = 3600
    /// 保持步骤要求的最低电量（%）。
    public static let holdMinimumPercent = 99
    /// 放电步骤的目标电量（%，暂定，不提供修改）。
    public static let dischargeTarget = 15

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 这一步需要的系统上限（%），100 为关闭；回到上限这一步为 nil（使用目标上限）。
    public var systemLimit: Int? {
        switch self {
        case .chargeToFull, .holdFull, .rechargeToFull, .holdFullAgain: 100
        case .dischargeToLow: Self.dischargeTarget
        case .restoreLimit: nil
        }
    }

    var next: CalibrationStep? { CalibrationStep(rawValue: rawValue + 1) }

    var isChargeStep: Bool { self == .chargeToFull || self == .rechargeToFull }
    var isHoldStep: Bool { self == .holdFull || self == .holdFullAgain }
}

/// 校准暂停的原因。
public enum CalibrationPauseReason: String, Sendable, Equatable, Codable {
    /// 用户点了暂停。
    case user
    /// 上次退出或崩溃时校准还在进行，等用户选择继续或放弃。
    case appQuit
    /// 充电和保持步骤需要插电。
    case unplugged
    /// 系统校准或强制充满期间，放电步骤暂停。
    case systemPolicy
    /// 其他充电控制工具正在运行。
    case otherTool
    /// 写入失败，按节流规则重试。
    case writeFailed
    /// 放电步骤需要后台组件。
    case helperUnavailable

    /// 需要用户操作才会结束的暂停。
    public var isSticky: Bool { self == .user || self == .appQuit }
}

/// 校准的开始方式。
public enum CalibrationStartKind: String, Sendable, Equatable, Codable {
    case manual
    /// 系统充满后接着完成校准（21.5、21.6）。
    case afterSystemFullCharge
}

/// 步骤的完成方式。
public enum CalibrationStepCompletion: String, Sendable, Equatable, Codable {
    case reached
    case alreadySatisfied
    case skipped
}

/// 校准的结束方式。
public enum CalibrationEnding: String, Sendable, Equatable, Codable {
    case completed
    case cancelled
    /// 退出或崩溃后用户选择放弃。
    case interrupted
}

/// 校准进度，存在 UserDefaults，每次变化立即保存。
public struct CalibrationProgress: Sendable, Equatable, Codable {
    /// 数据库 `calibration_runs` 的 id，写库失败时为 nil。
    public var runID: Int64?
    public var start: CalibrationStartKind
    public var startedAt: Date
    public var step: CalibrationStep
    public var stepStartedAt: Date
    public var stepStartPercent: Int?
    /// 数据库 `calibration_steps` 的 id。
    public var stepRecordID: Int64?
    /// 当前保持步骤已累计的时长（秒）。
    public var holdSeconds: TimeInterval
    /// 最近一次满足保持条件的读数时间。条件中断时为 nil，下一次满足时从那时重新累计。
    public var lastHoldTick: Date?
    /// 需要用户操作才会结束的暂停（用户暂停、退出后待继续）。
    public var stickyPause: CalibrationPauseReason?
    /// 当前生效的暂停原因，nil 表示进行中。
    public var pauseReason: CalibrationPauseReason?
    /// 数据库 `calibration_pauses` 中当前暂停的 id。
    public var pauseRecordID: Int64?

    public init(start: CalibrationStartKind, step: CalibrationStep, at date: Date, percent: Int?) {
        self.start = start
        self.startedAt = date
        self.step = step
        self.stepStartedAt = date
        self.stepStartPercent = percent
        self.holdSeconds = 0
    }

    public var isPaused: Bool { pauseReason != nil }
}

/// 一次判断的输入。
public struct CalibrationInput: Sendable {
    public var now: Date
    public var snapshot: BatterySnapshot
    public var isOtherToolRunning: Bool
    public var canWriteBelowThreshold: Bool
    /// 最近一次写入失败，还在节流时间内。
    public var isWriteFailing: Bool
    /// 系统上限已读回为目标上限（第 6 步的完成条件）。
    public var isTargetApplied: Bool

    public init(
        now: Date, snapshot: BatterySnapshot, isOtherToolRunning: Bool, canWriteBelowThreshold: Bool,
        isWriteFailing: Bool, isTargetApplied: Bool
    ) {
        self.now = now
        self.snapshot = snapshot
        self.isOtherToolRunning = isOtherToolRunning
        self.canWriteBelowThreshold = canWriteBelowThreshold
        self.isWriteFailing = isWriteFailing
        self.isTargetApplied = isTargetApplied
    }
}

/// 判断产生的变化，由调用方写库、发通知、记日志。
public enum CalibrationEvent: Sendable, Equatable {
    case stepFinished(CalibrationStep, CalibrationStepCompletion)
    case stepStarted(CalibrationStep)
    case paused(CalibrationPauseReason)
    case resumed(CalibrationPauseReason)
    case finished(CalibrationEnding)
}

/// 校准状态机，不含任何读写。
public enum CalibrationEngine {
    public struct Result: Sendable, Equatable {
        /// 结束后为 nil。
        public var progress: CalibrationProgress?
        public var events: [CalibrationEvent]

        public init(progress: CalibrationProgress?, events: [CalibrationEvent]) {
            self.progress = progress
            self.events = events
        }
    }

    /// 开始校准。`step` 之前的步骤记为 `earlierCompletion`。
    public static func start(
        _ kind: CalibrationStartKind,
        from step: CalibrationStep,
        earlierCompletion: CalibrationStepCompletion,
        at date: Date,
        percent: Int?
    ) -> Result {
        let events = CalibrationStep.allCases.filter { $0 < step }.flatMap {
            [CalibrationEvent.stepStarted($0), .stepFinished($0, earlierCompletion)]
        } + [.stepStarted(step)]
        return Result(progress: CalibrationProgress(start: kind, step: step, at: date, percent: percent), events: events)
    }

    /// 确认框的默认起点：电量已是 100% 时第 1 步算完成；最近 1 小时一直插电且 ≥ 99% 时第 2 步也算完成。
    public static func suggestedStart(percent: Int?, heldFullForLastHour: Bool) -> CalibrationStep {
        guard percent == 100 else { return .chargeToFull }
        return heldFullForLastHour ? .dischargeToLow : .holdFull
    }

    /// 这一步需要的系统上限（%），100 为关闭；nil 表示使用目标上限（暂停或回到上限）。
    public static func requestedLimit(for progress: CalibrationProgress) -> Int? {
        switch progress.pauseReason {
        case .user?, .appQuit?, .otherTool?, .helperUnavailable?: return nil
        default: return progress.step.systemLimit
        }
    }

    /// 按当前读数重新判断一次。
    public static func evaluate(_ current: CalibrationProgress, input: CalibrationInput) -> Result {
        var progress = current
        var events: [CalibrationEvent] = []
        let snapshot = input.snapshot

        let pause = progress.stickyPause ?? automaticPause(step: progress.step, input: input)
        if pause != progress.pauseReason {
            if let old = progress.pauseReason { events.append(.resumed(old)) }
            if let pause { events.append(.paused(pause)) }
            progress.pauseReason = pause
        }
        if pause != nil {
            // 暂停期间不累计保持时长；插电睡眠不算暂停，唤醒时仍满足条件就计入。
            progress.lastHoldTick = nil
            return Result(progress: progress, events: events)
        }

        let isPlugged = snapshot.isExternalPower == true
        let percent = snapshot.percent
        let finished: Bool
        switch progress.step {
        case .chargeToFull, .rechargeToFull:
            finished = isPlugged && percent == 100 && snapshot.isCharging == false
        case .holdFull, .holdFullAgain:
            if isPlugged, let percent, percent >= CalibrationStep.holdMinimumPercent {
                if let last = progress.lastHoldTick, input.now > last {
                    progress.holdSeconds += input.now.timeIntervalSince(last)
                }
                progress.lastHoldTick = input.now
            } else {
                // 电量低于 99% 时回到充电（上限保持关闭），计时停止但不清零。
                progress.lastHoldTick = nil
            }
            finished = progress.holdSeconds >= CalibrationStep.holdDuration
        case .dischargeToLow:
            finished = percent.map { $0 <= CalibrationStep.dischargeTarget } ?? false
        case .restoreLimit:
            finished = input.isTargetApplied
        }

        guard finished else { return Result(progress: progress, events: events) }
        events.append(.stepFinished(progress.step, .reached))
        return advance(progress, events: events, at: input.now, percent: percent)
    }

    /// 跳过当前步骤，只能往后；回到上限这一步不能跳过。
    public static func skip(_ progress: CalibrationProgress, at date: Date, percent: Int?) -> Result {
        guard progress.step != .restoreLimit else { return Result(progress: progress, events: []) }
        return advance(progress, events: [.stepFinished(progress.step, .skipped)], at: date, percent: percent)
    }

    /// 重做当前步骤：重新开始计时。
    public static func redo(_ current: CalibrationProgress, at date: Date, percent: Int?) -> Result {
        var progress = current
        progress.stepStartedAt = date
        progress.stepStartPercent = percent
        progress.holdSeconds = 0
        progress.lastHoldTick = nil
        return Result(progress: progress, events: [.stepFinished(current.step, .skipped), .stepStarted(current.step)])
    }

    /// 用户暂停或继续。继续同时结束“退出后待继续”的暂停。
    public static func setUserPaused(_ paused: Bool, _ current: CalibrationProgress) -> CalibrationProgress {
        var progress = current
        progress.stickyPause = paused ? .user : nil
        return progress
    }

    /// App 启动时：上次退出或崩溃时还在进行的校准，等用户选择继续或放弃。
    public static func pauseForRelaunch(_ current: CalibrationProgress) -> CalibrationProgress {
        var progress = current
        if progress.stickyPause == nil { progress.stickyPause = .appQuit }
        progress.pauseReason = progress.stickyPause
        // 继续按钮可能早于下一次采样，不能把退出期间的时间计入保持。
        progress.lastHoldTick = nil
        return progress
    }

    private static func advance(
        _ current: CalibrationProgress, events: [CalibrationEvent], at date: Date, percent: Int?
    ) -> Result {
        guard let next = current.step.next else {
            return Result(progress: nil, events: events + [.finished(.completed)])
        }
        var progress = current
        progress.step = next
        progress.stepStartedAt = date
        progress.stepStartPercent = percent
        progress.stepRecordID = nil
        progress.holdSeconds = 0
        progress.lastHoldTick = nil
        return Result(progress: progress, events: events + [.stepStarted(next)])
    }

    private static func automaticPause(step: CalibrationStep, input: CalibrationInput) -> CalibrationPauseReason? {
        if input.isOtherToolRunning { return .otherTool }
        if input.isWriteFailing { return .writeFailed }
        switch step {
        case .chargeToFull, .holdFull, .rechargeToFull, .holdFullAgain:
            // 第 1、2、4、5 步需要插电；放电步骤用电池放到 15% 同样算数。
            return input.snapshot.isExternalPower == false ? .unplugged : nil
        case .dischargeToLow:
            if input.snapshot.isSystemFullChargeActive { return .systemPolicy }
            return input.canWriteBelowThreshold ? nil : .helperUnavailable
        case .restoreLimit:
            return nil
        }
    }
}

/// 校准进度的展示数据。
extension CalibrationProgress {
    /// 当前步骤的完成比例（0–1），无法估计时为 nil。
    public func stepFraction(snapshot: BatterySnapshot) -> Double? {
        guard let percent = snapshot.percent else { return nil }
        switch step {
        case .chargeToFull, .rechargeToFull:
            let start = Double(stepStartPercent ?? percent)
            guard start < 100 else { return 1 }
            return min(max((Double(percent) - start) / (100 - start), 0), 1)
        case .holdFull, .holdFullAgain:
            return min(holdSeconds / CalibrationStep.holdDuration, 1)
        case .dischargeToLow:
            let start = Double(stepStartPercent ?? percent)
            let target = Double(CalibrationStep.dischargeTarget)
            guard start > target else { return 1 }
            return min(max((start - Double(percent)) / (start - target), 0), 1)
        case .restoreLimit:
            return nil
        }
    }

    /// 当前步骤预计剩余时间（分钟），无法估计时为 nil。
    /// 放电步骤按电池剩余能量 ÷ 当前系统功率估算，空闲时可能需要 5–8 小时。
    public func remainingMinutes(snapshot: BatterySnapshot) -> Int? {
        switch step {
        case .chargeToFull, .rechargeToFull:
            if snapshot.percent == 100 { return 0 }
            return snapshot.timeToFullMinutes
        case .holdFull, .holdFullAgain:
            return Int(((CalibrationStep.holdDuration - holdSeconds) / 60).rounded(.up))
        case .dischargeToLow:
            guard let percent = snapshot.percent, let capacity = snapshot.fullChargeCapacityMAh,
                  let voltage = snapshot.voltageMV, let load = snapshot.systemLoadMW, load > 1000
            else { return nil }
            let remainingPercent = Double(max(percent - CalibrationStep.dischargeTarget, 0))
            // mAh × mV = µWh。
            let energyMWh = Double(capacity) * remainingPercent / 100 * Double(voltage) / 1000
            return Int((energyMWh / Double(load) * 60).rounded())
        case .restoreLimit:
            return nil
        }
    }
}
