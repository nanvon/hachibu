/// 三节点功率流向图的数据。规则见 docs/v1技术设计.md 第 8 节，布局和文案由 FeatureUI 负责。
public struct PowerFlow: Sendable, Equatable {
    public enum Node: Sendable, Equatable {
        case charger
        case computer
        case battery
    }

    /// 一条流带。`powerMW` 决定宽度，所需数值缺失时为 nil。
    public struct Link: Sendable, Equatable {
        public var from: Node
        public var to: Node
        public var powerMW: Int?

        public init(from: Node, to: Node, powerMW: Int?) {
            self.from = from
            self.to = to
            self.powerMW = powerMW
        }
    }

    /// 流向图下方的说明句，只陈述数值。数值单位 mW。
    public enum Caption: Sendable, Equatable {
        /// 充电器输入 {input}：电脑使用 {load}，充入电池 {battery}。
        case charging(inputMW: Int, loadMW: Int, batteryMW: Int)
        /// 充电器为电脑供电 {load}，电池未充电。
        case pluggedInIdle(loadMW: Int)
        /// 充电器输入 {input}，电池补充 {battery}，电脑使用 {load}。
        case pluggedInDraining(inputMW: Int, batteryMW: Int, loadMW: Int)
        /// 电脑由电池供电 {load}。
        case onBattery(loadMW: Int)
    }

    public var links: [Link]
    /// 节点数值直接取原始读数，三者不一定满足加减关系。
    /// 充电器：`SystemPowerIn`。
    public var chargerMW: Int?
    /// 电脑：`SystemLoad`。
    public var computerMW: Int?
    /// 电池：`|BatteryPower|`。
    public var batteryMW: Int?
    /// 任一所需数值缺失时为 nil，不显示说明句。
    public var caption: Caption?

    /// 不知道是否接电时返回 nil。
    public init?(_ snapshot: BatterySnapshot) {
        guard let isExternalPower = snapshot.isExternalPower else { return nil }

        let load = snapshot.systemLoadMW
        let input = snapshot.powerInMW
        let rawBattery = snapshot.batteryPowerMW
        let batteryMagnitude = rawBattery.map(abs)
        // 判断方向时，绝对值小于 500 mW 视为 0。
        let battery = rawBattery.map { abs($0) < BatterySnapshot.batteryPowerDeadbandMW ? 0 : $0 }

        chargerMW = input
        computerMW = load
        batteryMW = batteryMagnitude

        if !isExternalPower {
            links = [Link(from: .battery, to: .computer, powerMW: load)]
            caption = load.map { .onBattery(loadMW: $0) }
            return
        }

        switch battery {
        case let b? where b > 0:
            links = [
                Link(from: .charger, to: .computer, powerMW: load),
                Link(from: .charger, to: .battery, powerMW: b),
            ]
            if let input, let load, let batteryMagnitude {
                caption = .charging(inputMW: input, loadMW: load, batteryMW: batteryMagnitude)
            }
        case let b? where b < 0:
            links = [
                Link(from: .charger, to: .computer, powerMW: load.map { max(0, $0 - abs(b)) }),
                Link(from: .battery, to: .computer, powerMW: abs(b)),
            ]
            if let input, let load, let batteryMagnitude {
                caption = .pluggedInDraining(inputMW: input, batteryMW: batteryMagnitude, loadMW: load)
            }
        default:
            // 电池功率为 0；读不到电池功率时也只画充电器 → 电脑，但不显示说明句。
            links = [Link(from: .charger, to: .computer, powerMW: load)]
            if battery != nil, let load {
                caption = .pluggedInIdle(loadMW: load)
            }
        }
    }
}
