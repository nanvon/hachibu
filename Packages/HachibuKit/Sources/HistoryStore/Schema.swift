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

        // 每日数据按来源和电池记录，见 docs/v1技术设计.md 第 10 节。
        migrator.registerMigration("v2") { db in
            try db.alter(table: "hourly_samples") { t in
                t.add(column: "charging_minutes", .integer)
                t.add(column: "system_load_min_mw", .integer)
                t.add(column: "battery_power_avg_mw", .double)
                t.add(column: "battery_power_min_mw", .integer)
                t.add(column: "battery_power_max_mw", .integer)
                t.add(column: "power_in_avg_mw", .double)
                t.add(column: "power_in_min_mw", .integer)
                t.add(column: "power_in_max_mw", .integer)
                t.add(column: "temperature_min_c", .double)
                t.add(column: "voltage_avg_mv", .double)
                t.add(column: "voltage_min_mv", .integer)
                t.add(column: "voltage_max_mv", .integer)
                t.add(column: "amperage_avg_ma", .double)
                t.add(column: "amperage_min_ma", .integer)
                t.add(column: "amperage_max_ma", .integer)
            }

            try db.create(table: "batteries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serial_sha256", .text).notNull().unique()
                t.column("design_mah", .integer)
                t.column("design_cycle_count", .integer)
                t.column("first_seen_at", .integer).notNull()
                t.column("last_seen_at", .integer).notNull()
            }

            // 自增 id 不复用，id 越大的导入越晚。
            try db.create(table: "sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("app", .text).notNull()
                t.column("app_version", .text)
                t.column("file_sha256", .text).unique()
                t.column("time_zone", .text)
                t.column("imported_at", .integer)
            }
            try db.execute(
                sql: "INSERT INTO sources (id, kind, app) VALUES (?, 'native', 'Hachibu')",
                arguments: [HistoryStore.nativeSourceID]
            )

            try db.create(table: "daily_health") { t in
                t.column("day", .text).notNull()
                t.column("source_id", .integer).notNull().references("sources", onDelete: .cascade)
                t.column("battery_id", .integer).references("batteries", onDelete: .setNull)
                t.column("full_charge_mah", .integer)
                t.column("design_mah", .integer)
                t.column("cycle_count", .integer)
                t.column("system_max_capacity_pct", .integer)
                t.column("health_condition", .text)
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["day", "source_id"])
            }
            try db.create(indexOn: "daily_health", columns: ["source_id"])
            try db.create(indexOn: "daily_health", columns: ["battery_id"])

            try db.create(table: "battery_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("battery_id", .integer).references("batteries", onDelete: .setNull)
                t.column("value", .integer)
            }
            try db.create(indexOn: "battery_events", columns: ["kind", "ts"])
            try db.create(indexOn: "battery_events", columns: ["battery_id"])

            try db.execute(
                sql: """
                    INSERT INTO daily_health
                        (day, source_id, full_charge_mah, design_mah, cycle_count, system_max_capacity_pct, updated_at)
                    SELECT day, ?, full_charge_mah, design_mah, cycle_count, system_max_capacity_pct, updated_at
                    FROM daily_samples
                    """,
                arguments: [HistoryStore.nativeSourceID]
            )
            try db.drop(table: "daily_samples")
        }

        // 导入的历史时间不能决定本机当前电池；单独记录本机识别时间。
        migrator.registerMigration("v3") { db in
            try db.alter(table: "batteries") { t in
                t.add(column: "last_native_seen_at", .integer)
            }
            // 仅从本机每日记录和换电池事件恢复身份，不根据导入记录推断。
            try db.execute(sql: """
                UPDATE batteries SET last_native_seen_at = (
                    SELECT MAX(ts) FROM (
                        SELECT updated_at AS ts FROM daily_health
                        WHERE source_id = \(HistoryStore.nativeSourceID) AND battery_id = batteries.id
                        UNION ALL
                        SELECT ts FROM battery_events
                        WHERE kind = 'battery_changed' AND battery_id = batteries.id
                    )
                )
                """)
        }

        return migrator
    }
}
