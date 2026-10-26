// 历史数据导入：解析公开导入格式、排除异常值、按天取值，写入 `sources` 和 `daily_health`。
// 规则见 docs/v1技术设计.md 第 20 节。不包含界面文案。
import BatteryCore
import CryptoKit
import Foundation
import GRDB

public enum HistoryImportError: Error, Equatable, Sendable {
    /// 文件超过 `HistoryImportFile.maximumFileSize`。
    case fileTooLarge
    /// 不是 JSON，或顶层不是对象。
    case notJSON
    /// `format` 不是 `hachibu-import`。
    case unsupportedFormat
    /// `version` 不受支持。
    case unsupportedVersion
    /// 缺少 `source.app`。
    case missingSourceApp
    /// 没有一天有效的数据。
    case noValidRecords
    /// 同一个文件已经导入过。
    case alreadyImported
}

/// 解析并规范化后的导入文件，还没有写入数据库。
public struct HistoryImportFile: Sendable, Equatable {
    public static let maximumFileSize = 50 * 1024 * 1024

    public var sourceApp: String
    public var sourceVersion: String?
    /// 计算本地日期用的时区标识。
    public var timeZone: String
    var fileSHA256: String
    /// 每天一项，按日期排序。
    var days: [Day]
    /// 有效记录数（不含排除和跳过的）。
    public var recordCount: Int
    /// 被异常规则排除的记录数。
    public var excludedCount: Int
    /// 指标名未知、时间无效或值的类型不符而跳过的记录数。
    public var skippedCount: Int

    public var dayCount: Int { days.count }
    public var firstDay: String? { days.first?.day }
    public var lastDay: String? { days.last?.day }
    /// 文件里有电池序列号。没有时导入的数据不能计算容量比。
    public var hasBatterySerial: Bool { days.contains { $0.serialHash != nil } }

    struct Day: Sendable, Equatable {
        var day: String
        var fullChargeCapacityMAh: Int?
        var designCapacityMAh: Int?
        var cycleCount: Int?
        var systemMaxCapacityPercent: Int?
        var serialHash: String?
    }
}

/// 导入前给用户确认的信息。
public struct HistoryImportPreview: Sendable, Equatable {
    public var file: HistoryImportFile
    /// 与本机已有每日数据重叠的天数，这些天以本机为准。
    public var overlappingNativeDays: Int
    /// 文件里的电池与本机最近一次见到的电池不同。文件没有序列号或本机没有电池时为 false。
    public var isDifferentBattery: Bool
}

extension HistoryImportFile {
    private enum Metric: String {
        case fullChargeCapacity = "full_charge_mah"
        case designCapacity = "design_mah"
        case cycleCount = "cycle_count"
        case systemMaxCapacity = "system_max_capacity_pct"
        case batterySerial = "battery_serial"
    }

    private enum Value {
        case int(Int)
        case serialHash(String)
    }

    private struct Record {
        var metric: Metric
        var date: Date
        var value: Value
    }

    /// 解析导入文件。整个文件不符合格式时抛出 `HistoryImportError`；单条记录有问题时跳过并计数。
    public static func parse(_ data: Data, calendar: Calendar = .current) throws -> HistoryImportFile {
        guard data.count <= maximumFileSize else { throw HistoryImportError.fileTooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HistoryImportError.notJSON
        }
        guard root["format"] as? String == "hachibu-import" else { throw HistoryImportError.unsupportedFormat }
        guard integer(root["version"]) == 1 else { throw HistoryImportError.unsupportedVersion }
        let source = root["source"] as? [String: Any]
        guard let app = (source?["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            throw HistoryImportError.missingSourceApp
        }

        let dateParser = DateParser()
        var records: [Record] = []
        var skipped = 0
        for item in root["records"] as? [Any] ?? [] {
            if let record = record(item, dateParser: dateParser) {
                records.append(record)
            } else {
                skipped += 1
            }
        }

        let (valid, excluded) = excludeAnomalies(records)
        let days = normalize(valid, calendar: calendar)
        guard !days.isEmpty else { throw HistoryImportError.noValidRecords }

        return HistoryImportFile(
            sourceApp: app,
            sourceVersion: source?["version"] as? String,
            timeZone: calendar.timeZone.identifier,
            fileSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            days: days,
            recordCount: valid.count,
            excludedCount: excluded,
            skippedCount: skipped
        )
    }

    private static func record(_ item: Any, dateParser: DateParser) -> Record? {
        guard let item = item as? [String: Any],
              let metric = (item["metric"] as? String).flatMap(Metric.init),
              let date = (item["time"] as? String).flatMap(dateParser.date)
        else { return nil }
        switch metric {
        case .batterySerial:
            // 空序列号是有效类型，交给异常规则排除。
            guard let serial = item["value"] as? String else { return nil }
            return Record(metric: metric, date: date, value: .serialHash(BatterySnapshot.serialHash(serial) ?? ""))
        default:
            guard let value = integer(item["value"]) else { return nil }
            return Record(metric: metric, date: date, value: .int(value))
        }
    }

    /// 整数，或没有小数部分的数值。布尔值不算。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    /// ISO 8601，必须带 `Z` 或时区偏移，可带毫秒。
    private final class DateParser {
        private let withFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private let withoutFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func date(_ string: String) -> Date? {
            withFraction.date(from: string) ?? withoutFraction.date(from: string)
        }
    }

    /// 返回有效记录和被排除的记录数。
    private static func excludeAnomalies(_ records: [Record]) -> (valid: [Record], excluded: Int) {
        // AlDente 采集失效时，同一秒内满充容量和循环次数同为 0。
        let failedSeconds = Set(records.compactMap { record -> Int64? in
            guard record.metric == .fullChargeCapacity, case .int(let value) = record.value, value <= 0 else { return nil }
            return UnixTime.seconds(record.date)
        })
        let valid = records.filter { record in
            switch (record.metric, record.value) {
            case (.fullChargeCapacity, .int(let value)), (.designCapacity, .int(let value)):
                return value > 0
            case (.systemMaxCapacity, .int(let value)):
                return (1...100).contains(value)
            case (.cycleCount, .int(let value)):
                return value > 0 || (value == 0 && !failedSeconds.contains(UnixTime.seconds(record.date)))
            case (.batterySerial, .serialHash(let hash)):
                return !hash.isEmpty
            default:
                return false
            }
        }
        return (valid, records.count - valid.count)
    }

    /// 每天每个指标取时间最晚的值；每天归属当天或之前最近一条序列号对应的电池，早于第一条序列号的日子归属第一条。
    private static func normalize(_ records: [Record], calendar: Calendar) -> [Day] {
        var byDay: [String: Day] = [:]
        var serials: [(day: String, hash: String)] = []

        for record in records.sorted(by: { $0.date < $1.date }) {
            let day = DailyHealth.day(for: record.date, calendar: calendar)
            if case .serialHash(let hash) = record.value {
                serials.append((day, hash))
                continue
            }
            guard case .int(let value) = record.value else { continue }
            var entry = byDay[day] ?? Day(day: day)
            switch record.metric {
            case .fullChargeCapacity: entry.fullChargeCapacityMAh = value
            case .designCapacity: entry.designCapacityMAh = value
            case .cycleCount: entry.cycleCount = value
            case .systemMaxCapacity: entry.systemMaxCapacityPercent = value
            case .batterySerial: break
            }
            byDay[day] = entry
        }

        // `YYYY-MM-DD` 按字符串比较即按日期比较。
        return byDay.values.sorted { $0.day < $1.day }.map { day in
            var day = day
            day.serialHash = serials.last { $0.day <= day.day }?.hash ?? serials.first?.hash
            return day
        }
    }
}

// MARK: - 写入数据库

extension HistoryStore {
    /// 导入前的确认信息。文件已经导入过时抛出 `HistoryImportError.alreadyImported`。
    public func previewImport(_ file: HistoryImportFile) async throws -> HistoryImportPreview {
        try await dbQueue.read { db in
            try Self.checkNotImported(db, file)
            let nativeDays = try Set(String.fetchAll(
                db,
                sql: "SELECT day FROM daily_health WHERE source_id = ?",
                arguments: [Self.nativeSourceID]
            ))
            let currentSerial = try String.fetchOne(
                db,
                sql: "SELECT serial_sha256 FROM batteries ORDER BY last_seen_at DESC, id DESC LIMIT 1"
            )
            let fileSerials = Set(file.days.compactMap(\.serialHash))
            return HistoryImportPreview(
                file: file,
                overlappingNativeDays: file.days.filter { nativeDays.contains($0.day) }.count,
                isDifferentBattery: currentSerial.map { !fileSerials.isEmpty && fileSerials != [$0] } ?? false
            )
        }
    }

    /// 在一个事务里写入一个导入来源和它的每日数据，返回来源 id。
    @discardableResult
    public func importHistory(_ file: HistoryImportFile, at date: Date = Date()) async throws -> Int64 {
        try await dbQueue.write { db in
            try Self.checkNotImported(db, file)
            try db.execute(
                sql: """
                    INSERT INTO sources (kind, app, app_version, file_sha256, time_zone, imported_at)
                    VALUES ('import', ?, ?, ?, ?, ?)
                    """,
                arguments: [file.sourceApp, file.sourceVersion, file.fileSHA256, file.timeZone, UnixTime.seconds(date)]
            )
            let sourceID = db.lastInsertedRowID

            var batteryIDs: [String: Int64] = [:]
            for (hash, days) in Dictionary(grouping: file.days.filter { $0.serialHash != nil }, by: { $0.serialHash! }) {
                batteryIDs[hash] = try Self.importBattery(db, serialHash: hash, days: days)
            }

            for day in file.days {
                try db.execute(
                    sql: """
                        INSERT INTO daily_health
                            (day, source_id, battery_id, full_charge_mah, design_mah, cycle_count,
                             system_max_capacity_pct, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        day.day, sourceID, day.serialHash.flatMap { batteryIDs[$0] }, day.fullChargeCapacityMAh,
                        day.designCapacityMAh, day.cycleCount, day.systemMaxCapacityPercent, UnixTime.seconds(date),
                    ]
                )
            }
            return sourceID
        }
    }

    /// 已导入的来源，按导入先后排序。
    public func importedSources() async throws -> [ImportedSource] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id, s.app, s.app_version, s.imported_at,
                        MIN(d.day) AS first_day, MAX(d.day) AS last_day, COUNT(d.day) AS day_count
                    FROM sources s
                    LEFT JOIN daily_health d ON d.source_id = s.id
                    WHERE s.kind = 'import'
                    GROUP BY s.id
                    ORDER BY s.id
                    """
            ).map { row in
                ImportedSource(
                    id: row["id"],
                    app: row["app"],
                    appVersion: row["app_version"],
                    importedAt: UnixTime.date(row["imported_at"] ?? 0),
                    firstDay: row["first_day"],
                    lastDay: row["last_day"],
                    dayCount: row["day_count"]
                )
            }
        }
    }

    /// 删除一个导入来源和它的每日数据，再删除不再被引用的电池。本机来源不能删除。
    public func deleteImportedSource(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ? AND kind = 'import'", arguments: [id])
            try db.execute(
                sql: """
                    DELETE FROM batteries
                    WHERE id NOT IN (SELECT battery_id FROM daily_health WHERE battery_id IS NOT NULL)
                      AND id NOT IN (SELECT battery_id FROM battery_events WHERE battery_id IS NOT NULL)
                    """
            )
        }
    }

    private static func checkNotImported(_ db: Database, _ file: HistoryImportFile) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM sources WHERE file_sha256 = ?)",
            arguments: [file.fileSHA256]
        ) ?? false
        if exists {
            throw HistoryImportError.alreadyImported
        }
    }

    /// 按哈希查找或新建电池。电池没有设计容量时，用归属它的最后一个设计容量；见到的时间范围扩展到这些日子。
    private static func importBattery(_ db: Database, serialHash: String, days: [HistoryImportFile.Day]) throws -> Int64 {
        let design = days.last { $0.designCapacityMAh != nil }?.designCapacityMAh
        let dayStarts = days.compactMap { Self.startOfDay($0.day) }
        let firstSeen = UnixTime.seconds(dayStarts.min() ?? Date())
        let lastSeen = UnixTime.seconds(dayStarts.max() ?? Date())
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM batteries WHERE serial_sha256 = ?", arguments: [serialHash]) {
            try db.execute(
                sql: """
                    UPDATE batteries SET
                        design_mah = COALESCE(design_mah, ?),
                        first_seen_at = MIN(first_seen_at, ?),
                        last_seen_at = MAX(last_seen_at, ?)
                    WHERE id = ?
                    """,
                arguments: [design, firstSeen, lastSeen, id]
            )
            return id
        }
        try db.execute(
            sql: "INSERT INTO batteries (serial_sha256, design_mah, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?)",
            arguments: [serialHash, design, firstSeen, lastSeen]
        )
        return db.lastInsertedRowID
    }

    /// `YYYY-MM-DD` 在 UTC 的 0 点，只用来记电池见到的大致时间。
    private static func startOfDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
