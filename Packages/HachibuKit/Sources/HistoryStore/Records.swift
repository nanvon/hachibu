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
/// 平均值、最大值只统计非 NULL 的样本，全部为 NULL 时为 nil。
public struct HourlySample: Sendable, Equatable {
    /// 小时起点。
    public var hour: Date
    public var sampleCount: Int
    /// 该小时内接电的分钟数。
    public var externalMinutes: Int
    public var percentAverage: Double?
    public var percentMin: Int?
    public var percentMax: Int?
    public var systemLoadAverageMW: Double?
    public var systemLoadMaxMW: Int?
    public var temperatureAverageCelsius: Double?
    public var temperatureMaxCelsius: Double?

    public init(
        hour: Date,
        sampleCount: Int,
        externalMinutes: Int,
        percentAverage: Double? = nil,
        percentMin: Int? = nil,
        percentMax: Int? = nil,
        systemLoadAverageMW: Double? = nil,
        systemLoadMaxMW: Int? = nil,
        temperatureAverageCelsius: Double? = nil,
        temperatureMaxCelsius: Double? = nil
    ) {
        self.hour = hour
        self.sampleCount = sampleCount
        self.externalMinutes = externalMinutes
        self.percentAverage = percentAverage
        self.percentMin = percentMin
        self.percentMax = percentMax
        self.systemLoadAverageMW = systemLoadAverageMW
        self.systemLoadMaxMW = systemLoadMaxMW
        self.temperatureAverageCelsius = temperatureAverageCelsius
        self.temperatureMaxCelsius = temperatureMaxCelsius
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

/// `daily_samples` 的一行，按本地日期 upsert，一天保留最后的值。
public struct DailySample: Sendable, Equatable {
    /// 本地日期 `YYYY-MM-DD`。
    public var day: String
    /// 系统最大容量（%），来自 `system_profiler`。
    public var systemMaxCapacityPercent: Int?
    public var fullChargeCapacityMAh: Int?
    public var designCapacityMAh: Int?
    public var cycleCount: Int?
    public var updatedAt: Date

    public init(
        day: String,
        systemMaxCapacityPercent: Int? = nil,
        fullChargeCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        cycleCount: Int? = nil,
        updatedAt: Date
    ) {
        self.day = day
        self.systemMaxCapacityPercent = systemMaxCapacityPercent
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.cycleCount = cycleCount
        self.updatedAt = updatedAt
    }

    /// 系统最大容量来自 `system_profiler`，满充容量、设计容量、循环次数来自当时的 IORegistry 读数。
    public init(date: Date, health: BatteryHealthInfo, snapshot: BatterySnapshot, calendar: Calendar = .current) {
        self.init(
            day: Self.day(for: date, calendar: calendar),
            systemMaxCapacityPercent: health.systemMaximumCapacityPercent,
            fullChargeCapacityMAh: snapshot.fullChargeCapacityMAh,
            designCapacityMAh: snapshot.designCapacityMAh,
            cycleCount: snapshot.cycleCount,
            updatedAt: date
        )
    }

    /// 按 `calendar` 的时区取本地日期，格式 `YYYY-MM-DD`。
    public static func day(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
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

extension HourlySample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hourly_samples"

    public init(row: Row) throws {
        self.init(
            hour: UnixTime.date(row["hour_ts"]),
            sampleCount: row["sample_count"],
            externalMinutes: row["external_minutes"],
            percentAverage: row["percent_avg"],
            percentMin: row["percent_min"],
            percentMax: row["percent_max"],
            systemLoadAverageMW: row["system_load_avg_mw"],
            systemLoadMaxMW: row["system_load_max_mw"],
            temperatureAverageCelsius: row["temperature_avg_c"],
            temperatureMaxCelsius: row["temperature_max_c"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["hour_ts"] = UnixTime.seconds(hour)
        container["sample_count"] = sampleCount
        container["external_minutes"] = externalMinutes
        container["percent_avg"] = percentAverage
        container["percent_min"] = percentMin
        container["percent_max"] = percentMax
        container["system_load_avg_mw"] = systemLoadAverageMW
        container["system_load_max_mw"] = systemLoadMaxMW
        container["temperature_avg_c"] = temperatureAverageCelsius
        container["temperature_max_c"] = temperatureMaxCelsius
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

extension DailySample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "daily_samples"

    public init(row: Row) throws {
        self.init(
            day: row["day"],
            systemMaxCapacityPercent: row["system_max_capacity_pct"],
            fullChargeCapacityMAh: row["full_charge_mah"],
            designCapacityMAh: row["design_mah"],
            cycleCount: row["cycle_count"],
            updatedAt: UnixTime.date(row["updated_at"])
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["day"] = day
        container["system_max_capacity_pct"] = systemMaxCapacityPercent
        container["full_charge_mah"] = fullChargeCapacityMAh
        container["design_mah"] = designCapacityMAh
        container["cycle_count"] = cycleCount
        container["updated_at"] = UnixTime.seconds(updatedAt)
    }
}
