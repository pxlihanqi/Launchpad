import AppKit
import Foundation

/// Pushes synthetic mouse events through the real AppKit pipeline (event queue
/// → local monitor → hit testing → controller) to prove that clicking an icon
/// actually activates it. Nothing is launched and no window is shown.
@MainActor
enum UITest {
    private static var failures: [String] = []

    static func run() -> Int32 {
        _ = NSApplication.shared
        let controller = LaunchpadController.shared
        LaunchpadController.suppressRealLaunch = true
        controller.bootstrap()

        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let display = DisplayContext(id: 0,
                                     screen: nil,
                                     frame: CGRect(origin: .zero, size: size),
                                     scale: screen?.backingScaleFactor ?? 2,
                                     metrics: Metrics(size: size),
                                     isActive: true,
                                     backdrop: nil,
                                     strongBackdrop: nil,
                                     rawWallpaper: nil)
        controller.displays = [display]
        controller.isOpen = true
        controller.page = 0
        controller.jiggle = false
        controller.endSearch(clearText: true)

        let coordinator = OverlayCoordinator.shared
        coordinator.installMonitorsForTesting()
        defer { coordinator.removeMonitorsForTesting() }

        expect(display.frame.width == size.width, "使用真实屏幕尺寸 \(Int(size.width))x\(Int(size.height))")

        // 1. Click the first tile: it must activate that exact icon.
        if let first = controller.currentItems.first, let bundleID = first.appID {
            let center = display.metrics.cellCenter(index: 0)
            controller.launchAnimation = nil
            click(atWindowPoint: CGPoint(x: center.x, y: size.height - center.y))
            expect(controller.launchAnimation == LPItem.app(bundleID).id,
                   "点击第 1 个图标命中的是「\(controller.itemName(first))」")
        } else {
            fail("页面 1 上没有应用")
        }

        // 2. A click that wobbles a few points still counts as a click.
        let second = display.metrics.cellCenter(index: 1)
        if let item = controller.item(at: 1), let bundleID = item.appID {
            controller.launchAnimation = nil
            controller.jiggle = false
            click(atWindowPoint: CGPoint(x: second.x, y: size.height - second.y),
                  releaseOffset: CGSize(width: 5, height: -4))
            expect(controller.launchAnimation == LPItem.app(bundleID).id,
                   "点击带 5pt 抖动时仍命中「\(controller.itemName(item))」")
            expect(controller.jiggle == false, "抖动点击不会进入抖动模式")
        }

        // 3. A press-drag-release is not a click.
        if let item = controller.item(at: 2), let bundleID = item.appID {
            controller.launchAnimation = nil
            click(atWindowPoint: CGPoint(x: second.x, y: size.height - second.y),
                  releaseOffset: CGSize(width: 120, height: 0))
            expect(controller.launchAnimation == nil,
                   "拖拽不会误触发「\(controller.itemName(item))」")
        }

        // 4. Clicking an empty area does nothing (backdrop handles closing).
        controller.launchAnimation = nil
        let empty = CGPoint(x: display.metrics.gridFrame.minX + 4,
                            y: display.metrics.gridFrame.maxY + 30)
        click(atWindowPoint: CGPoint(x: empty.x, y: size.height - empty.y))
        expect(controller.launchAnimation == nil, "点击空白处不会打开应用")

        // 5. Clicking the space between icons is background too.
        controller.launchAnimation = nil
        let gap = CGPoint(x: display.metrics.cellFrame(index: 0).minX + 6,
                          y: display.metrics.cellCenter(index: 0).y)
        click(atWindowPoint: CGPoint(x: gap.x, y: size.height - gap.y))
        expect(controller.launchAnimation == nil, "点击图标之间的空隙不会打开应用")

        controller.isOpen = false

        if failures.isEmpty {
            print("事件级测试通过 ✓")
            return 0
        }
        print("事件级测试失败:")
        for failure in failures { print("  ✗ \(failure)") }
        return 1
    }

    // MARK: - Helpers

    /// Feeds mouse events through the same handlers the monitors and the panel
    /// use (event → hit test → controller).
    private static func click(atWindowPoint point: CGPoint, releaseOffset: CGSize = .zero) {
        let coordinator = OverlayCoordinator.shared
        if let down = mouseEvent(.leftMouseDown, at: point) {
            coordinator.recordMouseDown(event: down)
        }
        if let up = mouseEvent(.leftMouseUp, at: CGPoint(x: point.x + releaseOffset.width,
                                                        y: point.y + releaseOffset.height)) {
            coordinator.handlePossibleClick(event: up)
        }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: point,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition { print("  ✓ \(message)") } else { fail(message) }
    }

    private static func fail(_ message: String) {
        failures.append(message)
        print("  ✗ \(message)")
    }
}
