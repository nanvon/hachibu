import SwiftUI

/// 面板头部的碗形水位图：水位等于电量；读到充电上限时在上限位置画一道刻度，读不到不画；电量缺失时碗为空。
/// 形状取自 design/brand/bowl-mark.svg（800 × 640），见 docs/v1技术设计.md 第 19.2 节。
struct BowlGauge: View {
    let percent: Int?
    let chargeLimitPercent: Int?

    var body: some View {
        ZStack {
            BowlBody()
                .fill(Color.brand.opacity(0.12))
            BowlWater(level: Double(percent ?? 0) / 100)
                .fill(LinearGradient(colors: [Color.brand.opacity(0.75), Color.brand], startPoint: .top, endPoint: .bottom))
            if let chargeLimitPercent {
                BowlLevelLine(level: Double(chargeLimitPercent) / 100)
                    .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .clipShape(BowlBody())
            }
            BowlOutline()
                .stroke(Color.brand, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .aspectRatio(BowlGeometry.size.width / BowlGeometry.size.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text("Battery Level", bundle: .module))
        .accessibilityValue(Text(verbatim: DisplayFormat.percent(percent)))
    }
}

/// SVG 坐标。水位 0% 在碗底（圈足上沿），100% 在碗口椭圆的中线。
private enum BowlGeometry {
    static let size = CGSize(width: 800, height: 640)
    static let rimY: CGFloat = 124
    static let bottomY: CGFloat = 570

    static func y(forLevel level: Double) -> CGFloat {
        bottomY - (bottomY - rimY) * CGFloat(min(max(level, 0), 1))
    }

    static func transform(into rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / size.width, y: rect.height / size.height)
    }

    /// 碗口椭圆。
    static let rim = Path(ellipseIn: CGRect(x: 40, y: 32, width: 720, height: 184))

    /// 碗身侧面和圈足，从右侧碗口到左侧碗口，不闭合。
    static let sides: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 760, y: rimY))
        path.addLine(to: CGPoint(x: 760, y: 188))
        path.addCurve(to: CGPoint(x: 510, y: 570), control1: CGPoint(x: 760, y: 366), control2: CGPoint(x: 667, y: 514))
        path.addLine(to: CGPoint(x: 510, y: 596))
        path.addCurve(to: CGPoint(x: 400, y: 628), control1: CGPoint(x: 510, y: 619), control2: CGPoint(x: 484, y: 628))
        path.addCurve(to: CGPoint(x: 290, y: 596), control1: CGPoint(x: 316, y: 628), control2: CGPoint(x: 290, y: 619))
        path.addLine(to: CGPoint(x: 290, y: 570))
        path.addCurve(to: CGPoint(x: 40, y: 188), control1: CGPoint(x: 133, y: 514), control2: CGPoint(x: 40, y: 366))
        path.addLine(to: CGPoint(x: 40, y: rimY))
        return path
    }()

    /// 碗身内部（碗口中线以下），用于填充和裁剪。
    static let body: Path = {
        var path = sides
        path.closeSubpath()
        return path
    }()
}

private struct BowlBody: Shape {
    func path(in rect: CGRect) -> Path {
        BowlGeometry.body.applying(BowlGeometry.transform(into: rect))
    }
}

private struct BowlOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = BowlGeometry.rim
        path.addPath(BowlGeometry.sides)
        return path.applying(BowlGeometry.transform(into: rect))
    }
}

/// 水：碗身内部在水位线以下的部分。
private struct BowlWater: Shape {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let y = BowlGeometry.y(forLevel: level)
        let below = Path(CGRect(x: 0, y: y, width: BowlGeometry.size.width, height: BowlGeometry.size.height - y))
        return BowlGeometry.body.intersection(below).applying(BowlGeometry.transform(into: rect))
    }
}

/// 充电上限刻度线，绘制时按碗身裁剪。
private struct BowlLevelLine: Shape {
    var level: Double

    func path(in rect: CGRect) -> Path {
        let y = BowlGeometry.y(forLevel: level)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: BowlGeometry.size.width, y: y))
        return path.applying(BowlGeometry.transform(into: rect))
    }
}
