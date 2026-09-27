import AppKit
import SwiftUI

/// Creates and manages one overlay panel per display.
@MainActor
final class OverlayCoordinator {
    static let shared = OverlayCoordinator()

    private var panels: [CGDirectDisplayID: LaunchpadPanel] = [:]
    private var scrollMonitor: Any?
    private var mouseMonitors: [Any] = []
    private var lastMouseDown: (point: CGPoint, time: Date)?
    private var previousApplication: NSRunningApplication?
    private var keyMonitor: Any?
    private var gestureMonitor: Any?
    private var globalPinchAccumulator: CGFloat = 0
    /// 外观设置（透明度/图标大小/每行列数）改动后的合并重建。
    private var appearanceWork: DispatchWorkItem?

    /// - Parameter resetState: true 用于真正打开启动台（清掉搜索/拖动等状态）；
    ///   外观设置变化时用 false 就地重建，保留用户当前所在的页与选择。
    /// - Parameter repackPages: 每行图标数量变化时，按新容量把图标顺序重新分页。
    func present(resetState: Bool = true, repackPages: Bool = false) {
        let controller = LaunchpadController.shared
        if resetState {
            controller.prepareForOpen()
        } else {
            controller.refreshCatalog()
            controller.page = min(controller.page, controller.pageCount - 1)
        }
        // 壁纸模式下每次打开都重新读一遍壁纸文件：换过壁纸后立刻就是新的。
        if Prefs.backdropStyle == .wallpaper {
            WallpaperProvider.shared.invalidate()
        }

        // Keyboard events are routed by the *active* application, not by the
        // window, so the overlay has to activate us. The panel covers the whole
        // screen (including the menu bar) and we hand focus back on dismissal.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
        NSApp.activate(ignoringOtherApps: true)

        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main

        var contexts: [DisplayContext] = []
        var activePanel: LaunchpadPanel?
        var stale = Set(panels.keys)

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = screen.displayID
            stale.remove(displayID)
            let metrics = Metrics(size: screen.frame.size,
                                  columns: Prefs.columnOverride,
                                  iconScale: CGFloat(Prefs.iconScale))
            let isActive = screen == activeScreen || (activeScreen == nil && index == 0)
            let raw = WallpaperProvider.shared.rawWallpaper(for: screen)
            // 系统模糊模式背景由 NSVisualEffectView 画，不需要预先渲染位图；
            // 只有"系统壁纸图片"模式才需要（省掉每次打开时的大图模糊）。
            let needsImage = Prefs.backdropStyle.needsBitmap
            let backdrop = needsImage
                ? WallpaperProvider.shared.backdrop(for: screen, size: screen.frame.size, strong: false)
                : nil
            let strong = needsImage
                ? WallpaperProvider.shared.backdrop(for: screen, size: screen.frame.size, strong: true)
                : nil

            let context = DisplayContext(id: displayID,
                                         screen: screen,
                                         frame: screen.frame,
                                         scale: screen.backingScaleFactor,
                                         metrics: metrics,
                                         isActive: isActive,
                                         backdrop: backdrop,
                                         strongBackdrop: strong,
                                         rawWallpaper: raw)
            contexts.append(context)

            let panel = panels[displayID] ?? LaunchpadPanel(displayID: displayID, frame: screen.frame)
            panel.controller = controller
            panel.setFrame(screen.frame, display: false)
            panel.contentView = NSHostingView(rootView: LaunchpadRootView(controller: controller, display: context))
            panels[displayID] = panel
            if isActive { activePanel = panel }
        }

        for key in stale {
            panels[key]?.orderOut(nil)
            panels[key] = nil
        }

        controller.displays = contexts
        // 网格几何刚刚换成新值，这时重排页容量才是对的。
        if repackPages {
            controller.repackForCurrentGrid()
            controller.page = min(controller.page, controller.pageCount - 1)
        }
        Log.info("backdrop source: \(WallpaperProvider.shared.lastSource)")
        WallpaperProvider.shared.appendDiagnostic()
        installScrollMonitor()
        for panel in panels.values where panel !== activePanel {
            panel.orderFrontRegardless()
        }
        // makeKeyAndOrderFront also asks the system to activate us.
        activePanel?.makeKeyAndOrderFront(nil)
        controller.isOpen = true
        installKeyMonitor()
        // Activation above is asynchronous: once it settles, make sure the panel
        // really is the key window (the input method needs that) and that the
        // search field holds focus.
        DispatchQueue.main.async {
            activePanel?.makeKey()
            FieldFocus.focusSearch()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            activePanel?.makeKey()
            FieldFocus.focusSearch()
        }
        Log.info("presented on \(contexts.count) display(s)")
    }

    /// `restoreFocus` is false when an app was launched from the grid (that app
    /// takes over) and true when Launchpad was simply dismissed.
    func dismiss(restoreFocus: Bool = false) {
        let controller = LaunchpadController.shared
        guard !controller.isClosing else { return }
        controller.isClosing = true
        // 先淡出（0.22s）再真正隐藏，避免"啪一下消失"。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            MainActor.assumeIsolated {
                for panel in self.panels.values { panel.orderOut(nil) }
                self.removeScrollMonitor()
                self.removeKeyMonitor()
                controller.isClosing = false
                controller.isOpen = false
                NSApp.deactivate()
                if restoreFocus, let previous = self.previousApplication {
                    previous.activate()
                }
                self.previousApplication = nil
            }
        }
    }

    /// SwiftUI's hosting view can swallow wheel events before the panel sees
    /// them, so trackpad swipes are also intercepted here.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            MainActor.assumeIsolated {
                let controller = LaunchpadController.shared
                guard controller.isOpen, !controller.isAlertPresented, !controller.isClosing else { return event }
                let deltaX = event.scrollingDeltaX
                guard abs(deltaX) > abs(event.scrollingDeltaY), abs(deltaX) > 0.4 else { return event }
                controller.handleScroll(deltaX: deltaX, momentum: !event.momentumPhase.isEmpty)
                return nil
            }
        }
        installMouseMonitor()
    }

    /// Deterministic click handling: SwiftUI gesture resolution is fine for
    /// dragging, but a click must never be lost, so the AppKit event is also
    /// hit tested against the very same geometry the grid is drawn with.
    /// `activate` de-duplicates when both paths fire.
    private func installMouseMonitor() {
        guard mouseMonitors.isEmpty else { return }
        let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated {
                OverlayCoordinator.shared.recordMouseDown(event: event)
            }
            return event
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            MainActor.assumeIsolated {
                // If a drag is in flight the tile that started it may have been
                // removed from the hierarchy (page flip, leaving a folder), so
                // the gesture's own onEnded never arrives.
                if LaunchpadController.shared.drag != nil {
                    LaunchpadController.shared.endDrag()
                }
                OverlayCoordinator.shared.handlePossibleClick(event: event)
            }
            return event
        }
        // Keep feeding pointer positions during a drag: this is what makes
        // dragging out of a folder (and across pages) smooth instead of frozen.
        let dragged = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            MainActor.assumeIsolated {
                OverlayCoordinator.shared.handleDragMove(event: event)
            }
            return event
        }
        mouseMonitors = [down, up, dragged]
    }

    func handleDragMove(event: NSEvent) {
        let controller = LaunchpadController.shared
        guard controller.isOpen, !controller.isAlertPresented, controller.drag != nil else { return }
        guard let window = event.window else { return }
        controller.updateDrag(point: CGPoint(x: event.locationInWindow.x,
                                            y: window.frame.height - event.locationInWindow.y))
    }

    /// Called from the local monitor and from the panel itself, so a click is
    /// recognised even if SwiftUI swallows the mouse event.
    func recordMouseDown(event: NSEvent) {
        lastMouseDown = (event.locationInWindow, Date())
    }

    func handlePossibleClick(event: NSEvent) {
        let controller = LaunchpadController.shared
        guard controller.isOpen,
              !controller.isAlertPresented,
              controller.drag == nil,
              let display = controller.activeDisplay,
              let down = lastMouseDown,
              Date().timeIntervalSince(down.time) < 1.2
        else { return }

        // 改名过程中点击别处：确认改名并吞掉这次点击
        if controller.folderNameEditing {
            controller.commitFolderName()
            return
        }

        let upPoint = event.locationInWindow
        guard hypot(upPoint.x - down.point.x, upPoint.y - down.point.y) < 16 else { return }

        // Window coordinates are bottom-left based; the grid math is top-left.
        let local = CGPoint(x: upPoint.x, y: display.size.height - upPoint.y)

        if let folderID = controller.openFolderID {
            if let bundleID = controller.app(inFolder: folderID, atPoint: local) {
                controller.launch(bundleID)
            }
            return
        }
        // Search results are drawn in the same grid, so clicks work there too.
        guard display.metrics.gridFrame.contains(local),
              let item = controller.item(atGridPoint: local)
        else { return }
        controller.clickItem(item)
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        lastMouseDown = nil
    }

    /// Second, independent path for keystrokes: a local monitor sees every key
    /// event that reaches this application, whatever window ends up key.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                guard LaunchpadController.shared.isOpen else { return event }
                guard let panel = OverlayCoordinator.shared.panels.values.first else { return event }
                return panel.handleKeyEventForTesting(event) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 全局捏合手势：在任意应用里用拇指+三指捏合即可唤起启动台。
    /// 系统若未把捏合事件交给第三方（或需要辅助功能权限），此监听不会触发，
    /// 但也不会有副作用。
    func installGlobalGestureMonitor() {
        guard gestureMonitor == nil else { return }
        gestureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { event in
            MainActor.assumeIsolated {
                let controller = LaunchpadController.shared
                guard Prefs.pinchToOpen, !controller.isOpen, !controller.isAlertPresented else { return }
                let coordinator = OverlayCoordinator.shared
                coordinator.globalPinchAccumulator = coordinator.globalPinchAccumulator * 0.6 + event.magnification
                if coordinator.globalPinchAccumulator <= -0.22 {
                    coordinator.globalPinchAccumulator = 0
                    controller.toggle()
                }
            }
        }
    }

    func refreshBackdrops() {
        // 只有启动台正开着才需要就地重画；关着的时候下次打开自然会读新设置
        // （以前这里会直接把覆盖层弹出来，是个惊吓）。
        guard !panels.isEmpty, LaunchpadController.shared.isOpen else { return }
        present(resetState: false)
    }

    /// 外观设置（透明度 / 图标大小 / 每行列数）变了：合并成一次重建，
    /// 拖动滑杆时不会每个刻度都重造一遍窗口。
    func applyAppearanceChange() {
        appearanceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 启动台没开着就不用重画：下次打开自然会读到新设置。
                guard !self.panels.isEmpty, LaunchpadController.shared.isOpen else { return }
                WallpaperProvider.shared.invalidate()
                self.present(resetState: false, repackPages: true)
            }
        }
        appearanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Windows currently on screen (used to step out of the way of a modal alert).
    var visiblePanels: [NSWindow] {
        panels.values.filter { $0.isVisible }
    }

    /// Used by `--uitest` to exercise the real event pipeline without showing
    /// a window.
    func installMonitorsForTesting() { installScrollMonitor() }
    func removeMonitorsForTesting() { removeScrollMonitor(); removeKeyMonitor() }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
