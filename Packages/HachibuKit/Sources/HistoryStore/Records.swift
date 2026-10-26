import BatteryCore
import Foundation
import GRDB

/// `minute_samples` 的一行。每分钟一行，保留 7 天后聚合进 `hourly_samples`。
/// 缺失的指标为 nil，存 NULL。
public struct MinuteSample: Sendable, Equatable {
    /// 采样时间，按分钟取整。
    public var timestamp: Date
    public var percent: Int?
    public var isExternalPower: Bool?
    public var isCharging: Bool?
    public var systemLoadMW: Int?
    public var batteryPowerMW: Int?
    public var powerInMW: Int?
    public var temperatureCelsius: Double?
    public var voltageMV: Int?
    public var amperageMA: Int?

    public init(
        timestamp: Date,
        percent: Int? = nil,
        isExternalPower: Bool? = nil,
        isCharging: Bool? = nil,
        systemLoadMW: Int? = nil,
        batteryPowerMW: Int? = nil,
        powerInMW: Int? = nil,
        temperatureCelsius: Double? = nil,
        voltageMV: Int? = nil,
        amperageMA: Int? = nil
    ) {
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(UnixTime.floor(timestamp, to: 60)))
        self.percent = percent
        self.isExternalPower = isExternalPower
        self.isCharging = isCharging
        self.systemLoadMW = systemLoadMW
        self.batteryPowerMW = batteryPowerMW
        self.powerInMW = powerInMW
        self.temperatureCelsius = temperatureCelsius
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
    }

    /// 用当时最近一次读取的值生成一行。
    public init(timestamp: Date, snapshot: BatterySnapshot) {
        self.init(
            timestamp: timestamp,
            percent: snapshot.percent,
            isExternalPower: snapshot.isExternalPower,
            isCharging: snapshot.isCharging,
            systemLoadMW: snapshot.systemLoadMW,
            batteryPowerMW: snapshot.batteryPowerMW,
            powerInMW: snapshot.powerInMW,
            temperatureCelsius: snapshot.temperatureCelsius,
            voltageMV: snapshot.voltageMV,
            amperageMA: snapshot.amperageMA
        )
    }
}

/// 一小时的汇总，`hourly_samples` 的一行。近期 7 天曲线用的是 `HourlyAverage`。
/// 平均值、最小值、最大值只统计非 NULL 的样本，全部为 NULL 时为 nil。迁移 v2 之前生成的行，v2 新增的字段为 nil。
public struct HourlySample: Sendable, Equatable {
    /// 小时起点。
    public var hour: Date
    public var sampleCount: Int
    /// 该小时内接电的分钟数。
    public var externalMinutes: Int
    /// 该小时内充电的分钟数。
    public var chargingMinutes: Int?
    public var percent: Summary<Int>
    public var systemLoadMW: Summary<Int>
    public var batteryPowerMW: Summary<Int>
    public var powerInMW: Summary<Int>
    public var temperatureCelsius: Summary<Double>
    public var voltageMV: Summary<Int>
    public var amperageMA: Summary<Int>

    /// 一个指标在一小时内的平均值、最小值、最大值。
    public struct Summary<Value: Sendable & Equatable>: Sendable, Equatable {
        public var average: Double?
        public var min: Value?
        public var max: Value?

        public init(average: Double? = nil, min: Value? = nil, max: Value? = nil) {
            self.average = average
            self.min = min
            self.max = max
        }
    }

    public init(
        hour: Date,
        sampleCount: Int,
        externalMinutes: Int,
        chargingMinutes: Int? = nil,
        percent: Summary<Int> = Summary(),
        systemLoadMW: Summary<Int> = Summary(),
        batteryPowerMW: Summary<Int> = Summary(),
        powerInMW: Summary<Int> = Summary(),
        temperatureCelsius: Summary<Double> = Summary(),
        voltageMV: Summary<Int> = Summary(),
        amperageMA: Summary<Int> = Summary()
    ) {
        self.hour = hour
        self.sampleCount = sampleCount
        self.externalMinutes = externalMinutes
        self.chargingMinutes = chargingMinutes
        self.percent = percent
        self.systemLoadMW = systemLoadMW
        self.batteryPowerMW = batteryPowerMW
        self.powerInMW = powerInMW
        self.temperatureCelsius = temperatureCelsius
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
    }
}

/// 分钟数据按小时求平均的结果，用于近期 7 天曲线，不对应数据表。
/// 平均值只统计非 NULL 的样本，全部为 NULL 时为 nil。
public struct HourlyAverage: Sendable, Equatable {
    /// 小时起点。
    public var hour: Date
    public var sampleCount: Int
    /// 该小时内接电的分钟数。
    public var externalMinutes: Int
    public var percent: Double?
    public var systemLoadMW: Double?
    public var batteryPowerMW: Double?
    public var powerInMW: Double?
    public var temperatureCelsius: Double?
    public var voltageMV: Double?

    public init(
        hour: Date,
        sampleCount: Int,
        externalMinutes: Int,
        percent: Double? = nil,
        systemLoadMW: Double? = nil,
        batteryPowerMW: Double? = nil,
        powerInMW: Double? = nil,
        temperatureCelsius: Double? = nil,
        voltageMV: Double? = nil
    ) {
        self.hour = hour
        self.sampleCount = sampleCount
        self.externalMinutes = externalMinutes
        self.percent = percent
        self.systemLoadMW = systemLoadMW
        self.batteryPowerMW = batteryPowerMW
        self.powerInMW = powerInMW
        self.temperatureCelsius = temperatureCelsius
        self.voltageMV = voltageMV
    }
}

/// 一天的电池健康数据，由 `daily_health` 按字段合并各来源得到：本机的值优先，其次是最近一次导入的来源。
/// 规则见 docs/v1技术设计.md 第 10 节。
public struct DailyHealth: Sendable, Equatable {
    /// 本地日期 `YYYY-MM-DD`。
    public var day: String
    /// 系统最大容量（%），来自 `system_profiler`。
    public var systemMaxCapacityPercent: Int?
    public var fullChargeCapacityMAh: Int?
    /// 与满充容量同一行的设计容量；这一行没有时取它所属电池的设计容量。用于计算容量比。
    public var designCapacityMAh: Int?
    public var cycleCount: Int?
    /// `system_profiler` 的健康状态原文，如 `Good`。
    public var healthCondition: String?
    /// 至少有一个字段来自导入的数据。
    public var includesImportedData: Bool

    public init(
        day: String,
        systemMaxCapacityPercent: Int? = nil,
        fullChargeCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        cycleCount: Int? = nil,
        healthCondition: String? = nil,
        includesImportedData: Bool = false
    ) {
        self.day = day
        self.systemMaxCapacityPercent = systemMaxCapacityPercent
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.cycleCount = cycleCount
        self.healthCondition = healthCondition
        self.includesImportedData = includesImportedData
    }

    /// 存储与解析日期键统一用公历；只跟随系统时区，不跟随用户选择的日历。
    public static func gregorianCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 按 `calendar` 的时区取公历本地日期，格式 `YYYY-MM-DD`。
    public static func day(for date: Date, calendar: Calendar = .current) -> String {
        let calendar = gregorianCalendar(timeZone: calendar.timeZone)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// `battery_events` 的一行。
public struct BatteryEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// 本机电池与上一次见到的电池不同。`batteryID` 为新电池。
        case batteryChanged = "battery_changed"
        /// 系统充电上限变化。`value` 为开启时的上限百分比，关闭时为 100。
        case chargeLimit = "charge_limit"
    }

    public var date: Date
    public var kind: Kind
    public var batteryID: Int64?
    public var value: Int?

    public init(date: Date, kind: Kind, batteryID: Int64? = nil, value: Int? = nil) {
        self.date = date
        self.kind = kind
        self.batteryID = batteryID
        self.value = value
    }
}

/// 一次导入，`sources` 中 `kind = import` 的一行，附带它的每日数据范围。
public struct ImportedSource: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var app: String
    public var appVersion: String?
    public var importedAt: Date
    /// 最早、最晚的一天，`YYYY-MM-DD`。没有每日数据时为 nil。
    public var firstDay: String?
    public var lastDay: String?
    public var dayCount: Int

    public init(id: Int64, app: String, appVersion: String?, importedAt: Date, firstDay: String?, lastDay: String?, dayCount: Int) {
        self.id = id
        self.app = app
        self.appVersion = appVersion
        self.importedAt = importedAt
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.dayCount = dayCount
    }
}

// MARK: - 时间戳

/// 数据库里的时间戳都是 UTC Unix 秒。
enum UnixTime {
    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    static func floor(_ date: Date, to interval: Int64) -> Int64 {
        let seconds = seconds(date)
        return seconds - ((seconds % interval) + interval) % interval
    }

    static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

// MARK: - GRDB

extension MinuteSample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "minute_samples"

    public init(row: Row) throws {
        self.init(
            timestamp: UnixTime.date(row["ts"]),
            percent: row["percent"],
            isExternalPower: row["is_external"],
            isCharging: row["is_charging"],
            systemLoadMW: row["system_load_mw"],
            batteryPowerMW: row["battery_power_mw"],
            powerInMW: row["power_in_mw"],
            temperatureCelsius: row["temperature_c"],
            voltageMV: row["voltage_mv"],
            amperageMA: row["amperage_ma"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["ts"] = UnixTime.seconds(timestamp)
        container["percent"] = percent
        container["is_external"] = isExternalPower
        container["is_charging"] = isCharging
        container["system_load_mw"] = systemLoadMW
        container["battery_power_mw"] = batteryPowerMW
        container["power_in_mw"] = powerInMW
        container["temperature_c"] = temperatureCelsius
        container["voltage_mv"] = voltageMV
        container["amperage_ma"] = amperageMA
    }
}

extension HourlySample: FetchableRecord {
    public init(row: Row) throws {
        func summary<Value: DatabaseValueConvertible & Sendable & Equatable>(_ prefix: String, _ unit: String) -> Summary<Value> {
            Summary(average: row["\(prefix)_avg\(unit)"], min: row["\(prefix)_min\(unit)"], max: row["\(prefix)_max\(unit)"])
        }
        self.init(
            hour: UnixTime.date(row["hour_ts"]),
            sampleCount: row["sample_count"],
            externalMinutes: row["external_minutes"],
            chargingMinutes: row["charging_minutes"],
            percent: summary("percent", ""),
            systemLoadMW: summary("system_load", "_mw"),
            batteryPowerMW: summary("battery_power", "_mw"),
            powerInMW: summary("power_in", "_mw"),
            temperatureCelsius: summary("temperature", "_c"),
            voltageMV: summary("voltage", "_mv"),
            amperageMA: summary("amperage", "_ma")
        )
    }
}

extension HourlyAverage: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            hour: UnixTime.date(row["hour_ts"]),
            sampleCount: row["sample_count"],
            externalMinutes: row["external_minutes"],
            percent: row["percent_avg"],
            systemLoadMW: row["system_load_avg_mw"],
            batteryPowerMW: row["battery_power_avg_mw"],
            powerInMW: row["power_in_avg_mw"],
            temperatureCelsius: row["temperature_avg_c"],
            voltageMV: row["voltage_avg_mv"]
        )
    }
}
