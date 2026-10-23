import Foundation
import GRDB
import Testing
@testable import HistoryStore

func archiveFixture(edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var tables: [String: Any] = [:]
    var schema: [[String: Any]] = []
    for table in AlDenteTable.allCases {
        let columnNames = ["id", "timestamp", "value"]
        let columnTypes = ["INTEGER", "TEXT", table.valueType]
        let columns: [[String: Any]] = columnNames.indices.map { index in
            ["position": index, "name": columnNames[index], "type": columnTypes[index],
             "notNull": 1, "default": NSNull(), "primaryKey": index == 0 ? 1 : 0]
        }
        let value: Any
        switch table.valueType {
        case "TEXT": value = table == .batterySerial ? "fixture-device" : ""
        case "REAL": value = -1.5
        default: value = 0
        }
        tables[table.rawValue] = [
            "columns": columns, "rowCount": 1,
            "rows": [["id": 1, "timestamp": "2026-10-22T08:13:43.766", "value": value]],
        ]
        // 源 SQL 永远不执行，即使内容是破坏性语句。
        schema.append(["type": "table", "name": table.rawValue, "table": table.rawValue,
                       "sql": "DROP TABLE daily_samples"])
    }
    var root: [String: Any] = [
        "format": "hachibu.aldente.raw", "formatVersion": 1,
        "source": ["app": "AlDente", "bundleIdentifier": "com.apphousekitchen.aldente-pro",
                   "version": "1.39.3", "build": "111"],
        "schema": schema, "tables": tables,
    ]
    edit(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

func editTable(_ root: inout [String: Any], _ name: String, edit: (inout [String: Any]) -> Void) {
    var tables = root["tables"] as! [String: [String: Any]]
    var table = tables[name]!
    edit(&table)
    tables[name] = table
    root["tables"] = tables
}

@Suite struct AlDenteArchiveTests {
    @Test func preservesAllTablesAndRawValues() throws {
        let archive = try AlDenteArchive(data: archiveFixture())
        #expect(archive.tables.count == 13)
        #expect(archive.recordCount == 13)
        #expect(archive.records.allSatisfy { $0.timestamp == "2026-10-22T08:13:43.766" })
        let cycle = try #require(archive.records.first { $0.table == .batteryCycles })
        #expect(cycle.value == Data(repeating: 0, count: 8))
        let condition = try #require(archive.records.first { $0.table == .macOSbatteryCondition })
        #expect(condition.value.isEmpty)
        let power = try #require(archive.records.first { $0.table == .chargingPower })
        #expect(power.value == Data([0xbf, 0xf8, 0, 0, 0, 0, 0, 0]))
    }

    @Test func rejectsMissingTables() throws {
        let data = try archiveFixture { root in
            var tables = root["tables"] as! [String: Any]
            tables.removeValue(forKey: "batterySerial")
            root["tables"] = tables
        }
        #expect(throws: AlDenteArchiveError.incompleteTables) { try AlDenteArchive(data: data) }
    }

    @Test func rejectsMismatchedCountsAndDuplicateIDs() throws {
        let wrongCount = try archiveFixture { root in
            editTable(&root, "batteryCycles") { $0["rowCount"] = 2 }
        }
        #expect(throws: AlDenteArchiveError.invalidTable("batteryCycles")) {
            try AlDenteArchive(data: wrongCount)
        }
        let duplicates = try archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                let rows = table["rows"] as! [[String: Any]]
                table["rows"] = rows + rows
                table["rowCount"] = 2
            }
        }
        #expect(throws: AlDenteArchiveError.invalidTable("batteryCycles")) {
            try AlDenteArchive(data: duplicates)
        }
    }

    @Test(arguments: ["batteryCycles", "chargingPower"])
    func rejectsBooleanValues(_ name: String) throws {
        let data = try archiveFixture { root in
            editTable(&root, name) { table in
                var rows = table["rows"] as! [[String: Any]]
                rows[0]["value"] = true
                table["rows"] = rows
            }
        }
        #expect(throws: AlDenteArchiveError.invalidTable(name)) { try AlDenteArchive(data: data) }
    }

    @Test func rejectsWrongColumnType() throws {
        let data = try archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                var columns = table["columns"] as! [[String: Any]]
                columns[2]["type"] = "REAL"
                table["columns"] = columns
            }
        }
        #expect(throws: AlDenteArchiveError.invalidTable("batteryCycles")) {
            try AlDenteArchive(data: data)
        }
    }

    @Test func rejectsMalformedAndUnsupportedFiles() throws {
        #expect(throws: AlDenteArchiveError.invalidJSON) { try AlDenteArchive(data: Data("{".utf8)) }
        let version = try archiveFixture { $0["formatVersion"] = 2 }
        #expect(throws: AlDenteArchiveError.unsupportedVersion) { try AlDenteArchive(data: version) }
        let source = try archiveFixture { $0["source"] = [:] }
        #expect(throws: AlDenteArchiveError.invalidSource) { try AlDenteArchive(data: source) }
    }
}

@Suite struct AlDenteImportTests {
    @Test func storesOriginalFileAndEveryRecordWithoutChangingNativeSamples() async throws {
        let store = try HistoryStore.inMemory()
        let native = DailySample(day: "2026-10-22", systemMaxCapacityPercent: 98,
                                 fullChargeCapacityMAh: 9000, designCapacityMAh: 9500,
                                 cycleCount: 3, updatedAt: Date(timeIntervalSince1970: 1_000))
        try await store.write(native)
        let data = try archiveFixture()
        let archive = try AlDenteArchive(data: data)
        let result = try await store.importAlDenteArchive(archive)
        #expect(result.addedRecords == 13)
        #expect(result.existingRecords == 0)
        #expect(try await store.alDenteArchiveData(identifier: result.identifier) == data)
        #expect(try await store.dailySamples() == [native])
        try await verifyEveryRecord(archive, in: store)
    }

    @Test func deduplicatesRepeatedAndOverlappingExports() async throws {
        let store = try HistoryStore.inMemory()
        let archive = try AlDenteArchive(data: archiveFixture())
        _ = try await store.importAlDenteArchive(archive)
        let repeated = try await store.importAlDenteArchive(archive)
        #expect(repeated.addedRecords == 0)
        #expect(repeated.existingRecords == 13)
        let changed = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                var rows = table["rows"] as! [[String: Any]]
                // 循环 ID 相同而时间不同，必须保留成新记录。
                rows[0]["timestamp"] = "2026-10-23T08:13:43.766"
                table["rows"] = rows
            }
        })
        let overlap = try await store.importAlDenteArchive(changed)
        #expect(overlap.addedRecords == 1)
        #expect(overlap.existingRecords == 12)
        try await verifyEveryRecord(changed, in: store)
        #expect(try await store.alDenteArchiveData(identifier: archive.identifier) == archive.data)
    }

    @Test func retainsChangedValuesAtTheSameIDAndTime() async throws {
        let store = try HistoryStore.inMemory()
        _ = try await store.importAlDenteArchive(AlDenteArchive(data: archiveFixture()))
        let changed = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                var rows = table["rows"] as! [[String: Any]]
                rows[0]["value"] = 1
                table["rows"] = rows
            }
        })
        #expect(try await store.importAlDenteArchive(changed).addedRecords == 1)
        try await verifyEveryRecord(changed, in: store)
    }

    @Test func failureRollsBackArchiveRecordsAndMemberships() async throws {
        let store = try HistoryStore.inMemory()
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_import BEFORE INSERT ON aldente_records
                WHEN NEW.source_table = 'batterySerial'
                BEGIN SELECT RAISE(ABORT, 'injected import failure'); END
                """)
        }
        let archive = try AlDenteArchive(data: archiveFixture())
        await #expect(throws: (any Error).self) { try await store.importAlDenteArchive(archive) }
        let counts = try await store.dbQueue.read { db in
            try ["aldente_imports", "aldente_records", "aldente_import_records"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")
            }
        }
        #expect(counts == [0, 0, 0])
    }

    @Test func upgradesV1WithoutChangingNativeData() throws {
        let queue = try DatabaseQueue()
        try HistoryStore.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO minute_samples(ts, percent) VALUES (60, 80)")
        }
        try HistoryStore.migrator.migrate(queue)
        let value = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT percent FROM minute_samples WHERE ts=60")
        }
        #expect(value == 80)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_ALDENTE_VALIDATION_FILE"] != nil))
    func fullLocalExportRoundTrips() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HACHIBU_ALDENTE_VALIDATION_FILE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let archive = try AlDenteArchive(data: data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlDenteImportTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(fileURL: url)
        let result = try await store.importAlDenteArchive(archive)
        #expect(result.addedRecords == archive.recordCount)
        #expect(archive.tables.count == 13)
        let reopened = try HistoryStore(fileURL: url)
        #expect(try await reopened.alDenteArchiveData(identifier: archive.identifier) == data)
        try await verifyEveryRecord(archive, in: reopened)
        let batches = try await reopened.alDenteImports()
        #expect(batches.map(\.id) == [archive.identifier])
        let summaries = try await reopened.alDenteTableSummaries(importIdentifier: archive.identifier)
        #expect(summaries.map(\.recordCount) == archive.tables.map(\.recordCount))
        for table in archive.tables {
            var offset = 0
            var actual: [AlDenteHistoryRecord] = []
            repeat {
                let page = try await reopened.alDenteRecordPage(importIdentifier: archive.identifier,
                    table: table.table, offset: offset, limit: 500)
                actual += page.records
                offset += page.limit
            } while offset < table.recordCount
            let expected = Dictionary(uniqueKeysWithValues: archive.records.filter { $0.table == table.table }
                .map { ($0.identifier, $0) })
            #expect(Set(actual.map(\.id)) == Set(expected.keys))
            for record in actual {
                let source = try #require(expected[record.id])
                #expect(record.sourceID == source.sourceID)
                #expect(record.timestamp == source.timestamp)
                switch record.value {
                case .integer(let value): #expect(AlDenteArchive.bytes(UInt64(bitPattern: value)) == source.value)
                case .real(let value): #expect(AlDenteArchive.bytes(value.bitPattern) == source.value)
                case .text(let value): #expect(Data(value.utf8) == source.value)
                }
            }
        }
        #expect(try await reopened.importAlDenteArchive(archive).existingRecords == archive.recordCount)
    }
}

@Suite struct AlDenteHistoryTests {
    @Test func listsBatchMetadataAndEmptyTables() async throws {
        let store = try HistoryStore.inMemory()
        #expect(try await store.alDenteImports().isEmpty)
        let archive = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                table["rows"] = [] as [[String: Any]]
                table["rowCount"] = 0
            }
        })
        _ = try await store.importAlDenteArchive(archive)
        let batch = try #require(try await store.alDenteImports().first)
        #expect(batch.id == archive.identifier)
        #expect(batch.sourceVersion == "1.39.3")
        #expect(batch.sourceBuild == "111")
        #expect(batch.recordCount == 12)
        let tables = try await store.alDenteTableSummaries(importIdentifier: batch.id)
        #expect(tables.count == 13)
        #expect(tables.first?.recordCount == 0)
        #expect(tables.first?.firstTimestamp == nil)
        let page = try await store.alDenteRecordPage(importIdentifier: batch.id, table: .batteryCycles)
        #expect(page.totalCount == 0)
        #expect(page.records.isEmpty)
    }

    @Test func pagesStablyAndIsolatesBatches() async throws {
        let store = try HistoryStore.inMemory()
        let original = try AlDenteArchive(data: archiveFixture())
        _ = try await store.importAlDenteArchive(original)
        let large = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                table["rows"] = (1...503).map { id in
                    ["id": id, "timestamp": id == 1 ? "2027-01-01T00:00:00.000" : "2026-10-22T08:13:43.766",
                     "value": id] as [String: Any]
                }
                table["rowCount"] = 503
            }
        })
        _ = try await store.importAlDenteArchive(large)
        let first = try await store.alDenteRecordPage(importIdentifier: large.identifier,
            table: .batteryCycles, offset: -10, limit: 1000)
        let last = try await store.alDenteRecordPage(importIdentifier: large.identifier,
            table: .batteryCycles, offset: 500, limit: 500)
        #expect(first.limit == 500)
        #expect(first.offset == 0)
        #expect(first.totalCount == 503)
        #expect(first.records.first?.sourceID == 1) // 最新时间优先，ID 不表示先后。
        #expect(first.records.dropFirst().first?.sourceID == 503)
        let all = try await store.alDenteRecords(importIdentifier: large.identifier, table: .batteryCycles)
        #expect(all.count == 503)
        #expect(all.last?.sourceID == 1)
        #expect(last.records.map(\.sourceID) == [4, 3, 2])
        #expect(Set((first.records + last.records).map(\.id)).count == 503)
        let old = try await store.alDenteRecordPage(importIdentifier: original.identifier, table: .batteryCycles)
        #expect(old.totalCount == 1)
        #expect(old.records.first?.value == .integer(0))
        #expect(try await store.alDenteRecords(importIdentifier: original.identifier, table: .batteryCycles).count == 1)
        let bounded = try await store.alDenteRecordPage(importIdentifier: large.identifier, table: .batteryCycles, limit: 0)
        #expect(bounded.limit == 1)
    }

    @Test func decodesExactValuesAndRejectsCorruption() async throws {
        let store = try HistoryStore.inMemory()
        let archive = try AlDenteArchive(data: archiveFixture { root in
            editTable(&root, "batteryCycles") { table in
                table["rows"] = [
                    ["id": 1, "timestamp": "a", "value": Int64.min],
                    ["id": 2, "timestamp": "b", "value": Int64.max],
                ] as [[String: Any]]
                table["rowCount"] = 2
            }
        })
        _ = try await store.importAlDenteArchive(archive)
        let integers = try await store.alDenteRecordPage(importIdentifier: archive.identifier, table: .batteryCycles)
        #expect(integers.records.map(\.value) == [.integer(Int64.max), .integer(Int64.min)])
        let real = try await store.alDenteRecordPage(importIdentifier: archive.identifier, table: .chargingPower)
        #expect(real.records.first?.value == .real(-1.5))
        let text = try await store.alDenteRecordPage(importIdentifier: archive.identifier, table: .macOSbatteryCondition)
        #expect(text.records.first?.value == .text(""))
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE aldente_records SET value = ? WHERE source_table = ?",
                           arguments: [Data([0]), "chargingPower"])
        }
        await #expect(throws: AlDenteHistoryError.self) {
            try await store.alDenteRecordPage(importIdentifier: archive.identifier, table: .chargingPower)
        }
        #expect(try await store.alDenteArchiveData(identifier: archive.identifier) == archive.data)
    }

    @Test func rejectsMissingBatch() async throws {
        let store = try HistoryStore.inMemory()
        await #expect(throws: AlDenteHistoryError.self) {
            try await store.alDenteTableSummaries(importIdentifier: "missing")
        }
        await #expect(throws: AlDenteHistoryError.self) {
            try await store.alDenteRecordPage(importIdentifier: "missing", table: .batteryCycles)
        }
        await #expect(throws: AlDenteHistoryError.self) {
            try await store.alDenteRecords(importIdentifier: "missing", table: .batteryCycles)
        }
    }
}

private func verifyEveryRecord(_ archive: AlDenteArchive, in store: HistoryStore) async throws {
    let actual = try await store.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT r.* FROM aldente_records AS r
            JOIN aldente_import_records AS m ON m.record_id = r.id WHERE m.import_id = ?
            ORDER BY r.id
            """, arguments: [archive.identifier]).map { row in
                AlDenteRecord(table: AlDenteTable(rawValue: row["source_table"])!,
                              sourceID: row["source_id"], timestamp: row["timestamp"], value: row["value"])
            }
    }
    #expect(actual == archive.records.sorted { $0.identifier < $1.identifier })
}
