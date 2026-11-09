import BatteryCore
import Foundation

extension BatteryMonitor {
    /// 诊断导出用的充电接管和校准信息。helper 状态经 XPC 读取，未启用时为 nil。
    public func chargeControlDiagnostics() async -> ChargeControlDiagnostics {
        let service = helperService
        return ChargeControlDiagnostics(
            mode: chargeControl.mode.rawValue,
            target: chargeControl.target,
            keepsLimitOnQuit: chargeControl.keepsLimitOnQuit,
            helperState: String(describing: service.state),
            helperStatus: await service.helperStatus(),
            battlimitOutput: registrationRawOutput,
            registration: registration,
            calibration: calibration,
            managedLimitState: managedLimitState.map { String(describing: $0) }
        )
    }
}
