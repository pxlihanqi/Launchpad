import AppKit
import Foundation

/// 用户自己上传的背景图片。
///
/// 选中的图片会被**复制**进应用支持目录，所以原图后来被移动或删除都不影响；
/// 读取时按屏幕比例裁剪缩放并缓存。整个过程只读文件，不需要任何隐私权限。
@MainActor
enum CustomBackdrop {
    static var directory: URL {
        let dir = SupportPaths.directory.appendingPathComponent("Background", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 缓存键里带上目标尺寸：换分辨率/接外屏时不会拿到旧尺寸的图。
    private static var cachedKey: String?
    private static var cachedImage: CGImage?

    static var fileURL: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return files.first { !$0.lastPathComponent.hasPrefix(".") }
    }

    static var hasImage: Bool { fileURL != nil }

    static var displayName: String {
        if let name = Prefs.customBackdropName { return name }
        return fileURL?.lastPathComponent ?? "自定义图片"
    }

    /// 复制用户选择的图片进来（旧的先删掉）。
    @discardableResult
    static func importImage(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return false }
        remove()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let target = directory.appendingPathComponent("background.\(ext)")
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            Log.error("custom backdrop copy failed: \(error.localizedDescription)")
            return false
        }
        Prefs.customBackdropName = url.lastPathComponent
        invalidate()
        return true
    }

    static func remove() {
        if let file = fileURL { try? FileManager.default.removeItem(at: file) }
        Prefs.customBackdropName = nil
        invalidate()
    }

    static func invalidate() {
        cachedKey = nil
        cachedImage = nil
    }

    /// 按屏幕比例裁剪缩放的背景图。**不模糊**：用户上传的照片要保持它本来的样子，
    /// 亮度由偏好设置里的"背景不透明度"统一控制。
    static func image(size: CGSize) -> CGImage? {
        guard let file = fileURL else { return nil }
        let key = "\(file.path)|\(Int(size.width))x\(Int(size.height))"
        if cachedKey == key, let cachedImage { return cachedImage }
        guard let source = NSImage(contentsOf: file) else { return nil }
        var rect = CGRect(origin: .zero, size: source.size)
        guard let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let filled = ImageEffects.aspectFill(cg, size: size) ?? cg
        cachedKey = key
        cachedImage = filled
        return filled
    }
}
