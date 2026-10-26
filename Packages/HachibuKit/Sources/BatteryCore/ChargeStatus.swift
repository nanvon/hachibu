/// 面板头部的状态。规则见 docs/v1技术设计.md 第 7 节，文案由 FeatureUI 负责。
public enum ChargeStatus: Sendable, Equatable {
    case onBattery
    case charging
    /// 电量高于系统充电上限，系统不用充电器、由电池供电，放到上限后恢复。
    case aboveChargeLimit(limit: Int)
    case pluggedInDraining
    /// 正在“保持当前电量”：系统上限临时为当前电量，由充电器供电。
    case holdingCharge(percent: Int)
    case fullyCharged
    case chargeLimitReached(limit: Int)
    case pluggedInNotCharging

    /// Apple 文档 102338：达到充电上限后，电量下降超过 5% 才恢复充电。
    /// 只有本次插电已到达过当前上限（`hasReachedChargeLimit`）时，这个区间内插电未充电才算已达到上限。
    static let chargeLimitResumeMargin = 5

    /// 按顺序匹配，用第一条符合的。不知道是否插电时返回 nil。
    /// `NotChargingReason` 不参与判断。
    public init?(_ snapshot: BatterySnapshot) {
        guard let isExternalPower = snapshot.isExternalPower else { return nil }

        if !isExternalPower {
            self = .onBattery
        } else if snapshot.isCharging == true {
            self = .charging
        } else if let batteryPower = snapshot.batteryPowerMW, batteryPower < -BatterySnapshot.batteryPowerDeadbandMW {
            // 充电器功率不够时也会放电，这时输入功率不为 0，不归为高于上限。
            if let limit = snapshot.chargeLimitPercent, let percent = snapshot.percent, percent > limit,
               let powerIn = snapshot.powerInMW, powerIn < BatterySnapshot.batteryPowerDeadbandMW {
                self = .aboveChargeLimit(limit: limit)
            } else {
                self = .pluggedInDraining
            }
        } else if let hold = snapshot.chargeLimitHold {
            self = .holdingCharge(percent: hold.heldLimit)
        } else if snapshot.percent == 100 {
            self = .fullyCharged
        } else if let limit = snapshot.chargeLimitPercent, let percent = snapshot.percent,
                  percent >= limit
                    || (snapshot.hasReachedChargeLimit && percent >= limit - Self.chargeLimitResumeMargin) {
            self = .chargeLimitReached(limit: limit)
        } else {
            self = .pluggedInNotCharging
        }
    }
}

/// 记录本次插电期间电量是否已在未充电时到达当前充电上限，结果写入快照的 `hasReachedChargeLimit`。
/// 拔电、开始充电、上限变化或关闭时清除。按时间顺序对每次读数调用。
public struct ChargeLimitHoldTracker: Sendable {
    /// 已到达的上限（%）。
    private var reachedLimit: Int?

    public init() {}

    public mutating func apply(to snapshot: inout BatterySnapshot) {
        let limit = snapshot.chargeLimitPercent
        if snapshot.isExternalPower == false || snapshot.isCharging == true || limit != reachedLimit {
            reachedLimit = nil
        }
        if let limit, snapshot.isExternalPower == true, snapshot.isCharging == false,
           let percent = snapshot.percent, percent >= limit {
            reachedLimit = limit
        }
        snapshot.hasReachedChargeLimit = limit != nil && reachedLimit == limit
    }
}

/// 面板显示的剩余时间。
public enum RemainingTime: Sendable, Equatable {
    case untilEmpty(minutes: Int)
    case untilFull(minutes: Int)
}

extension BatterySnapshot {
    /// 电池功率绝对值小于该值时视为 0（mW）。
    public static let batteryPowerDeadbandMW = 500

    /// 使用电池时取 `Time to Empty`，充电中取 `Time to Full Charge`，其他状态为 nil（显示“—”）。
    public var remainingTime: RemainingTime? {
        switch ChargeStatus(self) {
        case .onBattery: timeToEmptyMinutes.map { .untilEmpty(minutes: $0) }
        case .charging: timeToFullMinutes.map { .untilFull(minutes: $0) }
        default: nil
        }
    }
}
