import AppKit
import Foundation

/// Caches rendered application icons in memory and on disk (mirrors the Dock's
/// own `image_cache` table so opening Launchpad feels instant).
@MainActor
final class IconStore {
    static let shared = IconStore()

    private let memory = NSCache<NSString, NSImage>()
    private var pending: Set<String> = []
    private let pixelSize = 256

    private init() {
        memory.countLimit = 240
    }

    func icon(for entry: AppEntry) -> NSImage? {
        let key = entry.bundleID as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let url = cacheURL(for: entry)
        if let image = loadFromDisk(url: url, entry: entry) {
            memory.setObject(image, forKey: key)
            return image
        }
        guard let image = renderIcon(entry: entry) else { return nil }
        memory.setObject(image, forKey: key)
        writeToDisk(image: image, url: url)
        return image
    }

    /// Warms the cache in the background so the first open is instant.
    func preload(_ entries: [AppEntry]) {
        let missing = entries.filter { memory.object(forKey: $0.bundleID as NSString) == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for entry in missing {
                // 后台线程渲染并落盘，再把结果直接放进内存缓存
                // （不要再回主线程读一遍磁盘，那会造成 100+ 次主线程 I/O）
                guard let rendered = autoreleasepool(invoking: { () -> NSImage? in
                    if let cg = IconStore.decodeCachedIcon(for: entry) {
                        // 磁盘缓存里的 PNG 是"懒解码"的：不在这里解出来，
                        // 第一次绘制那一页时要现场解 30 多个图标 —— 实测就是这一次
                        // 让滑动第一轮出现 70ms 级别的掉帧（第二轮就恢复正常）。
                        return NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
                    }
                    guard let cg = IconStore.rasterize(path: entry.path, pixelSize: 256) else { return nil }
                    IconStore.persist(cg, to: IconStore.diskURL(for: entry))
                    return NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
                }) else { continue }
                DispatchQueue.main.async {
                    IconStore.shared.memory.setObject(rendered, forKey: entry.bundleID as NSString)
                }
            }
        }
    }

    /// 把磁盘缓存里的 PNG 真正解码成位图（`NSImage(contentsOf:)` 是懒解码的）。
    nonisolated private static func decodeCachedIcon(for entry: AppEntry) -> CGImage? {
        let url = diskURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Drops a cached icon (memory + disk) after the app behind it changed.
    func invalidate(_ bundleID: String) {
        memory.removeObject(forKey: bundleID as NSString)
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(at: SupportPaths.iconCacheDirectory
            .appendingPathComponent(safe + ".png"))
    }

    // MARK: - Rendering

    private func renderIcon(entry: AppEntry) -> NSImage? {
        guard let cg = IconStore.rasterize(path: entry.path, pixelSize: pixelSize) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
    }

    nonisolated private static func rasterize(path: String, pixelSize: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: pixelSize, height: pixelSize)
        var rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return cg
    }

    private func cachedFromDisk(entry: AppEntry) -> NSImage? {
        loadFromDisk(url: cacheURL(for: entry), entry: entry, allowRender: false)
    }

    private func loadFromDisk(url: URL, entry: AppEntry, allowRender: Bool = true) -> NSImage? {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date,
           modified >= entry.bundleModDate,
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 128, height: 128)
            return image
        }
        return nil
    }

    private func writeToDisk(image: NSImage, url: URL) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        IconStore.persist(cg, to: url)
    }

    nonisolated private static func persist(_ cg: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func cacheURL(for entry: AppEntry) -> URL { IconStore.diskURL(for: entry) }

    nonisolated private static func diskURL(for entry: AppEntry) -> URL {
        let safe = entry.bundleID.replacingOccurrences(of: "/", with: "_")
        return SupportPaths.iconCacheDirectory.appendingPathComponent(safe + ".png")
    }
}
