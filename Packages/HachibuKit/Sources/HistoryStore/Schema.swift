import GRDB

extension HistoryStore {
    /// 已发布的迁移只追加，不修改。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "minute_samples") { t in
                t.primaryKey("ts", .integer)
                t.column("percent", .integer)
                t.column("is_external", .integer)
                t.column("is_charging", .integer)
                t.column("system_load_mw", .integer)
                t.column("battery_power_mw", .integer)
                t.column("power_in_mw", .integer)
                t.column("temperature_c", .double)
                t.column("voltage_mv", .integer)
                t.column("amperage_ma", .integer)
            }

            try db.create(table: "hourly_samples") { t in
                t.primaryKey("hour_ts", .integer)
                t.column("sample_count", .integer).notNull()
                t.column("external_minutes", .integer).notNull()
                t.column("percent_avg", .double)
                t.column("percent_min", .integer)
                t.column("percent_max", .integer)
                t.column("system_load_avg_mw", .double)
                t.column("system_load_max_mw", .integer)
                t.column("temperature_avg_c", .double)
                t.column("temperature_max_c", .double)
            }

            try db.create(table: "daily_samples") { t in
                t.primaryKey("day", .text)
                t.column("system_max_capacity_pct", .integer)
                t.column("full_charge_mah", .integer)
                t.column("design_mah", .integer)
                t.column("cycle_count", .integer)
                t.column("updated_at", .integer).notNull()
            }
        }

        migrator.registerMigration("aldenteRawImports") { db in
            try db.create(table: "aldente_imports") { t in
                t.primaryKey("id", .text)
                t.column("imported_at", .double).notNull()
                t.column("source_version", .text).notNull()
                t.column("source_build", .text).notNull()
                t.column("record_count", .integer).notNull()
                t.column("archive", .blob).notNull()
            }
            try db.create(table: "aldente_records") { t in
                t.primaryKey("id", .text)
                t.column("source_table", .text).notNull().indexed()
                t.column("source_id", .integer).notNull()
                t.column("timestamp", .text).notNull()
                t.column("value_type", .text).notNull()
                t.column("value", .blob).notNull()
            }
            try db.create(table: "aldente_import_records") { t in
                t.column("import_id", .text).notNull().references("aldente_imports", onDelete: .cascade)
                t.column("record_id", .text).notNull().references("aldente_records")
                t.primaryKey(["import_id", "record_id"])
            }
        }

        migrator.registerMigration("unifiedHistory") { db in
            try db.alter(table: "minute_samples") { t in t.add(column: "charge_limit_pct", .integer) }
            try db.alter(table: "hourly_samples") { t in t.add(column: "charge_limit_pct", .integer) }
            try db.create(table: "history_records") { t in
                t.primaryKey("id", .text)
                t.column("metric", .text).notNull()
                t.column("ts", .double)
                t.column("original_timestamp", .text).notNull()
                t.column("value_type", .text).notNull()
                t.column("value", .blob).notNull()
            }
            try db.create(index: "history_records_metric_time", on: "history_records", columns: ["metric", "ts"])
            try db.create(index: "history_records_time", on: "history_records", columns: ["ts"])
            // 已有导入自动进入统一历史；不要求重新选择文件，不改动原始档案或实时采样。
            let formatter = Self.historyTimestampFormatter()
            for row in try Row.fetchAll(db, sql: "SELECT * FROM aldente_records ORDER BY id") {
                guard let table = AlDenteTable(rawValue: row["source_table"]) else {
                    throw AlDenteHistoryError.invalidStoredRecord
                }
                let record = AlDenteRecord(table: table, sourceID: row["source_id"], timestamp: row["timestamp"], value: row["value"])
                try Self.insertHistoryRecord(record, in: db, formatter: formatter)
            }
        }

        return migrator
    }
}
