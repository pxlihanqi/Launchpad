import AppKit

/// Modal confirmations shown on top of the full screen overlay.
@MainActor
enum Confirmation {
    /// Mirrors Launchpad's delete prompt: app icon, warning style, destructive
    /// button + cancel.
    static func deleteApp(name: String, icon: NSImage?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要删除“\(name)”吗？"
        alert.informativeText = "“\(name)”将被移到废纸篓。此操作不会删除它的文稿和数据。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if let icon {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        // NSAlert shrinks to fit short text; keep the system-like width so the
        // message does not wrap into a narrow column.
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
        return runAboveOverlay(alert) == .alertFirstButtonReturn
    }

    static func error(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
        _ = runAboveOverlay(alert)
    }

    /// 批量删除确认：列出所有会被删除的项目名（太多就折叠成"等 N 个"）。
    static func deleteApps(names: [String], icon: NSImage?) -> Bool {
        guard let first = names.first else { return false }
        if names.count == 1 { return deleteApp(name: first, icon: icon) }

        let listed = names.prefix(6).map { "“\($0)”" }.joined(separator: "、")
        let suffix = names.count > 6 ? " 等 \(names.count) 个项目" : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要删除这 \(names.count) 个项目吗？"
        alert.informativeText = "\(listed)\(suffix)将被移到废纸篓。此操作不会删除它们的文稿和数据。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if let icon {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
        return runAboveOverlay(alert) == .alertFirstButtonReturn
    }

    /// The alert has to sit above our overlay window, and the overlay must stop
    /// handling keys while it is up.
    private static func runAboveOverlay(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // The overlay sits at mainMenu + 1, so the alert has to go above it.
        // NSAlert resets its window to `.modalPanel` (8) when the modal session
        // starts, which would hide it behind the overlay — so keep re-asserting
        // the level from inside the modal run loop.
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        alert.window.level = level
        LaunchpadController.shared.isAlertPresented = true
        let keeper = Timer(timeInterval: 0.05, repeats: true) { _ in
            if alert.window.level != level { alert.window.level = level }
        }
        RunLoop.main.add(keeper, forMode: .modalPanel)
        defer {
            keeper.invalidate()
            LaunchpadController.shared.isAlertPresented = false
        }
        return alert.runModal()
    }
}
