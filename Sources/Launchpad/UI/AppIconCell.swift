import AppKit
import SwiftUI

/// One tile of the grid: app icon or folder, with label, wiggle, delete badge
/// and drag behaviour.
struct AppIconCell: View {
    @ObservedObject var controller: LaunchpadController
    let item: LPItem
    let index: Int
    let display: DisplayContext
    let sourceFolder: String?
    /// Search results cannot be dragged or jiggled, they are launch targets.
    var draggable: Bool = true

    private var metrics: Metrics { display.metrics }
    @State private var appeared = false
    private var iconSize: CGFloat { metrics.iconSize }
    private var labelHeight: CGFloat { ceil(metrics.labelFont * 1.3) }
    private var contentHeight: CGFloat { iconSize + 5 + labelHeight }

    private var isInHand: Bool {
        guard let drag = controller.drag else { return false }
        return drag.itemID == item.id && drag.pending == nil
    }

    /// The folder currently forming over this tile (if any).
    private var formingPartners: [String]? {
        guard let drag = controller.drag, let pending = drag.pending else { return nil }
        guard pending.targetIndex == index, controller.page == pending.targetPage else { return nil }
        if pending.targetFolderID != nil { return nil }
        guard let dragged = drag.item.appID, let target = item.appID else { return nil }
        return [target, dragged]
    }

    private var showDeleteBadge: Bool {
        draggable && controller.showsDeleteBadge(for: item)
    }

    /// 键盘游标或 ⌘ 多选/框选都算选中。
    private var isSelected: Bool { controller.isSelected(item) }

    /// 打开启动台时播放一次入场动画；切页等重建情况下直接显示，避免闪烁。
    private var isPresent: Bool { appeared || !controller.isOpening }

    /// 正在启动这个应用：图标放大并淡出。
    private var isLaunching: Bool { controller.launchAnimation == item.id }

    /// Highlighted while an icon is dragged over this folder.
    private var isDropTarget: Bool {
        guard let folderID = item.folderID else { return false }
        return controller.drag?.hoveredFolderID == folderID
    }

    /// 指针停住、准备与这个图标合成文件夹时高亮。
    private var isFolderCandidate: Bool {
        controller.drag?.folderCandidateID == item.id
    }

    var body: some View {
        let center = metrics.cellCenter(index: index)
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.selectionFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.selectionStroke, lineWidth: 1)
                    )
                    .frame(width: iconSize + 26, height: iconSize + 26)
                    .offset(y: -(labelHeight + 5) / 2 - 2)
            }

            VStack(spacing: 5) {
                ZStack {
                    iconView
                }
                .frame(width: iconSize, height: iconSize)
                .shadow(color: Theme.iconShadow, radius: 6, x: 0, y: 3)
                .scaleEffect(isDropTarget ? 1.14 : 1)
                .scaleEffect(isFolderCandidate ? 1.08 : 1)
                .shadow(color: .white.opacity(isDropTarget || isFolderCandidate ? 0.5 : 0), radius: 14)

                Text(label)
                    .font(Theme.labelFont(metrics.labelFont))
                    .foregroundStyle(Theme.labelColor)
                    .shadow(color: Theme.labelShadow, radius: 2, x: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: metrics.itemLabelWidth, height: labelHeight)
            }
            .jiggling(controller.wobbles(item) && !isInHand, seed: seed)
            .opacity(isLaunching ? 0 : (isInHand ? 0 : (isPresent ? 1 : 0)))
            .scaleEffect(isLaunching ? 1.5 : (isPresent ? 1 : 0.9))
            .animation(.easeOut(duration: 0.16), value: isLaunching)
            .animation(.spring(response: 0.34, dampingFraction: 0.82)
                .delay(min(Double(index) * 0.008, 0.12)), value: appeared)
            .onAppear { appeared = true }

            if showDeleteBadge {
                deleteBadge
                    .offset(x: -iconSize / 2 + iconSize * 0.14,
                            y: -contentHeight / 2 + iconSize * 0.14)
            }
        }
        // Only the icon + caption is interactive: dragging the gaps around it
        // falls through to the background and pans between pages.
        .frame(width: metrics.itemInteractiveWidth, height: metrics.itemInteractiveHeight)
        .contentShape(Rectangle())
        // The drag gesture never becomes active for a plain click, so the tap
        // has to be handled explicitly. `activate` de-duplicates the two paths.
        .modifier(TileInteraction(controller: controller,
                                  item: item,
                                  center: center,
                                  sourceFolder: sourceFolder,
                                  draggable: draggable,
                                  onClick: handleClick))
        .contextMenu { contextMenu }
        .position(x: center.x, y: center.y)
    }

    private var seed: Double {
        let value = sin(Double(index) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private var label: String {
        controller.itemName(item)
    }

    @ViewBuilder
    private var iconView: some View {
        if let partners = formingPartners {
            FolderIconView(appIDs: partners,
                           size: iconSize,
                           glass: GlassCache.shared.glass(raw: display.rawWallpaper,
                                                          displaySize: metrics.size,
                                                          rect: metrics.cellFrame(index: index)),
                           catalog: controller.catalog,
                           iconStore: IconStore.shared,
                           partners: partners)
        } else {
            switch item {
            case .app(let bundleID):
                if let entry = controller.catalog.entry(bundleID), let image = IconStore.shared.icon(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                }
            case .folder(let folderID):
                FolderIconView(appIDs: controller.layout.folders[folderID]?.apps ?? [],
                               size: iconSize,
                               glass: GlassCache.shared.glass(raw: display.rawWallpaper,
                                                              displaySize: metrics.size,
                                                              rect: metrics.cellFrame(index: index)),
                               catalog: controller.catalog,
                               iconStore: IconStore.shared)
            }
        }
    }

    private var deleteBadge: some View {
        DeleteBadge(size: 22) {
            if let bundleID = item.appID { controller.requestDelete(bundleID) }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        // 多选状态下，右键任意一个选中项都是"对整组操作"。
        if controller.multiSelection.count > 1, controller.multiSelection.contains(item.id) {
            batchContextMenu
        } else {
            singleContextMenu
        }
    }

    @ViewBuilder
    private var batchContextMenu: some View {
        let count = controller.multiSelection.count
        Text("已选中 \(count) 个项目")
        Divider()
        Button("新建文件夹") { controller.createFolderFromSelection() }
        Button("从启动台隐藏所选 \(count) 个") { controller.hideSelected() }
        Button("移到废纸篓（\(count) 个）…") { controller.requestDeleteSelected() }
        Divider()
        Button("取消选择") { controller.clearMultiSelection() }
    }

    @ViewBuilder
    private var singleContextMenu: some View {
        switch item {
        case .app(let bundleID):
            Button("打开") { controller.launch(bundleID) }
            Button("在访达中显示") { controller.revealInFinder(bundleID) }
            if controller.canDelete(bundleID) {
                Button("移到废纸篓") { controller.requestDelete(bundleID) }
            }
            Divider()
            Button("显示应用信息（⌥ 点击）") { controller.showInfo(for: item) }
            Button("从启动台隐藏") { controller.hideFromLaunchpad(bundleID) }
        case .folder(let folderID):
            Button("打开") { controller.activate(item) }
            Button("重新命名") {
                controller.openFolderID = folderID
                controller.beginRenamingFolder()
            }
            Divider()
            Button("显示文件夹信息（⌥ 点击）") { controller.showInfo(for: item) }
            Button("在启动台中散开") { controller.dissolveFolder(folderID) }
        }
    }

    private func handleClick() {
        controller.clickItem(item)
    }
}

/// 让 SwiftUI 在父视图重画时能跳过没变化的格子。
///
/// 滑动时根视图每帧都要重画（位移在变），如果格子不可比较，SwiftUI 就只能
/// 重新求值每一个格子的 body —— 一页 35 个、两页 70 个，这就是滑动每一帧的主要开销。
/// 格子只依赖这几个稳定的输入（controller 是同一个对象、图标、序号、几何），
/// 位移变化完全不影响它们，所以可以直接跳过。
extension AppIconCell: Equatable {
    static func == (lhs: AppIconCell, rhs: AppIconCell) -> Bool {
        lhs.controller === rhs.controller
            && lhs.item == rhs.item
            && lhs.index == rhs.index
            && lhs.draggable == rhs.draggable
            && lhs.sourceFolder == rhs.sourceFolder
            && lhs.display.id == rhs.display.id
            && lhs.display.metrics == rhs.display.metrics
    }
}
