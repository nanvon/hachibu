import BatteryCore
import Foundation
import Observation

/// 用户设置，保存在 UserDefaults。设置项见 docs/v1技术设计.md 第 12、13 节。
@MainActor
@Observable
public final class AppSettings {
    public static let temperatureThresholdRange = 30...50
    public static let lowBatteryThresholdRange = 10...50
    /// 保留旧接口；最大容量提醒已移除。
    public static let healthThresholdRange = 50...95

    /// 菜单栏图标旁显示的读数，按 `MenuBarContent.allCases` 的固定顺序排列，可以为空（只显示图标）。
    /// 存在新键里；旧键 `menuBarContent` 同时写入第一项，装回旧版本时仍有合理的单项选择。
    public var menuBarContents: [MenuBarContent] {
        didSet {
            // 调用方保证顺序（设置页按固定顺序写入）；这里只按固定顺序保存，读取时同样排序。
            let ordered = MenuBarContent.ordered(menuBarContents)
            defaults.set(ordered.map(\.rawValue), forKey: Key.menuBarContents)
            if let first = ordered.first {
                defaults.set(first.rawValue, forKey: Key.menuBarContent)
            }
        }
    }
    public var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Key.menuBarIconStyle) }
    }
    public var temperatureAlertEnabled: Bool {
        didSet { defaults.set(temperatureAlertEnabled, forKey: Key.temperatureAlertEnabled) }
    }
    /// 电池温度提醒阈值（°C）。面板的“偏高”标签也用这个值。
    public var temperatureAlertThreshold: Int {
        didSet { defaults.set(temperatureAlertThreshold, forKey: Key.temperatureAlertThreshold) }
    }
    /// 本次插电后充满或到达充电上限。默认关闭，避免升级后突然收到通知。
    public var chargeCompleteAlertEnabled: Bool {
        didSet { defaults.set(chargeCompleteAlertEnabled, forKey: Key.chargeCompleteAlertEnabled) }
    }
    /// 使用电池且电量不高于阈值。默认关闭。
    public var lowBatteryAlertEnabled: Bool {
        didSet { defaults.set(lowBatteryAlertEnabled, forKey: Key.lowBatteryAlertEnabled) }
    }
    /// 低电量提醒阈值（%）。
    public var lowBatteryAlertThreshold: Int {
        didSet { defaults.set(lowBatteryAlertThreshold, forKey: Key.lowBatteryAlertThreshold) }
    }
    /// 电池校准完成和中断。
    public var calibrationAlertsEnabled: Bool {
        didSet { defaults.set(calibrationAlertsEnabled, forKey: Key.calibrationAlertsEnabled) }
    }
    /// 充电上限没能生效。
    public var chargeLimitAlertEnabled: Bool {
        didSet { defaults.set(chargeLimitAlertEnabled, forKey: Key.chargeLimitAlertEnabled) }
    }
    /// macOS 开始校准电池。
    public var systemCalibrationAlertEnabled: Bool {
        didSet { defaults.set(systemCalibrationAlertEnabled, forKey: Key.systemCalibrationAlertEnabled) }
    }
    public var healthAlertEnabled: Bool {
        didSet { defaults.set(healthAlertEnabled, forKey: Key.healthAlertEnabled) }
    }
    /// 保留旧设置，不再控制提醒。
    public var healthAlertThreshold: Int {
        didSet { defaults.set(healthAlertThreshold, forKey: Key.healthAlertThreshold) }
    }
    /// 插电且电量高于系统充电上限时的处理，见 docs/v1技术设计.md 第 6 节。
    public var chargeAboveLimitAction: ChargeAboveLimitAction {
        didSet { defaults.set(chargeAboveLimitAction.rawValue, forKey: Key.chargeAboveLimitAction) }
    }

    /// 充电上限管理方式，见 docs/v1技术设计.md 21.1。
    public var chargeControlMode: ChargeControlMode {
        didSet { defaults.set(chargeControlMode.rawValue, forKey: Key.chargeControlMode) }
    }
    /// 接管模式的目标上限（%），100 表示关闭。
    public var managedChargeLimit: Int {
        didSet {
            let clamped = Self.clamp(managedChargeLimit, ManagedChargeLimit.targetRange)
            if clamped != managedChargeLimit { managedChargeLimit = clamped; return }
            defaults.set(managedChargeLimit, forKey: Key.managedChargeLimit)
        }
    }
    public var managedLimitOnQuit: ManagedLimitOnQuit {
        didSet { defaults.set(managedLimitOnQuit.rawValue, forKey: Key.managedLimitOnQuit) }
    }
    public var afterSystemFullCharge: AfterSystemFullCharge {
        didSet { defaults.set(afterSystemFullCharge.rawValue, forKey: Key.afterSystemFullCharge) }
    }

    /// 同步给 BatteryMonitor 的接管设置。
    public var chargeControlConfiguration: ChargeControlConfiguration {
        ChargeControlConfiguration(
            mode: chargeControlMode, target: managedChargeLimit, keepsLimitOnQuit: managedLimitOnQuit == .keepLimit,
            continuesCalibrationAfterSystemFullCharge: afterSystemFullCharge == .continueCalibration
        )
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Key.menuBarContents) {
            menuBarContents = MenuBarContent.ordered(stored.compactMap(MenuBarContent.init(rawValue:)))
        } else {
            // 旧版本只存一项；未知值回退电量。
            menuBarContents = [defaults.string(forKey: Key.menuBarContent).flatMap(MenuBarContent.init(rawValue:)) ?? .batteryLevel]
        }
        menuBarIconStyle = defaults.string(forKey: Key.menuBarIconStyle).flatMap(MenuBarIconStyle.init(rawValue:)) ?? .battery
        temperatureAlertEnabled = defaults.object(forKey: Key.temperatureAlertEnabled) as? Bool ?? true
        temperatureAlertThreshold = Self.integer(defaults, Key.temperatureAlertThreshold, default: 40, in: Self.temperatureThresholdRange)
        chargeCompleteAlertEnabled = defaults.object(forKey: Key.chargeCompleteAlertEnabled) as? Bool ?? false
        lowBatteryAlertEnabled = defaults.object(forKey: Key.lowBatteryAlertEnabled) as? Bool ?? false
        lowBatteryAlertThreshold = Self.integer(defaults, Key.lowBatteryAlertThreshold, default: 20, in: Self.lowBatteryThresholdRange)
        calibrationAlertsEnabled = defaults.object(forKey: Key.calibrationAlertsEnabled) as? Bool ?? true
        chargeLimitAlertEnabled = defaults.object(forKey: Key.chargeLimitAlertEnabled) as? Bool ?? true
        systemCalibrationAlertEnabled = defaults.object(forKey: Key.systemCalibrationAlertEnabled) as? Bool ?? false
        healthAlertEnabled = defaults.object(forKey: Key.healthAlertEnabled) as? Bool ?? true
        healthAlertThreshold = Self.integer(defaults, Key.healthAlertThreshold, default: 80, in: Self.healthThresholdRange)
        chargeAboveLimitAction = defaults.string(forKey: Key.chargeAboveLimitAction)
            .flatMap(ChargeAboveLimitAction.init(rawValue:)) ?? .dischargeToLimit
        chargeControlMode = defaults.string(forKey: Key.chargeControlMode).flatMap(ChargeControlMode.init(rawValue:)) ?? .followSystem
        managedChargeLimit = Self.integer(defaults, Key.managedChargeLimit, default: 80, in: ManagedChargeLimit.targetRange)
        managedLimitOnQuit = defaults.string(forKey: Key.managedLimitOnQuit).flatMap(ManagedLimitOnQuit.init(rawValue:)) ?? .restoreSystem
        afterSystemFullCharge = defaults.string(forKey: Key.afterSystemFullCharge)
            .flatMap(AfterSystemFullCharge.init(rawValue:)) ?? .dischargeToLimit
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// 没有保存过时用默认值；超出范围时取范围内最近的值。
    private static func integer(_ defaults: UserDefaults, _ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private enum Key {
        static let menuBarContent = "menuBarContent"
        static let menuBarContents = "menuBarContents"
        static let menuBarIconStyle = "menuBarIconStyle"
        static let temperatureAlertEnabled = "temperatureAlertEnabled"
        static let temperatureAlertThreshold = "temperatureAlertThreshold"
        static let chargeCompleteAlertEnabled = "chargeCompleteAlertEnabled"
        static let lowBatteryAlertEnabled = "lowBatteryAlertEnabled"
        static let lowBatteryAlertThreshold = "lowBatteryAlertThreshold"
        static let calibrationAlertsEnabled = "calibrationAlertsEnabled"
        static let chargeLimitAlertEnabled = "chargeLimitAlertEnabled"
        static let systemCalibrationAlertEnabled = "systemCalibrationAlertEnabled"
        static let healthAlertEnabled = "healthAlertEnabled"
        static let healthAlertThreshold = "healthAlertThreshold"
        static let chargeAboveLimitAction = "chargeAboveLimitAction"
        static let chargeControlMode = "chargeControlMode"
        static let managedChargeLimit = "managedChargeLimit"
        static let managedLimitOnQuit = "managedLimitOnQuit"
        static let afterSystemFullCharge = "afterSystemFullCharge"
    }
}

/// 插电且电量高于系统充电上限时的处理。
public enum ChargeAboveLimitAction: String, CaseIterable, Sendable {
    /// 系统默认行为：用电池放到上限，Hachibu 不写入。
    case dischargeToLimit
    /// 把系统上限临时写成当前电量，由充电器供电。
    case holdCurrentCharge
}

/// 接管模式下退出 Hachibu 后的处理。
public enum ManagedLimitOnQuit: String, CaseIterable, Sendable {
    /// 恢复接管前的系统设置（默认）。
    case restoreSystem
    /// 保留当前上限，helper 也不自动恢复。
    case keepLimit
}

/// 系统自动充满（校准、强制充满）后的处理，见 docs/v1技术设计.md 21.6。
public enum AfterSystemFullCharge: String, CaseIterable, Sendable {
    /// 放电回上限（默认）。
    case dischargeToLimit
    /// 接着完成校准，从第 3 步开始。
    case continueCalibration
}

/// 菜单栏电池外观；旧样式和未知存储值回退到 macOS。
public enum MenuBarIconStyle: String, CaseIterable, Sendable {
    /// 保留第一批实现的持久化值 `battery`。
    case battery
    case ios
}

/// 菜单栏显示的读数。声明顺序就是菜单栏里的显示顺序。
public enum MenuBarContent: String, CaseIterable, Sendable {
    case batteryLevel
    case systemPower
    case temperature

    /// 去重并按固定顺序排列。
    static func ordered(_ contents: [MenuBarContent]) -> [MenuBarContent] {
        allCases.filter(contents.contains)
    }
}

/// 菜单栏文字。数值格式与面板一致，缺失时显示“—”。
public enum MenuBarTitle {
    /// 多项读数按给定顺序拼接。没有读数或没有电池时只显示一次“—”或提示文字。
    public static func string(for reading: BatteryReading?, contents: [MenuBarContent], separator: String = "  ") -> String {
        guard case .battery = reading, !contents.isEmpty else {
            return string(for: reading, content: contents.first ?? .batteryLevel)
        }
        return contents.map { string(for: reading, content: $0) }.joined(separator: separator)
    }

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
