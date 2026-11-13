/// 系统明确优先于手动充电上限的策略。进行中时 Hachibu 不自动写入，只记录和显示，结束后再写一次。
/// 规则见 docs/v1技术设计.md 21.5。
public enum ChargePolicy: String, Sendable, Equatable, CaseIterable, Codable {
    /// 系统校准电池（`SystemChargeState` 18）。
    case systemCalibration
    /// 长期未充满，系统强制充满（`SystemFullChargeOverride`）。
    case fullChargeOverride
    /// 用户在系统里选了临时充满（状态 3）。
    case temporaryFullCharge
    /// 优化电池充电暂停或放电（状态 6、10、12）。
    case optimizedCharging

    /// 此策略是否活动。对应的读取失败或状态码未知时为 nil。
    public func activity(in snapshot: BatterySnapshot) -> Bool? {
        if self == .fullChargeOverride { return snapshot.isFullChargeOverrideActive }
        guard snapshot.isPowerUIChargeStateKnown else { return nil }
        switch (self, snapshot.systemChargeState) {
        case (.systemCalibration, .calibrating?),
             (.temporaryFullCharge, .temporaryFullCharge?),
             (.optimizedCharging, .optimizedChargingPaused?),
             (.optimizedCharging, .optimizedChargingDischarging?):
            return true
        default:
            return false
        }
    }
}

extension BatterySnapshot {
    fileprivate var isPowerUIChargeStateKnown: Bool {
        // 0 是 Undefined；1–18 是已核对过的 PowerUI 状态码。
        systemChargeState != nil || powerUIStateCode.map { (1...18).contains($0) } == true
    }

    /// 两个独立来源都给出已识别的状态，才能确认没有活动策略。
    public var isChargePolicyKnown: Bool {
        isPowerUIChargeStateKnown && isFullChargeOverrideActive != nil
    }

    /// 当前进行中的系统策略，按 `ChargePolicy.allCases` 的顺序。
    public var activeChargePolicies: [ChargePolicy] {
        ChargePolicy.allCases.filter { $0.activity(in: self) == true }
    }

    /// 任一来源报告系统充满即为 true，两个来源均确认未活动才为 false。
    public var systemFullChargeActivity: Bool? {
        let calibration = ChargePolicy.systemCalibration.activity(in: self)
        if calibration == true || isFullChargeOverrideActive == true { return true }
        if calibration == false, isFullChargeOverrideActive == false { return false }
        return nil
    }

    /// 系统校准或强制充满：系统会充到 100%，结束后按“电量高于上限时”的选项回到目标。
    public var isSystemFullChargeActive: Bool {
        systemFullChargeActivity == true
    }
}
