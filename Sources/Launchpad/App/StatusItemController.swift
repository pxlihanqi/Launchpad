import AppKit
import SwiftUI

/// Menu bar entry point: Launchpad has no Dock icon of its own.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "启动台")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "启动台"
            // 左键直接进入启动台；右键（或按住 ⌥）才弹出菜单。
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu = buildMenu()
    }

    private var menu = NSMenu()

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil          // 恢复"左键直接进入"
        } else {
            LaunchpadController.shared.toggle()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开启动台", action: #selector(openLaunchpad), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "重新扫描应用程序", action: #selector(rescan), keyEquivalent: "")
        menu.addItem(withTitle: "从旧版启动台导入布局…", action: #selector(importLegacy), keyEquivalent: "")
        menu.addItem(withTitle: "显示所有隐藏的应用", action: #selector(unhideAll), keyEquivalent: "")
        menu.addItem(withTitle: "切换背景（系统模糊 / 系统壁纸图片）", action: #selector(toggleBackdropStyle), keyEquivalent: "")
        menu.addItem(withTitle: "在访达中显示布局文件", action: #selector(revealLayout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出启动台", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    @objc private func openLaunchpad() {
        LaunchpadController.shared.toggle()
    }

    @objc private func rescan() {
        LaunchpadController.shared.catalog.reload()
        LaunchpadController.shared.refreshCatalog()
        IconStore.shared.preload(Array(LaunchpadController.shared.catalog.apps.values))
    }

    @objc private func importLegacy() {
        let alert = NSAlert()
        guard let result = LaunchpadDBImporter.importLayout(catalog: LaunchpadController.shared.catalog) else {
            alert.messageText = "没有找到旧版启动台数据库"
            alert.informativeText = "系统中已经没有 com.apple.dock.launchpad 数据库，无法恢复旧布局。"
            alert.runModal()
            return
        }
        alert.messageText = "导入旧版启动台布局？"
        alert.informativeText = "将使用旧数据库中的布局（\(result.summary)）覆盖当前布局。"
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            LaunchpadController.shared.replaceLayout(with: result.layout)
        }
    }

    @objc private func unhideAll() {
        LaunchpadController.shared.unhideAll()
    }

    /// 在两种**免权限**背景之间切换：系统模糊（实时，含窗口）/ 系统壁纸图片（只有壁纸）。
    @objc private func toggleBackdropStyle() {
        let next: BackdropStyle = Prefs.backdropStyle == .blur ? .wallpaper : .blur
        Prefs.backdropStyle = next
        WallpaperProvider.shared.invalidate()
        OverlayCoordinator.shared.refreshBackdrops()

        let alert = NSAlert()
        alert.messageText = "背景已改为「\(next == .blur ? "系统模糊" : "系统壁纸图片")」"
        alert.informativeText = next.detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func revealLayout() {
        NSWorkspace.shared.activateFileViewerSelecting([SupportPaths.layoutFile])
    }

    @objc private func showPreferences() {
        Self.showPreferencesWindow()
    }

    /// 偏好设置窗口（菜单栏「偏好设置…」与 `--preferences` 共用）。
    private static var preferencesWindow: NSWindow?

    @MainActor
    static func showPreferencesWindow() {
        if preferencesWindow == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "启动台偏好设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // 抬到启动台覆盖层之上，这样开着启动台拖滑杆能立刻看到效果。
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
            window.center()
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        LaunchpadController.shared.persistNow()
        NSApp.terminate(nil)
    }
}
