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

        return migrator
    }
}
