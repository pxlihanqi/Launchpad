import AppKit
import CoreImage
import Foundation

/// All wallpaper processing happens on the CPU/GPU through Core Image so the
/// result can also be produced headlessly (used for snapshot tests).
enum ImageEffects {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func ciImage(_ image: CGImage) -> CIImage { CIImage(cgImage: image) }

    static func render(_ image: CIImage, rect: CGRect? = nil) -> CGImage? {
        let extent = rect ?? image.extent
        return context.createCGImage(image, from: extent)
    }

    /// Scales and crops an image to fill `size` (aspect fill).
    static func aspectFill(_ image: CGImage, size: CGSize) -> CGImage? {
        let source = CGSize(width: image.width, height: image.height)
        guard source.width > 0, source.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / source.width, size.height / source.height)
        let scaled = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.extent
        let crop = CGRect(
            x: bounds.origin.x + (bounds.width - size.width) / 2,
            y: bounds.origin.y + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return render(scaled, rect: crop)
    }

    /// Maps a rectangle in display space onto the source image, honouring the
    /// aspect-fill geometry used by `aspectFill`.
    static func sourceRect(forDisplayRect rect: CGRect, displaySize: CGSize, imageSize: CGSize) -> CGRect {
        let scale = max(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (displaySize.width - displayed.width) / 2,
                             y: (displaySize.height - displayed.height) / 2)
        return CGRect(
            x: (rect.minX - origin.x) / scale,
            y: (rect.minY - origin.y) / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped.integral)
    }

    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0 else { return image }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        return render(output, rect: input.extent)
    }

    static func colorAdjusted(_ image: CGImage, saturation: CGFloat, brightness: CGFloat, contrast: CGFloat = 1) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        guard let output = filter.outputImage else { return image }
        return render(output, rect: input.extent)
    }

    /// Composites a black overlay of `alpha` on top of the image.
    static func darkened(_ image: CGImage, alpha: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let overlay = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha)).cropped(to: input.extent)
        let output = overlay.composited(over: input)
        return render(output, rect: input.extent)
    }

    /// The Launchpad backdrop: heavily blurred wallpaper with boosted
    /// saturation and a dark overlay.
    static func backdrop(from raw: CGImage,
                         size: CGSize,
                         blur: CGFloat = 46,
                         darken: CGFloat = 0.22,
                         saturation: CGFloat = 1.18,
                         brightness: CGFloat = -0.06) -> CGImage? {
        // Work at half resolution: Launchpad's backdrop is soft anyway and this
        // keeps the first paint instant.
        let workSize = CGSize(width: max(320, size.width * 0.5), height: max(200, size.height * 0.5))
        guard let filled = aspectFill(raw, size: workSize) else { return nil }
        guard let blurred = blurred(filled, radius: blur * 0.5) else { return nil }
        guard let adjusted = colorAdjusted(blurred, saturation: saturation, brightness: brightness) else { return nil }
        return darkened(adjusted, alpha: darken)
    }

    /// Fallback backdrop when the wallpaper cannot be read.
    static func gradient(size: CGSize) -> CGImage? {
        let width = Int(max(160, size.width / 4))
        let height = Int(max(120, size.height / 4))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [
                                            CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
                                            CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
                                        ] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: height),
                                   end: CGPoint(x: width, y: 0),
                                   options: [])
        return context.makeImage()
    }

    /// Blurred wallpaper sample used as the glass behind a folder icon.
    static func glassSample(raw: CGImage,
                            displayRect: CGRect,
                            displaySize: CGSize,
                            blur: CGFloat = 20) -> CGImage? {
        let source = sourceRect(forDisplayRect: displayRect,
                                displaySize: displaySize,
                                imageSize: CGSize(width: raw.width, height: raw.height))
        guard let crop = cropped(raw, to: source) else { return nil }
        guard let blurred = blurred(crop, radius: blur) else { return nil }
        return colorAdjusted(blurred, saturation: 1.25, brightness: -0.05)
    }

    /// Cuts a rectangle out of an already blurred backdrop (used for the
    /// opened-folder panel, which is simply the wallpaper behind a blur).
    static func cropBackdrop(_ backdrop: CGImage,
                             displayRect: CGRect,
                             displaySize: CGSize,
                             workScale: CGFloat = 0.5) -> CGImage? {
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        let sx = CGFloat(backdrop.width) / (displaySize.width * workScale)
        let sy = CGFloat(backdrop.height) / (displaySize.height * workScale)
        let rect = CGRect(x: displayRect.minX * workScale * sx,
                          y: displayRect.minY * workScale * sy,
                          width: displayRect.width * workScale * sx,
                          height: displayRect.height * workScale * sy)
        return cropped(backdrop, to: rect)
    }
}
