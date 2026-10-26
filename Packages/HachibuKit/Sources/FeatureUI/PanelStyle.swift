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
    func panelGlassButtonStyle() -> some View {
        modifier(PanelGlassButton())
    }

    /// 面板里的一块内容：玻璃底板上的半透明圆角块，铺满宽度。`backdrop` 画在底色和亮边之间，按圆角裁剪。
    func panelTile<Backdrop: View>(
        padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
        @ViewBuilder backdrop: () -> Backdrop = { EmptyView() }
    ) -> some View {
        modifier(PanelTile(padding: padding, backdrop: backdrop()))
    }
}

extension EnvironmentValues {
    /// 渲染测试用：`ImageRenderer` 画不出 AppKit 控件，为 true 时开关改为静态图形。
    @Entry var rendersStaticControls = false
}

/// 面板块的底色、亮边和阴影，`panelTile()`、低电量模式胶囊和渲染测试共用。
enum PanelTileStyle {
    /// 与面板圆角同心：面板圆角 28 减去面板内边距 12。
    static let cornerRadius: CGFloat = 16

    /// 底色的平均值，渲染测试里给单独的功率流向图做背景。
    static func fill(_ colorScheme: ColorScheme) -> Color {
        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.58)
    }

    /// 底色上浅下深，像一块有厚度的玻璃。
    static func fillGradient(_ colorScheme: ColorScheme) -> LinearGradient {
        let dark = colorScheme == .dark
        return LinearGradient(
            colors: [.white.opacity(dark ? 0.11 : 0.72), .white.opacity(dark ? 0.05 : 0.46)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 亮边：顶部最亮，中段几乎消失，底部回亮一点，模拟玻璃边缘的反光。
    static func rim(_ colorScheme: ColorScheme) -> LinearGradient {
        let dark = colorScheme == .dark
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(dark ? 0.26 : 0.95), location: 0),
                .init(color: .white.opacity(dark ? 0.05 : 0.3), location: 0.55),
                .init(color: .white.opacity(dark ? 0.1 : 0.6), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func shadow(_ colorScheme: ColorScheme) -> Color {
        .black.opacity(colorScheme == .dark ? 0.22 : 0.06)
    }
}

private struct PanelTile<Backdrop: View>: ViewModifier {
    let padding: EdgeInsets
    let backdrop: Backdrop
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelTileStyle.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(PanelTileStyle.fillGradient(colorScheme))
                    backdrop.clipShape(shape)
                    shape.strokeBorder(PanelTileStyle.rim(colorScheme), lineWidth: 1)
                }
                .compositingGroup()
                .shadow(color: PanelTileStyle.shadow(colorScheme), radius: 6, y: 2)
            }
    }
}

private struct PanelGlassButton: ViewModifier {
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    func body(content: Content) -> some View {
        if rendersStaticControls {
            content.buttonStyle(StaticGlassButtonStyle())
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// 渲染测试里代替玻璃按钮的静态图形，高度接近 `.controlSize(.large)`。
private struct StaticGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .frame(minWidth: 32, minHeight: 32)
            .background {
                Capsule().fill(PanelTileStyle.fillGradient(colorScheme))
                Capsule().strokeBorder(PanelTileStyle.rim(colorScheme), lineWidth: 1)
            }
            .compositingGroup()
            .shadow(color: PanelTileStyle.shadow(colorScheme), radius: 6, y: 2)
    }
}
