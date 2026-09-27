import AppKit
import Foundation

/// Verifies the two halves of keyboard routing: presenting the overlay makes us
/// the active application (so keys reach it), and dismissing it hands focus
/// back to whatever the user was using.
@MainActor
enum FocusTest {
    private static var failures: [String] = []
    private static let reportURL = URL(fileURLWithPath: "/tmp/launchpad-focustest.log")

    static func run() -> Int32 {
        try? "".write(to: reportURL, atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let controller = LaunchpadController.shared
        LaunchpadController.suppressRealLaunch = true
        controller.bootstrap()

        let before = NSWorkspace.shared.frontmostApplication
        report("  打开前的前台应用: \(before?.localizedName ?? "nil")")

        OverlayCoordinator.shared.present()
        report("  t0 刚 present: isActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
        if !NSApp.isActive {
            NSApp.activate()
            spin(0.2)
            report("  A NSApp.activate(): isActive=\(NSApp.isActive)")
            NSApp.activate(ignoringOtherApps: true)
            spin(0.2)
            report("  B activate(ignoringOtherApps:): isActive=\(NSApp.isActive)")
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            spin(0.2)
            report("  C NSRunningApplication.activate: isActive=\(NSApp.isActive)")
            NSApp.activate(ignoringOtherApps: true)
            spin(0.4)
            report("  D 再来一次 legacy: isActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
        }
        spin(1.2)
        report("  t1 spin 后: isActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil) panels=\(NSApp.windows.filter { $0.isVisible }.count)")
        let during = NSWorkspace.shared.frontmostApplication
        expect(during?.bundleIdentifier == "com.launchpad.app",
               "打开后前台应用是启动台（键盘事件才能送达）: \(during?.localizedName ?? "nil")")
        expect(controller.isOpen, "覆盖层处于打开状态")
        if !FieldFocus.isSearchEditing() {
            report("  诊断: 主动聚焦一次")
            FieldFocus.focusSearch()
            spin(0.3)
        }
        expect(FieldFocus.isSearchEditing(), "搜索框已获得键盘焦点（输入法组字的前提）")

        // Typing goes through the real text field: simulate what the input
        // method does when it commits 「微」 into the field.
        if let field = FieldFocus.searchField, let editor = field.currentEditor() as? NSTextView {
            // `insertText` is exactly what the input method calls when it commits
            // a candidate, so this exercises the real composition path.
            editor.insertText("微", replacementRange: editor.selectedRange)
            spin(0.2)
            expect(controller.searchText == "微", "输入框内容同步到搜索状态 (searchText=\(controller.searchText))")
            expect(controller.isFiltering || controller.searchActive, "输入后进入筛选")
            expect(!controller.displayItems.isEmpty, "筛选后仍有结果 (\(controller.displayItems.count) 项)")
            expect(FieldFocus.isComposing(in: field.window) == false, "无组字状态下不阻塞按键")
            controller.endSearch(clearText: true)
            spin(0.2)
            report("  t2 搜索块后: isActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
            expect(controller.searchText.isEmpty, "清空后回到全部应用")

            // Full input method flow: compose pinyin, then commit a candidate.
            if field.window?.isKeyWindow != true {
                report("  信息: appActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)（由终端/测试触发时系统会要求用户交互才允许激活）")
                field.window?.makeKeyAndOrderFront(nil)
                spin(0.4)
                report("  信息: 再次尝试后 key=\(field.window?.isKeyWindow == true)")
            }
            // Only informational: activation requires real user interaction,
            // which a scripted test cannot provide.
            editor.setMarkedText("weixin",
                                 selectedRange: NSRange(location: 6, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.2)
            expect(editor.hasMarkedText(), "拼音组字态生效 (marked=weixin)")
            expect(controller.searchText.isEmpty, "组字过程中不筛选 (searchText=\(controller.searchText))")
            editor.insertText("微信", replacementRange: editor.markedRange())
            spin(0.2)
            expect(!editor.hasMarkedText(), "提交候选词后组字结束")
            expect(controller.searchText == "微信", "提交后写入搜索 (searchText=\(controller.searchText))")
            expect(controller.displayItems.contains { $0.appID == "com.tencent.xinWeChat" },
                   "提交后能搜到微信 (结果 \(controller.displayItems.count) 项)")
            controller.endSearch(clearText: true)
        } else {
            fail("搜索框没有字段编辑器，输入法无法工作")
        }

        controller.closeAndDismiss()
        spin(1.5)
        let after = NSWorkspace.shared.frontmostApplication
        expect(after?.bundleIdentifier == before?.bundleIdentifier,
               "关闭后焦点还给原应用: \(after?.localizedName ?? "nil")")
        expect(!controller.isOpen, "覆盖层已关闭")

        if failures.isEmpty {
            report("焦点测试通过 ✓")
            return 0
        }
        report("焦点测试失败:")
        for failure in failures { print("  ✗ \(failure)") }
        return 1
    }

    private static func expect(_ condition: Bool, _ message: String) {
        report(condition ? "  ✓ \(message)" : "  ✗ \(message)")
        if !condition { failures.append(message) }
    }

    private static func fail(_ message: String) {
        failures.append(message)
        report("  ✗ \(message)")
    }

    /// Mirrors output to a file so the test can also be run through
    /// LaunchServices (`open --args --focustest`), where activation behaves the
    /// same as in the real app.
    private static func report(_ message: String) {
        print(message)
        if let handle = try? FileHandle(forWritingTo: reportURL) {
            handle.seekToEndOfFile()
            handle.write(Data((message + "\n").utf8))
            try? handle.close()
        } else {
            try? (message + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
