// Launchpad 图标设计：三个方案，按苹果标准图标网格绘制（1024 画布内容 824）。
// 用法：
//   swift Tools/IconDesign.swift sheet <输出.png>            # 生成对比图
//   swift Tools/IconDesign.swift appiconset <目录> [方案名]   # 生成 AppIcon.appiconset
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Variant: String, CaseIterable {
    case classic   // 经典：银白底 + 彩色 3x3 小方块（最接近系统启动台图标）
    case glass     // 玻璃：蓝色渐变 + 白色小方块（当前图标的精修版）
    case midnight  // 深空：深蓝底 + 星光 + 白色小方块

    var title: String {
        switch self {
        case .classic: return "经典银白"
        case .glass: return "蓝色玻璃"
        case .midnight: return "深空星点"
        }
    }
}

/// 苹果图标网格：内容占画布的 824/1024，其余留白给投影。
let contentRatio: CGFloat = 824.0 / 1024.0

func squirclePath(rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    let rx = rect.width / 2
    let ry = rect.height / 2
    func power(_ value: CGFloat) -> CGFloat { pow(abs(value), 2 / exponent) }
    for step in 0 ... steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = rect.midX + rx * power(cosine) * (cosine < 0 ? -1 : 1)
        let y = rect.midY + ry * power(sine) * (sine < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func gradient(_ context: CGContext, colors: [CGColor], from: CGPoint, to: CGPoint) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
    context.drawLinearGradient(gradient, start: from, end: to, options: [])
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// 3x3 小方块的配色（classic 用彩色，其余用白色）。
func tileColors(for variant: Variant) -> [CGColor] {
    switch variant {
    case .classic:
        return [
            rgb(0.29, 0.52, 0.98), rgb(0.24, 0.78, 0.44), rgb(0.98, 0.42, 0.55),
            rgb(0.99, 0.66, 0.24), rgb(0.20, 0.72, 0.83), rgb(0.55, 0.42, 0.94),
            rgb(0.98, 0.78, 0.20), rgb(0.95, 0.35, 0.32), rgb(0.35, 0.45, 0.95)
        ]
    case .glass:
        return Array(repeating: rgb(1, 1, 1, 0.96), count: 9)
    case .midnight:
        return Array(repeating: rgb(0.93, 0.96, 1.0, 0.95), count: 9)
    }
}

func drawIcon(variant: Variant, size: Int) -> CGImage? {
    let canvas = CGFloat(size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil,
                                  width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let content = canvas * contentRatio
    let rect = CGRect(x: (canvas - content) / 2, y: (canvas - content) / 2, width: content, height: content)
    let path = squirclePath(rect: rect)

    // 系统图标自带的那层柔和投影（落在留白里）
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012),
                      blur: canvas * 0.035,
                      color: rgb(0, 0, 0, 0.32))
    context.addPath(path)
    context.setFillColor(rgb(0.5, 0.5, 0.55))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()

    // 底色
    switch variant {
    case .classic:
        gradient(context,
                 colors: [rgb(0.99, 0.99, 1.0), rgb(0.89, 0.91, 0.94)],
                 from: CGPoint(x: rect.minX, y: rect.maxY),
                 to: CGPoint(x: rect.maxX, y: rect.minY))
    case .glass:
        gradient(context,
                 colors: [rgb(0.36, 0.58, 0.99), rgb(0.12, 0.31, 0.85)],
                 from: CGPoint(x: rect.minX, y: rect.maxY),
                 to: CGPoint(x: rect.maxX, y: rect.minY))
    case .midnight:
        gradient(context,
                 colors: [rgb(0.16, 0.21, 0.38), rgb(0.05, 0.07, 0.15)],
                 from: CGPoint(x: rect.minX, y: rect.maxY),
                 to: CGPoint(x: rect.maxX, y: rect.minY))
        // 星点（确定性伪随机，保证每次生成一致）
        var seed: UInt64 = 0x5DEECE66D
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10000) / 10000
        }
        for _ in 0 ..< 90 {
            let x = rect.minX + next() * rect.width
            let y = rect.minY + next() * rect.height
            let radius = content * (0.0015 + next() * 0.004)
            context.setFillColor(rgb(1, 1, 1, 0.10 + next() * 0.35))
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
        }
    }

    // 顶部高光
    gradient(context,
             colors: [rgb(1, 1, 1, variant == .classic ? 0.55 : 0.22), rgb(1, 1, 1, 0)],
             from: CGPoint(x: rect.midX, y: rect.maxY),
             to: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.05))

    // 3x3 小方块
    let columns = 3
    let tile = content * 0.155
    let gap = content * 0.055
    let total = CGFloat(columns) * tile + CGFloat(columns - 1) * gap
    let originX = rect.midX - total / 2
    let originY = rect.midY - total / 2
    let colors = tileColors(for: variant)
    let tileRadius = tile * 0.29

    for row in 0 ..< columns {
        for column in 0 ..< columns {
            let tileRect = CGRect(x: originX + CGFloat(column) * (tile + gap),
                                  y: originY + CGFloat(row) * (tile + gap),
                                  width: tile,
                                  height: tile)
            let tilePath = CGPath(roundedRect: tileRect,
                                  cornerWidth: tileRadius,
                                  cornerHeight: tileRadius,
                                  transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -content * 0.004),
                              blur: content * 0.012,
                              color: rgb(0, 0, 0, variant == .classic ? 0.18 : 0.28))
            context.addPath(tilePath)
            context.setFillColor(colors[row * columns + column])
            context.fillPath()
            context.restoreGState()

            // 小块自身的顶部高光，让它有玻璃质感
            context.saveGState()
            context.addPath(tilePath)
            context.clip()
            gradient(context,
                     colors: [rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0)],
                     from: CGPoint(x: tileRect.midX, y: tileRect.maxY),
                     to: CGPoint(x: tileRect.midX, y: tileRect.midY))
            context.restoreGState()
        }
    }

    // 内描边：让边缘和系统图标一样有一圈细微的明暗过渡
    context.addPath(path)
    context.setLineWidth(max(1, canvas * 0.0035))
    context.setStrokeColor(rgb(0, 0, 0, 0.10))
    context.strokePath()

    context.restoreGState()
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                           UTType.png.identifier as CFString,
                                                           1,
                                                           nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: - 入口

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("""
    usage:
      swift Tools/IconDesign.swift sheet <out.png>
      swift Tools/IconDesign.swift appiconset <AppIcon.appiconset> [classic|glass|midnight]
    """)
    exit(1)
}

switch arguments[1] {
case "sheet":
    let url = URL(fileURLWithPath: arguments[2])
    let preview = 256
    let small = 64
    let tiny = 32
    let width = preview * Variant.allCases.count
    let height = preview + small + tiny + 40
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.setFillColor(rgb(0.10, 0.11, 0.13))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, variant) in Variant.allCases.enumerated() {
        let baseX = CGFloat(index * preview)
        if let big = drawIcon(variant: variant, size: preview) {
            context.draw(big, in: CGRect(x: baseX, y: CGFloat(height - preview), width: CGFloat(preview), height: CGFloat(preview)))
        }
        if let mid = drawIcon(variant: variant, size: small) {
            context.draw(mid, in: CGRect(x: baseX + 16, y: 12, width: CGFloat(small), height: CGFloat(small)))
        }
        if let smallIcon = drawIcon(variant: variant, size: tiny) {
            context.draw(smallIcon, in: CGRect(x: baseX + 16 + CGFloat(small) + 12, y: 12,
                                               width: CGFloat(tiny), height: CGFloat(tiny)))
        }
    }
    guard let sheet = context.makeImage(), write(sheet, to: url) else { exit(1) }
    print("sheet written to \(url.path) (\(width)x\(height))")

case "appiconset":
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let variant = Variant(rawValue: arguments.count > 3 ? arguments[3] : "classic") ?? .classic
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let base = drawIcon(variant: variant, size: 1024) else { exit(1) }
    let variants: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, size) in variants {
        let url = directory.appendingPathComponent(name)
        if size == 1024 {
            _ = write(base, to: url)
        } else if let scaled = drawIcon(variant: variant, size: size) {
            _ = write(scaled, to: url)
        }
    }
    print("appiconset (\(variant.rawValue)) written to \(directory.path)")

default:
    exit(1)
}
