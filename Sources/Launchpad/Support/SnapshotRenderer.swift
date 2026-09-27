import AppKit
import Foundation
import SwiftUI

/// Headless renderer used to visually verify the layout without a display.
@MainActor
enum SnapshotRenderer {
    static func run(directory: URL, size: CGSize) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 离线渲染无法绘制 NSVisualEffectView（需要窗口服务器），
        // 所以开发用的快照固定走"系统壁纸图片"路径。
        Prefs.backdropStyle = .wallpaper
        let controller = LaunchpadController.shared
        controller.bootstrap()

        guard let raw = WallpaperProvider.shared.legacyWallpaperImage() ?? ImageEffects.gradient(size: size) else {
            print("no wallpaper available")
            return 1
        }
        let backdrop = ImageEffects.backdrop(from: raw, size: size)
        let strong = ImageEffects.backdrop(from: raw, size: size, blur: 74, darken: 0.34)

        let display = DisplayContext(id: 1,
                                     screen: nil,
                                     frame: CGRect(origin: .zero, size: size),
                                     scale: 1,
                                     metrics: Metrics(size: size),
                                     isActive: true,
                                     backdrop: backdrop,
                                     strongBackdrop: strong,
                                     rawWallpaper: raw)
        controller.displays = [display]

        var count = 0
        for variant in variants(controller: controller, display: display) {
            variant.configure()
            guard let image = render(controller: controller, display: display, size: size) else {
                print("render failed: \(variant.name)")
                continue
            }
            let url = directory.appendingPathComponent(variant.name + ".png")
            if ImageWriter.write(image, to: url) {
                count += 1
                print("wrote \(url.path) \(image.width)x\(image.height)")
            }
        }
        return count > 0 ? 0 : 1
    }

    private struct Variant {
        var name: String
        var configure: () -> Void
    }

    private static func variants(controller: LaunchpadController, display: DisplayContext) -> [Variant] {
        var list: [Variant] = []

        for index in 0 ..< min(3, controller.pageCount) {
            list.append(Variant(name: String(format: "%02d-page%d", index + 1, index + 1)) {
                controller.page = index
                controller.jiggle = false
                controller.drag = nil
                controller.openFolderID = nil
                controller.selection = nil
                controller.endSearch(clearText: true)
            })
        }

        list.append(Variant(name: "04-jiggle") {
            controller.page = 0
            controller.jiggle = true
            controller.drag = nil
            controller.openFolderID = nil
            controller.selection = controller.currentItems.first?.id
            controller.endSearch(clearText: true)
        })

        list.append(Variant(name: "05-folder") {
            controller.page = 0
            controller.jiggle = false
            controller.drag = nil
            controller.endSearch(clearText: true)
            let folder = controller.layout.pages
                .flatMap { $0 }
                .compactMap(\.folderID)
                .max { lhs, rhs in
                    (controller.layout.folders[lhs]?.apps.count ?? 0) < (controller.layout.folders[rhs]?.apps.count ?? 0)
                }
            controller.openFolderID = folder
        })

        list.append(Variant(name: "06-search") {
            controller.page = 0
            controller.jiggle = false
            controller.drag = nil
            controller.openFolderID = nil
            controller.searchActive = true
            controller.searchText = "微"
            controller.searchCaret = 1
            controller.searchSelection = 0
        })

        list.append(Variant(name: "07-drag") {
            controller.page = 0
            controller.jiggle = true
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            let items = controller.currentItems
            guard items.count > 6 else { return }
            let item = items[3]
            let metrics = display.metrics
            let center = metrics.cellCenter(index: 3)
            let target = metrics.cellCenter(index: 6)
            controller.drag = DragState(item: item,
                                        itemID: item.id,
                                        startPoint: center,
                                        point: CGPoint(x: target.x + 14, y: target.y - 10),
                                        grabOffset: CGSize(width: target.x + 14 - center.x,
                                                           height: target.y - 10 - center.y),
                                        page: 0,
                                        index: 3,
                                        originPage: 0,
                                        originIndex: 3,
                                        sourceFolderID: nil,
                                        startedAt: Date())
        })

        list.append(Variant(name: "08-folder-forming") {
            controller.page = 0
            controller.jiggle = true
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            let items = controller.currentItems
            guard items.count > 4, let target = items[3].appID, let dragged = items[2].appID else { return }
            let metrics = display.metrics
            let center = metrics.cellCenter(index: 3)
            controller.drag = DragState(item: .app(dragged),
                                        itemID: LPItem.app(dragged).id,
                                        startPoint: center,
                                        point: center,
                                        grabOffset: .zero,
                                        page: 0,
                                        index: 3,
                                        originPage: 0,
                                        originIndex: 2,
                                        sourceFolderID: nil,
                                        startedAt: Date(),
                                        pending: PendingFolder(targetItemID: LPItem.app(target).id,
                                                               targetFolderID: nil,
                                                               targetFolderName: nil,
                                                               targetPage: 0,
                                                               targetIndex: 3))
        })

        list.append(Variant(name: "09-pan") {
            controller.page = 0
            controller.jiggle = false
            controller.drag = nil
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            controller.isPanning = true
            controller.swipeOffset = -display.metrics.size.width * 0.38
        })

        list.append(Variant(name: "10-last-page") {
            controller.page = max(0, controller.pageCount - 1)
            controller.jiggle = false
            controller.drag = nil
            controller.openFolderID = nil
            controller.isPanning = false
            controller.swipeOffset = 0
            controller.endSearch(clearText: true)
        })

        list.append(Variant(name: "11-folder-peek") {
            controller.page = 0
            controller.jiggle = true
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            // Drag an app over an existing folder to show the peek.
            var folderIndex: Int?
            var folderID: String?
            for (index, item) in controller.currentItems.enumerated() {
                if let id = item.folderID { folderIndex = index; folderID = id; break }
            }
            guard let target = folderIndex, let id = folderID,
                  let dragged = controller.currentItems.first(where: { $0.appID != nil })?.appID
            else { return }
            let metrics = display.metrics
            let center = metrics.cellCenter(index: target)
            controller.drag = DragState(item: .app(dragged),
                                        itemID: LPItem.app(dragged).id,
                                        startPoint: center,
                                        point: center,
                                        grabOffset: .zero,
                                        page: 0,
                                        index: target,
                                        originPage: 0,
                                        originIndex: 0,
                                        sourceFolderID: nil,
                                        startedAt: Date(),
                                        pending: PendingFolder(targetItemID: LPItem.folder(id).id,
                                                               targetFolderID: id,
                                                               targetFolderName: controller.layout.folders[id]?.name,
                                                               targetPage: 0,
                                                               targetIndex: target))
        })

        // 12–14：多选 / 框选、信息浮层、成组拖拽。
        list.append(Variant(name: "12-multi-select") {
            controller.page = 0
            controller.jiggle = false
            controller.drag = nil
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            let ids = controller.currentItems.prefix(4).map(\.id)
            controller.multiSelection = Set(ids)
            controller.selection = nil
            controller.bandRect = nil
        })

        list.append(Variant(name: "13-selection-band") {
            controller.page = 0
            controller.drag = nil
            controller.openFolderID = nil
            controller.endSearch(clearText: true)
            let metrics = display.metrics
            controller.updateBand(from: CGPoint(x: metrics.gridFrame.minX + 10,
                                                y: metrics.gridFrame.minY + 10),
                                  to: CGPoint(x: metrics.cellFrame(index: 9).maxX - 10,
                                              y: metrics.cellFrame(index: 9).maxY - 10))
        })

        list.append(Variant(name: "14-info-card") {
            controller.page = 0
            controller.drag = nil
            controller.openFolderID = nil
            controller.bandRect = nil
            controller.multiSelection.removeAll()
            controller.endSearch(clearText: true)
            guard let item = controller.currentItems.first(where: { $0.appID != nil }) else { return }
            controller.showInfo(for: item)
        })

        list.append(Variant(name: "15-group-drag") {
            controller.page = 0
            controller.jiggle = true
            controller.openFolderID = nil
            controller.infoCard = nil
            controller.bandRect = nil
            controller.endSearch(clearText: true)
            let items = controller.currentItems
            guard items.count > 5 else { return }
            let metrics = display.metrics
            let centers = [0, 1, 2].map { metrics.cellCenter(index: $0) }
            controller.multiSelection = Set(items.prefix(3).map(\.id))
            let center = centers[0]
            let dropTarget = metrics.cellCenter(index: 4)
            let point = CGPoint(x: dropTarget.x + 40, y: dropTarget.y + 30)
            var state = DragState(item: items[0],
                                  itemID: items[0].id,
                                  startPoint: center,
                                  point: point,
                                  grabOffset: .zero,
                                  page: 0,
                                  index: 0,
                                  originPage: 0,
                                  originIndex: 0,
                                  sourceFolderID: nil,
                                  startedAt: Date())
            state.companionIDs = Array(items.prefix(3).dropFirst().map(\.id))
            controller.drag = state
        })

        return list
    }

    private static func render(controller: LaunchpadController,
                               display: DisplayContext,
                               size: CGSize) -> CGImage? {
        let view = LaunchpadRootView(controller: controller, display: display, animate: false)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.cgImage
    }
}
