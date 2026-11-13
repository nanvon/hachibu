import BatteryCore
import Foundation

/// 面板和设置页中充电上限控制的显示内容。规则见 docs/v1技术设计.md 第 6、13 节和 21.7。
/// 为 nil 时不提供控制，只读显示上限。
struct ChargeLimitControl: Equatable {
    /// 接管模式下可新选的目标范围。已有目标可低于这个范围。
    static let managedSelectionRange = 70...100
    /// 面板快捷档。目标不在档位上时作为额外的选中档位显示。
    static let managedOptions = [managedSelectionRange.lowerBound, 80, 90, managedSelectionRange.upperBound]
    /// 读回被别处改过后，提示“充电上限由 Hachibu 管理”的时长。
    static let externalChangeNoticeDuration: TimeInterval = 600

    var mode: ChargeControlMode = .followSystem
    var isEnabled: Bool
    /// 选中的档位（%）。上限关闭时为 100：PowerUI 设置 100% 即关闭上限，界面不单独提供开关。
    var percent: Int
    /// 可选档位，总是包含 100。
    var options: [Int]
    /// AlDente 等充电控制工具正在运行，控制不可用。
    var isBlocked: Bool
    var isWriting: Bool
    var writeFailed: Bool
    /// 接管模式下的生效状态，跟随系统设置时为 nil。
    var managedState: ManagedLimitState?
    /// 接管模式下刚改回被别处修改的上限。
    var showsExternalChangeNotice = false
    /// 系统充满时可以趁现在完成校准（21.5）。
    var offersCalibration = false

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
            percent = 100
        case .unsupported, nil:
            return nil
        }
        self.options = options.contains(100) ? options : options + [100]
        self.isBlocked = isBlocked
        self.isWriting = isWriting
        self.writeFailed = writeFailed
    }

    /// 接管模式：选中的是 Hachibu 的目标，不是系统读回的值。
    init?(
        managedTarget target: Int,
        snapshot: BatterySnapshot,
        canWrite: Bool,
        state: ManagedLimitState?,
        isBlocked: Bool,
        isWriting: Bool = false,
        writeFailed: Bool = false,
        showsExternalChangeNotice: Bool = false,
        offersCalibration: Bool = false
    ) {
        guard canWrite, let setting = snapshot.chargeLimit, setting != .unsupported else { return nil }
        mode = .managed
        isEnabled = target < 100
        percent = target
        options = Self.managedOptions.contains(target) ? Self.managedOptions : (Self.managedOptions + [target]).sorted()
        managedState = state
        self.isBlocked = isBlocked
        self.isWriting = isWriting
        self.writeFailed = writeFailed
        self.showsExternalChangeNotice = showsExternalChangeNotice
        self.offersCalibration = offersCalibration
    }

    @MainActor
    init?(monitor: BatteryMonitor, now: Date = Date()) {
        guard case .battery(let snapshot)? = monitor.reading else { return nil }
        switch monitor.chargeControl.mode {
        case .followSystem:
            self.init(
                snapshot: snapshot,
                canWrite: monitor.canWriteChargeLimit,
                isBlocked: monitor.isChargeControlAppRunning,
                isWriting: monitor.isWritingChargeLimit,
                writeFailed: monitor.chargeLimitWriteFailed
            )
        case .managed:
            self.init(
                managedTarget: monitor.chargeControl.target,
                snapshot: snapshot,
                canWrite: monitor.canWriteChargeLimit,
                state: monitor.managedLimitState,
                isBlocked: monitor.isChargeControlAppRunning,
                // 接管模式的写入都是自动的，写入期间仍然可以改目标。
                isWriting: false,
                writeFailed: monitor.managedWriteFailed,
                showsExternalChangeNotice: monitor.externalChangeRevertedAt
                    .map { now.timeIntervalSince($0) < Self.externalChangeNoticeDuration } ?? false,
                offersCalibration: monitor.canOfferCalibrationAfterSystemFullCharge
            )
        }
    }

    /// 控件是否可以操作。
    var isInteractive: Bool {
        !isBlocked && !isWriting
    }
}
