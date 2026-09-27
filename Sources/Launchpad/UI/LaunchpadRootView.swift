import AppKit
import SwiftUI

/// The complete overlay for one display.
struct LaunchpadRootView: View {
    @ObservedObject var controller: LaunchpadController
    /// 位移/翻页这类"正在动"的状态单独观察：图标格子不观察它，
    /// 于是滑动时不会被每帧拖着重算（这是滑动卡顿的根源）。
    @ObservedObject private var motion = MotionState.shared
    let display: DisplayContext
    var animate: Bool = true
    @State private var appeared = false

    private var metrics: Metrics { display.metrics }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WallpaperBackdrop(image: backdropImage,
                              size: metrics.size,
                              extraDim: controller.openFolderID != nil,
                              style: Prefs.backdropStyle)

            // Tap target for the empty background.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: metrics.size.width, height: metrics.size.height)
                .gesture(backgroundPanGesture)
                .onTapGesture { controller.clickBackdrop() }

            if display.isActive {
                activeContent
            }

            // ⌘ 拖背景拉出来的框选矩形
            if display.isActive, let band = controller.bandRect {
                SelectionBandView(rect: band)
            }

            // ⌥ 点图标弹出的信息浮层
            if display.isActive, let card = controller.infoCard {
                AppInfoCardView(controller: controller,
                                card: card,
                                metrics: metrics,
                                display: display)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .coordinateSpace(name: "launchpad")
        .opacity(appeared && !controller.isClosing ? 1 : 0)
        .scaleEffect(appeared && !controller.isClosing ? 1 : 0.985)
        .animation(.easeInOut(duration: 0.22), value: controller.isClosing)
        .onAppear {
            guard animate else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    private var backdropImage: CGImage? {
        (controller.openFolderID != nil || controller.isFiltering)
            ? (display.strongBackdrop ?? controller.backdropImage(for: display))
            : controller.backdropImage(for: display)
    }

    @ViewBuilder
    private var activeContent: some View {
        if controller.isFiltering {
            // Search keeps the exact same grid style, it just shows the matches.
            filteredGrid
        } else {
            pageStack
                .opacity(controller.openFolderID == nil ? 1 : 0)
        }

        if controller.openFolderID == nil, !controller.isFiltering {
            PageDotsView(count: controller.pageCount,
                         current: controller.page,
                         metrics: metrics,
                         onSelect: { controller.goToPage($0) })
        }

        SearchFieldView(controller: controller, metrics: metrics)
            .opacity(controller.openFolderID == nil ? 1 : 0)

        if let folder = controller.openFolder {
            FolderOpenView(controller: controller,
                           folder: folder,
                           display: display)
        }

        DragProxyView(controller: controller, display: display)

        // 删除特效（只在当前屏幕、且图标在网格上时显示）
        if display.isActive, let ghost = controller.deletingGhost {
            DeletingGhostView(ghost: ghost, metrics: metrics, catalog: controller.catalog)
        }

        // Peek inside a folder while dragging an icon over it.
        if let drag = controller.drag,
           let folderID = drag.hoveredFolderID,
           let folder = controller.layout.folders[folderID],
           let index = controller.currentItems.firstIndex(where: { $0.folderID == folderID }) {
            FolderPeekView(folder: folder,
                           anchor: metrics.cellCenter(index: index),
                           metrics: metrics,
                           catalog: controller.catalog)
        }
    }

    /// The current page with its neighbours beside it, so dragging the
    /// background slides whole pages the way the original Launchpad does.
    ///
    /// 只建"这一帧真的可能出现在屏幕上"的页：静止时只有当前页，
    /// 手指/鼠标真的在滑动时才补上左右相邻页（见 `PageRenderPolicy`）。
    private var pageStack: some View {
        let width = metrics.size.width
        let pages = PageRenderPolicy.pages(current: controller.page,
                                           count: controller.pageCount,
                                           sliding: abs(controller.swipeOffset) > 0.5,
                                           offset: controller.swipeOffset,
                                           prefetch: controller.prefetchedPages,
                                           flip: controller.flippingPages)
        return ZStack(alignment: .topLeading) {
            ForEach(pages, id: \.self) { index in
                GridPageView(controller: controller,
                             display: display,
                             items: controller.items(onPage: index),
                             interactive: index == controller.page
                                 && !controller.isPanning
                                 && controller.flippingPages.isEmpty)
                    .offset(x: CGFloat(index - controller.page) * width + controller.swipeOffset)
            }
        }
        .frame(width: width, height: metrics.size.height, alignment: .topLeading)
        .clipped()
    }

    private var filteredGrid: some View {
        let capacity = max(1, metrics.capacity)
        let results = controller.displayItems
        return ZStack(alignment: .topLeading) {
            GridPageView(controller: controller,
                         display: display,
                         items: Array(results.prefix(capacity)),
                         draggable: false)
            if results.count > capacity {
                Text("还有 \(results.count - capacity) 个匹配项")
                    .font(.system(size: max(12, metrics.labelFont * 0.95)))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .position(x: metrics.size.width / 2, y: metrics.gridFrame.maxY + 30)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
    }

    private var backgroundPanGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("launchpad"))
            .onChanged { value in
                MainActor.assumeIsolated {
                    if !controller.isPanning, !controller.isBanding {
                        controller.beginPan(at: value.startLocation)
                    }
                    controller.updatePan(translation: value.translation.width,
                                         point: value.location)
                }
            }
            .onEnded { value in
                MainActor.assumeIsolated {
                    controller.endPan(predicted: value.predictedEndTranslation.width)
                }
            }
    }
}
