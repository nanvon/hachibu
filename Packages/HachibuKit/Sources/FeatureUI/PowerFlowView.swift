import BatteryCore
import SwiftUI

/// 三段功率流向图：供电方 → MacBook → 用电方。规则见 docs/v1技术设计.md 第 8 节，样式见第 19.2 节。
/// 侧边节点的高度等于流带在该侧的宽度（太小时为胶囊）；流带在 MacBook 一侧按功率收窄；数值写在流带上，太窄时写在流带上方。
/// 流带上有一道从左往右移动的高光，`isAnimating` 为 false 或开启“减弱动态效果”时停止。
struct PowerFlowView: View {
    private static let height: CGFloat = 156
    /// 高光走完一遍的时长。
    private static let shimmerPeriod: TimeInterval = 2.6

    let flow: PowerFlow
    let isAnimating: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = isAnimating && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            Canvas { graphics, size in
                let layout = FlowLayout(flow: flow, size: size)
                let progress = animates ? Self.shimmerProgress(at: context.date) : nil
                FlowRenderer(layout: layout, palette: FlowPalette(colorScheme: colorScheme), shimmerProgress: progress)
                    .draw(in: &graphics)
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private static func shimmerProgress(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
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

// MARK: - 样式

/// 节点图标和流带颜色。充电器、充电中的电池为绿色，供电的电池为橙色，系统为靛蓝。
enum FlowStyle {
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
    var nodeFill: Color
    var bandFill: Color
    var edge: Color
    var shine: Color
    var icon: Color

    init(colorScheme: ColorScheme) {
        let dark = colorScheme == .dark
        nodeFill = dark ? .white.opacity(0.16) : .white
        bandFill = dark ? .white.opacity(0.08) : .white.opacity(0.9)
        edge = dark ? .white.opacity(0.14) : .black.opacity(0.09)
        shine = dark ? .white.opacity(0.55) : .white
        icon = .primary.opacity(0.8)
    }
}

// MARK: - 布局

private struct FlowLayout {
    static let sideWidth: CGFloat = 30
    static let hubWidth: CGFloat = 46
    /// 节点和流带之间的空隙。
    static let gap: CGFloat = 6
    /// 侧边节点的最小高度，低于它时画成胶囊。
    static let minNodeHeight: CGFloat = 26
    static let nodeSpacing: CGFloat = 10
    static let minBandWidth: CGFloat = 3
    /// MacBook 节点占图高的比例。
    static let hubFraction: CGFloat = 0.78

    struct Node {
        var node: PowerFlow.Node?
        var rect: CGRect
        var symbol: String
        var tint: Color?
        var value: String?
    }

    struct Band {
        var path: Path
        var startX: CGFloat
        var endX: CGFloat
        var sourceTint: Color?
        var targetTint: Color?
        var label: String
        var labelPoint: CGPoint
        /// 流带最窄处放不下数值时，数值写在流带上方。
        var labelAbove: Bool
    }

    var nodes: [Node] = []
    var bands: [Band] = []

    init(flow: PowerFlow, size: CGSize) {
        let height = size.height
        let watts: (PowerFlow.Stream) -> CGFloat = { CGFloat(max(0, $0.powerMW ?? 0)) / 1000 }
        let maxSum = max(flow.inputs.map(watts).reduce(0, +), flow.outputs.map(watts).reduce(0, +))
        let hubHeight = height * Self.hubFraction
        let scale = maxSum > 0 ? hubHeight / maxSum : 0
        let hubRect = CGRect(x: (size.width - Self.hubWidth) / 2, y: (height - hubHeight) / 2, width: Self.hubWidth, height: hubHeight)

        let inputSides = Self.sideRects(flow.inputs.map { watts($0) * scale }, x: 0, height: height)
        let outputSides = Self.sideRects(flow.outputs.map { watts($0) * scale }, x: size.width - Self.sideWidth, height: height)
        let inputHub = Self.hubSlots(flow.inputs.map { watts($0) * scale }, in: hubRect)
        let outputHub = Self.hubSlots(flow.outputs.map { watts($0) * scale }, in: hubRect)

        for (index, stream) in flow.inputs.enumerated() {
            let side = inputSides[index]
            nodes.append(Node(node: stream.node, rect: side, symbol: FlowStyle.symbol(stream.node), tint: FlowStyle.tint(stream.node, isInput: true)))
            // 充电器的流带不着色，只有供电的电池流带起点为橙色。
            bands.append(Self.band(
                from: side.minY...side.maxY, atX: side.maxX + Self.gap,
                to: inputHub[index], atX: hubRect.minX - Self.gap,
                sourceTint: stream.node == .charger ? nil : FlowStyle.tint(stream.node, isInput: true),
                targetTint: nil,
                label: DisplayFormat.watts(milliwatts: stream.powerMW)
            ))
        }
        for (index, stream) in flow.outputs.enumerated() {
            let side = outputSides[index]
            nodes.append(Node(node: stream.node, rect: side, symbol: FlowStyle.symbol(stream.node), tint: stream.node == .system ? nil : FlowStyle.tint(stream.node, isInput: false)))
            bands.append(Self.band(
                from: outputHub[index], atX: hubRect.maxX + Self.gap,
                to: side.minY...side.maxY, atX: side.minX - Self.gap,
                sourceTint: nil,
                targetTint: FlowStyle.tint(stream.node, isInput: false),
                label: DisplayFormat.watts(milliwatts: stream.powerMW)
            ))
        }
        nodes.append(Node(node: nil, rect: hubRect, symbol: "laptopcomputer", value: DisplayFormat.watts(milliwatts: flow.computerMW)))
    }

    /// 一个节点时垂直居中；两个节点时第一个贴顶、第二个贴底。总高超出时等比缩小。
    private static func sideRects(_ bandWidths: [CGFloat], x: CGFloat, height: CGFloat) -> [CGRect] {
        var heights = bandWidths.map { max(minNodeHeight, $0) }
        let spacing = nodeSpacing * CGFloat(max(0, heights.count - 1))
        let total = heights.reduce(0, +)
        if total + spacing > height, total > 0 {
            let factor = (height - spacing) / total
            heights = heights.map { $0 * factor }
        }
        switch heights.count {
        case 1:
            return [CGRect(x: x, y: (height - heights[0]) / 2, width: sideWidth, height: heights[0])]
        default:
            var y: CGFloat = 0
            return heights.enumerated().map { index, nodeHeight in
                if index == heights.count - 1 {
                    y = height - nodeHeight
                }
                defer { y += nodeHeight + nodeSpacing }
                return CGRect(x: x, y: y, width: sideWidth, height: nodeHeight)
            }
        }
    }

    /// 流带在 MacBook 一侧按功率依次排开，整体在节点内垂直居中。
    private static func hubSlots(_ bandWidths: [CGFloat], in hub: CGRect) -> [ClosedRange<CGFloat>] {
        let widths = bandWidths.map { max(minBandWidth, $0) }
        var y = hub.midY - widths.reduce(0, +) / 2
        return widths.map { width in
            defer { y += width }
            return y...(y + width)
        }
    }

    private static func band(
        from start: ClosedRange<CGFloat>, atX startX: CGFloat,
        to end: ClosedRange<CGFloat>, atX endX: CGFloat,
        sourceTint: Color?, targetTint: Color?, label: String
    ) -> Band {
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

        // 两段对称的三次曲线在中点处的 y 等于两端 y 的平均值。
        let midTop = (start.lowerBound + end.lowerBound) / 2
        let midBottom = (start.upperBound + end.upperBound) / 2
        let thinnest = min(start.upperBound - start.lowerBound, end.upperBound - end.lowerBound)
        let labelAbove = thinnest < 17
        return Band(
            path: path,
            startX: startX,
            endX: endX,
            sourceTint: sourceTint,
            targetTint: targetTint,
            label: label,
            labelPoint: CGPoint(x: midX, y: labelAbove ? midTop - 4 : (midTop + midBottom) / 2),
            labelAbove: labelAbove
        )
    }
}

// MARK: - 绘制

private struct FlowRenderer {
    let layout: FlowLayout
    let palette: FlowPalette
    /// 高光位置，0–1；为 nil 时不画高光。
    let shimmerProgress: Double?

    private static let shimmerWidth: CGFloat = 90

    func draw(in graphics: inout GraphicsContext) {
        for band in layout.bands {
            drawBand(band, in: &graphics)
        }
        for node in layout.nodes {
            drawNode(node, in: &graphics)
        }
        for band in layout.bands {
            let text = Text(verbatim: band.label)
                .font(.system(size: band.labelAbove ? 11.5 : 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            graphics.draw(text, at: band.labelPoint, anchor: band.labelAbove ? .bottom : .center)
        }
    }

    private func drawBand(_ band: FlowLayout.Band, in graphics: inout GraphicsContext) {
        graphics.fill(band.path, with: .color(palette.bandFill))
        // 起点带供电方颜色，终点带用电方颜色，中间留白。
        let gradient = Gradient(stops: [
            .init(color: band.sourceTint?.opacity(0.32) ?? .clear, location: 0),
            .init(color: .clear, location: 0.55),
            .init(color: band.targetTint?.opacity(0.42) ?? .clear, location: 1),
        ])
        graphics.fill(
            band.path,
            with: .linearGradient(gradient, startPoint: CGPoint(x: band.startX, y: 0), endPoint: CGPoint(x: band.endX, y: 0))
        )
        if let shimmerProgress {
            // 所有流带共用同一个横坐标，高光从左段连续走到右段。
            let width = layout.bands.map(\.endX).max() ?? 0
            let x = -Self.shimmerWidth + CGFloat(shimmerProgress) * (width + Self.shimmerWidth * 1.5)
            let shine = Gradient(colors: [palette.shine.opacity(0), palette.shine.opacity(0.8), palette.shine.opacity(0)])
            graphics.fill(
                band.path,
                with: .linearGradient(shine, startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + Self.shimmerWidth, y: 0))
            )
        }
        graphics.stroke(band.path, with: .color(palette.edge), lineWidth: 0.75)
    }

    private func drawNode(_ node: FlowLayout.Node, in graphics: inout GraphicsContext) {
        let shape = RoundedRectangle(cornerRadius: min(11, node.rect.height / 2), style: .continuous).path(in: node.rect)
        graphics.fill(shape, with: .color(palette.nodeFill))
        graphics.stroke(shape, with: .color(palette.edge), lineWidth: 0.75)

        let icon = Text(Image(systemName: node.symbol))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(node.tint ?? palette.icon)
        let iconCenterY = node.value == nil ? node.rect.midY : node.rect.midY - 9
        graphics.draw(icon, at: CGPoint(x: node.rect.midX, y: iconCenterY), anchor: .center)
        if let value = node.value {
            let text = Text(verbatim: value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            graphics.draw(text, at: CGPoint(x: node.rect.midX, y: node.rect.midY + 12), anchor: .center)
        }
    }
}
