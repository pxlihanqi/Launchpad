import AppKit
import Foundation
import ImageIO

/// Headless checks for the behaviours that are easy to regress: swiping between
/// pages, opening folders, and dragging an icon to a new slot.
@MainActor
enum SelfTest {
    private static var failures: [String] = []

    static func run() -> Int32 {
        _ = NSApplication.shared
        // 自检会大量拖动、建文件夹、删应用，全都会写 layout.json；还会大改
        // 偏好设置。所以没有显式指定支持目录时，先在隔离目录里跑，
        // 既不会动用户真正的布局，结果也不受已有布局影响（过去会偶发失败）。
        if ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"] == nil {
            let isolated = NSTemporaryDirectory() + "launchpad-selftest"
            try? FileManager.default.removeItem(atPath: isolated)
            try? FileManager.default.createDirectory(atPath: isolated, withIntermediateDirectories: true)
            setenv("LAUNCHPAD_SUPPORT_DIR", isolated, 1)
        }
        let controller = LaunchpadController.shared
        LaunchpadController.suppressRealLaunch = true
        controller.bootstrap()

        let size = CGSize(width: 1512, height: 982)
        let display = DisplayContext(id: 1,
                                     screen: nil,
                                     frame: CGRect(origin: .zero, size: size),
                                     scale: 2,
                                     metrics: Metrics(size: size),
                                     isActive: true,
                                     backdrop: nil,
                                     strongBackdrop: nil,
                                     rawWallpaper: nil)
        controller.displays = [display]
        controller.isOpen = true
        controller.page = 0

        let metrics = display.metrics
        expect(metrics.columns >= 5 && metrics.rows >= 3,
               "网格尺寸: \(metrics.columns)x\(metrics.rows)")

        // 1. Clicking an app must be idempotent (tap + drag release both fire).
        let firstApp = controller.currentItems.first { $0.appID != nil }
        if let firstApp {
            let name = controller.itemName(firstApp)
            controller.activate(firstApp)
            let animatedOnce = controller.launchAnimation != nil
            controller.launchAnimation = nil
            controller.activate(firstApp) // duplicate click within the debounce window
            let stayedQuiet = controller.launchAnimation == nil
            expect(animatedOnce && stayedQuiet, "点击应用「\(name)」只触发一次")
            controller.launchAnimation = nil
        } else {
            fail("页面 1 上没有应用")
        }

        // 2. Opening a folder and closing it again.
        if let folderID = controller.currentItems.compactMap(\.folderID).first {
            controller.activate(.folder(folderID))
            expect(controller.openFolderID == folderID, "点击文件夹可展开")
            controller.escape()
            expect(controller.openFolderID == nil, "Esc 可关闭文件夹")
        }

        // 3. Two finger swipe flipping pages, with the live offset.
        let pageCount = controller.pageCount
        expect(pageCount > 1, "至少有 2 页可翻")
        controller.handleScroll(deltaX: -150)
        let offsetWhileSwiping = controller.swipeOffset
        expect(offsetWhileSwiping < 0, "滑动过程中网格跟随偏移 (\(Int(offsetWhileSwiping)))")
        spin(0.3)
        expect(controller.page == 1, "向左滑动翻到第 2 页 (page=\(controller.page + 1))")
        expect(controller.swipeOffset == 0, "滑动结束后偏移归零")
        spin(0.2)
        controller.handleScroll(deltaX: 150)
        spin(0.3)
        expect(controller.page == 0, "向右滑动翻回第 1 页 (page=\(controller.page + 1))")

        // 4. Dragging an icon to another slot reorders the grid.
        // (first make sure the gaps around an icon belong to the background)
        let rowGap = (metrics.itemInteractiveFrame(index: 0).maxY
            + metrics.itemInteractiveFrame(index: metrics.columns).minY) / 2
        let gapPoints = [
            CGPoint(x: metrics.cellFrame(index: 0).minX + 6, y: metrics.cellCenter(index: 0).y),
            CGPoint(x: metrics.cellCenter(index: 0).x, y: rowGap),
            CGPoint(x: metrics.cellFrame(index: metrics.columns - 1).maxX - 6,
                    y: metrics.cellCenter(index: metrics.columns - 1).y)
        ]
        for point in gapPoints {
            expect(controller.item(atGridPoint: point) == nil, "图标周围空隙不归图标 (\(Int(point.x)),\(Int(point.y)))")
        }
        expect(controller.item(atGridPoint: metrics.cellCenter(index: 0)) != nil, "图标本体仍然可点/可拖")

        let items = controller.currentItems
        if items.count > 4 {
            let dragged = items[0]
            let targetIndex = 3
            let start = metrics.cellCenter(index: 0)
            let end = metrics.cellCenter(index: targetIndex)
            controller.beginDrag(item: dragged,
                                 point: start,
                                 grabOffset: .zero,
                                 fromFolder: nil)
            controller.updateDrag(point: end)
            controller.endDrag()
            let after = controller.currentItems
            let landing = after.firstIndex(where: { $0.id == dragged.id })
            expect(landing == targetIndex,
                   "拖拽后图标落在第 \(targetIndex + 1) 个位置 (实际 \(landing.map { $0 + 1 } ?? -1))")
            expect(controller.jiggle, "拖拽会进入抖动模式")

            // A click that wobbles a few points must not latch jiggle mode.
            let wobble = CGPoint(x: start.x + 4, y: start.y + 3)
            controller.beginDrag(item: after[targetIndex],
                                 point: start,
                                 grabOffset: .zero,
                                 fromFolder: nil)
            controller.updateDrag(point: wobble)
            controller.endDrag()
            expect(controller.jiggle == false, "轻微抖动不会卡在抖动模式")
        }

        // 5. Search finds apps by their localized name.
        controller.searchActive = true
        controller.searchText = "微"
        let hits = controller.searchHits()
        expect(!hits.isEmpty, "搜索“微”命中 \(hits.count) 个结果")
        controller.endSearch(clearText: true)

        // 6. Dragging the background pans whole pages, with rubber banding.
        controller.page = 0
        controller.beginPan()
        controller.updatePan(translation: -metrics.size.width * 0.4)
        expect(controller.isPanning && controller.swipeOffset < 0,
               "拖动背景时网格跟手位移 (\(Int(controller.swipeOffset)))")
        let draggedOffset = controller.swipeOffset
        controller.endPan(predicted: -metrics.size.width * 0.5)
        // The incoming page must appear exactly where the next page already was:
        // nextPageBefore = width + draggedOffset, and now = settleOffset.
        expect(abs(controller.lastSettleOffset - (metrics.size.width + draggedOffset)) < 0.5,
               "翻页瞬间位置连续，无跳变 (\(Int(controller.lastSettleOffset)))")
        expect(controller.page == 1, "向左拖动背景翻到第 2 页 (page=\(controller.page + 1))")
        spin(0.4)
        expect(controller.swipeOffset == 0, "松手后回弹到位")

        controller.page = 0
        controller.beginPan()
        controller.updatePan(translation: -metrics.size.width * 0.4)
        controller.endPan(predicted: -metrics.size.width * 0.5)
        spin(0.4)
        // And back: the previous page must land continuously too.
        controller.beginPan()
        controller.updatePan(translation: metrics.size.width * 0.3)
        let backOffset = controller.swipeOffset
        controller.endPan(predicted: metrics.size.width * 0.4)
        expect(abs(controller.lastSettleOffset - (backOffset - metrics.size.width)) < 0.5,
               "回翻瞬间位置连续 (\(Int(controller.lastSettleOffset)))")
        expect(controller.page == 0, "向右拖动翻回第 1 页")
        spin(0.4)

        controller.beginPan()
        controller.updatePan(translation: 300)
        expect(controller.swipeOffset > 0 && controller.swipeOffset < 300,
               "第一页继续右拖有橡皮筋阻力 (\(Int(controller.swipeOffset)))")
        controller.endPan(predicted: 0)
        spin(0.3)
        expect(controller.page == 0, "第一页右拖不会翻页")
        expect(controller.swipeOffset == 0, "橡皮筋回弹归零")

        // 7. Keyboard paging shortcuts go through the real panel key handler.
        let panel = LaunchpadPanel(displayID: 0, frame: CGRect(origin: .zero, size: size))
        panel.controller = controller
        controller.page = 0
        pressKey(panel, 124, [.command])
        expect(controller.page == 1, "⌘→ 翻到第 2 页 (page=\(controller.page + 1))")
        pressKey(panel, 123, [.option])
        expect(controller.page == 0, "⌥← 翻回第 1 页 (page=\(controller.page + 1))")
        pressKey(panel, 121, [])
        expect(controller.page == 1, "Page Down 翻页 (page=\(controller.page + 1))")
        pressKey(panel, 116, [])
        expect(controller.page == 0, "Page Up 翻页 (page=\(controller.page + 1))")
        pressKey(panel, 20, [.command]) // ⌘3
        expect(controller.page == min(2, controller.pageCount - 1), "⌘3 跳到第 3 页 (page=\(controller.page + 1))")
        pressKey(panel, 25, [.command]) // ⌘9
        expect(controller.page == controller.pageCount - 1, "⌘9 跳到最后一页 (page=\(controller.page + 1))")
        pressKey(panel, 115, [])
        expect(controller.page == 0, "Home 跳到第 1 页")
        pressKey(panel, 119, [])
        expect(controller.page == controller.pageCount - 1, "End 跳到最后一页")

        // 8. Typing goes into the search field, backspace edits it, Esc leaves.
        controller.endSearch(clearText: true)
        pressKey(panel, 13, [], characters: "w")  // W
        expect(controller.searchActive && controller.searchText == "w",
               "输入字符进入搜索 (searchText=\(controller.searchText))")
        pressKey(panel, 14, [], characters: "e")  // E
        expect(controller.searchText == "we", "继续输入会追加 (searchText=\(controller.searchText))")
        pressKey(panel, 51, [], characters: "\u{7f}")
        expect(controller.searchText == "w", "退格删除最后一个字符 (searchText=\(controller.searchText))")
        expect(!controller.searchHits().isEmpty, "搜索「w」命中 \(controller.searchHits().count) 个结果")
        controller.endSearch(clearText: true)
        controller.insertSearchText("微")
        expect(!controller.searchHits().isEmpty, "搜索「微」命中 \(controller.searchHits().count) 个结果")

        // 9. Search keeps the grid style: empty query shows everything, a query
        //    filters the same grid and the results cannot be rearranged.
        controller.endSearch(clearText: true)
        controller.page = 0
        controller.beginSearch()
        expect(!controller.isFiltering, "搜索框为空时不算筛选状态")
        expect(controller.displayItems.count == controller.currentItems.count,
               "未输入时展示当前页全部应用 (\(controller.displayItems.count) 项)")

        controller.insertSearchText("微")
        let matches = controller.searchHits()
        expect(controller.isFiltering, "输入后进入筛选状态")
        expect(controller.displayItems.count == matches.count,
               "筛选结果与命中数一致 (\(controller.displayItems.count) 项)")
        let matchIDs = Set(matches.map(\.item.id))
        expect(controller.displayItems.allSatisfy { matchIDs.contains($0.id) },
               "筛选后网格里只剩匹配项")
        expect(controller.displayItems.first?.id == matches.first?.item.id,
               "网格第一格是最佳匹配")

        let layoutBefore = controller.layout.pages
        controller.beginDrag(item: controller.displayItems[0],
                             point: metrics.cellCenter(index: 0),
                             grabOffset: .zero,
                             fromFolder: nil)
        expect(controller.drag == nil, "搜索结果不可拖动")
        expect(controller.layout.pages == layoutBefore, "拖动搜索结果不会改动布局")

        if let firstResult = controller.displayItems.first, let bundleID = firstResult.appID {
            controller.launchAnimation = nil
            controller.clickItem(firstResult)
            expect(controller.launchAnimation == LPItem.app(bundleID).id,
                   "点击搜索结果会打开对应应用")
            controller.launchAnimation = nil
        }

        pressKey(panel, 53, [])
        expect(!controller.searchActive && controller.searchText.isEmpty, "Esc 退出搜索并清空")

        // 10. ⊗ badges: visible in edit mode (also while dragging another icon),
        //     hidden for system apps and for the icon held by the pointer.
        controller.page = 0
        controller.jiggle = true
        let removable = controller.currentItems.first { item in
            guard let bundleID = item.appID else { return false }
            return controller.canDelete(bundleID)
        }
        let systemApp = controller.currentItems.first { item in
            guard let bundleID = item.appID else { return false }
            return !controller.canDelete(bundleID)
        }
        if let removable {
            expect(controller.showsDeleteBadge(for: removable), "抖动模式下可删除应用显示 ⊗")
            if let other = controller.currentItems.first(where: { $0.id != removable.id }) {
                controller.beginDrag(item: other,
                                     point: metrics.cellCenter(index: 0),
                                     grabOffset: .zero,
                                     fromFolder: nil)
                expect(controller.showsDeleteBadge(for: removable), "拖动别的图标时 ⊗ 仍然显示")
                expect(!controller.showsDeleteBadge(for: other), "被拿起的图标自己不显示 ⊗")
                controller.endDrag()
            }
        } else {
            fail("页面 1 上没有可删除的应用")
        }
        if let systemApp {
            expect(!controller.showsDeleteBadge(for: systemApp), "系统应用不显示 ⊗")
            expect(!controller.wobbles(systemApp), "没有 ⊗ 的图标不抖动")
        }
        controller.jiggle = false

        // Folder members get a badge too, so jiggling inside a folder is useful.
        if let folder = controller.layout.folders.values.first(where: { !$0.apps.isEmpty }),
           let member = folder.apps.first {
            controller.jiggle = true
            expect(controller.showsDeleteBadge(for: .app(member)) == controller.canDelete(member),
                   "文件夹内的应用同样按可删除性显示 ⊗")
            controller.jiggle = false
        }

        // 11. Deleting asks for confirmation first; cancelling changes nothing.
        if let removable {
            var prompted: [String] = []
            controller.confirmationHandler = { name in
                prompted.append(name)
                return false // user pressed 取消
            }
            let pagesBefore = controller.layout.pages
            controller.jiggle = true
            controller.requestDelete(removable.appID ?? "")
            controller.jiggle = false
            expect(prompted == [controller.name(of: removable.appID ?? "")],
                   "点删除会先弹确认框 (询问「\(prompted.first ?? "-")」)")
            expect(controller.layout.pages == pagesBefore, "取消后不会真的删除")
            controller.confirmationHandler = nil
        }

        // 12. Dragging past the right edge of the last page creates a new page.
        controller.page = controller.pageCount - 1
        if let item = controller.currentItems.first {
            let pagesBefore = controller.layout.pages.count
            controller.suppressDragAutoEnd = true
            controller.beginDrag(item: item,
                                 point: metrics.cellCenter(index: 0),
                                 grabOffset: .zero,
                                 fromFolder: nil)
            let rightEdge = CGPoint(x: metrics.size.width - 4, y: metrics.cellCenter(index: 0).y)
            controller.pointerLocationOverride = rightEdge
            controller.updateDrag(point: rightEdge)      // anchors
            spin(0.7)                                    // hold past the edge
            controller.updateDrag(point: rightEdge)      // flips
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
            expect(controller.layout.pages.count == pagesBefore + 1,
                   "拖到最后一页右缘会新建一页 (\(pagesBefore) → \(controller.layout.pages.count))")
            expect(controller.currentItems.contains { $0.id == item.id },
                   "被拖动的图标落在新页上")
        }

        // 13. A folder holds at most 35 icons (7 columns x 5 rows).
        if let folderID = controller.layout.folders.keys.sorted().first {
            for index in 0 ..< 45 {
                controller.addToFolderForTesting(folderID, app: "com.probe.app\(index)")
            }
            let count = controller.layout.folders[folderID]?.apps.count ?? 0
            expect(count == 35, "文件夹上限为 35 个图标 (实际 \(count))")
            controller.catalog.reload()
            controller.refreshCatalog()                  // drops the fake apps
            expect((controller.layout.folders[folderID]?.apps.count ?? 0) < 35,
                   "不存在的应用会被清理掉")
        }

        // 14. Dropping straight onto a folder puts the icon inside — no dwell.
        controller.page = 0   // the folder lives on the first page
        if let folderIndex = controller.currentItems.firstIndex(where: { $0.folderID != nil }),
           let folderID = controller.currentItems[folderIndex].folderID,
           let appIndex = controller.currentItems.firstIndex(where: { $0.appID != nil }),
           let appBundle = controller.currentItems[appIndex].appID {
            let before = controller.layout.folders[folderID]?.apps.count ?? 0
            let folderCenter = metrics.cellCenter(index: folderIndex)
            controller.suppressDragAutoEnd = true
            controller.pointerLocationOverride = folderCenter
            controller.beginDrag(item: controller.currentItems[appIndex],
                                 point: metrics.cellCenter(index: appIndex),
                                 grabOffset: .zero,
                                 fromFolder: nil)
            controller.updateDrag(point: folderCenter)
            expect(controller.drag?.hoveredFolderID == folderID, "拖到文件夹图标上会标记为放入目标")
            expect(controller.currentItems.firstIndex(where: { $0.folderID == folderID }) == folderIndex,
                   "悬停文件夹时它不会被图标挤走")
            // A pointer anywhere in the folder's slot must work too — otherwise
            // the folder dodges away before the icon area is reached.
            let slotEdge = CGPoint(x: metrics.cellFrame(index: folderIndex).minX + 6,
                                   y: metrics.cellFrame(index: folderIndex).midY)
            controller.updateDrag(point: slotEdge)
            expect(controller.drag?.hoveredFolderID == folderID, "格子边缘也能命中文件夹")
            expect(controller.currentItems.firstIndex(where: { $0.folderID == folderID }) == folderIndex,
                   "停在格子边缘时文件夹依然不动")
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
            expect((controller.layout.folders[folderID]?.apps.count ?? 0) == before + 1,
                   "松手即放进文件夹，无需等待 0.5 秒")
        }

        // 16. A folder being dragged never targets itself, so it can be moved.
        controller.page = 0
        if let folderIndex = controller.currentItems.firstIndex(where: { $0.folderID != nil }),
           folderIndex < controller.currentItems.count {
            let folderItem = controller.currentItems[folderIndex]
            let center = metrics.cellCenter(index: folderIndex)
            controller.suppressDragAutoEnd = true
            controller.pointerLocationOverride = metrics.cellCenter(index: 5)
            controller.beginDrag(item: folderItem, point: center, grabOffset: .zero, fromFolder: nil)
            controller.updateDrag(point: metrics.cellCenter(index: 5))
            expect(controller.drag?.hoveredFolderID == nil, "拖动文件夹时不会把自己当成投放目标")
            expect(controller.drag?.index == 5 || controller.currentItems.firstIndex(where: { $0.id == folderItem.id }) == 5,
                   "文件夹本身仍然可以拖动排序")
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
        }

        // 15. Dragging an app out of an opened folder returns it to the grid.
        if let folderID = controller.layout.folders.keys.sorted().first,
           let app = controller.layout.folders[folderID]?.apps.first,
           let folderIndex = controller.currentItems.firstIndex(where: { $0.folderID == folderID }) {
            let countBefore = controller.layout.folders[folderID]?.apps.count ?? 0
            let panel = metrics.folderPanel(itemCount: countBefore)
            let inside = panel.cellCenter(index: 0)
            let outside = CGPoint(x: metrics.gridFrame.minX + 30, y: metrics.gridFrame.maxY - 30)
            controller.openFolderID = folderID
            controller.suppressDragAutoEnd = true
            controller.pointerLocationOverride = outside
            controller.beginDrag(item: .app(app),
                                 point: inside,
                                 grabOffset: .zero,
                                 fromFolder: folderID)
            controller.updateDrag(point: outside)
            expect(!(controller.layout.folders[folderID]?.apps.contains(app) ?? false),
                   "拖出面板后应用已离开文件夹")
            expect(controller.layout.contains(app: app), "拖出后应用回到网格")
            expect(controller.openFolderID == nil, "拖出后面板自动关闭")
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
            expect(controller.layout.pages.contains { $0.contains(.app(app)) }, "松手后应用留在网格上")
        }

        // 17. ⌘Q quits the helper (menu bar app: no Dock icon to quit from).
        var didQuit = false
        let savedTerminator = controller.terminateHandler
        controller.terminateHandler = { didQuit = true }
        controller.isOpen = true
        pressKey(panel, 12, [.command], characters: "q")   // kVK_ANSI_Q
        expect(didQuit, "在启动台界面里按 ⌘Q 可以退出应用")
        controller.terminateHandler = savedTerminator

        // 18. Pinch gestures: inward pinch closes when open.
        controller.isOpen = true
        controller.handlePinch(magnification: -0.05)
        expect(controller.isOpen, "小幅捏合不触发关闭（累积中）")
        controller.handlePinch(magnification: -0.2)
        expect(!controller.isOpen, "向内捏合关闭启动台")
        controller.handlePinch(magnification: 0.3)
        expect(!controller.isOpen, "向外张开不会误触发")

        // 19. Dragging a folder to another page must keep its contents.
        controller.page = 0
        if let folderIndex = controller.currentItems.firstIndex(where: { $0.folderID != nil }),
           let folderID = controller.currentItems[folderIndex].folderID {
            let appsBefore = controller.layout.folders[folderID]?.apps ?? []
            let folderItem = controller.currentItems[folderIndex]
            controller.suppressDragAutoEnd = true
            let rightEdge = CGPoint(x: metrics.size.width - 4, y: metrics.cellCenter(index: folderIndex).y)
            controller.pointerLocationOverride = rightEdge
            controller.beginDrag(item: folderItem,
                                 point: metrics.cellCenter(index: folderIndex),
                                 grabOffset: .zero,
                                 fromFolder: nil)
            controller.updateDrag(point: rightEdge)   // 锚定
            spin(0.7)                                  // 停在边缘翻页
            controller.updateDrag(point: rightEdge)
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
            expect(controller.layout.folders[folderID]?.apps.count == appsBefore.count,
                   "拖动文件夹换页后内容仍在（\(appsBefore.count) → \(controller.layout.folders[folderID]?.apps.count ?? -1)）")
            expect(controller.layout.pages.contains { $0.contains(.folder(folderID)) },
                   "文件夹本身还在网格上")
        }

        // 20. Holding still over another icon must arm (and then form) a folder.
        controller.page = 0
        let itemsForFolder = controller.currentItems
        if itemsForFolder.count > 3,
           let draggedApp = itemsForFolder[0].appID,
           let targetApp = itemsForFolder[2].appID {
            let targetCenter = metrics.cellCenter(index: 2)
            let startCenter = metrics.cellCenter(index: 0)
            controller.suppressDragAutoEnd = true
            controller.pointerLocationOverride = targetCenter
            controller.beginDrag(item: .app(draggedApp), point: startCenter, grabOffset: .zero, fromFolder: nil)
            controller.updateDrag(point: targetCenter)
            spin(0.5)                                  // 停住不动
            controller.updateDrag(point: targetCenter)
            expect(controller.drag?.folderCandidateID != nil, "停住时高亮将要合并的图标")
            controller.endDrag()
            controller.pointerLocationOverride = nil
            controller.suppressDragAutoEnd = false
            let formedFolder = controller.layout.folders.values.first {
                $0.apps.contains(draggedApp) && $0.apps.contains(targetApp)
            }
            expect(formedFolder != nil, "停住 0.4 秒后松手即建成文件夹")
        }

        // 21. 关闭时先播放淡出动画，窗口不会立刻消失.
        controller.isOpen = true
        OverlayCoordinator.shared.dismiss()
        expect(controller.isClosing, "关闭时先进入淡出状态")
        expect(controller.isOpen, "淡出期间界面仍然在（避免突然消失）")
        spin(0.35)
        expect(!controller.isOpen && !controller.isClosing, "淡出结束后才真正关闭")

        // 22. 入场动画只在"刚打开"那段时间生效，切页不会重放（避免闪一下）.
        controller.isOpen = true
        controller.prepareForOpen()
        expect(controller.isOpening, "打开启动台时进入入场动画阶段")
        spin(0.8)
        expect(!controller.isOpening, "0.7 秒后入场动画阶段结束（此后切页图标直接显示）")

        controller.isOpen = false

        // 23. 背景默认免权限：老版本存下的"截屏桌面"会一次性迁移到系统模糊；
        //     录屏方式已从代码里删除，新旧键都要被清掉.
        checkBackdropMigration()

        // 24. 外观设置：不透明度 / 图标大小 / 每行图标数量.
        checkAppearanceSettings()
        checkGridRepack()

        // 25. 只渲染当前页（滑动时才带相邻页）。
        checkPageRenderPolicy()

        // 26. 多选 / 框选 / 批量操作。
        checkMultiSelection(controller: controller, metrics: metrics)

        // 27. 自定义背景图片。
        checkCustomBackdrop(size: size)

        // 28. 隐藏 Dock 图标开关。
        checkDockIconPref()

        // 29. 应用信息浮层。
        checkInfoCard(controller: controller)

        // 30. 翻页动画（点圆点 / 按快捷键也要滑过去）。
        checkPageFlipAnimation(controller: controller, metrics: metrics)

        // 31. 跟手翻页的手感：能走满一整屏，松手接着手指速度滑完。
        checkPanFeel(controller: controller, metrics: metrics)

        if failures.isEmpty {
            print("自检通过 ✓")
            return 0
        }
        print("自检失败:")
        for failure in failures { print("  ✗ \(failure)") }
        return 1
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition { print("  ✓ \(message)") } else { fail(message) }
    }

    /// 「背景方式」的默认值与一次性迁移：默认必须是免权限的系统模糊。
    /// 录屏方式已经删除，所以老版本存下的 screenshot 与旧开关都要被清掉。
    private static func checkBackdropMigration() {
        let defaults = UserDefaults.standard
        let savedStyle = defaults.object(forKey: "backdropStyle")
        let savedLegacy = defaults.object(forKey: "useScreenshotBackdrop")
        let savedVersion = defaults.object(forKey: "backdropMigrationVersion")
        defer {
            restore(savedStyle, "backdropStyle", in: defaults)
            restore(savedLegacy, "useScreenshotBackdrop", in: defaults)
            restore(savedVersion, "backdropMigrationVersion", in: defaults)
        }

        // 全新安装：没有任何背景设置时用系统模糊。
        defaults.removeObject(forKey: "backdropStyle")
        defaults.removeObject(forKey: "useScreenshotBackdrop")
        defaults.removeObject(forKey: "backdropMigrationVersion")
        expect(Prefs.backdropStyle == .blur, "默认背景方式是系统模糊")
        expect(!BackdropStyle.allCases.contains { $0.rawValue == "screenshot" },
               "背景方式里已经没有截屏方式了（现有 \(BackdropStyle.allCases.count) 种，全部免权限）")

        // 老版本：保存了"截屏桌面" + 旧的 useScreenshotBackdrop 开关。
        defaults.set("screenshot", forKey: "backdropStyle")
        defaults.set(true, forKey: "useScreenshotBackdrop")
        defaults.set(true, forKey: "liveBackdrop")
        Prefs.migrateBackdropDefaultsIfNeeded()
        expect(Prefs.backdropStyle == .blur, "老版本的截屏背景已迁移为系统模糊")
        expect(defaults.object(forKey: "useScreenshotBackdrop") == nil, "迁移时清掉旧的截屏开关")
        expect(defaults.object(forKey: "liveBackdrop") == nil, "迁移时清掉旧的实时抓屏开关")

        // 迁移只做一次：用户之后选的"系统壁纸图片"不会被再改掉。
        Prefs.backdropStyle = .wallpaper
        Prefs.migrateBackdropDefaultsIfNeeded()
        expect(Prefs.backdropStyle == .wallpaper, "迁移只执行一次，之后尊重用户的选择")
        Prefs.backdropStyle = .blur
    }

    /// 外观设置：默认值、范围夹取，以及几何是否真的跟着变。
    private static func checkAppearanceSettings() {
        let defaults = UserDefaults.standard
        let keys = ["backdropOpacity", "iconScale", "gridColumns"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { restore(value, key, in: defaults) } }

        for key in keys { defaults.removeObject(forKey: key) }
        expect(Prefs.backdropOpacity == 0.70, "背景不透明度默认 70%")
        expect(Prefs.backdropDim > 0.29 && Prefs.backdropDim < 0.31, "压暗浓度 = 1 - 不透明度")
        expect(Prefs.iconScale == 1.0, "图标大小默认 100%")
        expect(Prefs.gridColumns == 0, "每行图标数量默认自动")
        expect(Prefs.columnOverride == nil, "自动时不覆盖网格列数")

        Prefs.backdropOpacity = 0.1
        expect(Prefs.backdropOpacity == 0.25, "不透明度下限夹到 25%")
        Prefs.backdropOpacity = 2
        expect(Prefs.backdropOpacity == 1.0, "不透明度上限夹到 100%")
        Prefs.iconScale = 9
        expect(Prefs.iconScale == 1.35, "图标缩放上限夹到 135%")
        Prefs.iconScale = 0.1
        expect(Prefs.iconScale == 0.7, "图标缩放下限夹到 70%")
        Prefs.gridColumns = 40
        expect(Prefs.gridColumns == Prefs.maxColumns, "每行列数上限夹到 \(Prefs.maxColumns)")
        Prefs.gridColumns = 1
        expect(Prefs.gridColumns == 0, "小于下限的值按自动处理")

        // 几何：列数覆盖与图标缩放确实作用到 Metrics 上。
        let size = CGSize(width: 3008, height: 1692)
        let auto = Metrics(size: size)
        let five = Metrics(size: size, columns: 5)
        expect(auto.columns == 7, "大屏自动是 7 列")
        expect(five.columns == 5, "手动指定 5 列生效")
        expect(five.capacity == 25, "5 列 × 5 行 = 每页 25 个")
        expect(five.iconSize >= auto.iconSize, "列数变少时图标变大（不缩小）")
        let big = Metrics(size: size, iconScale: 1.35)
        let small = Metrics(size: size, iconScale: 0.7)
        expect(big.iconSize > auto.iconSize, "图标放大生效（\(Int(auto.iconSize)) → \(Int(big.iconSize))）")
        expect(small.iconSize < auto.iconSize, "图标缩小生效（\(Int(auto.iconSize)) → \(Int(small.iconSize))）")
        expect(big.iconSize <= big.cellSize.height * 0.86 + 0.01, "放大后不会顶到下一行")
        expect(big.labelFont > small.labelFont, "名称字号跟着图标一起缩放")

        // 背景遮罩必须读设置里的值（之前参数漏传，滑杆怎么拖都不变）。
        Prefs.backdropOpacity = 1.0
        expect(WallpaperBackdrop.currentOverlayDim(style: .blur) == 0,
               "不透明度 100% 时系统模糊层不叠加黑色遮罩")
        Prefs.backdropOpacity = 0.4
        let dim40 = WallpaperBackdrop.currentOverlayDim(style: .blur)
        expect(abs(dim40 - 0.6) < 0.001, "不透明度 40% → 压暗 0.60（实际 \(dim40)）")
        let folderDim = WallpaperBackdrop.currentOverlayDim(style: .blur, extraDim: true)
        expect(abs(folderDim - 0.72) < 0.001, "打开文件夹时再多压暗 0.12")
        Prefs.backdropOpacity = 1.0
        expect(WallpaperBackdrop.currentOverlayDim(style: .wallpaper) == 0,
               "壁纸模式在 100% 时也不再额外压暗")
        Prefs.backdropOpacity = 0.25
        expect(WallpaperBackdrop.currentOverlayDim(style: .blur) == 0.75,
               "不透明度 25% → 压暗 0.75")
        expect(WallpaperBackdrop.overlayDim(style: .blur, dim: 0.9, extraDim: true) == 0.85,
               "压暗上限 0.85（不会整块变黑）")
    }

    /// 每行列数变化后单页容量会变：
    /// · 平时打开应用只"拆分"超容量的页，用户自己排的分页要保留；
    /// · 用户显式改列数时才按顺序整页重排。
    private static func checkGridRepack() {
        let items = (0 ..< 40).map { LPItem.app("com.example.app\($0)") }
        let packed = Layout.repack([items], capacity: 25)
        expect(packed.count == 2, "40 个图标按每页 25 个重排成 2 页")
        expect(packed[0].count == 25 && packed[1].count == 15, "分页是 25 + 15")
        expect(packed.flatMap { $0 } == items, "重排后顺序不变")
        let wide = Layout.repack(packed, capacity: 35)
        expect(wide.count == 2 && wide[0].count == 35 && wide[1].count == 5, "调回 7 列后重新合并成 35 + 5")
        expect(Layout.repack([], capacity: 35).count == 1, "空布局仍然是 1 个空页")

        // 打开应用时的"拆分"：不满的页原样保留，超出的页拆开。
        let sparse = [Array(items[0 ..< 3]), Array(items[3 ..< 39])]
        let split = Layout.splitOverflowing(sparse, capacity: 25)
        expect(split.count == 3, "只拆超容量的那一页（2 → 3）")
        expect(split[0].count == 3, "不满的页保持不动")
        expect(split[1].count == 25 && split[2].count == 11, "超出的页被切成 25 + 11")
        expect(Layout.splitOverflowing([[items[0]]], capacity: 25)[0].count == 1, "单页小布局不受影响")
    }

    private static func restore(_ value: Any?, _ key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    /// 每帧只建"真的可能出现在屏幕上"的页。
    private static func checkPageRenderPolicy() {
        expect(PageRenderPolicy.pages(current: 2, count: 5, sliding: false) == [2],
               "静止且还没预取时只渲染当前页")
        expect(PageRenderPolicy.pages(current: 2, count: 5, sliding: false, prefetch: [1, 3]) == [1, 2, 3],
               "预取完成后相邻页留着，起步拖动才不会卡第一帧")
        expect(PageRenderPolicy.pages(current: 2, count: 5, sliding: true, offset: -400) == [2, 3],
               "左滑只需要当前页 + 右侧下一页")
        expect(PageRenderPolicy.pages(current: 2, count: 5, sliding: true, offset: 400) == [1, 2],
               "右滑只需要当前页 + 左侧上一页")
        expect(PageRenderPolicy.pages(current: 2, count: 5, sliding: true, offset: -400, prefetch: [1]) == [1, 2, 3],
               "已经开始滑时，预取过的页要留着（移出视图树就会被销毁）")
        expect(PageRenderPolicy.pages(current: 1, count: 5, sliding: true, offset: 600) == [0, 1],
               "换页那一帧不再现建远在屏幕外的页（这正是原来卡一下的原因）")
        expect(PageRenderPolicy.pages(current: 0, count: 5, sliding: true, offset: -400) == [0, 1],
               "第一页不会渲染越界的上一页")
        expect(PageRenderPolicy.pages(current: 4, count: 5, sliding: true, offset: 400) == [3, 4],
               "最后一页不会渲染越界的下一页")
        expect(PageRenderPolicy.pages(current: 0, count: 1, sliding: true, offset: -400) == [0],
               "只有一页时只渲染它自己")
        expect(PageRenderPolicy.pages(current: 9, count: 3, sliding: false) == [2],
               "页码越界时夹到最后一页")
        // 橡皮筋：第一页往右拖不会凭空出现上一页。
        expect(PageRenderPolicy.pages(current: 0, count: 5, sliding: true, offset: 300) == [0],
               "第一页往右拉（橡皮筋）不会渲染不存在的上一页")
    }

    /// 多选、框选、成组拖拽与批量操作。
    private static func checkMultiSelection(controller: LaunchpadController, metrics: Metrics) {
        controller.page = 0
        controller.multiSelection.removeAll()
        controller.selection = nil

        // 注意：首页第一个格子可能是文件夹，所以"前两个格子"和"前两个应用"
        // 不是一回事 —— 框选按格子算，多选/批量按应用算，分开取。
        let slotItems = Array(controller.currentItems.prefix(2))
        let apps = controller.currentItems.compactMap(\.appID)
        expect(apps.count >= 3, "首页至少有 3 个应用可用于测试（实际 \(apps.count)）")
        guard apps.count >= 3, slotItems.count == 2 else { return }

        let first = LPItem.app(apps[0])
        let second = LPItem.app(apps[1])

        controller.toggleMultiSelection(first)
        expect(controller.isSelected(first), "⌘ 点选后图标处于选中态")
        expect(controller.multiSelection.count == 1, "选中集合里有 1 个")
        controller.toggleMultiSelection(first)
        expect(!controller.isSelected(first), "再 ⌘ 点一次取消选中")

        // 框选：覆盖前两个格子的矩形应该正好选中前两个。
        let rectStart = CGPoint(x: metrics.gridFrame.minX + 4, y: metrics.gridFrame.minY + 4)
        let rectEnd = CGPoint(x: metrics.cellFrame(index: 1).maxX - 4,
                              y: metrics.cellFrame(index: 1).maxY - 4)
        controller.updateBand(from: rectStart, to: rectEnd)
        expect(controller.bandRect != nil, "框选时记录矩形（用于画选框）")
        expect(controller.multiSelection.contains(slotItems[0].id), "框选命中第 1 个格子")
        expect(controller.multiSelection.contains(slotItems[1].id), "框选命中第 2 个格子")
        expect(controller.multiSelection.count == 2, "框选结果正好 2 个（实际 \(controller.multiSelection.count)）")
        controller.endBand()
        expect(controller.bandRect == nil, "松手后选框消失")

        // ⌘A 全选当前页。
        controller.selectAllOnPage()
        expect(controller.multiSelection.count == controller.currentItems.count,
               "⌘A 选中当前页全部 \(controller.currentItems.count) 个")
        controller.clearMultiSelection()
        expect(controller.multiSelection.isEmpty, "Esc/点空白可以清空选择")

        // 成组拖拽：多选里拖一个 → 整组被带走。
        controller.multiSelection = Set([first, second].map(\.id))
        controller.suppressDragAutoEnd = true
        controller.beginDrag(item: second,
                             point: metrics.cellCenter(index: 1),
                             grabOffset: .zero,
                             fromFolder: nil)
        expect(controller.drag?.isGroupDrag == true, "多选状态下拖动会带上整组")
        expect(controller.drag?.companionIDs == [first.id], "同行伙伴就是另一个选中项")
        controller.cancelDrag()
        controller.suppressDragAutoEnd = false

        // 批量隐藏。
        controller.multiSelection = Set([first, second].map(\.id))
        controller.hideSelected()
        expect(controller.multiSelection.isEmpty, "批量操作后自动取消选择")
        expect(controller.layout.hidden.contains(apps[0]) && controller.layout.hidden.contains(apps[1]),
               "两个应用都被收进隐藏列表")
        expect(!controller.layout.pages.contains { $0.contains(first) }, "隐藏后不再出现在网格上")

        controller.unhideAll()
        expect(controller.layout.hidden.isEmpty, "可以从偏好设置一次性恢复")
        expect(controller.layout.pages.contains { $0.contains(first) }, "恢复后回到网格")

        // 批量删除必须经过确认：取消时一个都不能动。
        let target = controller.currentItems.compactMap(\.appID)
            .first { controller.canDelete($0) }
        if let target {
            controller.multiSelection = [LPItem.app(target).id]
            var asked: [String] = []
            controller.batchConfirmationHandler = { names in
                asked = names
                return false
            }
            let before = controller.layout.contains(app: target)
            controller.requestDeleteSelected()
            expect(asked.count == 1, "批量删除会先把要删的清单交给确认框")
            expect(controller.layout.contains(app: target) == before, "点“取消”后什么都没删")
            controller.batchConfirmationHandler = nil
            controller.multiSelection.removeAll()
        }
    }

    /// 自定义背景图：导入 / 读取 / 移除 / 越界兜底。
    private static func checkCustomBackdrop(size: CGSize) {
        CustomBackdrop.remove()
        expect(!CustomBackdrop.hasImage, "一开始没有自定义背景")

        // 造一张 64×64 的**左红右蓝** PNG 当作"用户选的图片"：
        // 有硬边才能验证"模糊真的生效了"（纯色图模糊前后是一样的）。
        let source = URL(fileURLWithPath: NSTemporaryDirectory() + "launchpad-selftest-bg.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                               bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
            if let image = ctx.makeImage(),
               let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }

        expect(CustomBackdrop.importImage(from: source), "可以导入用户选择的图片")
        expect(CustomBackdrop.hasImage, "导入后标记为已有背景")
        expect(CustomBackdrop.fileURL != nil, "图片被复制进应用支持目录（原图移动也不影响）")
        let loaded = CustomBackdrop.image(size: size)
        expect(loaded != nil, "能按屏幕尺寸读出背景图")
        expect((loaded?.width ?? 0) == Int(size.width), "背景图按屏幕宽度裁剪（\(loaded?.width ?? 0)）")

        expect(WallpaperBackdrop.overlayDim(style: .image, dim: 0.3, extraDim: false) == 0.3,
               "自定义图片用完整遮罩（图本身没有预先压暗）")

        checkCustomBackdropBlur(size: size)

        CustomBackdrop.remove()
        expect(!CustomBackdrop.hasImage, "移除后回到没有自定义背景")

        // 选了"自定义图片"但文件不见了 → 打开时退回系统模糊，而不是一片黑。
        let defaults = UserDefaults.standard
        let savedStyle = defaults.object(forKey: "backdropStyle")
        let savedVersion = defaults.object(forKey: "backdropMigrationVersion")
        defaults.set(BackdropStyle.image.rawValue, forKey: "backdropStyle")
        defaults.set(0, forKey: "backdropMigrationVersion")
        Prefs.migrateBackdropDefaultsIfNeeded()
        expect(Prefs.backdropStyle == .blur, "图片丢失时自动退回系统模糊")
        restore(savedStyle, "backdropStyle", in: defaults)
        restore(savedVersion, "backdropMigrationVersion", in: defaults)
    }

    private static func checkDockIconPref() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "hideDockIcon")
        defer { restore(saved, "hideDockIcon", in: defaults) }
        defaults.removeObject(forKey: "hideDockIcon")
        expect(Prefs.hideDockIcon == false, "默认在程序坞里显示图标")
        Prefs.hideDockIcon = true
        expect(Prefs.hideDockIcon, "可以设置隐藏程序坞图标")
        Prefs.hideDockIcon = false
        expect(!Prefs.hideDockIcon, "可以再打开")
    }

    /// 自定义背景图的模糊：默认开启、范围夹取、而且真的作用到像素上。
    private static func checkCustomBackdropBlur(size: CGSize) {
        let defaults = UserDefaults.standard
        let savedBlur = defaults.object(forKey: "backdropBlur")
        let savedStyle = defaults.object(forKey: "backdropStyle")
        defer {
            restore(savedBlur, "backdropBlur", in: defaults)
            restore(savedStyle, "backdropStyle", in: defaults)
            WallpaperProvider.shared.invalidate()
        }

        defaults.removeObject(forKey: "backdropBlur")
        expect(Prefs.backdropBlur == 40, "自定义背景图默认带模糊（40）")
        Prefs.backdropBlur = -5
        expect(Prefs.backdropBlur == 0, "模糊强度下限夹到 0（原图）")
        Prefs.backdropBlur = 999
        expect(Prefs.backdropBlur == Prefs.maxBackdropBlur, "模糊强度上限夹到 \(Int(Prefs.maxBackdropBlur))")

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            expect(true, "没有屏幕，跳过模糊像素验证")
            return
        }
        Prefs.backdropStyle = .image
        let sampleSize = CGSize(width: 400, height: 300)

        Prefs.backdropBlur = 0
        WallpaperProvider.shared.invalidate()
        let sharp = WallpaperProvider.shared.backdrop(for: screen, size: sampleSize, strong: false)
        Prefs.backdropBlur = 60
        WallpaperProvider.shared.invalidate()
        let blurred = WallpaperProvider.shared.backdrop(for: screen, size: sampleSize, strong: false)

        expect(sharp != nil && blurred != nil, "自定义图片两种模糊强度都能渲染出背景")
        expect(WallpaperProvider.shared.lastSource.contains("custom-image"),
               "背景来源标注为自定义图片（\(WallpaperProvider.shared.lastSource)）")
        guard let sharp, let blurred else {
            fail("取像素失败，无法验证模糊")
            return
        }
        // 左红右蓝的图：模糊会把红色"渗"进蓝色一侧。取接缝两侧一排点比较，
        // 不模糊时这一排几乎是纯色阶跃，模糊后必然明显变化。
        let probes = [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.42, y: 0.5),
                      CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.58, y: 0.5),
                      CGPoint(x: 0.7, y: 0.5)]
        var maxDelta = 0
        for probe in probes {
            guard let before = pixel(of: sharp, at: probe),
                  let after = pixel(of: blurred, at: probe) else { continue }
            maxDelta = max(maxDelta,
                           abs(before.red - after.red),
                           abs(before.green - after.green),
                           abs(before.blue - after.blue))
        }
        expect(maxDelta > 25, "模糊 60 之后接缝两侧像素明显变化（最大差 \(maxDelta)）")
        if let blur0 = pixel(of: sharp, at: CGPoint(x: 0.3, y: 0.5)),
           let blur60 = pixel(of: blurred, at: CGPoint(x: 0.3, y: 0.5)) {
            expect(blur60.blue > blur0.blue,
                   "模糊把蓝色渗进红色一侧（B \(blur0.blue) → \(blur60.blue)）")
        }
    }

    /// 取图片上某个相对位置的像素（0…1）。
    private static func pixel(of image: CGImage, at relative: CGPoint) -> (red: Int, green: Int, blue: Int)? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = CGFloat(image.width) * relative.x
        let y = CGFloat(image.height) * relative.y
        context.draw(image, in: CGRect(x: -x, y: -y,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// 翻页动画：点圆点 / 按快捷键 / 拖到边缘都要"整屏滑过去"，而不是瞬间跳。
    private static func checkPageFlipAnimation(controller: LaunchpadController, metrics: Metrics) {
        guard controller.pageCount > 1 else {
            expect(true, "只有一页，跳过翻页动画测试")
            return
        }
        controller.isOpen = true
        controller.page = 0
        controller.swipeOffset = 0
        controller.flippingPages = []

        controller.goToPage(1)
        expect(controller.page == 1, "goToPage 会立即切换当前页")
        expect(controller.flippingPages == [0, 1], "动画期间两端页都留在视图树里")
        expect(abs(controller.swipeOffset - metrics.size.width) < 0.5,
               "动画开始时目标页被摆在屏幕外（offset = 一屏宽）")
        spin(0.9)
        expect(abs(controller.swipeOffset) < 0.5, "动画结束后回到静止位置")
        expect(controller.flippingPages.isEmpty, "动画结束后释放多余页")

        controller.flipPage(-1)
        expect(controller.page == 0, "flipPage(-1) 回到上一页")
        expect(controller.flippingPages == [0, 1], "反向翻页同样有动画")
        spin(0.9)

        // 跨页跳转：中间页会快速掠过屏幕，必须一起渲染，否则会看到背景闪一下。
        controller.goToPage(controller.pageCount - 1)
        expect(controller.page == controller.pageCount - 1, "跨页跳转到最后一页")
        expect(controller.flippingPages == Array(0 ... (controller.pageCount - 1)),
               "跨页跳转把中间页也纳入渲染（\(controller.flippingPages)）")
        spin(1.4)   // 跨页越多动画越长（response 0.38 + 0.07/页），这里要等它收尾
        expect(controller.flippingPages.isEmpty, "跨页跳转结束后一样会收尾")

        controller.page = 0
        controller.swipeOffset = 0
    }

    /// 跟手翻页：能跟满一整屏，松手时把手指速度接到动画上。
    private static func checkPanFeel(controller: LaunchpadController, metrics: Metrics) {
        let width = metrics.size.width
        controller.isOpen = true
        controller.page = 0
        controller.swipeOffset = 0
        controller.isPanning = false
        controller.drag = nil

        // 鼠标拖背景：以前只能走 90% 一屏，剩下的靠松手动画一次窜过去。
        controller.beginPan(at: CGPoint(x: width / 2, y: metrics.size.height / 2))
        expect(controller.isPanning, "按住背景开始跟手拖动")
        let mid = CGPoint(x: width / 2, y: metrics.size.height / 2)
        controller.updatePan(translation: -width * 1.6, point: mid)
        expect(abs(controller.swipeOffset + width) < 0.5,
               "跟手最多走满一整屏（现在 \(Int(-controller.swipeOffset))）")
        controller.updatePan(translation: -width * 1.2, point: mid)
        controller.endPan(predicted: -width * 1.2)
        expect(!controller.isPanning, "松手结束跟手状态")
        // 松手那一瞬间，滑出去的那一页必须还留在渲染集合里。
        // （之前 `withAnimation { swipeOffset = 0 }` 让模型值立刻变 0，
        //   渲染规则据此认为"已经不在滑动"，把上一页移出了视图树 —— 看着就是突然消失。）
        expect(controller.page == 1, "松手后翻到第 2 页")
        expect(controller.flippingPages.contains(0) && controller.flippingPages.contains(1),
               "松手后两端页都被钉在渲染集合里（上一页不会突然消失）")
        let settlePages = PageRenderPolicy.pages(current: controller.page,
                                                 count: controller.pageCount,
                                                 sliding: abs(controller.swipeOffset) > 0.5,
                                                 offset: controller.swipeOffset,
                                                 prefetch: controller.prefetchedPages,
                                                 flip: controller.flippingPages)
        expect(settlePages.contains(0) && settlePages.contains(1),
               "动画期间上一页仍在渲染（\(settlePages)）")
        spin(0.7)
        expect(controller.flippingPages.isEmpty, "动画结束后才释放上一页")

        // 只拖了 40%：松手后剩下的 60% 由动画滑完，而不是瞬间跳过去。
        controller.page = 0
        controller.swipeOffset = 0
        controller.isPanning = true
        controller.updatePan(translation: -width * 0.4, point: mid)
        expect(abs(controller.swipeOffset + width * 0.4) < 0.5, "跟手 40% 时页面也停在 40%")
        controller.endPan(predicted: -width * 0.4)
        // 动画期间模型值已经是 0，所以要看向前衔接的位移（lastSettleOffset）。
        expect(abs(controller.lastSettleOffset) > width * 0.3,
               "松手后余下距离交给动画滑完（衔接位移 \(Int(controller.lastSettleOffset))）")
        spin(0.9)
        expect(abs(controller.swipeOffset) < 0.5, "动画结束后停在新页面")
        controller.page = 0
        controller.swipeOffset = 0

        // 双指滑动：以前只跟到 45%，这是"有点突然"的主要来源。
        controller.swipeOffset = 0
        controller.handleScroll(deltaX: -width * 1.4)
        expect(abs(controller.swipeOffset + width) < 1,
               "双指滑动也能跟满一整屏（现在 \(Int(-controller.swipeOffset))）")
        // 收尾，避免影响后面的用例
        controller.swipeOffset = 0
        spin(0.4)
        controller.page = 0
        controller.swipeOffset = 0
    }

    /// ⌥ 点图标弹出的信息卡片。
    private static func checkInfoCard(controller: LaunchpadController) {
        controller.page = 0
        guard let appIndex = controller.currentItems.firstIndex(where: { $0.appID != nil }),
              let bundleID = controller.currentItems[appIndex].appID,
              let entry = controller.catalog.entry(bundleID) else {
            fail("信息浮层测试需要至少一个应用")
            return
        }
        controller.showInfo(for: controller.currentItems[appIndex])
        guard let card = controller.infoCard else {
            fail("⌥ 点图标应该弹出信息卡片")
            return
        }
        // 卡片标题用的是启动台显示名（可能来自旧数据库），不一定等于应用包里的名字。
        expect(card.title == controller.name(of: bundleID), "卡片标题是启动台里的应用名（\(card.title)）")
        expect(card.rows.contains { $0.label == "位置" && $0.value.contains(entry.path) },
               "卡片里有应用路径")
        expect(card.rows.contains { $0.label == "标识符" && $0.value == bundleID },
               "卡片里有 bundle id")
        expect(card.rows.contains { $0.label == "最近打开" }, "卡片里有最近打开时间")
        expect(card.rows.contains { $0.label == "大小" }, "卡片里有体积（后台计算后补上）")
        expect(card.path != nil && card.bundleID == bundleID, "卡片记住了用于「在访达中显示」的路径")
        controller.hideInfo()
        expect(controller.infoCard == nil, "可以关掉信息卡片")

        // 文件夹也能看信息。
        if let folderIndex = controller.currentItems.firstIndex(where: { $0.folderID != nil }) {
            controller.showInfo(for: controller.currentItems[folderIndex])
            expect(controller.infoCard?.subtitle == "文件夹", "文件夹信息卡片可用")
            controller.hideInfo()
        }
    }
    private static func fail(_ message: String) {
        failures.append(message)
        print("  ✗ \(message)")
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func pressKey(_ panel: LaunchpadPanel,
                                 _ keyCode: UInt16,
                                 _ flags: NSEvent.ModifierFlags,
                                 characters: String = "") {
        guard let event = NSEvent.keyEvent(with: .keyDown,
                                          location: .zero,
                                          modifierFlags: flags,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: 0,
                                          context: nil,
                                          characters: characters,
                                          charactersIgnoringModifiers: characters,
                                          isARepeat: false,
                                          keyCode: keyCode) else { return }
        _ = panel.handleKeyEventForTesting(event)
    }
}
