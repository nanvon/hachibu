import BatteryCore
import Foundation
import Observation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Alerts")

/// 系统通知授权状态。
public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case allowed
}

/// 要发出的提醒。
public enum BatteryAlert: Sendable, Equatable {
    case highTemperature(celsius: Double, threshold: Int)
    /// 保留旧接口；系统通知实现不再发送此类提醒。
    case lowHealth(maximumCapacityPercent: Int, threshold: Int)
    case calibrationCompleted
    /// 不含 `.user` 和 `.systemPolicy`，这两个原因不发通知。
    case calibrationPaused(CalibrationPauseReason)
    case limitNotApplied(limit: Int)
    case systemCalibrationStarted
    /// 本次插电后充电完成：`limit` 为 nil 表示充满，否则为到达的充电上限。
    case chargeCompleted(limit: Int?)
    case lowBattery(percent: Int, threshold: Int)
}

/// 发送系统通知。App 里用 SystemAlertNotifier，测试里替换。
public protocol AlertNotifier: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    /// 系统接受通知请求后返回；失败抛错，由调用方保留重试机会。
    func deliver(_ alert: BatteryAlert) async throws
}

/// 某个提醒当前的状态，通知页显示用。
enum AlertStatus: Equatable {
    case off
    case waiting
    case alerted
}

/// 按读数判定的提醒（电池温度、充电完成、低电量）和充电接管通知，规则见 docs/v1技术设计.md 第 12 节。
/// 温度是否已提醒存在 UserDefaults，重启后保留。系统通知未允许时不判定，允许后再开始。
@MainActor
@Observable
public final class AlertMonitor {
    public private(set) var authorization: NotificationAuthorization = .notDetermined
    /// 最近一次温度读数，通知页显示用。
    private(set) var latestTemperature: Double?
    private(set) var isTemperatureAlerted: Bool

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let notifier: any AlertNotifier
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var temperatureRule: TemperatureAlertRule
    @ObservationIgnored private var isDeliveringTemperature = false
    @ObservationIgnored private var chargeCompleteRule = ChargeCompleteAlertRule()
    @ObservationIgnored private var lowBatteryRule = LowBatteryAlertRule()
    @ObservationIgnored private var isDeliveringBatteryLevel = false
    /// 充电接管通知的去重：每个键最近一次发送成功的时间。
    @ObservationIgnored private var lastChargeControlDelivery: [String: Date] = [:]
    static let chargeControlDedupInterval: TimeInterval = 30 * 60

    public init(settings: AppSettings, notifier: any AlertNotifier, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.notifier = notifier
        self.defaults = defaults
        let temperatureAlerted = defaults.bool(forKey: Key.temperatureAlerted)
        isTemperatureAlerted = temperatureAlerted
        temperatureRule = TemperatureAlertRule(hasAlerted: temperatureAlerted)
    }

    var temperatureStatus: AlertStatus {
        guard settings.temperatureAlertEnabled else { return .off }
        return isTemperatureAlerted ? .alerted : .waiting
    }

    /// 读取授权状态；有提醒打开且还没询问过时，请求授权。
    public func start() {
        Task {
            await refreshAuthorization()
            await requestAuthorizationIfNeeded()
        }
    }

    /// 有按读数判定的提醒打开且还没询问过时，请求授权。通知页打开提醒开关时也调用。
    public func requestAuthorizationIfNeeded() async {
        guard authorization == .notDetermined else { return }
        guard settings.temperatureAlertEnabled || settings.chargeCompleteAlertEnabled || settings.lowBatteryAlertEnabled else { return }
        await requestAuthorization()
    }

    /// 重新读取授权状态。用户可能在系统设置里改过。
    public func refreshAuthorization() async {
        await setAuthorization(await notifier.authorization())
    }

    public func requestAuthorization() async {
        await setAuthorization(await notifier.requestAuthorization())
    }

    /// 每次读取后调用，读数没变也要调用：温度提醒按持续时间判定。
    /// `isCalibrating` 为 Hachibu 校准进行中（含暂停），这期间不发充电完成提醒。
    public func handleReading(_ reading: BatteryReading?, at date: Date, isCalibrating: Bool = false) async {
        let snapshot: BatterySnapshot?
        if case .battery(let battery)? = reading {
            snapshot = battery
        } else {
            snapshot = nil
        }
        await handleBatteryLevel(snapshot, isCalibrating: isCalibrating)
        await handleTemperature(snapshot?.temperatureCelsius, at: date)
    }

    /// 充电完成和低电量。两条规则都在通知允许且开关打开时才判定；关闭期间状态从头开始。
    private func handleBatteryLevel(_ snapshot: BatterySnapshot?, isCalibrating: Bool) async {
        guard !isDeliveringBatteryLevel else { return }
        let allowed = authorization == .allowed
        var alerts: [BatteryAlert] = []

        if allowed, settings.chargeCompleteAlertEnabled {
            if let alert = chargeCompleteRule.update(status: snapshot.flatMap(ChargeStatus.init), isCalibrating: isCalibrating) {
                alerts.append(alert)
            }
        } else {
            chargeCompleteRule = ChargeCompleteAlertRule()
        }

        if allowed, settings.lowBatteryAlertEnabled {
            let threshold = settings.lowBatteryAlertThreshold
            if lowBatteryRule.update(isExternalPower: snapshot?.isExternalPower, percent: snapshot?.percent, threshold: threshold),
               let percent = snapshot?.percent {
                alerts.append(.lowBattery(percent: percent, threshold: threshold))
            }
        } else {
            lowBatteryRule = LowBatteryAlertRule()
        }

        guard !alerts.isEmpty else { return }
        isDeliveringBatteryLevel = true
        for alert in alerts {
            do {
                try await notifier.deliver(alert)
            } catch {
                // 下一次读数仍满足条件时重试。
                if case .lowBattery = alert { lowBatteryRule.deliveryFailed() } else { chargeCompleteRule.deliveryFailed() }
                logger.error("Failed to deliver battery level alert: \(String(describing: error), privacy: .public)")
            }
        }
        isDeliveringBatteryLevel = false
    }

    private func handleTemperature(_ temperature: Double?, at date: Date) async {
        if latestTemperature != temperature { latestTemperature = temperature }
        guard !isDeliveringTemperature else {
            temperatureRule.resetTiming()
            return
        }
        guard settings.temperatureAlertEnabled, authorization == .allowed else {
            temperatureRule.resetTiming()
            return
        }

        let threshold = settings.temperatureAlertThreshold
        let shouldAlert = temperatureRule.update(temperature: temperature, threshold: threshold, at: date)
        if shouldAlert, let celsius = temperature {
            isDeliveringTemperature = true
            do {
                try await notifier.deliver(.highTemperature(celsius: celsius, threshold: threshold))
            } catch {
                // 保留已经满足的高温时长，下一次有效读数可重试。
                temperatureRule.deliveryFailed()
                logger.error("Failed to deliver temperature alert: \(String(describing: error), privacy: .public)")
            }
            isDeliveringTemperature = false
        }
        if temperatureRule.hasAlerted != isTemperatureAlerted {
            isTemperatureAlerted = temperatureRule.hasAlerted
            defaults.set(isTemperatureAlerted, forKey: Key.temperatureAlerted)
        }
    }

    /// 充电接管相关事件。按设置开关和系统授权决定是否发送；
    /// 上限未生效（同一上限）和校准暂停（同一原因）30 分钟内只发一次，发送失败不计入。
    public func handleChargeControlNotice(_ notice: ChargeControlNotice, at date: Date = Date()) async {
        guard authorization == .allowed else { return }
        let alert: BatteryAlert
        var dedupKey: String?
        switch notice {
        case .calibrationCompleted:
            guard settings.calibrationAlertsEnabled else { return }
            alert = .calibrationCompleted
        case .calibrationPaused(let reason):
            guard settings.calibrationAlertsEnabled, reason != .user, reason != .systemPolicy else { return }
            alert = .calibrationPaused(reason)
            dedupKey = "calibrationPaused.\(reason.rawValue)"
        case .limitNotApplied(let limit):
            guard settings.chargeLimitAlertEnabled else { return }
            alert = .limitNotApplied(limit: limit)
            dedupKey = "limitNotApplied.\(limit)"
        case .systemCalibrationStarted:
            guard settings.systemCalibrationAlertEnabled else { return }
            alert = .systemCalibrationStarted
        }
        if let dedupKey, let last = lastChargeControlDelivery[dedupKey],
           date.timeIntervalSince(last) < Self.chargeControlDedupInterval {
            return
        }
        do {
            try await notifier.deliver(alert)
            if let dedupKey { lastChargeControlDelivery[dedupKey] = date }
        } catch {
            logger.error("Failed to deliver charge control alert: \(String(describing: error), privacy: .public)")
        }
    }

    /// 保留旧接口，刷新通知授权状态；最大容量不再触发提醒。
    public func handleHealth(_ health: BatteryHealthInfo) async {
        await refreshAuthorization()
    }

    private func setAuthorization(_ authorization: NotificationAuthorization) async {
        guard authorization != self.authorization else { return }
        self.authorization = authorization
        if authorization != .allowed {
            temperatureRule.resetTiming()
        }
    }

    private enum Key {
        static let temperatureAlerted = "temperatureAlerted"
    }
}
