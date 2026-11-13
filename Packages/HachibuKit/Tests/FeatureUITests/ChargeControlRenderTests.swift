import AppKit
import BatteryCore
import Foundation
import HistoryStore
import ServiceManagement
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

    @Test func lastCalibrationUsesLatestFinishedRecord() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            CalibrationRun(id: 1, startedAt: base, endedAt: base.addingTimeInterval(100), trigger: .manual, result: .completed),
            CalibrationRun(id: 2, startedAt: base.addingTimeInterval(10), endedAt: base.addingTimeInterval(50), trigger: .manual, result: .cancelled),
            CalibrationRun(id: 3, startedAt: base.addingTimeInterval(200), trigger: .manual),
        ]
        #expect(CalibrationSettingsGroup.latestFinishedCalibration(in: records)?.id == 1)
        #expect(CalibrationSettingsGroup.latestFinishedCalibration(in: [records[2]]) == nil)
        #expect(CalibrationSettingsGroup.latestFinishedCalibration(in: []) == nil)
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
        let states: [(String, Int, ManagedLimitState, CalibrationDisplay?)] = [
            ("applied", 80, .applied, nil),
            ("approval", 70, .awaitingHelperApproval(effective: 80), nil),
            ("policy", 60, .systemPolicy(.systemCalibration, limit: 60), nil),
            ("discharge", 80, .applied, CalibrationDisplay(step: .dischargeToLow, fraction: 0.4, remainingMinutes: 180)),
            ("paused", 80, .applied, CalibrationDisplay(step: .holdFull, pauseReason: .appQuit, fraction: 0.4)),
        ]
        for (scheme, locale, variant) in variants {
            for (name, target, state, calibration) in states {
                let effectiveLimit = state == .awaitingHelperApproval(effective: 80) ? 80 : target
                let snapshot = PanelPreviewData.snapshot(percent: effectiveLimit, chargeLimit: .on(percent: effectiveLimit))
                let control = ChargeLimitControl(
                    managedTarget: target, snapshot: snapshot, canWrite: true, state: state, isBlocked: false
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
    func renderHelperApprovalAndFailure() async throws {
        let defaults = UserDefaults(suiteName: "ChargeHelperRenderTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.chargeControlMode = .managed
        settings.managedChargeLimit = 60
        let registration = FakeHelperRegistration()
        registration.status = .requiresApproval
        let helper = ChargeHelperService(registration: registration)
        let monitor = BatteryMonitor(
            sampler: BatterySampler(dataSource: RenderBattery(), systemProfiler: RenderProfiler(), chargeLimitWriter: RenderBattery(), store: nil),
            powerSourceReader: { nil }, smcReader: { _ in nil }, holdDefaults: defaults, helperService: helper
        )
        await monitor.read()
        monitor.chargeControl = settings.chargeControlConfiguration
        // 未安装、安装失败、需要允许、已允许（检查连接中）。静态渲染不运行 `.task`，连接结果无法出图。
        let states: [(String, SMAppService.Status, Error?)] = [
            ("not-installed", .notRegistered, nil),
            ("failure", .notRegistered, NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid signature"])),
            ("permission", .requiresApproval, nil),
            ("enabled", .enabled, nil),
        ]
        for (name, status, error) in states {
            registration.status = status
            registration.registrationError = error
            if error != nil { helper.register() } else { helper.refresh() }
            for (scheme, locale, variant) in variants {
                let content = SettingsPageContent(settings: settings, onExportDiagnostics: {}, onCheckForUpdates: nil)
                    .environment(monitor)
                    .frame(width: 968)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                try render(content, scheme: scheme, locale: locale, name: "charge-helper-\(name)-\(variant)")
            }
        }
        // 装过后切回跟随系统设置，仍显示 Hachibu Helper 行，保证能移除。
        settings.chargeControlMode = .followSystem
        monitor.chargeControl = settings.chargeControlConfiguration
        registration.status = .enabled
        helper.refresh()
        for (scheme, locale, variant) in variants {
            let content = SettingsPageContent(settings: settings, onExportDiagnostics: {}, onCheckForUpdates: nil)
                .environment(monitor)
                .frame(width: 968)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            try render(content, scheme: scheme, locale: locale, name: "charge-helper-follow-system-\(variant)")
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
