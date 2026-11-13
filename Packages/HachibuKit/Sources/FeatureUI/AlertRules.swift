import BatteryCore
import Foundation

/// 电池温度过高提醒的判定，规则见 docs/v1技术设计.md 第 12 节：
/// 连续 3 分钟高于阈值提醒一次；之后连续 5 分钟低于“阈值 − 2°C”才允许再次提醒。
/// 读数缺失既不算高于阈值，也不算恢复，两段计时都从头开始。
struct TemperatureAlertRule: Equatable {
    static let triggerDuration: TimeInterval = 180
    static let recoveryDuration: TimeInterval = 300
    static let recoveryMargin = 2.0
    /// 相邻两次读数的间隔超过这个时长（例如休眠）就从头计时。
    /// 面板关闭时最长约 70 秒读取一次。
    static let maxReadingGap: TimeInterval = 90

    /// 已提醒、尚未恢复。由调用方持久化。
    private(set) var hasAlerted: Bool
    private var highSince: Date?
    private var lowSince: Date?
    private var lastReadingAt: Date?
    private var lastThreshold: Int?

    init(hasAlerted: Bool = false) {
        self.hasAlerted = hasAlerted
    }

    /// 开关、授权或阈值变化后，不能把之前的时间计入新的持续区间。
    mutating func resetTiming() {
        highSince = nil
        lowSince = nil
        lastReadingAt = nil
    }

    /// 系统没有接受通知请求，保留本次读数时间与高温区间，下次读数可重试。
    mutating func deliveryFailed() {
        hasAlerted = false
    }

    /// 处理一次读数。返回 true 表示这次应当发出提醒。
    mutating func update(temperature: Double?, threshold: Int, at date: Date) -> Bool {
        if lastThreshold != threshold {
            resetTiming()
            lastThreshold = threshold
        }
        guard let temperature else {
            resetTiming()
            return false
        }
        if let lastReadingAt, date.timeIntervalSince(lastReadingAt) > Self.maxReadingGap {
            highSince = nil
            lowSince = nil
        }
        lastReadingAt = date

        if hasAlerted {
            highSince = nil
            guard temperature < Double(threshold) - Self.recoveryMargin else {
                lowSince = nil
                return false
            }
            let since = lowSince ?? date
            if date.timeIntervalSince(since) >= Self.recoveryDuration {
                hasAlerted = false
                lowSince = nil
            } else {
                lowSince = since
            }
            return false
        }

        lowSince = nil
        guard temperature > Double(threshold) else {
            highSince = nil
            return false
        }
        let since = highSince ?? date
        if date.timeIntervalSince(since) >= Self.triggerDuration {
            hasAlerted = true
            return true
        }
        highSince = since
        return false
    }
}

/// 充电完成提醒的判定，规则见 docs/v1技术设计.md 第 12 节：
/// 本次插电期间看到过充电，之后状态第一次变成已充满或已达上限时提醒一次；拔电后重新开始。
/// 启动时已经充满、只放电到上限、保持当前电量、Hachibu 校准期间都不提醒。不持久化：重启后要重新看到充电。
struct ChargeCompleteAlertRule: Equatable {
    /// 本次插电期间看到过充电。
    private(set) var sawCharging = false
    /// 本次插电期间已经提醒过。
    private(set) var hasAlerted = false

    /// 处理一次读数。返回要提醒的内容：nil 表示不提醒；`.chargeCompleted(limit: nil)` 表示充满。
    /// 发送失败时调用 `deliveryFailed()`，下一次读数仍满足条件时重试。
    mutating func update(status: ChargeStatus?, isCalibrating: Bool) -> BatteryAlert? {
        guard let status else { return nil }
        if isCalibrating {
            // 校准会充满并保持，结束后要重新看到充电才算一次充电。
            sawCharging = false
            return nil
        }
        switch status {
        case .onBattery:
            sawCharging = false
            hasAlerted = false
            return nil
        case .charging, .temporaryFullCharge:
            sawCharging = true
            return nil
        case .fullyCharged:
            return complete(limit: nil)
        case .chargeLimitReached(let limit):
            return complete(limit: limit)
        default:
            return nil
        }
    }

    mutating func deliveryFailed() {
        hasAlerted = false
    }

    private mutating func complete(limit: Int?) -> BatteryAlert? {
        guard sawCharging, !hasAlerted else { return nil }
        hasAlerted = true
        return .chargeCompleted(limit: limit)
    }
}

/// 低电量提醒的判定，规则见 docs/v1技术设计.md 第 12 节：
/// 使用电池且电量不高于阈值时提醒一次；插上电源或电量回到“阈值 + 5”以上后允许再次提醒。
/// 读数缺失不提醒也不重置。不持久化：重启后仍低于阈值会再提醒一次。
struct LowBatteryAlertRule: Equatable {
    static let recoveryMargin = 5

    private(set) var hasAlerted = false

    mutating func update(isExternalPower: Bool?, percent: Int?, threshold: Int) -> Bool {
        guard let isExternalPower, let percent else { return false }
        if isExternalPower || percent >= threshold + Self.recoveryMargin {
            hasAlerted = false
            return false
        }
        guard percent <= threshold, !hasAlerted else { return false }
        hasAlerted = true
        return true
    }

    mutating func deliveryFailed() {
        hasAlerted = false
    }
}
