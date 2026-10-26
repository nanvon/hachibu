/// 三段功率流向图的数据：供电方 → MacBook → 用电方。规则见 docs/v1技术设计.md 第 8 节，布局和文案由 FeatureUI 负责。
/// 所有数值直接取原始读数，不做配平，两侧合计不一定相等。
public struct PowerFlow: Sendable, Equatable {
    public enum Node: Sendable, Equatable {
        case charger
        case battery
        /// 系统负载，`SystemLoad`。
        case system
    }

    /// 一条流带。`powerMW` 决定宽度和流带上的数值，读数缺失时为 nil。
    public struct Stream: Sendable, Equatable {
        public var node: Node
        public var powerMW: Int?

        public init(_ node: Node, powerMW: Int?) {
            self.node = node
            self.powerMW = powerMW
        }
    }

    /// 流入 MacBook 的流带，按从上到下排列。
    public var inputs: [Stream]
    /// 从 MacBook 流出的流带，按从上到下排列。
    public var outputs: [Stream]

    /// 不知道是否插电时返回 nil。
    public init?(_ snapshot: BatterySnapshot) {
        guard let isExternalPower = snapshot.isExternalPower else { return nil }

        let load = snapshot.systemLoadMW
        let input = snapshot.powerInMW
        let batteryMagnitude = snapshot.batteryPowerMW.map(abs)
        // 判断方向时，绝对值小于 500 mW 视为 0。
        let battery = snapshot.batteryPowerMW.map { abs($0) < BatterySnapshot.batteryPowerDeadbandMW ? 0 : $0 }

        outputs = [Stream(.system, powerMW: load)]

        guard isExternalPower else {
            inputs = [Stream(.battery, powerMW: batteryMagnitude)]
            return
        }

        switch battery {
        case let b? where b > 0:
            inputs = [Stream(.charger, powerMW: input)]
            outputs.append(Stream(.battery, powerMW: batteryMagnitude))
        case let b? where b < 0:
            inputs = [Stream(.battery, powerMW: batteryMagnitude), Stream(.charger, powerMW: input)]
        default:
            // 电池功率为 0，或读不到电池功率。
            inputs = [Stream(.charger, powerMW: input)]
        }
    }
}
