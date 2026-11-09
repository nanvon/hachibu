import Darwin
import notify
import Foundation

/// 系统“长期未充满，强制充满一次”的状态。规则见 docs/v1技术设计.md 21.5。
/// powerd 开始为校准电量计充满时，把公开通知 `com.apple.system.powersources.chargingtofulloverride` 的 state 置 1，结束后置 0。
/// 读取不需要权限；开机后 powerd 第一次发出前读到 0。
public enum SystemFullChargeOverride {
    public static let notificationName = "com.apple.system.powersources.chargingtofulloverride"

    /// 正在强制充满时为 true，读取失败时为 nil。
    public static func isActive() -> Bool? {
        var token: Int32 = 0
        guard notify_register_check(notificationName, &token) == UInt32(NOTIFY_STATUS_OK) else { return nil }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else { return nil }
        return state == 1
    }
}
