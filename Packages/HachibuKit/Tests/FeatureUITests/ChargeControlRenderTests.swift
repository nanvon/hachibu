import AppKit
import BatteryCore
import Foundation
import HistoryStore
import SwiftUI
import Testing
@testable import FeatureUI

/// 仅渲染静态内容，不启动 App，不连接或安装 helper，不写本机充电设置。
@MainActor
@Suite struct ChargeControlRenderTests {
    private let variants: [(ColorScheme, String, String)] = [
        (.light, "zh-Hans", "light"), (.dark, "zh-Hans", "dark"), (.light, "en", "light-en"),
    ]

    @Test func durationUsesRequestedLanguage() {
        #expect(DisplayFormat.duration(minutes: 180, locale: Locale(identifier: "en")).contains("hr"))
        #expect(DisplayFormat.duration(minutes: 180, locale: Locale(identifier: "zh-Hans")).contains("小时"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderCalibrationRecords() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let runs = [CalibrationResult.completed, .cancelled, .interrupted].enumerated().map { index, result in
            CalibrationRun(
                id: Int64(index), startedAt: now.addingTimeInterval(Double(index - 3) * 86_400),
                endedAt: now.addingTimeInterval(Double(index - 3) * 86_400 + 21_600), trigger: .manual,
                result: result, before: CalibrationHealth(fullChargeMAh: 7900),
                after: result == .completed ? CalibrationHealth(fullChargeMAh: 7942) : nil
            )
        }
        for (scheme, locale, name) in variants {
            try render(
                VStack(spacing: 0) { CalibrationRecordRows(runs: runs) }
                    .padding(20).frame(width: 650)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)),
                scheme: scheme, locale: locale, name: "charge-records-\(name)"
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderManagedPanelStates() throws {
        let states: [(String, ManagedLimitState, CalibrationDisplay?)] = [
            ("applied", .applied, nil),
            ("approval", .awaitingHelperApproval(effective: 80), nil),
            ("policy", .systemPolicy(.systemCalibration, limit: 60), nil),
            ("discharge", .applied, CalibrationDisplay(step: .dischargeToLow, fraction: 0.4, remainingMinutes: 180)),
            ("paused", .applied, CalibrationDisplay(step: .holdFull, pauseReason: .appQuit, fraction: 0.4)),
        ]
        for (scheme, locale, variant) in variants {
            for (name, state, calibration) in states {
                let snapshot = PanelPreviewData.snapshot(percent: 60, chargeLimit: .on(percent: 60))
                let control = ChargeLimitControl(
                    managedTarget: 60, snapshot: snapshot, canWrite: true, state: state, isBlocked: false
                )
                let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                let panel = PanelContent(
                    reading: .battery(snapshot), health: PanelPreviewData.health, highTemperatureCelsius: 40,
                    chargeLimitControl: control, onChangeChargeLimit: { _ in },
                    onOpenMainWindow: {}, onOpenSettings: {}, onQuit: {}, calibration: calibration
                )
                .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96), in: shape)
                .panelOutline(in: shape)
                .padding(24)
                // 浅色以白色窗口为背景，检查轮廓。
                .background(scheme == .dark ? Color(white: 0.07) : .white)
                try render(panel, scheme: scheme, locale: locale, name: "charge-panel-\(name)-\(variant)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderManagedSettings() async throws {
        let defaults = UserDefaults(suiteName: "ChargeControlRenderTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.chargeControlMode = .managed
        settings.managedChargeLimit = 60
        let monitor = BatteryMonitor(
            sampler: BatterySampler(dataSource: RenderBattery(), systemProfiler: RenderProfiler(), chargeLimitWriter: RenderBattery(), store: nil),
            powerSourceReader: { nil }, smcReader: { _ in nil }, holdDefaults: defaults
        )
        await monitor.read()
        monitor.chargeControl = settings.chargeControlConfiguration
        for paused in [false, true] {
            if paused {
                let progress = CalibrationProgress(start: .manual, step: .holdFull, at: Date(), percent: 100)
                monitor.calibration = CalibrationEngine.pauseForRelaunch(progress)
            }
            for (scheme, locale, variant) in variants {
                let content = SettingsPageContent(
                    settings: settings, onExportDiagnostics: {}, onCheckForUpdates: nil
                )
                .environment(monitor)
                .frame(width: 968)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                try render(content, scheme: scheme, locale: locale, name: "charge-settings-\(paused ? "paused" : "idle")-\(variant)")
            }
        }
    }

    private func render(_ content: some View, scheme: ColorScheme, locale: String, name: String) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.rendersStaticControls, true))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private struct RenderBattery: BatteryDataSource, ChargeLimitWriter {
    func read() -> RawBatteryReadings {
        RawBatteryReadings(
            powerSources: [["Type": .string("InternalBattery"), "Current Capacity": .int(80), "Max Capacity": .int(100),
                "Power Source State": .string("AC Power"), "Is Charging": .bool(false)]],
            smartBattery: nil, smartBatteryPack: nil, adapterDetails: nil, chargeLimitArchive: nil,
            powerUIChargeLimit: PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80, availableLimits: [80, 85, 90, 95, 100]),
            lowPowerModeEnabled: false
        )
    }
    func write(_ change: ChargeLimitChange) throws {}
}

private struct RenderProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}
