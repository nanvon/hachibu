import Foundation
import GRDB

/// 应用自己的历史指标；导入格式只在导入边界映射到这些指标。
public enum HistoryMetric: String, CaseIterable, Sendable {
    case percent, temperature, cycleCount, fullChargeCapacity, designCapacity, maximumCapacity
    case chargeLimit, batteryPower, systemPower, inputPower, calibration, condition, batteryIdentifier

    init(_ table: AlDenteTable) {
        switch table {
        case .batteryPercentage: self = .percent
        case .batteryTemp: self = .temperature
        case .batteryCycles: self = .cycleCount
        case .batteryMaxCap: self = .fullChargeCapacity
        case .batteryDesignCap: self = .designCapacity
        case .macOSbatteryMaxCap: self = .maximumCapacity
        case .chargeLimit: self = .chargeLimit
        case .chargingPower: self = .batteryPower
        case .systemLoad: self = .systemPower
        case .systemPowerIn: self = .inputPower
        case .lastCalibration: self = .calibration
        case .macOSbatteryCondition: self = .condition
        case .batterySerial: self = .batteryIdentifier
        }
    }
}

public enum HistoryValue: Sendable, Equatable {
    case integer(Int64), real(Double), text(String)

    public var description: String {
        switch self {
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .text(let value): String(reflecting: value)
        }
    }

    var integer: Int? {
        guard case .integer(let value) = self else { return nil }
        return Int(exactly: value)
    }

    var number: Double? {
        switch self {
        case .integer(let value): Double(exactly: value)
        case .real(let value): value
        case .text: nil
        }
    }
}

public struct HistoryRecord: Sendable, Identifiable {
    public let id: String
    public let metric: HistoryMetric
    public let date: Date?
    public let originalTimestamp: String
    public let value: HistoryValue
    public let unit: String?

    public var isUnitUnverified: Bool {
        unit == nil && [.batteryPower, .systemPower, .inputPower].contains(metric)
    }
}

public struct HistoryRecordPage: Sendable {
    public let records: [HistoryRecord]
    public let totalCount: Int
    public let offset: Int
    public let limit: Int
}

extension HistoryStore {
    static func historyTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.isLenient = false
        return formatter
    }

    static func insertHistoryRecord(_ record: AlDenteRecord, in db: Database, formatter: DateFormatter) throws {
        let parsed = formatter.date(from: record.timestamp)
        let date = parsed.flatMap { formatter.string(from: $0) == record.timestamp ? $0 : nil }
        try db.execute(sql: """
            INSERT INTO history_records(id, metric, ts, original_timestamp, value_type, value)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
            """, arguments: [record.identifier, HistoryMetric(record.table).rawValue,
                date?.timeIntervalSince1970, record.timestamp, record.table.valueType, record.value])
    }

    public func historyRecords(metric: HistoryMetric? = nil, offset: Int = 0, limit: Int = 200) async throws -> HistoryRecordPage {
        let offset = max(0, offset)
        let limit = min(500, max(1, limit))
        return try await dbQueue.read { db in
            let filter = metric == nil ? "" : " WHERE metric = ?"
            let arguments = StatementArguments(metric.map { [$0.rawValue] } ?? [])
            let source = "FROM (\(Self.allHistoryRecordsSQL))\(filter)"
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(source)", arguments: arguments) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT * \(source)
                ORDER BY ts DESC, original_timestamp COLLATE BINARY DESC, id LIMIT ? OFFSET ?
                """, arguments: arguments + [limit, offset])
            return HistoryRecordPage(records: try Self.decodeHistoryRecords(rows), totalCount: count, offset: offset, limit: limit)
        }
    }

    static func decodeHistoryRecords(_ rows: [Row]) throws -> [HistoryRecord] {
        try rows.map { row in
            guard let metric = HistoryMetric(rawValue: row["metric"]) else { throw AlDenteHistoryError.invalidStoredRecord }
            let type: String = row["value_type"]
            let value: HistoryValue
            switch type {
            case "NATIVE_INTEGER": value = .integer(row["value"])
            case "NATIVE_REAL": value = .real(row["value"])
            case "TEXT":
                let data: Data = row["value"]
                guard let text = String(data: data, encoding: .utf8) else { throw AlDenteHistoryError.invalidStoredRecord }
                value = .text(text)
            case "INTEGER", "REAL":
                let data: Data = row["value"]
                guard data.count == 8 else { throw AlDenteHistoryError.invalidStoredRecord }
                let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if row["value_type"] as String == "INTEGER" {
                    value = .integer(Int64(bitPattern: bits))
                } else {
                    let number = Double(bitPattern: bits)
                    guard number.isFinite else { throw AlDenteHistoryError.invalidStoredRecord }
                    value = .real(number)
                }
            default: throw AlDenteHistoryError.invalidStoredRecord
            }
            let time: Double? = row["ts"]
            let unit: String?
            switch metric {
            case .percent, .maximumCapacity, .chargeLimit: unit = "%"
            case .temperature: unit = "°C"
            case .fullChargeCapacity, .designCapacity: unit = "mAh"
            case .batteryPower, .systemPower, .inputPower: unit = type.hasPrefix("NATIVE_") ? "mW" : nil
            default: unit = nil
            }
            return HistoryRecord(id: row["id"], metric: metric, date: time.map(Date.init(timeIntervalSince1970:)),
                originalTimestamp: row["original_timestamp"], value: value, unit: unit)
        }
    }

    /// 明细同样包含实时采样；只读取当前仍保存的分钟原值和每日记录，不把小时均值伪装为原始测量。
    private static var allHistoryRecordsSQL: String {
        var queries = ["SELECT id, metric, ts, original_timestamp, value_type, value FROM history_records"]
        let minuteColumns: [(HistoryMetric, String, String)] = [
            (.percent, "percent", "INTEGER"), (.temperature, "temperature_c", "REAL"),
            (.chargeLimit, "charge_limit_pct", "INTEGER"), (.systemPower, "system_load_mw", "INTEGER"),
            (.batteryPower, "battery_power_mw", "INTEGER"), (.inputPower, "power_in_mw", "INTEGER"),
        ]
        let dailyColumns: [(HistoryMetric, String, String)] = [
            (.cycleCount, "cycle_count", "INTEGER"), (.fullChargeCapacity, "full_charge_mah", "INTEGER"),
            (.designCapacity, "design_mah", "INTEGER"), (.maximumCapacity, "system_max_capacity_pct", "INTEGER"),
        ]
        for (table, time, columns) in [("minute_samples", "ts", minuteColumns), ("daily_samples", "updated_at", dailyColumns)] {
            let key = table == "minute_samples" ? "ts" : "day"
            for (metric, column, type) in columns {
                queries.append("""
                    SELECT '\(table):\(metric.rawValue):' || \(key) AS id, '\(metric.rawValue)' AS metric,
                        \(time) AS ts, strftime('%Y-%m-%dT%H:%M:%f', \(time), 'unixepoch') AS original_timestamp,
                        'NATIVE_\(type)' AS value_type, \(column) AS value
                    FROM \(table) WHERE \(column) IS NOT NULL
                    """)
            }
        }
        return queries.joined(separator: " UNION ALL ")
    }

    /// 所有指标各自按实际记录时间排序；同刻冲突按摘要稳定选择，全部原值仍保留在明细。
    static func historyRecords(in db: Database, from start: Date? = nil, to end: Date? = nil, metrics: [HistoryMetric] = []) throws -> [HistoryRecord] {
        var filters = ["ts IS NOT NULL"]
        var arguments = StatementArguments()
        if !metrics.isEmpty {
            filters.append("metric IN (\(Array(repeating: "?", count: metrics.count).joined(separator: ",")))")
            arguments += StatementArguments(metrics.map(\.rawValue))
        }
        if let start { filters.append("ts >= ?"); arguments += [start.timeIntervalSince1970] }
        if let end { filters.append("ts < ?"); arguments += [end.timeIntervalSince1970] }
        return try decodeHistoryRecords(Row.fetchAll(db, sql: """
            SELECT * FROM history_records WHERE \(filters.joined(separator: " AND ")) ORDER BY ts, id
            """, arguments: arguments))
    }

    static func mergedMinuteSamples(in db: Database, from start: Date, to end: Date) throws -> [MinuteSample] {
        let records = try historyRecords(in: db, from: start, to: end, metrics: [.percent, .temperature, .chargeLimit])
        var samples: [Int64: MinuteSample] = [:]
        for record in records {
            guard let date = record.date else { continue }
            let minute = UnixTime.floor(date, to: 60)
            switch record.metric {
            case .percent:
                guard let value = record.value.integer, record.value.number != nil else { continue }
                var sample = samples[minute] ?? MinuteSample(timestamp: date)
                sample.percent = value
                samples[minute] = sample
            case .temperature:
                guard let value = record.value.number else { continue }
                var sample = samples[minute] ?? MinuteSample(timestamp: date)
                sample.temperatureCelsius = value
                samples[minute] = sample
            case .chargeLimit:
                guard let value = record.value.integer, record.value.number != nil else { continue }
                var sample = samples[minute] ?? MinuteSample(timestamp: date)
                sample.chargeLimitPercent = value
                samples[minute] = sample
            default: break // 功率口径未确认，不换算为 mW；也不推断接电、充电状态。
            }
        }
        let native = try MinuteSample.fetchAll(db, sql: "SELECT * FROM minute_samples WHERE ts >= ? AND ts < ? ORDER BY ts",
            arguments: [UnixTime.seconds(start), UnixTime.seconds(end)])
        for var sample in native {
            let key = UnixTime.seconds(sample.timestamp)
            sample.percent = sample.percent ?? samples[key]?.percent
            sample.temperatureCelsius = sample.temperatureCelsius ?? samples[key]?.temperatureCelsius
            sample.chargeLimitPercent = sample.chargeLimitPercent ?? samples[key]?.chargeLimitPercent
            samples[key] = sample
        }
        return samples.keys.sorted().compactMap { samples[$0] }
    }

    static func mergedDailySamples(in db: Database, from firstDay: String? = nil, calendar: Calendar = .current) throws -> [DailySample] {
        var samples: [String: DailySample] = [:]
        for record in try historyRecords(in: db, metrics: [.cycleCount, .fullChargeCapacity, .designCapacity, .maximumCapacity]) {
            guard let date = record.date, let value = record.value.integer, record.value.number != nil else { continue }
            let day = DailySample.day(for: date, calendar: calendar)
            if let firstDay, day < firstDay { continue }
            var sample = samples[day] ?? DailySample(day: day, updatedAt: date)
            switch record.metric {
            case .cycleCount: sample.cycleCount = value
            case .fullChargeCapacity: sample.fullChargeCapacityMAh = value
            case .designCapacity: sample.designCapacityMAh = value
            case .maximumCapacity: sample.systemMaxCapacityPercent = value
            default: continue
            }
            sample.updatedAt = max(sample.updatedAt, date)
            samples[day] = sample
        }
        let native = try DailySample.fetchAll(db, sql: "SELECT * FROM daily_samples ORDER BY day")
        for var sample in native {
            if let firstDay, sample.day < firstDay { continue }
            if let historical = samples[sample.day] {
                sample.systemMaxCapacityPercent = sample.systemMaxCapacityPercent ?? historical.systemMaxCapacityPercent
                sample.fullChargeCapacityMAh = sample.fullChargeCapacityMAh ?? historical.fullChargeCapacityMAh
                sample.designCapacityMAh = sample.designCapacityMAh ?? historical.designCapacityMAh
                sample.cycleCount = sample.cycleCount ?? historical.cycleCount
            }
            samples[sample.day] = sample
        }
        return samples.keys.sorted().compactMap { samples[$0] }
    }
}
