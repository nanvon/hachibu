/// 面板头部的状态。规则见 docs/v1技术设计.md 第 7 节，文案由 FeatureUI 负责。
public enum ChargeStatus: Sendable, Equatable {
    case onBattery
    case charging
    case pluggedInDraining
    case fullyCharged
    case chargeLimitReached(limit: Int)
    case pluggedInNotCharging

    /// 按顺序匹配，用第一条符合的。不知道是否接电时返回 nil。
    /// `NotChargingReason` 不参与判断。
    public init?(_ snapshot: BatterySnapshot) {
        guard let isExternalPower = snapshot.isExternalPower else { return nil }

        if !isExternalPower {
            self = .onBattery
        } else if snapshot.isCharging == true {
            self = .charging
        } else if let batteryPower = snapshot.batteryPowerMW, batteryPower < -BatterySnapshot.batteryPowerDeadbandMW {
            self = .pluggedInDraining
        } else if snapshot.percent == 100 {
            self = .fullyCharged
        } else if let limit = snapshot.chargeLimitPercent, let percent = snapshot.percent, percent >= limit - 1 {
            self = .chargeLimitReached(limit: limit)
        } else {
            self = .pluggedInNotCharging
        }
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
