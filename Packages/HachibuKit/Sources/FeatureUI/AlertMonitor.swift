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

/// 电池温度提醒，规则见 docs/v1技术设计.md 第 12 节。
/// 是否已提醒存在 UserDefaults，重启后保留。系统通知未允许时不判定，允许后再开始。
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
            if authorization == .notDetermined, settings.temperatureAlertEnabled {
                await requestAuthorization()
            }
        }
    }

    /// 重新读取授权状态。用户可能在系统设置里改过。
    public func refreshAuthorization() async {
        await setAuthorization(await notifier.authorization())
    }

    public func requestAuthorization() async {
        await setAuthorization(await notifier.requestAuthorization())
    }

    /// 每次读取后调用，读数没变也要调用：温度提醒按持续时间判定。
    public func handleReading(_ reading: BatteryReading?, at date: Date) async {
        let temperature: Double?
        if case .battery(let snapshot)? = reading {
            temperature = snapshot.temperatureCelsius
        } else {
            temperature = nil
        }
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
