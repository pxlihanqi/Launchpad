import AppKit
import Foundation
import SwiftUI

/// 开发用诊断：把翻页过程中的每一帧真实渲染一遍，打印每帧耗时并落盘。
/// 用来判断滑动是不是在某一帧卡住、画面是不是连续。
@MainActor
enum PanFrameRenderer {
    static func run(directory: URL, size: CGSize) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // ImageRenderer 画不了 NSVisualEffectView，诊断固定用系统壁纸位图。
        Prefs.backdropStyle = .wallpaper
        let controller = LaunchpadController.shared
        controller.bootstrap()

        guard let raw = WallpaperProvider.shared.legacyWallpaperImage() ?? ImageEffects.gradient(size: size) else {
            print("no wallpaper available")
            return 1
        }
        let display = DisplayContext(id: 1,
                                     screen: nil,
                                     frame: CGRect(origin: .zero, size: size),
                                     scale: 1,
                                     metrics: Metrics(size: size),
                                     isActive: true,
                                     backdrop: ImageEffects.backdrop(from: raw, size: size),
                                     strongBackdrop: nil,
                                     rawWallpaper: raw)
        controller.displays = [display]
        controller.isOpen = true
        controller.page = 0
        controller.jiggle = false
        controller.isOpening = false
        controller.endSearch(clearText: true)

        guard controller.pageCount > 1 else {
            print("只有一页，测不出翻页")
            return 1
        }

        let width = size.width
        // name / page / swipeOffset / 这一帧的预取集合
        var frames: [(name: String, page: Int, offset: CGFloat, prefetch: [Int], flip: [Int])] = []
        frames.append(("00-rest", 0, 0, [1], []))

        let dragOffsets: [Double] = [-40, -120, -260, -460, -700, -900]
        for (index, offset) in dragOffsets.enumerated() {
            frames.append((String(format: "%02d-drag", index + 1), 0, CGFloat(offset), [1], []))
        }

        // 换页瞬间：page 跳一格、offset 补一屏宽；这时预取会被清掉，
        // 但"正在滑出的那一页"被 flippingPages 钉住 —— 少了它，上一页会当场消失。
        let carry = -900.0 + width
        frames.append(("07-swap", 1, CGFloat(carry), [], [0, 1]))
        let settleFractions: [Double] = [0.75, 0.5, 0.25, 0.1, 0.0]
        for (index, fraction) in settleFractions.enumerated() {
            frames.append((String(format: "%02d-settle", index + 8), 1,
                           CGFloat(carry * fraction), [], [0, 1]))
        }
        // 停稳 0.25 秒后分两步预取（此时画面静止，贵一点也看不出来）。
        frames.append(("13-prefetch-next", 1, 0, [2], []))
        frames.append(("14-prefetch-prev", 1, 0, [0, 2], []))

        // 两种情形各渲染一遍：
        //   cold = 没来得及预取（刚打开就马上拖）
        //   warm = 静止时已经预取好左右页（正常使用的情况）
        for (label, usePrefetch) in [("cold（没来得及预取）", false), ("warm（已预取）", true)] {
            var timings: [(String, Double)] = []
            for frame in frames {
                controller.page = frame.page
                controller.swipeOffset = frame.offset
                controller.prefetchedPages = usePrefetch
                    ? frame.prefetch.filter { $0 >= 0 && $0 < controller.pageCount }
                    : []
                controller.flippingPages = frame.flip
                let started = CFAbsoluteTimeGetCurrent()
                guard let image = render(controller: controller, display: display, size: size) else {
                    print("render failed: \(frame.name)")
                    continue
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                timings.append((frame.name, elapsed))
                if label.hasPrefix("warm") {
                    _ = ImageWriter.write(image, to: directory.appendingPathComponent(frame.name + ".png"))
                }
            }

            print("== \(label) ==")
            for (name, ms) in timings {
                print(String(format: "  %@ %.1f ms", name, ms))
            }
            let drags = timings.filter { $0.0.contains("-drag") }.map(\.1)
            let rest = timings.first { $0.0 == "00-rest" }?.1 ?? 0
            if let first = drags.first, drags.count > 1 {
                print(String(format: "静止 %.1f ms / 拖动第一帧 %.1f ms（首帧要现建相邻页）/ 后续 %.1f ms",
                             rest, first, drags[1]))
            }
        }

        print("页数 \(controller.pageCount)，每页最多 \(display.metrics.capacity) 个图标")
        print("静止渲染页 \(PageRenderPolicy.pages(current: 0, count: controller.pageCount, sliding: false, prefetch: [-1, 1]))")
        print("左滑渲染页 \(PageRenderPolicy.pages(current: 0, count: controller.pageCount, sliding: true, offset: -400, prefetch: [-1, 1]))")
        print("换页瞬间  \(PageRenderPolicy.pages(current: 1, count: controller.pageCount, sliding: true, offset: 600))")
        return 0
    }

    private static func render(controller: LaunchpadController,
                               display: DisplayContext,
                               size: CGSize) -> CGImage? {
        let view = LaunchpadRootView(controller: controller, display: display, animate: false)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }
}
