/// 充电上限的管理方式。规则见 docs/v1技术设计.md 21.1。
public enum ChargeControlMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// 第 6 节的现有行为：与“系统设置 → 电池”改的是同一项。
    case followSystem
    /// Hachibu 保存自己的目标上限，运行期间以它为准，退出时还给系统。
    case managed
}

/// 接管模式的写入决策，不含任何读写。规则见 docs/v1技术设计.md 21.2、21.4。
public enum ManagedChargeLimit {
    /// 接管模式保存和执行的目标范围（%），含已有的低于 70% 的目标。100 表示关闭上限。
    public static let targetRange = 20...100
    /// 低于这个值的上限要经 helper 写入。
    public static let helperThreshold = RoutedChargeLimitWriter.powerUIMinimum

    /// 系统应处于的上限（%），100 表示关闭。校准优先，其次是“保持当前电量”的临时值，最后是目标。
    /// helper 不可用时不低于 80%。
    public static func desiredLimit(target: Int, hold: ChargeLimitHold?, calibrationLimit: Int?, canWriteBelowThreshold: Bool) -> Int {
        let limit = calibrationLimit ?? hold?.heldLimit ?? target
        return canWriteBelowThreshold ? limit : max(limit, helperThreshold)
    }

    /// 读回的设置是否等于 `limit`（100 为关闭）。读不到时为 false。
    public static func isApplied(_ limit: Int, to setting: ChargeLimitSetting?) -> Bool {
        switch setting {
        case .off?: limit >= 100
        case .on(let percent)?: percent == limit
        default: false
        }
    }

    /// 写入 `limit` 用的修改。
    public static func change(for limit: Int) -> ChargeLimitChange {
        limit >= 100 ? .disable : .limit(limit)
    }

    /// 恢复系统原值的修改。原值不支持时为 nil。
    public static func restoreChange(for original: ChargeLimitSetting) -> ChargeLimitChange? {
        switch original {
        case .off: .disable
        case .on(let percent): change(for: percent)
        case .unsupported: nil
        }
    }

    /// 系统原值对应的上限（%），100 表示关闭。
    public static func limit(of setting: ChargeLimitSetting?) -> Int? {
        switch setting {
        case .off?: 100
        case .on(let percent)?: percent
        default: nil
        }
    }
}

/// 接管模式下上限是否已生效，用于面板说明行和设置页“当前状态”。规则见 docs/v1技术设计.md 21.2、21.7。
public enum ManagedLimitState: Sendable, Equatable {
    /// PowerUI 读回和 powerd 登记都等于目标。
    case applied
    /// PowerUI 已读回，powerd 还没有登记。
    case awaitingRegistration
    /// 使用电池时系统撤销了登记，插上电源后重新生效。
    case appliesWhenPluggedIn
    /// 目标低于 80%，后台组件还没批准，当前按 `effective`。
    case awaitingHelperApproval(effective: Int)
    /// 系统策略进行中，结束后回到 `limit`。
    case systemPolicy(ChargePolicy, limit: Int)
    /// 其他充电控制工具正在运行，已还给系统。
    case blockedByOtherTool
    /// PowerUI 读回与目标不同，正在或即将写回。
    case pending

    /// - Parameters:
    ///   - desired: `ManagedChargeLimit.desiredLimit` 的结果。
    ///   - target: 用户设置的目标，用于系统策略结束后回到的值。
    ///   - registration: `pmset -g battlimit` 的结果，nil 表示无法确认，继续等待登记。
    public static func resolve(
        desired: Int,
        target: Int,
        requested: Int,
        snapshot: BatterySnapshot,
        registration: ChargeLimitRegistration?,
        isOtherToolRunning: Bool
    ) -> ManagedLimitState {
        if isOtherToolRunning { return .blockedByOtherTool }
        if let policy = snapshot.activeChargePolicies.first { return .systemPolicy(policy, limit: target) }
        if requested < desired { return .awaitingHelperApproval(effective: desired) }
        guard ManagedChargeLimit.isApplied(desired, to: snapshot.chargeLimit) else { return .pending }
        if registration?.registers(desired) == true { return .applied }
        return snapshot.isExternalPower == false ? .appliesWhenPluggedIn : .awaitingRegistration
    }
}
