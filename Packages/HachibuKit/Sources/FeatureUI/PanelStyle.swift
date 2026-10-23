import SwiftUI

/// 面板和主窗口共用的颜色、材质，以及面板动效。规则见 docs/v1技术设计.md 第 19 节。
extension Color {
    /// 品牌蓝 `#287DD0`，深色模式下调亮，定义在 Asset Catalog。
    static let brand = Color("BrandBlue", bundle: .module)
}

enum PanelMotion {
    /// 系统开启“减弱动态效果”时，弹簧改为淡入淡出。
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.2)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

extension View {
    /// macOS 26+ 用玻璃，更早系统用材质背景。
    @ViewBuilder
    func panelGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// macOS 26+ 用玻璃按钮（带悬停、按压反馈），更早系统用 `.bordered`。
    @ViewBuilder
    func panelGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
