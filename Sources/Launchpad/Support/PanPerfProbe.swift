import AppKit
import QuartzCore
import SwiftUI

/// 开发用性能探针：开一个真实的覆盖层窗口，跑一段脚本化的翻页（跟手 + 松手动画），
/// 同时以 60Hz 在主线程上打点。主线程被渲染占满时，打点间隔会被拉长 ——
/// 于是"卡不卡"就有了具体数字：平均间隔、最坏间隔、掉帧次数。
///
/// 光看 `--pan-frames` 只能量到 CPU 光栅化的时间，那是离屏渲染，和窗口里真实的
/// 合成开销不是一回事；这个探针是在真窗口里跑的。
@MainActor
enum PanPerfProbe {
    static func run(seconds: Double = 2.0, repeats: Int = 2) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = LaunchpadController.shared
        controller.bootstrap()
        controller.isOpen = true
        controller.flippingPages = []
        controller.prefetchedPages = []

        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        guard let screen else {
            print("no screen")
            return 1
        }

        let display = DisplayContext(id: screen.displayID,
                                     screen: screen,
                                     frame: screen.frame,
                                     scale: screen.backingScaleFactor,
                                     metrics: Metrics(size: size,
                                                       columns: Prefs.columnOverride,
                                                       iconScale: CGFloat(Prefs.iconScale)),
                                     isActive: true,
                                     backdrop: WallpaperProvider.shared.backdrop(for: screen, size: size, strong: false),
                                     strongBackdrop: nil,
                                     rawWallpaper: WallpaperProvider.shared.rawWallpaper(for: screen))
        controller.displays = [display]

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.isOpaque = true
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: LaunchpadRootView(controller: controller,
                                                                       display: display,
                                                                       animate: false))
        window.orderFrontRegardless()
        // 让它先把第一帧画出来，并等静止预取完成 —— 这才是正常使用时的状态
        // （刚打开就立刻拖属于极端情况，单独用 --pan-frames 的 cold 组看）。
        controller.schedulePagePrefetch(after: 0.05)
        // 等图标预热跑完（后台把磁盘缓存里的 PNG 全部解码）。
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        // 跑多轮：第一轮包含"这些图标第一次被绘制"的解码开销，
        // 后面几轮是纯滑动开销 —— 两者分开看才知道卡在哪。
        let width = display.metrics.size.width
        let center = CGPoint(x: width / 2, y: display.metrics.size.height / 2)
        for round in 1 ... max(1, repeats) {
            var intervals: [Double] = []
            var last = CACurrentMediaTime()
            let sampler = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                let now = CACurrentMediaTime()
                intervals.append(now - last)
                last = now
            }
            RunLoop.main.add(sampler, forMode: .common)
            last = CACurrentMediaTime()

            // 连续滑三次（来回），更接近真实使用：每次都包含跟手 + 松手 + 之后的预取。
            for swipe in 0 ..< 3 {
                let forward = swipe % 2 == 0
                let sign: CGFloat = forward ? -1 : 1
                controller.page = forward ? 0 : 1
                controller.swipeOffset = 0
                controller.isPanning = false
                controller.beginPan(at: center)
                for step in 1 ... 18 {
                    controller.updatePan(translation: sign * width * 0.5 * CGFloat(step) / 18, point: center)
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
                }
                controller.endPan(predicted: sign * width * 0.5)
                // 等回弹 + 预取都发生（0.45s + 0.15s）
                RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            }
            _ = seconds
            sampler.invalidate()

            guard !intervals.isEmpty else { continue }
            let sorted = intervals.sorted()
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let worst = sorted.last ?? 0
            let dropped = intervals.filter { $0 > 1.0 / 45.0 }.count   // 慢于 45fps 就算掉帧
            print(String(format: "第 %d 轮：%d 帧，平均 %.2f ms（60fps = 16.7），P95 %.2f，最差 %.2f，掉帧 %d 次（%.1f%%）",
                         round, intervals.count, mean * 1000, p95 * 1000, worst * 1000,
                         dropped, Double(dropped) / Double(intervals.count) * 100))
            // 慢帧出现在第几帧：0–24 帧是跟手拖动，25 帧之后是松手动画。
            let slow = intervals.enumerated().filter { $0.element > 1.0 / 45.0 }
            if !slow.isEmpty {
                let described = slow.map { String(format: "第%d帧 %.0fms", $0.offset, $0.element * 1000) }
                print("        慢帧位置：" + described.joined(separator: "，"))
            }
            // 回到起点，下一轮再滑一次同样的路径
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        window.orderOut(nil)

        print(String(format: "渲染页数：静止 %d 页，滑动 %d 页",
                     PageRenderPolicy.pages(current: 0,
                                            count: controller.pageCount,
                                            sliding: false,
                                            prefetch: controller.prefetchedPages).count,
                     PageRenderPolicy.pages(current: 0,
                                            count: controller.pageCount,
                                            sliding: true,
                                            offset: -400,
                                            prefetch: controller.prefetchedPages).count))
        return 0
    }
}
