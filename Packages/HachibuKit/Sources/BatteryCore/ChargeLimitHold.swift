/// “保持当前电量”期间的上限：用户设置的上限和应用临时写入系统的值分开保存。
/// 规则见 docs/v1技术设计.md 第 6 节“电量高于上限时”。
public struct ChargeLimitHold: Sendable, Equatable, Codable {
    /// 用户设置的上限（%），恢复时写回这个值。
    public var userLimit: Int
    /// 应用临时写入系统的上限（%）。
    public var heldLimit: Int

    /// 临时上限最高写 99：PowerUI 写 100 会关闭充电上限。
    public static let maximumHeldLimit = 99

    public init(userLimit: Int, heldLimit: Int) {
        self.userLimit = userLimit
        self.heldLimit = heldLimit
    }

    public enum Action: Sendable, Equatable {
        case none
        /// 保存后写入 `heldLimit`。
        case hold(ChargeLimitHold)
        /// 写回 `userLimit`，成功后丢弃保存的值。
        case restore(ChargeLimitHold)
        /// 系统上限已被别处改过：只丢弃保存的值，不写入。
        case forget
    }

    /// 根据当前读数决定下一步。
    /// - Parameters:
    ///   - current: 已保存的保持状态。
    ///   - snapshot: 系统实际的上限读数（未替换成 `userLimit`）。
    ///   - isEnabled: 选择了“保持当前电量”，可以写入，且没有其他充电控制工具运行。
    ///   - restoresFirst: 应用刚启动，已保存的状态无论条件如何都先恢复。
    public static func action(
        current: ChargeLimitHold?,
        snapshot: BatterySnapshot,
        isEnabled: Bool,
        restoresFirst: Bool = false
    ) -> Action {
        // 临时充满期间系统上限读数为 100，不是被别处改过。不写入，以免打断充满，也不丢弃保存的值。
        if snapshot.systemChargeState == .temporaryFullCharge { return .none }

        if let current {
            switch snapshot.chargeLimit {
            case nil:
                // 读不到系统上限时等待，不写入。
                return .none
            case .on(let percent)? where percent == current.heldLimit:
                // 校准期间系统忽略上限，先写回用户的上限，校准结束后按当时的电量重新保持。
                if restoresFirst || !isEnabled || snapshot.isExternalPower == false
                    || snapshot.isCalibratingPastChargeLimit {
                    return .restore(current)
                }
                return .none
            default:
                return .forget
            }
        }

        // 还在充电时不开始保持：保持值不跟随电量变化，等充电停止后再取当时的电量。
        guard isEnabled, snapshot.isExternalPower == true, snapshot.isCharging != true,
              case .on(let limit)? = snapshot.chargeLimit, let percent = snapshot.percent
        else { return .none }
        let held = min(percent, maximumHeldLimit)
        guard held > limit else { return .none }
        return .hold(ChargeLimitHold(userLimit: limit, heldLimit: held))
    }
}
