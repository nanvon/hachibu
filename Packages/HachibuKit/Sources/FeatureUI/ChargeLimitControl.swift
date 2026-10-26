import BatteryCore

/// 面板和设置页中系统充电上限控制的显示内容。规则见 docs/v1技术设计.md 第 6、13 节。
/// 为 nil 时不提供控制，只读显示上限。
struct ChargeLimitControl: Equatable {
    var isEnabled: Bool
    /// 开启时的上限（%），关闭时为 nil。
    var percent: Int?
    var options: [Int]
    /// AlDente 等充电控制工具正在运行，控制不可用。
    var isBlocked: Bool
    var isWriting: Bool
    var writeFailed: Bool

    /// PowerUI 写入可用，且读到了开关状态和可选值时才提供控制。
    init?(
        snapshot: BatterySnapshot,
        canWrite: Bool,
        isBlocked: Bool,
        isWriting: Bool = false,
        writeFailed: Bool = false
    ) {
        guard canWrite, let options = snapshot.chargeLimitOptions else { return nil }
        switch snapshot.chargeLimit {
        case .on(let percent):
            isEnabled = true
            // 保持当前电量期间显示用户设置的上限，不显示临时值。
            self.percent = snapshot.chargeLimitHold?.userLimit ?? percent
        case .off:
            isEnabled = false
            percent = nil
        case .unsupported, nil:
            return nil
        }
        self.options = options
        self.isBlocked = isBlocked
        self.isWriting = isWriting
        self.writeFailed = writeFailed
    }

    @MainActor
    init?(monitor: BatteryMonitor) {
        guard case .battery(let snapshot)? = monitor.reading else { return nil }
        self.init(
            snapshot: snapshot,
            canWrite: monitor.canWriteChargeLimit,
            isBlocked: monitor.isChargeControlAppRunning,
            isWriting: monitor.isWritingChargeLimit,
            writeFailed: monitor.chargeLimitWriteFailed
        )
    }

    /// 控件是否可以操作。
    var isInteractive: Bool {
        !isBlocked && !isWriting
    }
}
