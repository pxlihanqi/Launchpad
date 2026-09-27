import AppKit
import Foundation
import SQLite3

/// 提供"系统壁纸图片"模式用的壁纸位图。
///
/// 注意：这里**不包含任何截屏/录屏代码**。默认的"系统模糊"背景由
/// `NSVisualEffectView` 在系统合成层实时完成，跟本文件无关；本文件只在
/// 用户选择"系统壁纸图片"时读取壁纸文件（`NSWorkspace.desktopImageURL` 等），
/// 读文件不需要任何隐私权限。
@MainActor
final class WallpaperProvider {
    static let shared = WallpaperProvider()

    private var rawCache: [String: CGImage] = [:]
    private var backdropCache: [String: CGImage] = [:]

    /// Where the current backdrop came from, for diagnostics.
    private(set) var lastSource = "none"

    /// Appends one line per presentation so "why is my background not the
    /// desktop?" can be answered from a file.
    func appendDiagnostic() {
        let url = SupportPaths.directory.appendingPathComponent("backdrop.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) "
            + "source=\(lastSource) style=\(Prefs.backdropStyle.rawValue) "
            + "opacity=\(String(format: "%.2f", Prefs.backdropOpacity)) "
            + "iconScale=\(String(format: "%.2f", Prefs.iconScale)) "
            + "columns=\(Prefs.gridColumns)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// One-off note appended to backdrop.log (used to trace present/dismiss).
    func appendNote(_ note: String) {
        let url = SupportPaths.directory.appendingPathComponent("backdrop.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) note=\(note)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func rawWallpaper(for screen: NSScreen) -> CGImage? {
        let key = screen.localizedName + "|" + screen.deviceDescription.debugDescription

        var image: CGImage?
        if let cached = rawCache[key] {
            lastSource = "wallpaper-cached"
            return cached
        }
        // 自定义图片模式下，文件夹的玻璃底也用这张图，观感才一致。
        if Prefs.backdropStyle == .image {
            if let cached = CustomBackdrop.image(size: screen.frame.size) {
                rawCache[key] = cached
                lastSource = "custom-image"
                return cached
            }
            lastSource = "custom-missing"
            return nil
        }
        if image == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen), Self.isUsableWallpaper(url) {
            image = Self.load(url)
            if image != nil { lastSource = "wallpaper-file" }
        }
        if image == nil {
            image = wallpaperFromStore()
            if image != nil { lastSource = "wallpaper-store" }
        }
        if image == nil {
            // The wallpaper recorded by the Dock, matched to the system thumbnail.
            image = legacyWallpaperImage()
            if image != nil { lastSource = "legacy-wallpaper" }
        }
        if image == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            image = Self.load(url)
            if image != nil { lastSource = "wallpaper-placeholder" }
        }
        if let image { rawCache[key] = image }
        return image
    }

    /// Launchpad's backdrop, cached per screen + strength.
    func backdrop(for screen: NSScreen, size: CGSize, strong: Bool) -> CGImage? {
        let baseKey = screen.localizedName + "|\(Int(size.width))x\(Int(size.height))|\(strong ? "s" : "n")"
        // 自定义图片：和系统壁纸走同一套模糊管线（半分辨率上做，速度足够快），
        // 但**不额外压暗**（亮度交给"背景不透明度"滑杆），也不用系统壁纸那套调色，
        // 免得把用户自己的照片染色。
        if Prefs.backdropStyle == .image {
            let blur = CGFloat(Prefs.backdropBlur)
            let key = baseKey + "|blur\(Int(blur))"
            if let cached = backdropCache[key] { return cached }
            let result = CustomBackdrop.image(size: size).flatMap {
                ImageEffects.backdrop(from: $0,
                                      size: size,
                                      blur: blur,
                                      darken: 0,
                                      saturation: 1,
                                      brightness: 0)
            }
            if let result { backdropCache[key] = result }
            lastSource = result == nil ? "custom-missing" : "custom-image-blur\(Int(blur))"
            return result
        }
        let key = baseKey
        if let cached = backdropCache[key] { return cached }
        let raw = rawWallpaper(for: screen)
        let result = raw.flatMap {
            ImageEffects.backdrop(from: $0,
                                  size: size,
                                  blur: strong ? 74 : 46,
                                  darken: strong ? 0.34 : 0.22)
        } ?? ImageEffects.gradient(size: size)
        if let result { backdropCache[key] = result }
        return result
    }

    /// Blurred wallpaper sample used as the glass background of a folder icon.
    func glassSample(for screen: NSScreen, rect: CGRect, displaySize: CGSize, blur: CGFloat) -> CGImage? {
        guard let raw = rawWallpaper(for: screen), raw.width > 0 else { return nil }
        let source = ImageEffects.sourceRect(forDisplayRect: rect,
                                             displaySize: displaySize,
                                             imageSize: CGSize(width: raw.width, height: raw.height))
        return ImageEffects.blurred(raw, radius: blur * 0.35).flatMap { blurred in
            ImageEffects.cropped(blurred, to: source).flatMap {
                ImageEffects.colorAdjusted($0, saturation: 1.3, brightness: -0.05)
            }
        }
    }

    func invalidate() {
        rawCache.removeAll()
        backdropCache.removeAll()
    }

    /// Wallpaper path recorded by the Dock (works without any screen, which is
    /// what the snapshot renderer needs).
    func legacyWallpaperPath() -> String? {
        let database = NSHomeDirectory() + "/Library/Application Support/Dock/desktoppicture.db"
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        let copy = NSTemporaryDirectory() + "launchpad-desktoppicture.db"
        try? FileManager.default.removeItem(atPath: copy)
        try? FileManager.default.copyItem(atPath: database, toPath: copy)
        defer { try? FileManager.default.removeItem(atPath: copy) }

        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(copy, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        func query(_ sql: String) -> [String] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
            }
            return values
        }

        let values = query("""
        SELECT d.value FROM preferences p
        JOIN data d ON d.rowid = p.data_id
        ORDER BY p.rowid DESC LIMIT 40
        """)
        for value in values where value.contains("/") || value.contains(".heic") || value.contains(".jpg") {
            return (value as NSString).expandingTildeInPath
        }
        return nil
    }

    /// The Dock recorded which wallpaper file was in use; even when that file
    /// has since been re-downloaded elsewhere, the matching system thumbnail
    /// still describes the same wallpaper.
    func legacyWallpaperImage() -> CGImage? {
        if let path = legacyWallpaperPath() {
            if let image = Self.load(URL(fileURLWithPath: path)) { return image }
            let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".heic", with: "")
            let thumb = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/" + base + ".heic")
            if let image = Self.load(thumb) { return image }
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first,
           let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            if let image = Self.load(url) { return image }
        }
        return nil
    }

    /// Current desktop picture as recorded by the wallpaper store.
    private func wallpaperFromStore() -> CGImage? {
        let store = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: store)),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        func files(in node: Any?) -> [String] {
            guard let node = node as? [String: Any] else { return [] }
            guard let content = node["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { return [] }
            return choices.flatMap { ($0["Files"] as? [String]) ?? [] }
        }

        var candidates: [String] = []
        if let displays = root["Displays"] as? [String: Any] {
            for (_, value) in displays {
                candidates.append(contentsOf: files(in: (value as? [String: Any])?["Desktop"]))
            }
        }
        candidates.append(contentsOf: files(in: root["AllSpacesAndDisplays"]))
        candidates.append(contentsOf: files(in: root["SystemDefault"]))

        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            if let image = Self.load(URL(fileURLWithPath: path)) { return image }
        }
        return nil
    }

    private static func isUsableWallpaper(_ url: URL) -> Bool {
        !url.path.hasSuffix("DefaultDesktop.heic")
    }

    private static func load(_ url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

}
