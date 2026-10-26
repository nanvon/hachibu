import AppKit
import BatteryCore
import Foundation
import SwiftUI
import Testing
@testable import FeatureUI

/// 把功率流向图的各状态渲染成 PNG，用来检查视觉。不做断言，只在设置了 `HACHIBU_RENDER_DIR` 时运行：
/// `HACHIBU_RENDER_DIR=/tmp/flow swift test --package-path Packages/HachibuKit --filter PowerFlowRenderTests`
/// `ImageRenderer` 画不出系统材质，玻璃底板用纯色近似，最终效果以 Xcode 预览和真机为准。
private let outputDirectory = ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]

@MainActor
@Suite struct PowerFlowRenderTests {
    /// 面板宽 360，减去面板内边距 12 × 2 和功率块内边距 14 × 2。
    private static let flowWidth: CGFloat = 308

    private static let samples: [(name: String, snapshot: BatterySnapshot)] = [
        ("On Battery", BatterySnapshot(isExternalPower: false, batteryPowerMW: -9800, systemLoadMW: 9800)),
        ("Charging", BatterySnapshot(isExternalPower: true, batteryPowerMW: 42000, powerInMW: 58000, systemLoadMW: 16000)),
        ("Plugged In, Draining", BatterySnapshot(isExternalPower: true, batteryPowerMW: -12000, powerInMW: 30000, systemLoadMW: 42000)),
        ("Plugged In, Slightly Draining", BatterySnapshot(isExternalPower: true, batteryPowerMW: -3000, powerInMW: 30000, systemLoadMW: 33000)),
        ("Plugged In, Not Charging", BatterySnapshot(isExternalPower: true, batteryPowerMW: 0, powerInMW: 14514, systemLoadMW: 14514)),
        ("Missing Data", BatterySnapshot(isExternalPower: false)),
    ]

    @Test(.enabled(if: outputDirectory != nil))
    func renderStates() throws {
        let directory = URL(fileURLWithPath: outputDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let sheet = Self.contactSheet(scheme: scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("power-flow-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// 所有状态竖排，每张图套在近似面板的背景和功率块里。
    private static func contactSheet(scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(samples, id: \.name) { sample in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: sample.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let flow = PowerFlow(sample.snapshot) {
                        PowerFlowView(flow: flow, isAnimating: false, frozenTime: 1.3)
                            .frame(width: flowWidth)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                PanelTileStyle.fill(scheme),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                    }
                }
            }
        }
        .padding(16)
        // 近似玻璃底板的颜色。
        .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.9))
        .environment(\.colorScheme, scheme)
    }
}
