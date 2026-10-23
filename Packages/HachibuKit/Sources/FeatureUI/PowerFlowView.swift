import BatteryCore
import SwiftUI

/// 三节点功率流向图。左列放供电方，右列放用电方，电池按方向换列。规则见 docs/v1技术设计.md 第 8 节，样式见第 19 节。
struct PowerFlowView: View {
    private static let height: CGFloat = 112
    private static let nodeSize = CGSize(width: 104, height: 40)
    /// 所有流带共用的 W → 宽度比例。
    private static let pointsPerWatt: CGFloat = 0.5
    private static let minLinkWidth: CGFloat = 2
    private static let maxLinkWidth: CGFloat = 36

    let flow: PowerFlow
    let isExternalPower: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(flow: flow, size: geometry.size, nodeWidth: Self.nodeSize.width)
            ZStack {
                Canvas { context, _ in
                    for ribbon in layout.ribbons(for: flow.links, width: Self.linkWidth) {
                        var path = Path()
                        path.move(to: ribbon.start)
                        let midX = (ribbon.start.x + ribbon.end.x) / 2
                        path.addCurve(
                            to: ribbon.end,
                            control1: CGPoint(x: midX, y: ribbon.start.y),
                            control2: CGPoint(x: midX, y: ribbon.end.y)
                        )
                        // 从供电方颜色渐变到用电方颜色。
                        let opacity = ribbon.link.powerMW == nil ? 0.25 : 0.55
                        let gradient = Gradient(colors: [
                            tint(of: ribbon.link.from).opacity(opacity),
                            tint(of: ribbon.link.to).opacity(opacity),
                        ])
                        context.stroke(
                            path,
                            with: .linearGradient(gradient, startPoint: ribbon.start, endPoint: ribbon.end),
                            style: StrokeStyle(lineWidth: ribbon.width, lineCap: .butt)
                        )
                    }
                }
                ForEach(layout.nodes, id: \.node) { placed in
                    NodeView(node: placed.node, milliwatts: milliwatts(for: placed.node), tint: tint(of: placed.node))
                        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
                        .opacity(placed.node == .charger && !isExternalPower ? 0.4 : 1)
                        .position(placed.center)
                }
            }
        }
        .frame(height: Self.height)
    }

    /// 节点数值直接取原始读数。
    private func milliwatts(for node: PowerFlow.Node) -> Int? {
        switch node {
        case .charger: flow.chargerMW
        case .computer: flow.computerMW
        case .battery: flow.batteryMW
        }
    }

    /// 充电器绿色；电池供电时橙色，充电时绿色；电脑为品牌蓝。
    private func tint(of node: PowerFlow.Node) -> Color {
        switch node {
        case .charger: .green
        case .battery: flow.links.contains { $0.from == .battery } ? .orange : .green
        case .computer: .brand
        }
    }

    /// 读数缺失时画最小宽度。
    private static func linkWidth(_ link: PowerFlow.Link) -> CGFloat {
        guard let powerMW = link.powerMW else { return minLinkWidth }
        let width = CGFloat(powerMW) / 1000 * pointsPerWatt
        return min(max(width, minLinkWidth), maxLinkWidth)
    }
}

// MARK: - 布局

private struct Layout {
    struct PlacedNode {
        var node: PowerFlow.Node
        var center: CGPoint
    }

    struct Ribbon {
        var link: PowerFlow.Link
        var start: CGPoint
        var end: CGPoint
        var width: CGFloat
    }

    var nodes: [PlacedNode]
    private let nodeWidth: CGFloat

    /// 充电器固定在左列，电脑固定在右列；电池向电脑供电时在左列，否则在右列。
    /// 一列两个节点时上下排列，一个节点时垂直居中。
    init(flow: PowerFlow, size: CGSize, nodeWidth: CGFloat) {
        self.nodeWidth = nodeWidth
        let batteryIsSupplier = flow.links.contains { $0.from == .battery }
        let left: [PowerFlow.Node] = batteryIsSupplier ? [.charger, .battery] : [.charger]
        let right: [PowerFlow.Node] = batteryIsSupplier ? [.computer] : [.computer, .battery]
        nodes = Self.place(left, x: nodeWidth / 2, height: size.height)
            + Self.place(right, x: size.width - nodeWidth / 2, height: size.height)
    }

    private static func place(_ column: [PowerFlow.Node], x: CGFloat, height: CGFloat) -> [PlacedNode] {
        column.enumerated().map { index, node in
            PlacedNode(node: node, center: CGPoint(x: x, y: height * (CGFloat(index) + 0.5) / CGFloat(column.count)))
        }
    }

    func center(of node: PowerFlow.Node) -> CGPoint {
        nodes.first { $0.node == node }?.center ?? .zero
    }

    /// 流带从供电方右边缘连到用电方左边缘。同一节点有多条流带时按对端的上下位置依次排开，不重叠。
    func ribbons(for links: [PowerFlow.Link], width: (PowerFlow.Link) -> CGFloat) -> [Ribbon] {
        let widths = links.map(width)

        func offset(of index: Int, among siblings: [Int], sortedBy key: (Int) -> CGFloat) -> CGFloat {
            let ordered = siblings.sorted { key($0) < key($1) }
            let total = ordered.reduce(0) { $0 + widths[$1] }
            var position = -total / 2
            for sibling in ordered {
                if sibling == index { return position + widths[sibling] / 2 }
                position += widths[sibling]
            }
            return 0
        }

        return links.indices.map { index in
            let link = links[index]
            let source = center(of: link.from)
            let target = center(of: link.to)
            let outgoing = links.indices.filter { links[$0].from == link.from }
            let incoming = links.indices.filter { links[$0].to == link.to }
            let startOffset = offset(of: index, among: outgoing) { center(of: links[$0].to).y }
            let endOffset = offset(of: index, among: incoming) { center(of: links[$0].from).y }
            return Ribbon(
                link: link,
                start: CGPoint(x: source.x + nodeWidth / 2, y: source.y + startOffset),
                end: CGPoint(x: target.x - nodeWidth / 2, y: target.y + endOffset),
                width: widths[index]
            )
        }
    }
}

// MARK: - 节点

/// 节点为玻璃胶囊，图标带颜色。
private struct NodeView: View {
    let node: PowerFlow.Node
    let milliwatts: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: DisplayFormat.watts(milliwatts: milliwatts))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelGlass(in: Capsule())
    }

    private var symbolName: String {
        switch node {
        case .charger: "powerplug"
        case .computer: "laptopcomputer"
        case .battery: "battery.100percent"
        }
    }

    private var title: Text {
        switch node {
        case .charger: Text("Charger", bundle: .module)
        case .computer: Text("Computer", bundle: .module)
        case .battery: Text("Battery", bundle: .module)
        }
    }
}
