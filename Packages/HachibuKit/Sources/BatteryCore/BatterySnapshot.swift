import Foundation

/// 一次读取的解析结果。
public enum BatteryReading: Sendable, Equatable {
    /// IOPS 中没有内置电池（如 Mac mini、Mac Studio）：不采样、不写库。
    case noBattery
    case battery(BatterySnapshot)

    public init(_ raw: RawBatteryReadings) {
        guard let source = raw.powerSources.first(where: { $0["Type"]?.stringValue == "InternalBattery" }) else {
            self = .noBattery
            return
        }
        self = .battery(BatterySnapshot(powerSource: source, raw: raw))
    }
}

/// 解析后的电池读数。读不到、类型不对或者是哨兵值的字段为 nil，界面显示“—”，数据库存 NULL。
/// 字段来源见 docs/v1技术设计.md 第 5 节。
public struct BatterySnapshot: Sendable, Equatable {
    /// 电量（%），IOPS `Current Capacity / Max Capacity`。
    public var percent: Int?
    /// 是否接外接电源，IOPS `Power Source State == "AC Power"`。
    public var isExternalPower: Bool?
    /// IOPS `Is Charging`。
    public var isCharging: Bool?
    /// IOPS `Time to Empty`（分钟）。
    public var timeToEmptyMinutes: Int?
    /// IOPS `Time to Full Charge`（分钟）。
    public var timeToFullMinutes: Int?

    /// 电池电压（mV）。
    public var voltageMV: Int?
    /// 电池电流（mA），负数为放电。
    public var amperageMA: Int?
    /// 电池功率（mW），正数充电、负数放电。
    public var batteryPowerMW: Int?
    /// 输入功率（mW）。
    public var powerInMW: Int?
    /// 系统功率（mW）。
    public var systemLoadMW: Int?
    /// 输入电压（mV）。
    public var inputVoltageMV: Int?
    /// 输入电流（mA）。
    public var inputCurrentMA: Int?
    /// 遥测数据的更新时间，`AppleSmartBattery.UpdateTime`。功率约每 60 秒刷新一次。
    public var telemetryUpdatedAt: Date?

    /// 电池温度（°C），来自 `AppleSmartBatteryPack` 节点。
    public var temperatureCelsius: Double?
    public var fullChargeCapacityMAh: Int?
    public var designCapacityMAh: Int?
    public var cycleCount: Int?
    /// 设计循环次数，`DesignCycleCount9C`。
    public var designCycleCount: Int?

    /// 充电器信息，`IOPSCopyExternalPowerAdapterDetails()`。未接电时为 nil。
    public var adapter: PowerAdapter?
    public var lowPowerModeEnabled: Bool
    /// 系统充电上限设置，读不到时为 nil（未知）。
    public var chargeLimit: ChargeLimitSetting?
    /// 系统充电上限的可选值（%，升序），来自 PowerUI 的 `availableChargeLimitsWithError:`。读不到时为 nil。
    public var chargeLimitOptions: [Int]?

    /// 已开启的系统充电上限（%）。未开启、不支持或未知时为 nil。
    public var chargeLimitPercent: Int? {
        guard case .on(let percent) = chargeLimit else { return nil }
        return percent
    }

    /// 容量比：满充容量 ÷ 设计容量（0–1）。
    public var capacityRatio: Double? {
        guard let fullChargeCapacityMAh, let designCapacityMAh, designCapacityMAh > 0 else { return nil }
        return Double(fullChargeCapacityMAh) / Double(designCapacityMAh)
    }

    public init(
        percent: Int? = nil,
        isExternalPower: Bool? = nil,
        isCharging: Bool? = nil,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        voltageMV: Int? = nil,
        amperageMA: Int? = nil,
        batteryPowerMW: Int? = nil,
        powerInMW: Int? = nil,
        systemLoadMW: Int? = nil,
        inputVoltageMV: Int? = nil,
        inputCurrentMA: Int? = nil,
        telemetryUpdatedAt: Date? = nil,
        temperatureCelsius: Double? = nil,
        fullChargeCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        cycleCount: Int? = nil,
        designCycleCount: Int? = nil,
        adapter: PowerAdapter? = nil,
        lowPowerModeEnabled: Bool = false,
        chargeLimit: ChargeLimitSetting? = nil,
        chargeLimitOptions: [Int]? = nil
    ) {
        self.percent = percent
        self.isExternalPower = isExternalPower
        self.isCharging = isCharging
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.batteryPowerMW = batteryPowerMW
        self.powerInMW = powerInMW
        self.systemLoadMW = systemLoadMW
        self.inputVoltageMV = inputVoltageMV
        self.inputCurrentMA = inputCurrentMA
        self.telemetryUpdatedAt = telemetryUpdatedAt
        self.temperatureCelsius = temperatureCelsius
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.adapter = adapter
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.chargeLimit = chargeLimit
        self.chargeLimitOptions = chargeLimitOptions
    }
}

public struct PowerAdapter: Sendable, Equatable {
    public var watts: Int?
    public var name: String?
    public var manufacturer: String?

    public init(watts: Int? = nil, name: String? = nil, manufacturer: String? = nil) {
        self.watts = watts
        self.name = name
        self.manufacturer = manufacturer
    }
}

// MARK: - 解析

extension BatterySnapshot {
    init(powerSource source: [String: RawValue], raw: RawBatteryReadings) {
        let battery = raw.smartBattery ?? [:]
        let telemetry = battery["PowerTelemetryData"]
        let batteryData = battery["BatteryData"]

        let percent: Int? = {
            guard let current = source["Current Capacity"]?.intValue,
                  let max = source["Max Capacity"]?.intValue, max > 0
            else { return nil }
            return Int((Double(current) * 100 / Double(max)).rounded())
        }()

        self.init(
            percent: percent,
            isExternalPower: source["Power Source State"]?.stringValue.map { $0 == "AC Power" },
            isCharging: source["Is Charging"]?.boolValue,
            timeToEmptyMinutes: Self.minutes(source["Time to Empty"]),
            timeToFullMinutes: Self.minutes(source["Time to Full Charge"]),
            voltageMV: battery["Voltage"]?.intValue,
            amperageMA: battery["Amperage"]?.intValue,
            batteryPowerMW: telemetry?["BatteryPower"]?.intValue,
            powerInMW: telemetry?["SystemPowerIn"]?.intValue,
            systemLoadMW: telemetry?["SystemLoad"]?.intValue,
            inputVoltageMV: telemetry?["SystemVoltageIn"]?.intValue,
            inputCurrentMA: telemetry?["SystemCurrentIn"]?.intValue,
            telemetryUpdatedAt: battery["UpdateTime"]?.intValue
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            temperatureCelsius: raw.smartBatteryPack?["BatteryData"]?["Temperature"]?.doubleValue.map { $0 / 100 },
            fullChargeCapacityMAh: batteryData?["FullChargeCapacity"]?.intValue,
            designCapacityMAh: batteryData?["DesignCapacity"]?.intValue,
            cycleCount: battery["CycleCount"]?.intValue,
            designCycleCount: battery["DesignCycleCount9C"]?.intValue,
            adapter: raw.adapterDetails.map {
                PowerAdapter(
                    watts: $0["Watts"]?.intValue,
                    name: $0["Name"]?.stringValue,
                    manufacturer: $0["Manufacturer"]?.stringValue
                )
            },
            lowPowerModeEnabled: raw.lowPowerModeEnabled,
            chargeLimit: ChargeLimitSetting.resolve(powerUI: raw.powerUIChargeLimit, archive: raw.chargeLimitArchive),
            chargeLimitOptions: Self.chargeLimitOptions(raw.powerUIChargeLimit)
        )
    }

    /// 只保留 50–100 的值；不支持、出错或没有可用值时为 nil。
    private static func chargeLimitOptions(_ powerUI: PowerUIChargeLimit?) -> [Int]? {
        guard let powerUI, powerUI.isSupported,
              let options = powerUI.availableLimits?.filter({ (50...100).contains($0) }), !options.isEmpty
        else { return nil }
        return options.sorted()
    }

    /// 剩余时间：`≤ 0` 或 `≥ 65535` 视为没有值。
    private static func minutes(_ value: RawValue?) -> Int? {
        guard let minutes = value?.intValue, minutes > 0, minutes < 65535 else { return nil }
        return minutes
    }
}
