import Foundation
import GRDB

public struct AlDenteImportResult: Sendable {
    public let identifier: String
    public let addedRecords: Int
    public let existingRecords: Int
}

extension HistoryStore {
    /// 原始档案和应用历史在同一事务中提交，导入后由现有历史查询统一读取。
    public func importAlDenteArchive(_ archive: AlDenteArchive) async throws -> AlDenteImportResult {
        try await dbQueue.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM aldente_imports WHERE id = ?)",
                                 arguments: [archive.identifier]) == true {
                return AlDenteImportResult(identifier: archive.identifier, addedRecords: 0,
                                           existingRecords: archive.recordCount)
            }
            try db.execute(sql: """
                INSERT INTO aldente_imports (id, imported_at, source_version, source_build, record_count, archive)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [archive.identifier, Date().timeIntervalSince1970,
                                  archive.sourceVersion, archive.sourceBuild, archive.recordCount, archive.data])
            let insertRecord = try db.makeStatement(sql: """
                INSERT INTO aldente_records (id, source_table, source_id, timestamp, value_type, value)
                VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
                """)
            let insertMembership = try db.makeStatement(sql: """
                INSERT INTO aldente_import_records (import_id, record_id) VALUES (?, ?)
                """)
            var added = 0
            let formatter = Self.historyTimestampFormatter()
            for record in archive.records {
                try Task.checkCancellation()
                try insertRecord.execute(arguments: [record.identifier, record.table.rawValue,
                    record.sourceID, record.timestamp, record.table.valueType, record.value])
                added += db.changesCount
                try insertMembership.execute(arguments: [archive.identifier, record.identifier])
                try Self.insertHistoryRecord(record, in: db, formatter: formatter)
            }
            // 按表逐字段核对，包括浮点位模式；失败则连同完整文件一起回滚。
            let expected = Dictionary(uniqueKeysWithValues: archive.records.map { ($0.identifier, $0) })
            for table in archive.tables {
                let stored = try Row.fetchAll(db, sql: """
                    SELECT r.* FROM aldente_import_records AS m
                    JOIN aldente_records AS r ON r.id = m.record_id
                    WHERE m.import_id = ? AND r.source_table = ?
                    """, arguments: [archive.identifier, table.table.rawValue])
                guard stored.count == table.recordCount else { throw AlDenteArchiveError.verificationFailed }
                for row in stored {
                    guard let record = expected[row["id"] as String],
                          row["source_table"] as String == record.table.rawValue,
                          row["source_id"] as Int64 == record.sourceID,
                          row["timestamp"] as String == record.timestamp,
                          row["value_type"] as String == record.table.valueType,
                          row["value"] as Data == record.value
                    else { throw AlDenteArchiveError.verificationFailed }
                }
            }
            return AlDenteImportResult(identifier: archive.identifier, addedRecords: added,
                                       existingRecords: archive.recordCount - added)
        }
    }

    /// 取回完整原始文件，用于核对及后续的数据转换，不重新编码。
    public func alDenteArchiveData(identifier: String) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT archive FROM aldente_imports WHERE id = ?", arguments: [identifier])
        }
    }
}
