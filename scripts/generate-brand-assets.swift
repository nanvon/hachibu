#!/usr/bin/env swift
// 在仓库根目录运行：swift scripts/generate-brand-assets.swift
// 使用 macOS 自带的 CoreGraphics / CoreText 导出，无第三方依赖。
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) else {
    fatalError("请在 Hachibu 仓库根目录运行")
}

struct Ink {
    let hex: String
    var color: CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
let indigo = Ink(hex: "#102C60")
let blue = Ink(hex: "#287DD0")
let ivory = Ink(hex: "#FFFCF5")
let white = Ink(hex: "#FFFFFF")
let black = Ink(hex: "#000000")
let secondary = Ink(hex: "#53647D")

struct Shape {
    let path: CGPath
    let ink: Ink
}
struct Artwork {
    let width: CGFloat
    let height: CGFloat
    let shapes: [Shape]
}

func path(_ source: String) -> CGPath {
    let regex = try! NSRegularExpression(pattern: "[MLCZ]|-?[0-9]+(?:\\.[0-9]+)?")
    let ns = source as NSString
    let tokens = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
    let result = CGMutablePath()
    var index = 0
    func point() -> CGPoint {
        let x = Double(tokens[index])!, y = Double(tokens[index + 1])!
        index += 2
        return CGPoint(x: x, y: y)
    }
    while index < tokens.count {
        let command = tokens[index]
        index += 1
        switch command {
        case "M": result.move(to: point())
        case "L": result.addLine(to: point())
        case "C":
            let first = point(), second = point(), end = point()
            result.addCurve(to: end, control1: first, control2: second)
        case "Z": result.closeSubpath()
        default: fatalError("Unsupported path command: \(command)")
        }
    }
    return result
}

func compound(_ paths: [CGPath]) -> CGPath {
    let result = CGMutablePath()
    paths.forEach { result.addPath($0) }
    return result
}

func transformed(_ shape: Shape, scale: CGFloat = 1, x: CGFloat = 0, y: CGFloat = 0) -> Shape {
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
    return Shape(path: shape.path.copy(using: &transform)!, ink: shape.ink)
}

// 母版坐标系为 800 × 640；各用途只变换比例、位置和颜色。
let outer = path("M40 124 C40 66 202 32 400 32 C598 32 760 66 760 124 L760 188 C760 366 667 514 510 570 L510 596 C510 619 484 628 400 628 C316 628 290 619 290 596 L290 570 C133 514 40 366 40 188 Z")
let opening = path("M80 139 C80 96 236 72 400 72 C564 72 720 96 720 139 L720 206 C720 260 580 300 400 300 C220 300 80 260 80 206 Z")
let rice = path("M80 206 C115 156 185 142 240 160 C265 167 285 180 298 188 C331 147 364 128 400 128 C436 128 469 147 502 188 C572 139 663 149 720 206 C720 260 580 300 400 300 C220 300 80 260 80 206 Z")
var grainTransform = CGAffineTransform(translationX: 554, y: 225).rotated(by: -.pi / 4)
let grain = CGPath(ellipseIn: CGRect(x: -39, y: -17, width: 78, height: 34), transform: &grainTransform)
func mark(monochrome: Ink? = nil, light: Bool = false) -> [Shape] {
    [Shape(path: compound([outer, opening]), ink: monochrome ?? (light ? white : indigo)),
     Shape(path: compound([rice, grain]), ink: monochrome ?? blue)]
}

func text(_ string: String, size: CGFloat, x: CGFloat, baseline: CGFloat,
          ink: Ink = indigo, fontName: String = "AvenirNext-DemiBold") -> Shape {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let result = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont
        for index in 0..<count {
            if let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) {
                let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: x + positions[index].x,
                                                  ty: baseline - positions[index].y)
                result.addPath(outline, transform: transform)
            }
        }
    }
    return Shape(path: result, ink: ink)
}

func rectangle(_ rect: CGRect, ink: Ink) -> Shape {
    Shape(path: CGPath(rect: rect, transform: nil), ink: ink)
}

func write(_ data: Data, to relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
func svgPath(_ path: CGPath) -> String {
    var parts: [String] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        func point(_ index: Int) -> String { "\(number(element.points[index].x)) \(number(element.points[index].y))" }
        switch element.type {
        case .moveToPoint: parts.append("M\(point(0))")
        case .addLineToPoint: parts.append("L\(point(0))")
        case .addQuadCurveToPoint: parts.append("Q\(point(0)) \(point(1))")
        case .addCurveToPoint: parts.append("C\(point(0)) \(point(1)) \(point(2))")
        case .closeSubpath: parts.append("Z")
        @unknown default: fatalError("Unknown path element")
        }
    }
    return parts.joined(separator: " ")
}

func svg(_ art: Artwork, title: String, to relative: String) throws {
    let paths = art.shapes.map { "  <path fill=\"\($0.ink.hex)\" fill-rule=\"evenodd\" d=\"\(svgPath($0.path))\"/>" }
        .joined(separator: "\n")
    let source = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(number(art.width))" height="\(number(art.height))" viewBox="0 0 \(number(art.width)) \(number(art.height))" role="img" aria-labelledby="title">
      <title id="title">\(title)</title>
    \(paths)
    </svg>

    """
    try write(Data(source.utf8), to: relative)
}

func draw(_ art: Artwork, into context: CGContext) {
    for shape in art.shapes {
        context.setFillColor(shape.ink.color)
        context.addPath(shape.path)
        context.drawPath(using: .eoFill)
    }
}

func png(_ art: Artwork, scale: CGFloat = 1) -> Data {
    let context = CGContext(data: nil, width: Int((art.width * scale).rounded()),
                            height: Int((art.height * scale).rounded()), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: art.height * scale)
    context.scaleBy(x: scale, y: -scale)
    draw(art, into: context)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [
        kCGImagePropertyDPIWidth: 72 * scale,
        kCGImagePropertyDPIHeight: 72 * scale
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

func pdf(_ art: Artwork, to relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: art.width, height: art.height)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: art.height)
    context.scaleBy(x: 1, y: -1)
    draw(art, into: context)
    context.endPDFPage()
    context.closePDF()
}

func json(_ object: Any, to relative: String) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try write(data, to: relative)
}
let info: [String: Any] = ["author": "xcode", "version": 1]
let appCatalog = "App/Resources/Assets.xcassets"
let featureCatalog = "Packages/HachibuKit/Sources/FeatureUI/Resources/Assets.xcassets"
try json(["info": info], to: "\(appCatalog)/Contents.json")
try json(["info": info], to: "\(featureCatalog)/Contents.json")

let symbol = Artwork(width: 800, height: 640, shapes: mark())
try svg(symbol, title: "Hachibu rice bowl", to: "design/brand/bowl-mark.svg")
try svg(symbol, title: "Hachibu rice bowl", to: "docs/assets/brand/mark.svg")
try write(png(symbol), to: "docs/assets/brand/mark.png")

// 传统 macOS 图标：透明外缘、浅暖白底板。小尺寸仍从同一轮廓导出。
// 底板按 Apple 图标网格：1024 画布内 824 × 824，四周各留 100，与系统图标同大。
let tile = path("M271 100 L753 100 C869.7 100 924 154.3 924 271 L924 753 C924 869.7 869.7 924 753 924 L271 924 C154.3 924 100 869.7 100 753 L100 271 C100 154.3 154.3 100 271 100 Z")
let appIcon = Artwork(width: 1024, height: 1024,
                      shapes: [Shape(path: tile, ink: ivory)] + mark().map { transformed($0, scale: 0.8645, x: 166.2, y: 222.3) })
try svg(appIcon, title: "Hachibu app icon", to: "design/brand/app-icon-master.svg")
try write(png(appIcon), to: "docs/assets/brand/app-icon.png")
var iconImages: [[String: Any]] = []
var pngBySize: [Int: Data] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = pngBySize[size] ?? png(appIcon, scale: CGFloat(size) / 1024)
        pngBySize[size] = data
        try write(data, to: "\(appCatalog)/AppIcon.appiconset/\(filename)")
        iconImages.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
    }
}
try json(["images": iconImages, "info": info], to: "\(appCatalog)/AppIcon.appiconset/Contents.json")

let menu = Artwork(width: 22, height: 18, shapes: mark(monochrome: black).map {
    transformed($0, scale: 0.0275, y: -0.075)
})
try svg(Artwork(width: 800, height: 640, shapes: mark(monochrome: black)), title: "Hachibu menu bar template", to: "design/brand/menubar-template.svg")
try pdf(menu, to: "\(appCatalog)/MenuBarIcon.imageset/MenuBarIcon.pdf")
try json(["images": [["filename": "MenuBarIcon.pdf", "idiom": "mac"]], "info": info,
          "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]],
         to: "\(appCatalog)/MenuBarIcon.imageset/Contents.json")

// 所有字标转为路径，使用者无需安装字体；字体文件不分发。
func logo(light: Bool) -> Artwork {
    let ink = light ? white : indigo
    return Artwork(width: 1040, height: 248, shapes:
        mark(light: light).map { transformed($0, scale: 0.34, x: 6, y: 6) } + [
            text("Hachibu", size: 120, x: 302, baseline: 153, ink: ink)
        ])
}
for light in [false, true] {
    let name = light ? "logo-dark" : "logo-light"
    let art = logo(light: light)
    // README 按画布居中；左右保留相同留白，应用内 PDF 仍沿用原尺寸。
    let bounds = art.shapes.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    let readmeLogo = Artwork(width: ceil(bounds.maxX + bounds.minX), height: art.height, shapes: art.shapes)
    try svg(readmeLogo, title: "Hachibu", to: "design/brand/\(name).svg")
    try svg(readmeLogo, title: "Hachibu", to: "docs/assets/brand/\(name).svg")
    try write(png(readmeLogo), to: "docs/assets/brand/\(name).png")
    try pdf(art, to: "\(featureCatalog)/BrandLogo.imageset/\(name).pdf")
}
try json(["images": [
    ["filename": "logo-light.pdf", "idiom": "mac"],
    ["filename": "logo-dark.pdf", "idiom": "mac", "appearances": [["appearance": "luminosity", "value": "dark"]]]
], "info": info, "properties": ["preserves-vector-representation": true]],
         to: "\(featureCatalog)/BrandLogo.imageset/Contents.json")

func cover(chinese: Bool) -> Artwork {
    Artwork(width: 1280, height: 640, shapes: [
        rectangle(CGRect(x: 0, y: 0, width: 1280, height: 640), ink: ivory),
        text("Hachibu", size: 108, x: 82, baseline: 287),
        text(chinese ? "macOS 菜单栏电池监控" : "Battery monitor for macOS", size: chinese ? 30 : 29,
             x: 86, baseline: 352, fontName: chinese ? "PingFangSC-Regular" : "AvenirNext-Regular"),
        text(chinese ? "功率 · 温度 · 电池健康" : "Power · Temperature · Battery health", size: chinese ? 23 : 22,
             x: 86, baseline: 526, ink: secondary,
             fontName: chinese ? "PingFangSC-Regular" : "AvenirNext-Regular")
    ] + mark().map { transformed($0, scale: 0.57, x: 770, y: 137) })
}
for chinese in [false, true] {
    let filename = chinese ? "readme-banner-zh-Hans" : "github-social-preview"
    try svg(cover(chinese: chinese), title: "Hachibu — Battery monitor for macOS", to: "docs/assets/promo/\(filename).svg")
    try write(png(cover(chinese: chinese)), to: "docs/assets/promo/\(filename).png")
}

// Finder 会显示文件名，安装背景不重复绘制文件名或虚构图标。
let arrow = path("M294 232 L354 232 L343 221 L349 215 L370 236 L349 257 L343 251 L354 240 L294 240 Z")
let dmg = Artwork(width: 660, height: 440, shapes: [
    rectangle(CGRect(x: 0, y: 0, width: 660, height: 440), ink: ivory),
    text("Hachibu", size: 29, x: 87, baseline: 66),
    text("Drag Hachibu to Applications", size: 14, x: 88, baseline: 91, ink: secondary, fontName: "AvenirNext-Regular"),
    Shape(path: arrow, ink: blue)
] + mark().map { transformed($0, scale: 0.0625, x: 26, y: 29) })
try svg(dmg, title: "Hachibu installer background", to: "packaging/dmg/background.svg")
try write(png(dmg), to: "packaging/dmg/background.png")
try write(png(dmg, scale: 2), to: "packaging/dmg/background@2x.png")
try json(["window": ["width": 660, "height": 440], "iconSize": 96,
          "background": "background.png", "volumeIcon": "VolumeIcon.icns",
          "application": ["name": "Hachibu.app", "x": 180, "y": 236],
          "applications": ["x": 480, "y": 236]],
         to: "packaging/dmg/layout.json")

// 标准 ICNS 容器，用于 DMG 卷图标；App 本身使用 AppIcon 资源集。
func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var chunks = Data()
for (size, tag) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let image = pngBySize[size]!
    chunks.append(Data(tag.utf8))
    chunks.append(bigEndian(UInt32(image.count + 8)))
    chunks.append(image)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(chunks.count + 8)))
icns.append(chunks)
try write(icns, to: "packaging/dmg/VolumeIcon.icns")

// 资源总览：仅静态品牌素材，不包含虚构的应用截图。
let preview = Artwork(width: 1280, height: 1240, shapes: [
    rectangle(CGRect(x: 0, y: 0, width: 1280, height: 1240), ink: ivory),
    text("Hachibu", size: 52, x: 64, baseline: 88),
    text("App icon · Menu bar · Brand · Release", size: 23, x: 65, baseline: 127, ink: secondary, fontName: "AvenirNext-Regular"),
    rectangle(CGRect(x: 64, y: 534, width: 1152, height: 140), ink: indigo)
] + appIcon.shapes.map { transformed($0, scale: 0.32, x: 70, y: 164) }
  + logo(light: false).shapes.map { transformed($0, scale: 0.66, x: 470, y: 230) }
  + mark(monochrome: black).map { transformed($0, scale: 0.075, x: 544, y: 439) }
  + [text("80%", size: 30, x: 623, baseline: 481, ink: black),
     text("14.5 W", size: 30, x: 810, baseline: 481, ink: black)]
  + mark(monochrome: black).map { transformed($0, scale: 0.075, x: 731, y: 439) }
  + logo(light: true).shapes.map { transformed($0, scale: 0.48, x: 390, y: 546) }
  + cover(chinese: false).shapes.map { transformed($0, scale: 0.9, x: 64, y: 697) })
try write(png(preview), to: "docs/assets/brand/overview.png")
print("已导出 AppIcon、菜单栏矢量 PDF、深浅色 Logo、宣传封面、DMG 背景与可编辑 SVG。")
