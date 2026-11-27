import SwiftUI

/// 面板和主窗口共用的颜色、材质，以及面板动效。规则见 docs/v1技术设计.md 第 19 节。
extension Color {
    /// 品牌蓝 `#287DD0`，深色模式下调亮，定义在 Asset Catalog。
    static let brand = Color("BrandBlue", bundle: .module)
    /// 深色底上的亮蓝 `#8CC4FF`：电量卡片里被水淹到的文字、深色模式下充电上限选中档位的文字。
    static let brandOnDark = Color(red: 0.55, green: 0.77, blue: 1)
    /// 系统功率：流向图中流向系统的流带、面板功率卡片的图标。
    static let systemPower = Color.indigo
}

public enum PanelMetrics {
    /// 面板外圆角，App 层 `PanelController`、面板内容与渲染测试共用。
    public static let cornerRadius: CGFloat = 24
}

enum PanelMotion {
    /// 结构变化的时长和曲线（强 ease-out，不回弹）。App 层 PanelController 缩放窗口用同样的数值，内容和窗口边缘同步。
    static let duration = 0.3
    static let curve = (0.23, 1.0, 0.32, 1.0)

    /// 系统开启“减弱动态效果”时改为淡入淡出。
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)
    }

    /// 出现时从上方 6pt 处淡入；减弱动态效果时只淡入淡出。
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6))
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

    /// 面板外轮廓的细边，画在玻璃底板上沿边缘一圈。浅色模式下其他应用多为白色窗口，只靠窗口阴影分不清面板边界；深色模式不画。
    func panelOutline(in shape: some InsettableShape) -> some View {
        modifier(PanelOutline(shape: shape))
    }

    /// macOS 26+ 用玻璃按钮（带悬停、按压反馈），更早系统用 `.bordered`。
    func panelGlassButtonStyle() -> some View {
        modifier(PanelGlassButton())
    }

    /// 面板里的一块内容：玻璃底板上的半透明圆角块，铺满宽度。`backdrop` 画在底色和亮边之间，按圆角裁剪。
    func panelTile<Backdrop: View>(
        padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
        emphasis: PanelTileEmphasis = .primary,
        @ViewBuilder backdrop: () -> Backdrop = { EmptyView() }
    ) -> some View {
        modifier(PanelTile(padding: padding, emphasis: emphasis, backdrop: backdrop()))
    }
}

enum PanelTileEmphasis {
    /// 顶部功率流与三张读数卡：保持主视觉存在感。
    case primary
    /// 充电上限、电池健康等次级信息块：边框与阴影更轻。
    case secondary
}

extension EnvironmentValues {
    /// 渲染测试用：`ImageRenderer` 画不出 AppKit 控件，为 true 时开关、按钮和分段控件改为静态图形。
    @Entry var rendersStaticControls = false
}

/// 面板块的底色、亮边和阴影，`panelTile()`、低电量模式胶囊和渲染测试共用。
enum PanelTileStyle {
    /// 与面板圆角同心：面板外圆角减去面板内边距 12。
    static let cornerRadius: CGFloat = PanelMetrics.cornerRadius - 12

    /// 底色的平均值，渲染测试里给单独的功率流向图做背景。
    static func fill(_ colorScheme: ColorScheme) -> Color {
        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60)
    }

    /// 底色上浅下深，像一块有厚度的玻璃。
    static func fillGradient(_ colorScheme: ColorScheme, emphasis: PanelTileEmphasis = .primary) -> LinearGradient {
        let dark = colorScheme == .dark
        let top: Double = switch (dark, emphasis) {
        case (true, .primary): 0.11
        case (true, .secondary): 0.075
        case (false, .primary): 0.74
        case (false, .secondary): 0.58
        }
        let bottom: Double = switch (dark, emphasis) {
        case (true, .primary): 0.05
        case (true, .secondary): 0.035
        case (false, .primary): 0.48
        case (false, .secondary): 0.36
        }
        return LinearGradient(
            colors: [.white.opacity(top), .white.opacity(bottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 亮边：顶部最亮，中段几乎消失，底部回亮一点，模拟玻璃边缘的反光。
    static func rim(_ colorScheme: ColorScheme, emphasis: PanelTileEmphasis = .primary) -> LinearGradient {
        let dark = colorScheme == .dark
        let stops: [Gradient.Stop] = switch (dark, emphasis) {
        case (true, .primary):
            [.init(color: .white.opacity(0.24), location: 0), .init(color: .white.opacity(0.05), location: 0.55), .init(color: .white.opacity(0.10), location: 1)]
        case (true, .secondary):
            [.init(color: .white.opacity(0.15), location: 0), .init(color: .white.opacity(0.03), location: 0.55), .init(color: .white.opacity(0.06), location: 1)]
        case (false, .primary):
            [.init(color: .white.opacity(0.86), location: 0), .init(color: .white.opacity(0.24), location: 0.55), .init(color: .white.opacity(0.48), location: 1)]
        case (false, .secondary):
            [.init(color: .white.opacity(0.62), location: 0), .init(color: .white.opacity(0.14), location: 0.55), .init(color: .white.opacity(0.30), location: 1)]
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    static func shadow(_ colorScheme: ColorScheme, emphasis: PanelTileEmphasis = .primary) -> Color {
        let dark = colorScheme == .dark
        let opacity: Double = switch (dark, emphasis) {
        case (true, .primary): 0.20
        case (true, .secondary): 0.12
        case (false, .primary): 0.065
        case (false, .secondary): 0.035
        }
        return .black.opacity(opacity)
    }

    /// 浅色模式下块外缘的极淡深色细边：避免在白色窗口上融在一起，同时不显框线感。深色模式不画。
    static func edge(_ colorScheme: ColorScheme, emphasis: PanelTileEmphasis = .primary) -> Color {
        guard colorScheme != .dark else { return .clear }
        return .black.opacity(emphasis == .primary ? 0.04 : 0.025)
    }
}

private struct PanelTile<Backdrop: View>: ViewModifier {
    let padding: EdgeInsets
    let emphasis: PanelTileEmphasis
    let backdrop: Backdrop
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelTileStyle.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(PanelTileStyle.fillGradient(colorScheme, emphasis: emphasis))
                    backdrop.clipShape(shape)
                    shape.strokeBorder(PanelTileStyle.rim(colorScheme, emphasis: emphasis), lineWidth: 1)
                    // 画在块的外面，不压住亮边。
                    shape.inset(by: -0.5).strokeBorder(PanelTileStyle.edge(colorScheme, emphasis: emphasis), lineWidth: 0.5)
                }
                .compositingGroup()
                .shadow(
                    color: PanelTileStyle.shadow(colorScheme, emphasis: emphasis),
                    radius: emphasis == .primary ? 5 : 4,
                    y: emphasis == .primary ? 1.5 : 1
                )
            }
    }
}

private struct PanelOutline<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    func body(content: Content) -> some View {
        content.overlay {
            if colorScheme == .light, shouldDrawOutline {
                shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// macOS 26+ 原生 `NSGlassEffectView` 自带边缘高光，只在旧系统或静态渲染近似图里保留细边。
    private var shouldDrawOutline: Bool {
        if rendersStaticControls { return true }
        if #available(macOS 26.0, *) { return false }
        return true
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
