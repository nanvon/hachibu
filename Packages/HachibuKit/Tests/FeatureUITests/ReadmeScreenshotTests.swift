import AppKit
import BatteryCore
import HistoryStore
import ObjectiveC
import ServiceManagement
import SwiftUI
import Testing
@testable import FeatureUI

/// README 用的主窗口截图：历史、通知、设置三页，浅色。
/// 读取 `HACHIBU_RENDER_DB` 指向的历史数据库副本，用真实记录出图；同时设置 `HACHIBU_RENDER_DIR` 时才运行。
/// 页面里不少日期和时长按进程的地区格式化，界面语言跟随进程地区：英文地区出英文图（文件名带 `-en`），其他出中文图。
/// 用法见 `docs/assets/screenshots/README.md`。
/// `ImageRenderer` 画不出 `NavigationSplitView` 和系统材质，窗口外框、侧栏和工具栏用静态图形近似。
private let outputDirectory = ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]
private let databasePath = ProcessInfo.processInfo.environment["HACHIBU_RENDER_DB"]

@MainActor
@Suite struct ReadmeScreenshotTests {
    private static let windowSize = CGSize(width: 1200, height: 840)
    private static let sidebarWidth: CGFloat = 232
    private static let toolbarHeight: CGFloat = 52

    @Test(.enabled(if: outputDirectory != nil && databasePath != nil))
    func renderMainWindow() async throws {
        let directory = URL(fileURLWithPath: outputDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 在副本上打开，避免迁移或写入影响正在使用的数据库。
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hachibu-readme-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: (databasePath! as NSString).expandingTildeInPath), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let store = try HistoryStore(fileURL: copy)
        let history = HistoryModel(store: store)
        await history.reloadAll()
        await history.loadHighestRecentTemperature()

        let defaults = UserDefaults(suiteName: "HachibuRender.Readme")!
        defaults.removePersistentDomain(forName: "HachibuRender.Readme")
        let settings = AppSettings(defaults: defaults)
        let alerts = AlertMonitor(settings: settings, notifier: AllowedNotifier(), defaults: defaults)
        await alerts.refreshAuthorization()
        let now = Date()
        let latest = try await store.minuteSamples(from: now.addingTimeInterval(-3600), to: now).last
        await alerts.handleReading(.battery(BatterySnapshot(temperatureCelsius: latest?.temperatureCelsius)), at: now)

        let system = PluggedInBatterySystem()
        let sampler = BatterySampler(dataSource: system, systemProfiler: EmptyPowerData(), chargeLimitWriter: system, store: nil)
        let monitor = BatteryMonitor(sampler: sampler, powerSourceReader: { nil })
        await monitor.read()

        // 测试进程没有应用图标，通知预览会显示文件夹图标。
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let icon = try #require(NSImage(contentsOf: repositoryRoot.appendingPathComponent("docs/assets/brand/app-icon.png")))
        NSApplication.shared.applicationIconImage = icon

        // 测试进程不是 App，SMAppService 返回 .notFound，设置页会写“系统找不到此登录项”。出图时按未注册处理。
        let statusMethod = try #require(class_getInstanceMethod(SMAppService.self, #selector(getter: SMAppService.status)))
        let originalStatus = method_getImplementation(statusMethod)
        let notRegistered: @convention(block) (AnyObject) -> Int = { _ in SMAppService.Status.notRegistered.rawValue }
        method_setImplementation(statusMethod, imp_implementationWithBlock(notRegistered))
        defer { method_setImplementation(statusMethod, originalStatus) }

        let isEnglish = Locale.current.language.languageCode == .english
        let locale = isEnglish ? "en" : "zh-Hans"
        let suffix = isEnglish ? "-en" : ""
        let lastUpdated = history.lastUpdated.map {
            Text("Last updated \($0.formatted(date: .omitted, time: .shortened))", bundle: .module)
        }
        try await render(
            HistoryChartsContent(model: history, temperatureThreshold: settings.temperatureAlertThreshold),
            page: .history, subtitle: lastUpdated, summary: history.summary,
            locale: locale, name: "history\(suffix)", to: directory
        )
        try await render(
            NotificationsPageContent(settings: settings, alerts: alerts, history: history),
            page: .notifications, subtitle: nil, summary: history.summary,
            locale: locale, name: "notifications\(suffix)", to: directory
        )
        try await render(
            SettingsPageContent(settings: settings, importer: history.importer, onExportDiagnostics: {}, onCheckForUpdates: {})
                .environment(monitor),
            page: .settings, subtitle: nil, summary: history.summary,
            locale: locale, name: "settings\(suffix)", to: directory
        )
    }

    private func render(
        _ content: some View,
        page: MainWindowPage,
        subtitle: Text?,
        summary: RecordingSummary?,
        locale: String,
        name: String,
        to directory: URL
    ) async throws {
        let view = Self.window(content: content, page: page, subtitle: subtitle, summary: summary)
            .padding(48)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.rendersStaticControls, true)
        // 先渲染一次触发 .task（读取导入来源等），再等它完成。
        _ = ImageRenderer(content: view).cgImage
        try await Task.sleep(for: .milliseconds(300))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// 默认大小的主窗口：左侧悬浮侧栏，右侧工具栏标题和页面内容，超出窗口高度的内容裁掉。
    private static func window(content: some View, page: MainWindowPage, subtitle: Text?, summary: RecordingSummary?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return HStack(alignment: .top, spacing: 0) {
            sidebar(selection: page, summary: summary)
                .frame(width: sidebarWidth)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    page.title
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: toolbarHeight)
                .padding(.horizontal, 20)
                content
                    .frame(width: windowSize.width - sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: windowSize.width - sidebarWidth, height: windowSize.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(Color(white: 0.96))
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
    }

    /// 近似 macOS 26 的悬浮玻璃侧栏：红绿灯、三页列表、底部记录概况。
    private static func sidebar(selection: MainWindowPage, summary: RecordingSummary?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 12)
            .frame(height: toolbarHeight - 8, alignment: .center)
            VStack(spacing: 2) {
                ForEach(MainWindowPage.allCases) { page in
                    Label {
                        page.title
                    } icon: {
                        Image(systemName: page.systemImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background(page == selection ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
            if let summary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary.dayCount) days recorded", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                    if let firstDay = HistoryChartBuilder.startOfDay(summary.firstDay) {
                        Text("Recording since \(firstDay.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.99).opacity(0.9), in: shape)
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(8)
    }
}

private struct AllowedNotifier: AlertNotifier {
    func authorization() async -> NotificationAuthorization { .allowed }
    func requestAuthorization() async -> NotificationAuthorization { .allowed }
    func deliver(_ alert: BatteryAlert) async {}
}

private struct EmptyPowerData: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

/// 插电未充电、上限 80% 的电池，PowerUI 可写。
private final class PluggedInBatterySystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
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
