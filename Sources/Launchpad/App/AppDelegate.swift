import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    /// Set by `--show` so the overlay opens as soon as the helper is ready.
    var autoPresent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = LaunchpadController.shared
        controller.bootstrap()

        GlobalHotKey.shared.onFire = { [weak controller] in
            controller?.toggle()
        }
        GlobalHotKey.shared.registerDefault()

        statusItem = StatusItemController()
        buildMainMenu()
        // 用户可能选择隐藏 Dock 图标：那就只留菜单栏图标 + 快捷键。
        AppDelegate.applyDockIconVisibility()

        OverlayCoordinator.shared.installGlobalGestureMonitor()

        // 默认注册为登录项，这样开机后菜单栏图标一直在。
        if !Prefs.launchAtLogin, !UserDefaults.standard.bool(forKey: "didRegisterLoginItem") {
            UserDefaults.standard.set(true, forKey: "didRegisterLoginItem")
            do {
                try SMAppService.mainApp.register()
                Prefs.launchAtLogin = true
                Log.info("registered as login item")
            } catch {
                Log.error("login item registration failed: \(error.localizedDescription)")
            }
        }

        // 背景不需要任何隐私权限：默认的系统模糊由 WindowServer 在合成层
        // 实时完成，这里只是把壁纸/模糊位图预热一下，让第一次打开更快。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                for screen in NSScreen.screens {
                    _ = WallpaperProvider.shared.backdrop(for: screen, size: screen.frame.size, strong: false)
                    _ = WallpaperProvider.shared.backdrop(for: screen, size: screen.frame.size, strong: true)
                }
            }
        }

        Log.info("Launchpad helper ready (hotkey: \(Prefs.hotKey.title))")

        // 用户主动启动（双击应用 / 点 Dock 图标）时直接进入启动台；
        // 作为登录项启动时应用不会成为前台应用，因此不会自动弹出。
        if !autoPresent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    if NSApp.isActive, !controller.isOpen { controller.toggle() }
                }
            }
        }

        if autoPresent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { controller.toggle() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 隐藏/显示程序坞（Dock）里的图标。
    /// `.accessory` 只是不占 Dock 和菜单栏，覆盖窗口、快捷键、菜单栏图标都不受影响。
    static func applyDockIconVisibility() {
        let wanted: NSApplication.ActivationPolicy = Prefs.hideDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        Log.info("activation policy → \(Prefs.hideDockIcon ? "accessory (无 Dock 图标)" : "regular")")
    }

    /// 点 Dock 图标（应用已在运行时）直接进入启动台。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let controller = LaunchpadController.shared
            if !controller.isOpen { controller.toggle() }
        }
        return true
    }

    /// 右键 Dock 图标时的菜单。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开启动台", action: #selector(openLaunchpad), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出启动台",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
        return menu
    }

    @objc private func openLaunchpad() {
        MainActor.assumeIsolated { LaunchpadController.shared.toggle() }
    }

    /// 最小主菜单：有了 Dock 图标后，应用可能处于"前台但无窗口"状态，需要一个菜单条。
    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于启动台",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let open = NSMenuItem(title: "打开启动台", action: #selector(openLaunchpad), keyEquivalent: "l")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏启动台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出启动台",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchpadController.shared.persistNow()
    }
}
