import AppKit
import BatteryCore
import HistoryStore
import SwiftUI
import Testing
@testable import FeatureUI

/// 通知页、设置页的两栏布局；系统控件换成静态图形。仅设置 HACHIBU_RENDER_DIR 时出图。
@MainActor
@Suite struct SettingsRenderTests {
    private static let width: CGFloat = 968
    private static let variants: [(ColorScheme, String, String)] = [
        (.light, "zh-Hans", "light"), (.dark, "zh-Hans", "dark"), (.light, "en", "light-en"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderNotifications() async throws {
        let defaults = UserDefaults(suiteName: "HachibuRender.Notifications")!
        defaults.removePersistentDomain(forName: "HachibuRender.Notifications")
        let settings = AppSettings(defaults: defaults)
        let alerts = AlertMonitor(settings: settings, notifier: FixedNotifier(), defaults: defaults)
        await alerts.refreshAuthorization()
        await alerts.handleReading(.battery(BatterySnapshot(temperatureCelsius: 31.5)), at: Date())

        let store = try HistoryStore.inMemory()
        let now = Date()
        for minute in 0..<600 {
            try await store.write(MinuteSample(
                timestamp: now.addingTimeInterval(Double(minute - 599) * 60),
                temperatureCelsius: 30 + 5 * sin(Double(minute) / 60)
            ))
        }
        let history = HistoryModel(store: store)
        await history.loadHighestRecentTemperature()

        for (scheme, locale, name) in Self.variants {
            let content = NotificationsPageContent(settings: settings, alerts: alerts, history: history)
            try await render(content, scheme: scheme, locale: locale, name: "notifications-\(name)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderSettings() async throws {
        let defaults = UserDefaults(suiteName: "HachibuRender.Settings")!
        defaults.removePersistentDomain(forName: "HachibuRender.Settings")
        let settings = AppSettings(defaults: defaults)
        settings.chargeAboveLimitAction = .holdCurrentCharge
        let system = FakeBatterySystem()
        let sampler = BatterySampler(dataSource: system, systemProfiler: EmptyProfiler(), chargeLimitWriter: system, store: nil)
        let monitor = BatteryMonitor(sampler: sampler, powerSourceReader: { nil })
        await monitor.read()

        let importer = HistoryImportModel(store: try HistoryStore.inMemory())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hachibu-render-import.json")
        try Self.importFile().write(to: file)
        await importer.prepare(fileURL: file)
        let preview = try #require(importer.pending)
        await importer.confirmImport(preview)

        for (scheme, locale, name) in Self.variants {
            let content = SettingsPageContent(
                settings: settings,
                importer: importer,
                onExportDiagnostics: {},
                onCheckForUpdates: {}
            )
            .environment(monitor)
            try await render(content, scheme: scheme, locale: locale, name: "settings-\(name)")
        }
    }

    private func render(_ content: some View, scheme: ColorScheme, locale: String, name: String) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = content
            .frame(width: Self.width)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.rendersStaticControls, true)
        // 先渲染一次触发 .task（读取 48 小时最高温度、导入来源），再等它完成。
        _ = ImageRenderer(content: view).cgImage
        try await Task.sleep(for: .milliseconds(300))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func importFile() throws -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .day, value: -400, to: Date())!
        let records: [[String: Any]] = (0..<30).map { day in
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            return ["metric": "full_charge_mah", "time": date.ISO8601Format(), "value": 8000 - day]
        }
        return try JSONSerialization.data(withJSONObject: [
            "format": "hachibu-import",
            "version": 1,
            "source": ["app": "AlDente", "version": "1.39.3"],
            "records": records,
        ] as [String: Any])
    }
}

private struct FixedNotifier: AlertNotifier {
    func authorization() async -> NotificationAuthorization { .allowed }
    func requestAuthorization() async -> NotificationAuthorization { .allowed }
    func deliver(_ alert: BatteryAlert) async {}
}

private struct EmptyProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

/// 插电未充电、上限 80% 的电池，PowerUI 可写。
private final class FakeBatterySystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    func read() -> RawBatteryReadings {
        RawBatteryReadings(
            powerSources: [[
                "Type": .string("InternalBattery"),
                "Current Capacity": .int(80), "Max Capacity": .int(100),
                "Power Source State": .string("AC Power"),
                "Is Charging": .bool(false),
            ]],
            smartBattery: nil,
            smartBatteryPack: nil,
            adapterDetails: nil,
            chargeLimitArchive: nil,
            powerUIChargeLimit: PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80, availableLimits: [80, 85, 90, 95, 100]),
            lowPowerModeEnabled: false
        )
    }

    func write(_ change: ChargeLimitChange) throws {}
}
