// Generates the app icon (a Launchpad style squircle with an app grid).
// Usage: swift Tools/make_appicon.swift <AppIcon.appiconset directory>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: swift Tools/make_appicon.swift <AppIcon.appiconset>")
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Superellipse (squircle) path, matching the macOS icon silhouette.
func squirclePath(size: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = size / 2
    func power(_ value: CGFloat) -> CGFloat { pow(abs(value), 2 / exponent) }
    for step in 0 ... steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x + radius * power(cosine) * (cosine < 0 ? -1 : 1)
        let y = center.y + radius * power(sine) * (sine < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func makeIcon(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil,
                                  width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let squircle = squirclePath(size: dimension)
    context.addPath(squircle)
    context.clip()

    // Background gradient.
    let colors = [
        CGColor(red: 0.42, green: 0.60, blue: 0.99, alpha: 1),
        CGColor(red: 0.16, green: 0.34, blue: 0.86, alpha: 1)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: dimension),
                                   end: CGPoint(x: dimension * 0.6, y: 0),
                                   options: [])
    }

    // Subtle top highlight.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.fill(CGRect(x: 0, y: dimension * 0.55, width: dimension, height: dimension * 0.45))

    // 5x3 grid of rounded squares.
    let columns = 5
    let rows = 3
    let tile = dimension * 0.118
    let gapX = dimension * 0.048
    let gapY = dimension * 0.052
    let totalWidth = CGFloat(columns) * tile + CGFloat(columns - 1) * gapX
    let totalHeight = CGFloat(rows) * tile + CGFloat(rows - 1) * gapY
    let originX = (dimension - totalWidth) / 2
    let originY = (dimension - totalHeight) / 2
    let corner = tile * 0.28

    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let rect = CGRect(x: originX + CGFloat(column) * (tile + gapX),
                              y: originY + CGFloat(row) * (tile + gapY),
                              width: tile,
                              height: tile)
            let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            context.addPath(path)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
            context.fillPath()
        }
    }

    return context.makeImage()
}

func write(_ image: CGImage, name: String) {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                           UTType.png.identifier as CFString,
                                                           1,
                                                           nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

guard let base = makeIcon(size: 1024) else {
    print("failed to render icon")
    exit(1)
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

let bitmap = NSBitmapImageRep(cgImage: base)
for variant in variants {
    if let rep = bitmap.representation(using: .png, properties: [:]), variant.size == 1024 {
        try? rep.write(to: outputDirectory.appendingPathComponent(variant.name))
        continue
    }
    // Draw the base icon scaled down for the smaller sizes.
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil,
                                  width: variant.size,
                                  height: variant.size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    context.interpolationQuality = .high
    context.draw(base, in: CGRect(x: 0, y: 0, width: variant.size, height: variant.size))
    if let image = context.makeImage() { write(image, name: variant.name) }
}
print("wrote \(variants.count) icon files to \(outputDirectory.path)")
