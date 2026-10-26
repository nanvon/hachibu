import AppKit
import BatteryCore
import FeatureUI

/// 只比较影响图标的状态，避免无关采样触发重绘。
struct MenuBarIcon: Equatable {
    let style: MenuBarIconStyle
    let percent: Int?
    private let mark: BatteryIconDrawing.Mark
    private let lowPower: Bool
    private let isDark: Bool

    init(style: MenuBarIconStyle, reading: BatteryReading?, appearance: NSAppearance) {
        self.style = style
        isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if case .battery(let snapshot) = reading {
            percent = snapshot.percent.map { min(max($0, 0), 100) }
            // 插头和闪电标记使用实时电源状态，避免尚未更新的功率把插电误画成未插电。
            if snapshot.isExternalPower == true {
                mark = snapshot.isCharging == true ? .charging : .pluggedIn
            } else {
                mark = .none
            }
            lowPower = snapshot.lowPowerModeEnabled
        } else {
            percent = nil
            mark = .none
            lowPower = false
        }
    }

    @MainActor
    func image() -> NSImage {
        return BatteryIconDrawing(
            style: style == .battery ? .macOS : .iOS, percent: percent,
            mark: mark, lowPower: lowPower, isDark: isDark
        ).image()
    }
}
