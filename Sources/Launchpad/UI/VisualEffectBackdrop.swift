import AppKit
import SwiftUI

/// 系统级模糊背景：由 WindowServer 在合成层完成，**不需要屏幕录制权限**，
/// 而且会随桌面/壁纸实时更新（不像截图那样是一张静止图）。
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active          // 覆盖层可能不是激活应用，强制生效
        view.isEmphasized = isEmphasized
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
    }
}

/// 背景模式。
///
/// 录屏式背景（截取桌面）已经从项目里删除：它需要"屏幕录制"权限，而权限
/// 对普通用户是负担。现在的两种模式都**不需要任何隐私授权**。
enum BackdropStyle: String, CaseIterable, Identifiable {
    /// 系统模糊（默认）：WindowServer 在合成层实时模糊窗口后面的内容，
    /// 桌面上换壁纸会立刻跟上，也不需要读屏。
    case blur
    /// 系统壁纸图片：直接读壁纸文件，只有壁纸、不含窗口；
    /// 动态壁纸可能只拿到静态占位图。
    case wallpaper
    /// 用户自己上传的图片（复制进应用支持目录，不模糊）。
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: return "系统模糊 · 实时（推荐）"
        case .wallpaper: return "系统壁纸图片 · 不含窗口"
        case .image: return "自定义图片"
        }
    }

    var detail: String {
        switch self {
        case .blur:
            return "由系统合成层实时模糊桌面，桌面上开着的窗口会被一起模糊。"
        case .wallpaper:
            return "只显示壁纸本身（不含窗口）；换壁纸后重新打开启动台即更新。"
        case .image:
            return "用你选的图片当背景，默认按系统壁纸的量级做模糊（下方可调，0 = 原图）；"
                + "原图会被复制一份存到应用支持目录，之后移动原图也不影响。"
        }
    }

    /// 是否需要预先渲染一张位图（系统模糊模式由 NSVisualEffectView 自己画）。
    var needsBitmap: Bool { self != .blur }
}
