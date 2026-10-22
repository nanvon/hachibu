import BatteryCore
import Foundation
import Observation

/// 用户设置，保存在 UserDefaults。设置项见 docs/v1技术设计.md 第 12、13 节。
@MainActor
@Observable
public final class AppSettings {
    public static let temperatureThresholdRange = 30...50
    public static let healthThresholdRange = 50...95

    public var menuBarContent: MenuBarContent {
        didSet { defaults.set(menuBarContent.rawValue, forKey: Key.menuBarContent) }
    }
    public var temperatureAlertEnabled: Bool {
        didSet { defaults.set(temperatureAlertEnabled, forKey: Key.temperatureAlertEnabled) }
    }
    /// 电池温度提醒阈值（°C）。面板的“偏高”标签也用这个值。
    public var temperatureAlertThreshold: Int {
        didSet { defaults.set(temperatureAlertThreshold, forKey: Key.temperatureAlertThreshold) }
    }
    public var healthAlertEnabled: Bool {
        didSet { defaults.set(healthAlertEnabled, forKey: Key.healthAlertEnabled) }
    }
    /// 健康度提醒阈值（%），与系统最大容量比较。
    public var healthAlertThreshold: Int {
        didSet { defaults.set(healthAlertThreshold, forKey: Key.healthAlertThreshold) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarContent = defaults.string(forKey: Key.menuBarContent).flatMap(MenuBarContent.init(rawValue:)) ?? .batteryLevel
        temperatureAlertEnabled = defaults.object(forKey: Key.temperatureAlertEnabled) as? Bool ?? true
        temperatureAlertThreshold = Self.integer(defaults, Key.temperatureAlertThreshold, default: 40, in: Self.temperatureThresholdRange)
        healthAlertEnabled = defaults.object(forKey: Key.healthAlertEnabled) as? Bool ?? true
        healthAlertThreshold = Self.integer(defaults, Key.healthAlertThreshold, default: 80, in: Self.healthThresholdRange)
    }

    /// 没有保存过时用默认值；超出范围时取范围内最近的值。
    private static func integer(_ defaults: UserDefaults, _ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private enum Key {
        static let menuBarContent = "menuBarContent"
        static let temperatureAlertEnabled = "temperatureAlertEnabled"
        static let temperatureAlertThreshold = "temperatureAlertThreshold"
        static let healthAlertEnabled = "healthAlertEnabled"
        static let healthAlertThreshold = "healthAlertThreshold"
    }
}

/// 菜单栏显示的读数。
public enum MenuBarContent: String, CaseIterable, Sendable {
    case batteryLevel
    case systemPower
    case temperature
}

/// 菜单栏文字。数值格式与面板一致，缺失时显示“—”。
public enum MenuBarTitle {
    public static func string(for reading: BatteryReading?, content: MenuBarContent) -> String {
        switch reading {
        case nil:
            DisplayFormat.missing
        case .noBattery:
            String(localized: "No Battery Detected", bundle: .module)
        case .battery(let snapshot):
            switch content {
            case .batteryLevel: DisplayFormat.percent(snapshot.percent)
            case .systemPower: DisplayFormat.watts(milliwatts: snapshot.systemLoadMW)
            case .temperature: DisplayFormat.celsius(snapshot.temperatureCelsius)
            }
        }
    }
}
