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
}

extension BatterySnapshot {
    /// 当前进行中的系统策略，按 `ChargePolicy.allCases` 的顺序。
    public var activeChargePolicies: [ChargePolicy] {
        ChargePolicy.allCases.filter { policy in
            switch policy {
            case .systemCalibration:
                systemChargeState == .calibrating
            case .fullChargeOverride:
                isFullChargeOverrideActive == true
            case .temporaryFullCharge:
                systemChargeState == .temporaryFullCharge
            case .optimizedCharging:
                switch systemChargeState {
                case .optimizedChargingPaused?, .optimizedChargingDischarging?: true
                default: false
                }
            }
        }
    }

    /// 系统校准或强制充满：系统会充到 100%，结束后按“电量高于上限时”的选项回到目标。
    public var isSystemFullChargeActive: Bool {
        systemChargeState == .calibrating || isFullChargeOverrideActive == true
    }
}
