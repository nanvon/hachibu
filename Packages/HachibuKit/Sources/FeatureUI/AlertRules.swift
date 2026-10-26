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

/// 健康度低提醒的判定：系统最大容量低于阈值时提醒一次。
/// 记下提醒时的阈值，用户把阈值改成别的值后才会再次提醒。
struct HealthAlertRule: Equatable {
    /// 上次提醒时的阈值。由调用方持久化。
    private(set) var alertedThreshold: Int?

    init(alertedThreshold: Int? = nil) {
        self.alertedThreshold = alertedThreshold
    }

    func hasAlerted(threshold: Int) -> Bool {
        alertedThreshold == threshold
    }

    /// 处理一次健康度读数。返回 true 表示这次应当发出提醒。
    mutating func update(maximumCapacity: Int?, threshold: Int) -> Bool {
        guard !hasAlerted(threshold: threshold), let maximumCapacity, maximumCapacity < threshold else {
            return false
        }
        alertedThreshold = threshold
        return true
    }
}
