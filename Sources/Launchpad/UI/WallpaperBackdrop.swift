import AppKit
import SwiftUI

/// The blurred desktop picture Launchpad sits on.
struct WallpaperBackdrop: View, Equatable {
    let image: CGImage?
    let size: CGSize
    /// 打开文件夹 / 搜索时再压暗一点，让前景更清楚。
    var extraDim: Bool = false
    var style: BackdropStyle = .blur

    var body: some View {
        ZStack {
            Color.black
            switch style {
            case .blur:
                // 系统模糊：不需要任何隐私权限，并且随桌面实时更新
                VisualEffectBackdrop()
            case .wallpaper:
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    // 图片读不出来（被删掉/格式坏了）时退回系统模糊，别留一片黑。
                    VisualEffectBackdrop()
                }
            case .image:
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    VisualEffectBackdrop()
                }
            }
            Color.black.opacity(Self.currentOverlayDim(style: style, extraDim: extraDim))
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
    }

    /// 背景层比一页图标更重（整屏位图 + 遮罩），只比较真正影响画面的输入，
    /// 父视图因为位移而重画时它可以整层跳过。
    static func == (lhs: WallpaperBackdrop, rhs: WallpaperBackdrop) -> Bool {
        lhs.image === rhs.image
            && lhs.size == rhs.size
            && lhs.extraDim == rhs.extraDim
            && lhs.style == rhs.style
    }

    /// 当前设置下实际叠上去的黑色浓度。
    /// 直接读 `Prefs`，而不是让调用方当参数传进来 —— 之前就是漏传了参数，
    /// 导致"背景不透明度"滑杆怎么拖都没反应。
    static func currentOverlayDim(style: BackdropStyle, extraDim: Bool = false) -> Double {
        overlayDim(style: style, dim: Prefs.backdropDim, extraDim: extraDim)
    }

    /// 浓度换算：上限 0.85，避免整块变黑看不清图标。
    static func overlayDim(style: BackdropStyle, dim: Double, extraDim: Bool) -> Double {
        let extra = extraDim ? 0.12 : 0
        let value: Double
        switch style {
        case .blur, .image:
            // 自定义图片没有预先压暗过，和系统模糊一样直接用完整遮罩。
            value = dim + extra
        case .wallpaper:
            // 壁纸模式的图片在 ImageEffects 里已经压暗了 0.22，
            // 这里只补差值，好让两个模式共用同一个"不透明度"滑杆。
            value = max(0, dim - 0.22) + extra
        }
        return min(0.85, value)
    }
}

/// Small helper that caches blurred wallpaper samples used behind folder icons.
@MainActor
final class GlassCache {
    static let shared = GlassCache()
    private var storage: [String: CGImage] = [:]

    func glass(raw: CGImage?, displaySize: CGSize, rect: CGRect, blur: CGFloat = 20) -> CGImage? {
        guard let raw else { return nil }
        let key = "\(raw.width)x\(raw.height)|\(Int(rect.minX))x\(Int(rect.minY))x\(Int(rect.width))x\(Int(rect.height))|\(Int(blur))"
        if let cached = storage[key] { return cached }
        let sample = ImageEffects.glassSample(raw: raw,
                                              displayRect: rect,
                                              displaySize: displaySize,
                                              blur: blur)
        if let sample { storage[key] = sample }
        return sample
    }

    func clear() { storage.removeAll() }
}
