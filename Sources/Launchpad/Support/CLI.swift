import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CLIMode {
    case dumpLayout
    case dumpCatalog
    case snapshot(directory: String, size: CGSize)
    case resetLayout
    case importLegacy(write: Bool)
    case selfTest
    case uiTest
    case focusTest
    case backdrop(path: String)
    case previewDeleteAlert
    case preferences
    case panFrames(directory: String)
    case perfPan
    case help

    static func parse(_ arguments: [String]) -> CLIMode? {
        guard arguments.count > 1 else { return nil }
        let args = arguments.dropFirst().filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        guard let first = args.first, first.hasPrefix("--") else { return nil }

        var size = CGSize(width: 1512, height: 982)
        var directory = FileManager.default.currentDirectoryPath + "/snapshots"
        var index = 1
        var positionals: [String] = []
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--size":
                if index + 1 < args.count { size = parseSize(args[index + 1]) ?? size; index += 1 }
            case "--out":
                if index + 1 < args.count { directory = args[index + 1]; index += 1 }
            default:
                if !argument.hasPrefix("--") { positionals.append(argument) }
            }
            index += 1
        }
        if let first = positionals.first { directory = first }

        switch first {
        case "--dump-layout": return .dumpLayout
        case "--dump-catalog": return .dumpCatalog
        case "--snapshot": return .snapshot(directory: directory, size: size)
        case "--reset-layout": return .resetLayout
        case "--import-legacy": return .importLegacy(write: false)
        case "--import-legacy-write": return .importLegacy(write: true)
        case "--selftest": return .selfTest
        case "--uitest": return .uiTest
        case "--focustest": return .focusTest
        case "--backdrop": return .backdrop(path: directory)
        case "--preview-delete-alert": return .previewDeleteAlert
        case "--preferences": return .preferences
        case "--pan-frames": return .panFrames(directory: directory)
        case "--perf-pan": return .perfPan
        case "--help", "-h": return .help
        // Unknown switches (including --show and LaunchServices' -psn_…) must
        // fall through to the normal GUI launch.
        default: return nil
        }
    }

    private static func parseSize(_ value: String) -> CGSize? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor
func runCLI(_ mode: CLIMode) -> Int32 {
    switch mode {
    case .help:
        print("""
        Launchpad 命令行工具
          --dump-layout             打印识别到的启动台布局（含旧数据库导入结果）
          --dump-catalog            列出扫描到的应用程序
          --snapshot [目录] [--size WxH]  渲染启动台界面截图
          --import-legacy[ -write]  从旧版启动台数据库导入布局
          --selftest                运行交互行为自检（翻页/点击/拖拽）
          --uitest                  用合成鼠标事件做点击链路测试
          --focustest               验证打开/关闭时的前台应用与键盘焦点
          --backdrop <文件>         把"系统壁纸图片"背景渲染成 PNG（用于检查背景来源）
          --preview-delete-alert    打开启动台并演示删除确认弹窗（按 Esc 结束）
          --preferences             直接打开偏好设置窗口（等同于菜单栏「偏好设置…」）
          --pan-frames <目录>        逐帧渲染翻页动画并打印每帧耗时（诊断滑动）
          --perf-pan                在真实窗口里跑一次翻页并输出主线程掉帧统计（诊断性能）
          --reset-layout            删除本地布局文件
        """)
        return 0

    case .dumpCatalog:
        AppCatalog.shared.reload()
        for bundleID in AppCatalog.shared.orderedBundleIDs {
            guard let entry = AppCatalog.shared.entry(bundleID) else { continue }
            print("\(entry.name)\t\(bundleID)\t\(entry.path)")
        }
        print("total: \(AppCatalog.shared.apps.count)")
        return 0

    case .dumpLayout:
        return CLIRunner.dumpLayout()

    case .snapshot(let directory, let size):
        return SnapshotRenderer.run(directory: URL(fileURLWithPath: directory), size: size)

    case .resetLayout:
        LayoutStore.reset()
        print("layout removed: \(SupportPaths.layoutFile.path)")
        return 0

    case .selfTest:
        return SelfTest.run()

    case .uiTest:
        return UITest.run()

    case .focusTest:
        return FocusTest.run()

    case .backdrop(let path):
        _ = NSApplication.shared
        WallpaperProvider.shared.invalidate()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            print("no screen available")
            return 1
        }
        guard let image = WallpaperProvider.shared.backdrop(for: screen,
                                                            size: screen.frame.size,
                                                            strong: false) else {
            print("no backdrop available")
            return 1
        }
        let url = URL(fileURLWithPath: path)
        let ok = ImageWriter.write(image, to: url)
        print("\(ok ? "wrote" : "failed") \(url.path) \(image.width)x\(image.height) source=\(WallpaperProvider.shared.lastSource)")
        return ok ? 0 : 1

    case .previewDeleteAlert:
        _ = NSApplication.shared
        LaunchpadController.shared.bootstrap()
        OverlayCoordinator.shared.present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            _ = Confirmation.deleteApp(name: "示例应用", icon: nil)
            exit(0)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        return 0

    case .preferences:
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        LaunchpadController.shared.bootstrap()
        StatusItemController.showPreferencesWindow()
        app.run()
        return 0

    case .panFrames(let directory):
        return PanFrameRenderer.run(directory: URL(fileURLWithPath: directory),
                                    size: CGSize(width: 1512, height: 982))

    case .perfPan:
        return PanPerfProbe.run()

    case .importLegacy(let write):
        AppCatalog.shared.reload()
        guard let result = LaunchpadDBImporter.importLayout(catalog: AppCatalog.shared) else {
            print("no legacy database found")
            return 1
        }
        print(result.summary)
        if write {
            var layout = result.layout
            layout.normalize(catalog: AppCatalog.shared, rows: 5, columns: 7)
            LayoutStore.save(layout)
            print("written to \(SupportPaths.layoutFile.path)")
        }
        return 0
    }
}

@MainActor
enum CLIRunner {
    static func dumpLayout() -> Int32 {
        let catalog = AppCatalog.shared
        catalog.reload()
        guard let result = LaunchpadDBImporter.importLayout(catalog: catalog) else {
            print("no legacy database found")
            return 1
        }
        var layout = result.layout
        layout.normalize(catalog: catalog, rows: 5, columns: 7)
        print("# \(result.summary)")
        for (index, page) in layout.pages.enumerated() {
            print("== page \(index + 1) (\(page.count) items)")
            for item in page {
                switch item {
                case .app(let bundleID):
                    print("  \(layout.displayName(for: bundleID, catalog: catalog))\t\(bundleID)")
                case .folder(let folderID):
                    guard let folder = layout.folders[folderID] else { continue }
                    print("  [\(folder.name)] \(folder.apps.count) apps")
                    for app in folder.apps {
                        print("      \(layout.displayName(for: app, catalog: catalog))\t\(app)")
                    }
                }
            }
        }
        if !result.unresolved.isEmpty {
            print("== unresolved")
            for bundleID in result.unresolved { print("  \(bundleID)") }
        }
        return 0
    }
}

enum ImageWriter {
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                               UTType.png.identifier as CFString,
                                                               1,
                                                               nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
