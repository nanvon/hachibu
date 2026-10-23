import Foundation
import GRDB

public struct AlDenteImportSummary: Sendable, Identifiable {
    public let id: String
    public let importedAt: Date
    public let sourceVersion: String
    public let sourceBuild: String
    public let recordCount: Int
}

/// 来源值不换算单位；整数和浮点从导入时保存的位模式还原。
public typealias AlDenteValue = HistoryValue

public struct AlDenteHistoryRecord: Sendable, Identifiable {
    public let id: String
    public let sourceID: Int64
    public let timestamp: String
    public let value: AlDenteValue
}

public struct AlDenteRecordPage: Sendable {
    public let records: [AlDenteHistoryRecord]
    public let totalCount: Int
    public let offset: Int
    public let limit: Int
}

public enum AlDenteHistoryError: Error {
    case archiveNotFound, invalidStoredRecord
}

extension HistoryStore {
    /// 只读取批次元数据，不加载完整 JSON。
    public func alDenteImports() async throws -> [AlDenteImportSummary] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, imported_at, source_version, source_build, record_count
                FROM aldente_imports ORDER BY imported_at DESC, id
                """).map { row in
                    AlDenteImportSummary(id: row["id"],
                        importedAt: Date(timeIntervalSince1970: row["imported_at"]),
                        sourceVersion: row["source_version"], sourceBuild: row["source_build"],
                        recordCount: row["record_count"])
                }
        }
    }

    /// 按批次统计全部 13 张表，包括空表；时间范围保持来源字符串。
    public func alDenteTableSummaries(importIdentifier: String) async throws -> [AlDenteTableSummary] {
        try await dbQueue.read { db in
            try Self.requireAlDenteImport(importIdentifier, in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.source_table, COUNT(*) AS record_count,
                    MIN(r.timestamp COLLATE BINARY) AS first_timestamp,
                    MAX(r.timestamp COLLATE BINARY) AS last_timestamp
                FROM aldente_import_records AS m JOIN aldente_records AS r ON r.id = m.record_id
                WHERE m.import_id = ? GROUP BY r.source_table
                """, arguments: [importIdentifier])
            let summaries = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["source_table"] as String, row)
            })
            return AlDenteTable.allCases.map { table in
                let row = summaries[table.rawValue]
                return AlDenteTableSummary(table: table, recordCount: row?["record_count"] ?? 0,
                    firstTimestamp: row?["first_timestamp"], lastTimestamp: row?["last_timestamp"])
            }
        }
    }

    /// 原始时间字符串倒序，同时间按来源 ID、记录摘要排序，保证翻页稳定。
    /// offset 最小为 0；limit 限制在 1...500，避免一次加载全部记录。
    public func alDenteRecordPage(
        importIdentifier: String, table: AlDenteTable, offset: Int = 0, limit: Int = 200
    ) async throws -> AlDenteRecordPage {
        let offset = max(0, offset)
        let limit = min(500, max(1, limit))
        return try await dbQueue.read { db in
            try Self.requireAlDenteImport(importIdentifier, in: db)
            let arguments: StatementArguments = [importIdentifier, table.rawValue]
            let source = """
                FROM aldente_import_records AS m JOIN aldente_records AS r ON r.id = m.record_id
                WHERE m.import_id = ? AND r.source_table = ?
                """
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(source)", arguments: arguments) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.source_id, r.timestamp, r.value_type, r.value \(source)
                ORDER BY r.timestamp COLLATE BINARY DESC, r.source_id DESC, r.id
                LIMIT ? OFFSET ?
                """, arguments: arguments + [limit, offset])
            let records = try Self.decodeAlDenteRecords(rows, table: table)
            return AlDenteRecordPage(records: records, totalCount: count, offset: offset, limit: limit)
        }
    }

    /// 曲线读取所选批次的一张来源表，不受明细分页限制，不修改或聚合原始值。
    public func alDenteRecords(importIdentifier: String, table: AlDenteTable) async throws -> [AlDenteHistoryRecord] {
        try await dbQueue.read { db in
            try Self.requireAlDenteImport(importIdentifier, in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.source_id, r.timestamp, r.value_type, r.value
                FROM aldente_import_records AS m JOIN aldente_records AS r ON r.id = m.record_id
                WHERE m.import_id = ? AND r.source_table = ?
                ORDER BY r.timestamp COLLATE BINARY, r.source_id, r.id
                """, arguments: [importIdentifier, table.rawValue])
            return try Self.decodeAlDenteRecords(rows, table: table)
        }
    }

    private static func decodeAlDenteRecords(_ rows: [Row], table: AlDenteTable) throws -> [AlDenteHistoryRecord] {
        try rows.map { row in
            let data: Data = row["value"]
            let value: AlDenteValue
            guard row["value_type"] as String == table.valueType else {
                throw AlDenteHistoryError.invalidStoredRecord
            }
            switch table.valueType {
            case "TEXT":
                guard let text = String(data: data, encoding: .utf8) else {
                    throw AlDenteHistoryError.invalidStoredRecord
                }
                value = .text(text)
            default:
                guard data.count == 8 else { throw AlDenteHistoryError.invalidStoredRecord }
                let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if table.valueType == "INTEGER" {
                    value = .integer(Int64(bitPattern: bits))
                } else {
                    let number = Double(bitPattern: bits)
                    guard number.isFinite else { throw AlDenteHistoryError.invalidStoredRecord }
                    value = .real(number)
                }
            }
            return AlDenteHistoryRecord(id: row["id"], sourceID: row["source_id"],
                timestamp: row["timestamp"], value: value)
        }
    }

    private static func requireAlDenteImport(_ identifier: String, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM aldente_imports WHERE id = ?)",
                                arguments: [identifier]) == true else {
            throw AlDenteHistoryError.archiveNotFound
        }
    }
}
