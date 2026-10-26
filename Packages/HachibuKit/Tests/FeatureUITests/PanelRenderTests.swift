import AppKit
import BatteryCore
import Foundation
import SwiftUI
import Testing
@testable import FeatureUI

/// 把菜单栏面板的各状态渲染成 PNG，用来检查视觉。不做断言，只在设置了 `HACHIBU_RENDER_DIR` 时运行：
/// `HACHIBU_RENDER_DIR=/tmp/panel swift test --package-path Packages/HachibuKit --filter PanelRenderTests`
/// `ImageRenderer` 画不出系统材质和玻璃按钮，底板用壁纸上的半透明纯色近似，最终效果以 Xcode 预览和真机为准。
private let outputDirectory = ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]

@MainActor
@Suite struct PanelRenderTests {
    private struct Sample {
        let name: String
        let reading: BatteryReading?
        var health: BatteryHealthInfo? = PanelPreviewData.health
        var isChargeControlAppRunning = false
    }

    private static let samples: [Sample] = [
        Sample(name: "On Battery", reading: .battery(PanelPreviewData.snapshot(
            percent: 64, isExternalPower: false, batteryPowerMW: -9800, systemLoadMW: 9800,
            amperageMA: -820, timeToEmptyMinutes: 312
        ))),
        Sample(name: "Charging, High Temperature", reading: .battery(PanelPreviewData.snapshot(
            percent: 46, isCharging: true, batteryPowerMW: 42000, powerInMW: 58000, systemLoadMW: 16000,
            amperageMA: 3400, timeToFullMinutes: 48, temperatureCelsius: 41.2
        ))),
        Sample(name: "Plugged In, Not Charging", reading: .battery(PanelPreviewData.snapshot())),
        Sample(
            name: "Limit Off, AlDente Running",
            reading: .battery(PanelPreviewData.snapshot(isCharging: true, batteryPowerMW: 30000, chargeLimit: .off)),
            isChargeControlAppRunning: true
        ),
        Sample(name: "Missing Data", reading: .battery(BatterySnapshot(isExternalPower: false)), health: nil),
    ]

    @Test(.enabled(if: outputDirectory != nil))
    func renderStates() throws {
        let directory = URL(fileURLWithPath: outputDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: Self.contactSheet(scheme: scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("panel-\(scheme == .dark ? "dark" : "light").png"))
            let detailRenderer = ImageRenderer(content: Self.panel(Self.samples[2], scheme: scheme)
                .padding(24)
                .background(Wallpaper(scheme: scheme))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            detailRenderer.scale = 2
            let detailImage = try #require(detailRenderer.cgImage)
            let detailData = try #require(NSBitmapImageRep(cgImage: detailImage).representation(using: .png, properties: [:]))
            try detailData.write(to: directory.appendingPathComponent("panel-detail-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// 所有状态横排，顶端对齐。
    private static func contactSheet(scheme: ColorScheme) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(samples, id: \.name) { sample in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: sample.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    panel(sample, scheme: scheme)
                }
            }
        }
        .padding(32)
        .background(Wallpaper(scheme: scheme))
        .environment(\.colorScheme, scheme)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }

    private static func panel(_ sample: Sample, scheme: ColorScheme) -> some View {
        let control: ChargeLimitControl? = if case .battery(let snapshot)? = sample.reading {
            ChargeLimitControl(snapshot: snapshot, canWrite: true, isBlocked: sample.isChargeControlAppRunning)
        } else {
            nil
        }
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return PanelContent(
            reading: sample.reading,
            health: sample.health,
            highTemperatureCelsius: 40,
            chargeLimitControl: control,
            isFlowAnimating: false,
            flowFrozenTime: 1.3,
            onChangeChargeLimit: { _ in },
            onOpenMainWindow: {},
            onOpenSettings: {},
            onQuit: {}
        )
        .environment(\.rendersStaticControls, true)
        // 近似玻璃底板：半透明纯色加一道亮边。
        .background(scheme == .dark ? Color(white: 0.13).opacity(0.82) : Color(white: 0.96).opacity(0.78), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.16 : 0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

/// 近似 macOS 默认壁纸的渐变，用来观察半透明底板的效果。
private struct Wallpaper: View {
    let scheme: ColorScheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.05, green: 0.08, blue: 0.2), Color(red: 0.16, green: 0.1, blue: 0.3)]
                    : [Color(red: 0.36, green: 0.62, blue: 0.95), Color(red: 0.72, green: 0.56, blue: 0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 1, green: 0.62, blue: 0.4).opacity(dark ? 0.35 : 0.6), .clear],
                center: UnitPoint(x: 0.75, y: 0.85),
                startRadius: 0,
                endRadius: 700
            )
        }
    }
}
