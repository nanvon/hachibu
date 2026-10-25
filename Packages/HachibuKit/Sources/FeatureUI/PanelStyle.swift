import SwiftUI

/// 面板和主窗口共用的颜色、材质，以及面板动效。规则见 docs/v1技术设计.md 第 19 节。
extension Color {
    /// 品牌蓝 `#287DD0`，深色模式下调亮，定义在 Asset Catalog。
    static let brand = Color("BrandBlue", bundle: .module)
    /// 系统功率：曲线、流向图中流向系统的流带、面板功率卡片的图标。
    static let systemPower = Color.indigo
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

    /// 面板里的一块内容：玻璃底板上的浅色圆角块，铺满宽度。
    func panelTile(padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) -> some View {
        modifier(PanelTile(padding: padding))
    }
}

/// 面板浅色块的填充和描边，`panelTile()` 和低电量模式胶囊共用。
enum PanelTileStyle {
    /// 浅色模式为半透明白，深色模式为很淡的白。
    static func fill(_ colorScheme: ColorScheme) -> Color {
        Color.white.opacity(colorScheme == .dark ? 0.07 : 0.6)
    }

    static let edge = Color.primary.opacity(0.06)
}

/// 圆角 18，带一道细描边。
private struct PanelTile: ViewModifier {
    static let cornerRadius: CGFloat = 18

    let padding: EdgeInsets
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(PanelTileStyle.fill(colorScheme))
                shape.strokeBorder(PanelTileStyle.edge, lineWidth: 0.5)
            }
    }
}
