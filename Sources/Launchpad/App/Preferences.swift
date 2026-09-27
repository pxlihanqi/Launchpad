import Carbon.HIToolbox
import Foundation

enum Prefs {
    enum HotKeyPreset: String, CaseIterable, Identifiable {
        case f4
        case controlCommandL
        case optionCommandSpace
        case commandShiftL
        case disabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .f4: return "F4"
            case .controlCommandL: return "⌃⌘L"
            case .optionCommandSpace: return "⌥⌘Space"
            case .commandShiftL: return "⇧⌘L"
            case .disabled: return "不设置"
            }
        }

        var keyCode: UInt32? {
            switch self {
            case .f4: return UInt32(kVK_F4)
            case .controlCommandL, .commandShiftL: return UInt32(kVK_ANSI_L)
            case .optionCommandSpace: return UInt32(kVK_Space)
            case .disabled: return nil
            }
        }

        var carbonModifiers: UInt32 {
            switch self {
            case .f4, .disabled: return 0
            case .controlCommandL: return UInt32(controlKey | cmdKey)
            case .optionCommandSpace: return UInt32(optionKey | cmdKey)
            case .commandShiftL: return UInt32(cmdKey | shiftKey)
            }
        }
    }

    private static let defaults = UserDefaults.standard

    static var hotKey: HotKeyPreset {
        get {
            guard let raw = defaults.string(forKey: "hotKey"),
                  let preset = HotKeyPreset(rawValue: raw) else { return .controlCommandL }
            return preset
        }
        set { defaults.set(newValue.rawValue, forKey: "hotKey") }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    /// 背景模式：默认系统模糊（免权限）。
    static var backdropStyle: BackdropStyle {
        get {
            if let raw = defaults.string(forKey: "backdropStyle"),
               let style = BackdropStyle(rawValue: raw) { return style }
            // 默认系统模糊：不需要任何权限，也能实时跟随桌面
            return .blur
        }
        set { defaults.set(newValue.rawValue, forKey: "backdropStyle") }
    }

    /// 背景不透明度：1.0 = 完全不加压暗（最透亮），越小越暗。
    /// 模糊模式下它决定叠在系统模糊之上的黑色遮罩浓度。
    static var backdropOpacity: Double {
        get {
            if defaults.object(forKey: "backdropOpacity") == nil { return 0.70 }
            return min(1.0, max(0.25, defaults.double(forKey: "backdropOpacity")))
        }
        set { defaults.set(min(1.0, max(0.25, newValue)), forKey: "backdropOpacity") }
    }

    /// 叠在背景上的压暗程度（由 backdropOpacity 换算）。
    static var backdropDim: Double { 1 - backdropOpacity }

    /// 图标缩放：1.0 为默认大小。
    static var iconScale: Double {
        get {
            if defaults.object(forKey: "iconScale") == nil { return 1.0 }
            return min(1.35, max(0.7, defaults.double(forKey: "iconScale")))
        }
        set { defaults.set(min(1.35, max(0.7, newValue)), forKey: "iconScale") }
    }

    /// 每行图标数量：0 = 跟随屏幕自动（默认 7）。
    static var gridColumns: Int {
        get {
            let stored = defaults.integer(forKey: "gridColumns")
            guard stored >= Self.minColumns else { return 0 }
            return min(Self.maxColumns, stored)
        }
        set {
            // 小于下限（含 0）都当作"自动"。
            if newValue < Self.minColumns { defaults.removeObject(forKey: "gridColumns") }
            else { defaults.set(min(Self.maxColumns, max(Self.minColumns, newValue)), forKey: "gridColumns") }
        }
    }

    static let minColumns = 4
    static let maxColumns = 12
    /// 传给 Metrics 的覆盖值：nil 表示自动。
    static var columnOverride: Int? {
        let columns = gridColumns
        return columns == 0 ? nil : columns
    }

    /// 隐藏 Dock（程序坞）里的图标，只留菜单栏图标 + 快捷键。
    /// 默认关闭：Dock 里有图标时点一下就能进启动台，最不容易迷路。
    static var hideDockIcon: Bool {
        get { defaults.bool(forKey: "hideDockIcon") }
        set { defaults.set(newValue, forKey: "hideDockIcon") }
    }

    /// 自定义背景图的原始文件名（图片本体存在 Background/ 目录里）。
    static var customBackdropName: String? {
        get { defaults.string(forKey: "customBackdropName") }
        set {
            if let newValue { defaults.set(newValue, forKey: "customBackdropName") }
            else { defaults.removeObject(forKey: "customBackdropName") }
        }
    }

    /// 自定义背景图的模糊强度（0 = 原图不模糊）。
    /// 默认和系统壁纸那套一个量级，这样图标与文字不会被照片细节抢走注意力。
    static var backdropBlur: Double {
        get {
            if defaults.object(forKey: "backdropBlur") == nil { return 40 }
            return min(Self.maxBackdropBlur, max(0, defaults.double(forKey: "backdropBlur")))
        }
        set { defaults.set(min(Self.maxBackdropBlur, max(0, newValue)), forKey: "backdropBlur") }
    }

    static let maxBackdropBlur = 80.0

    /// Include /System/Library/CoreServices/Applications (Keychain Access,
    /// Archive Utility, …); Launchpad itself leaves them out.
    static var includeSystemTools: Bool {
        get { defaults.bool(forKey: "includeSystemTools") }
        set { defaults.set(newValue, forKey: "includeSystemTools") }
    }

    /// 触控板捏合手势：在任意界面捏合即可打开启动台。
    static var pinchToOpen: Bool {
        get {
            if defaults.object(forKey: "pinchToOpen") == nil { return true }
            return defaults.bool(forKey: "pinchToOpen")
        }
        set { defaults.set(newValue, forKey: "pinchToOpen") }
    }

    // MARK: - 一次性迁移

    /// 早期版本默认"截取当前桌面"作为背景，那需要屏幕录制权限。
    /// 这个方案已经从项目里彻底删除（改成 `NSVisualEffectView` 的系统模糊，
    /// 免权限且由 WindowServer 在合成层实时完成）。老用户机器里还存着
    /// `screenshot` 与 `useScreenshotBackdrop`，这里统一迁移/清理一次。
    @MainActor
    static func migrateBackdropDefaultsIfNeeded() {
        let current = 4
        let stored = defaults.integer(forKey: "backdropMigrationVersion")
        guard stored < current else { return }
        defaults.set(current, forKey: "backdropMigrationVersion")

        // 更早的版本用的是 useScreenshotBackdrop 这个开关，等价于截图模式。
        let legacyScreenshot = defaults.object(forKey: "useScreenshotBackdrop") != nil
            && defaults.bool(forKey: "useScreenshotBackdrop")
        let storedStyle = defaults.string(forKey: "backdropStyle").flatMap(BackdropStyle.init(rawValue:))

        // 注意：BackdropStyle 里已经没有 screenshot 这个 case 了，所以这里
        // 按原始字符串判断（老版本存进去的就是 "screenshot"）。
        let storedScreenshot = defaults.string(forKey: "backdropStyle") == "screenshot"
        if storedScreenshot || (storedStyle == nil && legacyScreenshot) {
            defaults.set(BackdropStyle.blur.rawValue, forKey: "backdropStyle")
            Log.info("backdrop migrated: screenshot → blur（录屏方式已移除）")
        }
        // 录屏相关的键全部作废，清掉以免残留误导。
        defaults.removeObject(forKey: "useScreenshotBackdrop")
        defaults.removeObject(forKey: "liveBackdrop")

        // 选了"自定义图片"但图片文件已经不在了（比如手动清过缓存目录）→ 退回系统模糊，
        // 否则会得到一个纯黑背景，看起来像坏了。
        if defaults.string(forKey: "backdropStyle") == BackdropStyle.image.rawValue,
           !CustomBackdrop.hasImage {
            defaults.set(BackdropStyle.blur.rawValue, forKey: "backdropStyle")
            Log.info("custom backdrop missing → blur")
        }
    }
}
