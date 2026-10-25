import AppKit

/// 独立绘制的电池外观。尺寸参照 macOS 27 / iOS 27，未嵌入系统私有资源或 UI Kit 路径。
struct BatteryIconDrawing {
    enum Style { case macOS, iOS }
    enum Mark { case none, charging, pluggedIn }

    let style: Style
    let percent: Int?
    let mark: Mark
    let lowPower: Bool
    let isDark: Bool

    var size: NSSize {
        NSSize(width: style == .macOS ? 26 : 30, height: 18)
    }

    private var accent: NSColor? {
        if lowPower { return .systemYellow }
        if style == .iOS && mark == .charging { return .systemGreen }
        if let percent, percent <= 20 { return .systemRed }
        return nil
    }

    /// 先在透明位图中完成混合，再交给菜单栏；挖空数字和标记不会影响菜单栏背景。
    @MainActor
    func image() -> NSImage {
        let image = NSImage(size: size)
        for scale: CGFloat in [1, 2] {
            guard let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let foreground: NSColor = accent == nil ? .black : (isDark ? .white : .black)
            switch style {
            case .macOS: drawMac(in: context, foreground: foreground)
            case .iOS: drawIOS(in: context, foreground: foreground)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let bitmap = context.makeImage() {
                let representation = NSBitmapImageRep(cgImage: bitmap)
                representation.size = size
                image.addRepresentation(representation)
            }
        }
        image.isTemplate = accent == nil
        return image
    }

    private func drawMac(in context: CGContext, foreground: NSColor) {
        let body = CGRect(x: 0, y: 3, width: 23, height: 12)
        let outline = CGMutablePath()
        outline.addPath(Self.continuousRect(body, radius: 3.95, exponent: 2.4))
        outline.addPath(Self.continuousRect(body.insetBy(dx: 1, dy: 1), radius: 2.95, exponent: 2.4))
        context.addPath(outline)
        context.setFillColor(foreground.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        drawContact(in: context, rect: CGRect(x: 24, y: 6.875, width: 1.5, height: 4.25), color: foreground.withAlphaComponent(0.6))
        if let percent, percent > 0 {
            let fill = CGRect(x: 2, y: 5, width: 19 * CGFloat(percent) / 100, height: 8)
            context.addPath(CGPath(roundedRect: fill, cornerWidth: min(1, fill.width / 2), cornerHeight: 1, transform: nil))
            context.setFillColor((accent ?? foreground).cgColor)
            context.fillPath()
        }
        if percent == nil {
            drawText("?", center: CGPoint(x: 11.5, y: 9), size: 10, color: foreground, knockout: true, in: context)
        } else if mark != .none {
            let path = Self.markPath(mark, in: CGRect(x: 7.5, y: mark == .charging ? 3 : 2.5, width: 8, height: mark == .charging ? 12 : 13))
            context.saveGState()
            context.setBlendMode(.destinationOut)
            context.addPath(path)
            context.setLineWidth(2)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
            context.addPath(path)
            context.setFillColor(foreground.cgColor)
            context.fillPath()
        }
    }

    private func drawIOS(in context: CGContext, foreground: NSColor) {
        let body = CGRect(x: 0, y: 2.1666667, width: 26.3333333, height: 13.6666667)
        let path = Self.continuousRect(body, radius: 4.75, exponent: 2.35)
        context.addPath(path)
        context.setFillColor(foreground.withAlphaComponent(0.28).cgColor)
        context.fillPath()
        drawContact(in: context, rect: CGRect(x: 27.3333333, y: 6.5, width: 2, height: 5), color: foreground.withAlphaComponent(0.4))
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let percent, percent > 0 {
            context.setFillColor((accent ?? foreground).cgColor)
            context.fill(CGRect(x: body.minX, y: body.minY, width: body.width * CGFloat(percent) / 100, height: body.height))
        }
        context.restoreGState()

        let showsMark = percent != nil && mark != .none
        let text = percent.map(String.init) ?? "?"
        let fontSize: CGFloat = showsMark && percent == 100 ? 9 : 10
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)]).width
        let groupWidth = textWidth + (showsMark ? 6 : 0)
        let textCenter = CGPoint(x: (body.width - groupWidth + textWidth) / 2, y: 9)
        let ink: NSColor = accent == nil ? .black : (accent == .systemRed ? .white : .black)
        drawText(text, center: textCenter, size: fontSize, color: ink, knockout: accent == nil, in: context)
        if showsMark {
            let symbol = Self.markPath(mark, in: CGRect(x: (body.width + groupWidth) / 2 - 4.5, y: 5, width: 4.5, height: 8))
            context.saveGState()
            if accent == nil { context.setBlendMode(.destinationOut) }
            context.addPath(symbol)
            context.setFillColor(ink.cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }

    private func drawText(_ text: String, center: CGPoint, size: CGFloat, color: NSColor, knockout: Bool, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color,
        ]
        let string = text as NSString
        let bounds = string.size(withAttributes: attributes)
        context.saveGState()
        if knockout {
            // 未知电量的问号加透明描边，避免与填充粘连。
            if style == .macOS {
                let outlined: [NSAttributedString.Key: Any] = attributes.merging([
                    .strokeWidth: -20, .strokeColor: NSColor.black,
                ]) { _, new in new }
                context.setBlendMode(.destinationOut)
                string.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2), withAttributes: outlined)
                context.setBlendMode(.normal)
            } else {
                context.setBlendMode(.destinationOut)
            }
        }
        string.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2), withAttributes: attributes)
        context.restoreGState()
    }

    /// 圆角由超椭圆方程生成；不保存参考素材中的贝塞尔控制点。
    private static func continuousRect(_ rect: CGRect, radius: CGFloat, exponent: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (rect.maxX - radius, rect.maxY - radius, 0),
            (rect.minX + radius, rect.maxY - radius, .pi / 2),
            (rect.minX + radius, rect.minY + radius, .pi),
            (rect.maxX - radius, rect.minY + radius, .pi * 1.5),
        ]
        for (index, corner) in corners.enumerated() {
            for step in 0...48 {
                let angle = corner.2 + CGFloat(step) / 48 * .pi / 2
                let c = cos(angle), s = sin(angle)
                let point = CGPoint(
                    x: corner.0 + radius * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
                    y: corner.1 + radius * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
                )
                if index == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }

    private func drawContact(in context: CGContext, rect: CGRect, color: NSColor) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: rect.minX - rect.width, y: rect.minY, width: rect.width * 2, height: rect.height))
        context.restoreGState()
    }

    /// 用单位坐标独立绘制细长闪电和竖向插头，避免 SF Symbols 插头方向、留白不同。
    private static func markPath(_ mark: Mark, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        if mark == .charging {
            let points: [CGPoint] = [
                CGPoint(x: 0.72, y: 1), CGPoint(x: 0, y: 0.43), CGPoint(x: 0.43, y: 0.43),
                CGPoint(x: 0.25, y: 0), CGPoint(x: 1, y: 0.57), CGPoint(x: 0.57, y: 0.57),
            ]
            let scaled = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            // 以实际点数倒圆，保持闪电尖端细小且不过度尖锐。
            for index in scaled.indices {
                let previous = scaled[(index + scaled.count - 1) % scaled.count]
                let current = scaled[index]
                let next = scaled[(index + 1) % scaled.count]
                func approach(_ point: CGPoint) -> CGPoint {
                    let distance = hypot(point.x - current.x, point.y - current.y)
                    let amount = min(0.3, distance / 3) / distance
                    return CGPoint(x: current.x + (point.x - current.x) * amount, y: current.y + (point.y - current.y) * amount)
                }
                let entry = approach(previous), exit = approach(next)
                if index == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
                path.addQuadCurve(to: exit, control: current)
            }
            path.closeSubpath()
            return path
        } else {
            path.addRoundedRect(in: CGRect(x: 0.19, y: 0.58, width: 0.16, height: 0.42), cornerWidth: 0.08, cornerHeight: 0.05)
            path.addRoundedRect(in: CGRect(x: 0.65, y: 0.58, width: 0.16, height: 0.42), cornerWidth: 0.08, cornerHeight: 0.05)
            path.move(to: CGPoint(x: 0.06, y: 0.77))
            path.addLine(to: CGPoint(x: 0.94, y: 0.77))
            path.addLine(to: CGPoint(x: 0.94, y: 0.54))
            path.addCurve(to: CGPoint(x: 0.63, y: 0.31), control1: CGPoint(x: 0.94, y: 0.4), control2: CGPoint(x: 0.79, y: 0.34))
            path.addLine(to: CGPoint(x: 0.63, y: 0.03))
            path.addQuadCurve(to: CGPoint(x: 0.37, y: 0.03), control: CGPoint(x: 0.5, y: -0.03))
            path.addLine(to: CGPoint(x: 0.37, y: 0.31))
            path.addCurve(to: CGPoint(x: 0.06, y: 0.54), control1: CGPoint(x: 0.21, y: 0.34), control2: CGPoint(x: 0.06, y: 0.4))
            path.closeSubpath()
        }
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width, y: rect.height)
        return path.copy(using: &transform)!
    }
}
