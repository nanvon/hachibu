import BatteryCore
import SwiftUI

/// 三段功率流向图：供电方 → MacBook → 用电方。规则见 docs/v1技术设计.md 第 8 节，样式见第 19.2 节。
/// 节点画成细竖条，图标和数值写在节点外侧；流带从供电方颜色渐变到用电方颜色，在 MacBook 一侧按同一比例收窄。
/// 流带里有光点从左往右流动，`isAnimating` 为 false 或开启“减弱动态效果”时停止。读数变化时流带宽度用弹簧动画过渡。
struct PowerFlowView: View {
    private static let height: CGFloat = 156

    let flow: PowerFlow
    let isAnimating: Bool
    /// 渲染测试用：把光点固定在这个时刻，不启动动画。
    var frozenTime: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metrics = FlowMetrics(flow)
        AnimatedFlow(metrics: metrics, labels: FlowLabels(flow), motion: motion)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.7, bounce: 0.12), value: metrics)
            .frame(height: Self.height)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var motion: FlowMotion {
        if let frozenTime { return .frozen(frozenTime) }
        return isAnimating && !reduceMotion ? .live : .off
    }

    /// 例如“充电器 58.0 W, 电脑 58.0 W, 系统 16.0 W, 电池 42.0 W”。
    private var accessibilityText: Text {
        let parts = flow.inputs.map { Self.describe(FlowStyle.title($0.node), $0.powerMW) }
            + [Self.describe(Text("Computer", bundle: .module), flow.computerMW)]
            + flow.outputs.map { Self.describe(FlowStyle.title($0.node), $0.powerMW) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: ", ") + $1 }
    }

    private static func describe(_ title: Text, _ milliwatts: Int?) -> Text {
        title + Text(verbatim: " \(DisplayFormat.watts(milliwatts: milliwatts))")
    }
}

private enum FlowMotion: Equatable {
    case off
    case live
    case frozen(TimeInterval)
}

// MARK: - 样式

/// 节点图标和颜色。充电器、充电中的电池为绿色，供电的电池为橙色，系统为靛蓝，MacBook 为品牌蓝。
enum FlowStyle {
    static let hubTint = Color.brand

    static func title(_ node: PowerFlow.Node) -> Text {
        switch node {
        case .charger: Text("Charger", bundle: .module)
        case .battery: Text("Battery", bundle: .module)
        case .system: Text("System", bundle: .module)
        }
    }

    static func symbol(_ node: PowerFlow.Node) -> String {
        switch node {
        case .charger: "powerplug.fill"
        case .battery: "battery.100percent"
        case .system: "cpu"
        }
    }

    /// `isInput` 为 true 表示该节点在供电方一侧。
    static func tint(_ node: PowerFlow.Node, isInput: Bool) -> Color {
        switch node {
        case .charger: .green
        case .battery: isInput ? .orange : .green
        case .system: .systemPower
        }
    }
}

private struct FlowPalette {
    /// 流带填充的不透明度。
    var bandOpacity: Double
    /// 流带下方辉光的不透明度，0 表示不画。
    var glowOpacity: Double
    var hubIcon: Color

    init(colorScheme: ColorScheme) {
        let dark = colorScheme == .dark
        bandOpacity = dark ? 0.55 : 0.5
        glowOpacity = dark ? 0.45 : 0
        hubIcon = .primary.opacity(0.75)
    }
}

// MARK: - 数据

/// 四条流带的位置固定：左侧从上到下为供电的电池、充电器，右侧从上到下为系统、充电中的电池。
private enum FlowSlot: Int, CaseIterable {
    case batteryIn, charger, system, batteryOut

    static let inputs: [FlowSlot] = [.batteryIn, .charger]
    static let outputs: [FlowSlot] = [.system, .batteryOut]

    init(_ node: PowerFlow.Node, isInput: Bool) {
        switch node {
        case .charger: self = .charger
        case .system: self = .system
        case .battery: self = isInput ? .batteryIn : .batteryOut
        }
    }

    var node: PowerFlow.Node {
        switch self {
        case .batteryIn, .batteryOut: .battery
        case .charger: .charger
        case .system: .system
        }
    }

    var isInput: Bool { Self.inputs.contains(self) }
    var tint: Color { FlowStyle.tint(node, isInput: isInput) }
}

/// 参与动画的数值：每条流带的功率（W）和显示程度（0–1，出现、消失时为中间值）。
private struct FlowMetrics: VectorArithmetic {
    private var values: SIMD8<Double>

    init(_ flow: PowerFlow) {
        values = .zero
        for (streams, isInput) in [(flow.inputs, true), (flow.outputs, false)] {
            for stream in streams {
                let slot = FlowSlot(stream.node, isInput: isInput)
                values[slot.rawValue] = Double(max(0, stream.powerMW ?? 0)) / 1000
                values[slot.rawValue + 4] = 1
            }
        }
    }

    private init(values: SIMD8<Double>) { self.values = values }

    func watts(_ slot: FlowSlot) -> CGFloat { CGFloat(values[slot.rawValue]) }
    func presence(_ slot: FlowSlot) -> CGFloat { CGFloat(min(1, max(0, values[slot.rawValue + 4]))) }

    static var zero: FlowMetrics { FlowMetrics(values: .zero) }
    static func + (lhs: FlowMetrics, rhs: FlowMetrics) -> FlowMetrics { FlowMetrics(values: lhs.values + rhs.values) }
    static func - (lhs: FlowMetrics, rhs: FlowMetrics) -> FlowMetrics { FlowMetrics(values: lhs.values - rhs.values) }
    mutating func scale(by rhs: Double) { values *= rhs }
    var magnitudeSquared: Double { (values * values).sum() }
}

/// 不参与动画的文字：每条流带和 MacBook 节点上的数值。
private struct FlowLabels {
    var values: [FlowSlot: String] = [:]
    var hub: String

    init(_ flow: PowerFlow) {
        for stream in flow.inputs {
            values[FlowSlot(stream.node, isInput: true)] = DisplayFormat.watts(milliwatts: stream.powerMW)
        }
        for stream in flow.outputs {
            values[FlowSlot(stream.node, isInput: false)] = DisplayFormat.watts(milliwatts: stream.powerMW)
        }
        hub = DisplayFormat.watts(milliwatts: flow.computerMW)
    }
}

/// 读数变化时 SwiftUI 对 `metrics` 插值，每一帧重新布局。
private struct AnimatedFlow: View, Animatable {
    var metrics: FlowMetrics
    let labels: FlowLabels
    let motion: FlowMotion
    @Environment(\.colorScheme) private var colorScheme

    nonisolated var animatableData: FlowMetrics {
        get { metrics }
        set { metrics = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion != .live)) { context in
            Canvas { graphics, size in
                let layout = FlowLayout(metrics: metrics, labels: labels, size: size)
                let time: TimeInterval? = switch motion {
                case .off: nil
                case .live: context.date.timeIntervalSinceReferenceDate
                case .frozen(let time): time
                }
                FlowRenderer(layout: layout, palette: FlowPalette(colorScheme: colorScheme), time: time)
                    .draw(in: &graphics)
            }
        }
    }
}

// MARK: - 布局

private struct FlowLayout {
    /// 两侧图标和数值所占的宽度。
    static let labelWidth: CGFloat = 46
    static let labelGap: CGFloat = 4
    static let barWidth: CGFloat = 5
    static let hubWidth: CGFloat = 6
    /// 流带和节点之间的空隙。
    static let bandGap: CGFloat = 2
    /// 合计较大的一侧最多占图高的比例。
    static let sideFraction: CGFloat = 0.8
    /// 流带到 MacBook 一侧收窄到的比例。
    static let hubScale: CGFloat = 0.55
    static let nodeSpacing: CGFloat = 14
    static let minBandWidth: CGFloat = 3
    /// 两侧标签（图标 + 数值）的高度。
    static let labelHeight: CGFloat = 32

    struct Node {
        var slot: FlowSlot
        var rect: CGRect
        var opacity: CGFloat
        var labelCenter: CGPoint
        var value: String
    }

    struct Band {
        var slot: FlowSlot
        var startX: CGFloat
        var endX: CGFloat
        var start: ClosedRange<CGFloat>
        var end: ClosedRange<CGFloat>
        var sourceTint: Color
        var targetTint: Color
        var opacity: CGFloat

        var path: Path {
            let midX = (startX + endX) / 2
            var path = Path()
            path.move(to: CGPoint(x: startX, y: start.lowerBound))
            path.addCurve(
                to: CGPoint(x: endX, y: end.lowerBound),
                control1: CGPoint(x: midX, y: start.lowerBound),
                control2: CGPoint(x: midX, y: end.lowerBound)
            )
            path.addLine(to: CGPoint(x: endX, y: end.upperBound))
            path.addCurve(
                to: CGPoint(x: startX, y: start.upperBound),
                control1: CGPoint(x: midX, y: end.upperBound),
                control2: CGPoint(x: midX, y: start.upperBound)
            )
            path.closeSubpath()
            return path
        }

        /// 流带在横坐标 x 处的上下边。两条边是控制点横坐标都在中点的三次曲线，先由 x 解出曲线参数。
        func edges(atX x: CGFloat) -> ClosedRange<CGFloat> {
            let u = min(1, max(0, (x - startX) / (endX - startX)))
            // x(s) = 1.5s − 1.5s² + s³，单调递增，用牛顿法求 s。
            var s = u
            for _ in 0..<4 {
                let f = 1.5 * s - 1.5 * s * s + s * s * s - u
                let df = 1.5 - 3 * s + 3 * s * s
                s = min(1, max(0, s - f / df))
            }
            let ease = 3 * s * s - 2 * s * s * s
            let top = start.lowerBound + (end.lowerBound - start.lowerBound) * ease
            let bottom = start.upperBound + (end.upperBound - start.upperBound) * ease
            return top...max(top, bottom)
        }
    }

    var nodes: [Node] = []
    var bands: [Band] = []
    var hubRect: CGRect
    var hubValue: String

    init(metrics: FlowMetrics, labels: FlowLabels, size: CGSize) {
        let height = size.height
        let midY = height / 2

        // 两侧用同一比例，保证合计较大的一侧放得下。
        var scale = CGFloat.infinity
        for slots in [FlowSlot.inputs, FlowSlot.outputs] {
            let total = slots.map { metrics.watts($0) * metrics.presence($0) }.reduce(0, +)
            guard total > 0 else { continue }
            scale = min(scale, (height * Self.sideFraction - Self.spacing(slots, metrics)) / total)
        }
        if !scale.isFinite { scale = 0 }
        let width: (FlowSlot) -> CGFloat = { max(Self.minBandWidth, metrics.watts($0) * scale) * metrics.presence($0) }

        let leftBarX = Self.labelWidth + Self.labelGap
        let rightBarX = size.width - Self.labelWidth - Self.labelGap - Self.barWidth
        let hubX = (size.width - Self.hubWidth) / 2

        var hubTop = midY
        var hubBottom = midY
        for slots in [FlowSlot.inputs, FlowSlot.outputs] {
            let isInput = slots == FlowSlot.inputs
            let sides = Self.stack(slots.map(width), spacing: Self.spacing(slots, metrics), centerY: midY)
            let hubs = Self.stack(slots.map { width($0) * Self.hubScale }, spacing: 0, centerY: midY)
            hubTop = min(hubTop, hubs.first?.lowerBound ?? midY)
            hubBottom = max(hubBottom, hubs.last?.upperBound ?? midY)

            var centers = sides.map { ($0.lowerBound + $0.upperBound) / 2 }
            Self.separateLabels(&centers, presence: slots.map(metrics.presence), height: height)

            for (index, slot) in slots.enumerated() {
                let presence = metrics.presence(slot)
                guard presence > 0.01 else { continue }
                let side = sides[index]
                let barX = isInput ? leftBarX : rightBarX
                nodes.append(Node(
                    slot: slot,
                    rect: CGRect(x: barX, y: side.lowerBound, width: Self.barWidth, height: side.upperBound - side.lowerBound),
                    opacity: presence,
                    labelCenter: CGPoint(x: isInput ? Self.labelWidth / 2 : size.width - Self.labelWidth / 2, y: centers[index]),
                    value: labels.values[slot] ?? ""
                ))
                bands.append(isInput
                    ? Band(
                        slot: slot,
                        startX: leftBarX + Self.barWidth + Self.bandGap, endX: hubX - Self.bandGap,
                        start: side, end: hubs[index],
                        sourceTint: slot.tint, targetTint: FlowStyle.hubTint, opacity: presence
                    )
                    : Band(
                        slot: slot,
                        startX: hubX + Self.hubWidth + Self.bandGap, endX: rightBarX - Self.bandGap,
                        start: hubs[index], end: side,
                        sourceTint: FlowStyle.hubTint, targetTint: slot.tint, opacity: presence
                    ))
            }
        }
        // 没有读数时竖条缩成一个圆点。
        let hubHeight = max(Self.hubWidth, hubBottom - hubTop)
        hubRect = CGRect(x: hubX, y: (hubTop + hubBottom - hubHeight) / 2, width: Self.hubWidth, height: hubHeight)
        hubValue = labels.hub
    }

    /// 一侧两个节点都显示时才留间距，出现、消失时按显示程度缩放。
    private static func spacing(_ slots: [FlowSlot], _ metrics: FlowMetrics) -> CGFloat {
        nodeSpacing * (slots.map(metrics.presence).min() ?? 0)
    }

    /// 从上到下依次排开，整体垂直居中。
    private static func stack(_ widths: [CGFloat], spacing: CGFloat, centerY: CGFloat) -> [ClosedRange<CGFloat>] {
        var y = centerY - (widths.reduce(0, +) + spacing) / 2
        return widths.map { width in
            defer { y += width + spacing }
            return y...(y + width)
        }
    }

    /// 两个标签离得太近时以中点为准向两边推开，再整体移回图内。
    private static func separateLabels(_ centers: inout [CGFloat], presence: [CGFloat], height: CGFloat) {
        let half = labelHeight / 2
        if centers.count == 2, presence.allSatisfy({ $0 > 0.01 }) {
            let minDistance = labelHeight + 4
            if centers[1] - centers[0] < minDistance {
                let mid = (centers[0] + centers[1]) / 2
                centers = [mid - minDistance / 2, mid + minDistance / 2]
            }
        }
        let shift = max(0, half - (centers.min() ?? half)) - max(0, (centers.max() ?? 0) - (height - half))
        centers = centers.map { $0 + shift }
    }
}

// MARK: - 绘制

private struct FlowRenderer {
    let layout: FlowLayout
    let palette: FlowPalette
    /// 光点所在的时刻；为 nil 时不画光点。
    let time: TimeInterval?

    /// 同一条轨道上相邻光点的平均间距。
    private static let particleSpacing: CGFloat = 44
    /// 光点拖尾的长度。
    private static let streakLength: CGFloat = 12

    func draw(in graphics: inout GraphicsContext) {
        if palette.glowOpacity > 0 {
            graphics.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.opacity = palette.glowOpacity
                for band in layout.bands {
                    layer.fill(band.path, with: gradient(for: band, opacity: band.opacity))
                }
            }
        }
        for band in layout.bands {
            let path = band.path
            graphics.fill(path, with: gradient(for: band, opacity: palette.bandOpacity * band.opacity))
            if let time {
                drawParticles(band, path: path, time: time, in: graphics)
            }
        }
        for node in layout.nodes {
            drawNode(node, in: &graphics)
        }
        drawHub(in: &graphics)
    }

    /// 节点颜色占流带的大部分，只在靠近 MacBook 的一段过渡到品牌蓝，避免橙、蓝在中段混成灰色。
    private func gradient(for band: FlowLayout.Band, opacity: Double) -> GraphicsContext.Shading {
        let source = band.sourceTint.opacity(opacity)
        let target = band.targetTint.opacity(opacity)
        let stops: [Gradient.Stop] = band.slot.isInput
            ? [.init(color: source, location: 0), .init(color: source, location: 0.5), .init(color: target, location: 1)]
            : [.init(color: source, location: 0), .init(color: target, location: 0.5), .init(color: target, location: 1)]
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: band.startX, y: 0),
            endPoint: CGPoint(x: band.endX, y: 0)
        )
    }

    /// 光点按流带宽度分成几条轨道，轨道的位置、间距、速度各不相同，光点带一段渐隐的拖尾，
    /// 沿流带从左往右移动，靠近两端时淡出。
    private func drawParticles(_ band: FlowLayout.Band, path: Path, time: TimeInterval, in graphics: GraphicsContext) {
        var context = graphics
        context.clip(to: path)
        let length = band.endX - band.startX
        let thickness = max(band.start.upperBound - band.start.lowerBound, band.end.upperBound - band.end.lowerBound)
        let lanes = max(1, min(4, Int(thickness / 18)))
        for lane in 0..<lanes {
            let seed = Self.fraction(Double(lane) * 0.618 + Double(band.slot.rawValue) * 0.37)
            let seed2 = Self.fraction(seed * 7.31 + 0.13)
            let spacing = Self.particleSpacing * (0.8 + 0.5 * seed2)
            let speed = 26 + 12 * seed
            let across = (CGFloat(lane) + 0.25 + 0.5 * seed2) / CGFloat(lanes)
            let lineWidth = 1.5 + 0.7 * seed
            var x = CGFloat((time * speed + seed * spacing).truncatingRemainder(dividingBy: spacing)) - spacing
            while x < length + Self.streakLength {
                defer { x += spacing }
                let head = min(x, length)
                let tail = max(0, x - Self.streakLength)
                guard head > tail else { continue }
                let point = { (offset: CGFloat) -> CGPoint in
                    let edges = band.edges(atX: band.startX + offset)
                    return CGPoint(x: band.startX + offset, y: edges.lowerBound + (edges.upperBound - edges.lowerBound) * across)
                }
                let fade = min(1, head / 14, (length - tail) / 14) * band.opacity
                var streak = Path()
                streak.move(to: point(tail))
                streak.addLine(to: point(head))
                context.stroke(
                    streak,
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0), .white.opacity(0.95 * fade)]),
                        startPoint: point(x - Self.streakLength),
                        endPoint: point(x)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
        }
    }

    private static func fraction(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    private func drawNode(_ node: FlowLayout.Node, in graphics: inout GraphicsContext) {
        let bar = RoundedRectangle(cornerRadius: FlowLayout.barWidth / 2, style: .continuous).path(in: node.rect)
        graphics.fill(bar, with: .color(node.slot.tint.opacity(node.opacity)))

        var context = graphics
        context.opacity = node.opacity
        let icon = Text(Image(systemName: FlowStyle.symbol(node.slot.node)))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(node.slot.tint)
        context.draw(icon, at: CGPoint(x: node.labelCenter.x, y: node.labelCenter.y - 8), anchor: .center)
        context.draw(valueText(node.value, size: 12.5), at: CGPoint(x: node.labelCenter.x, y: node.labelCenter.y + 8), anchor: .center)
    }

    /// MacBook 节点：图标写在竖条上方，数值写在下方。
    private func drawHub(in graphics: inout GraphicsContext) {
        let rect = layout.hubRect
        let bar = RoundedRectangle(cornerRadius: FlowLayout.hubWidth / 2, style: .continuous).path(in: rect)
        graphics.fill(bar, with: .color(FlowStyle.hubTint))
        let icon = Text(Image(systemName: "laptopcomputer"))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.hubIcon)
        graphics.draw(icon, at: CGPoint(x: rect.midX, y: rect.minY - 6), anchor: .bottom)
        graphics.draw(valueText(layout.hubValue, size: 12), at: CGPoint(x: rect.midX, y: rect.maxY + 5), anchor: .top)
    }

    private func valueText(_ value: String, size: CGFloat) -> Text {
        Text(verbatim: value)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
    }
}
