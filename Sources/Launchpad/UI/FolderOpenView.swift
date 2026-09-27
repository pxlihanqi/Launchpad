import AppKit
import SwiftUI

/// The expanded folder: a frosted panel with its own 7x5 grid.
struct FolderOpenView: View {
    @ObservedObject var controller: LaunchpadController
    let folder: FolderEntry
    let display: DisplayContext

    private var metrics: Metrics { display.metrics }
    @State private var appeared = false

    var body: some View {
        let panel = metrics.folderPanel(itemCount: folder.apps.count)
        ZStack(alignment: .topLeading) {
            panelBackground(panel: panel)
            nameView(panel: panel)

            ForEach(Array(folder.apps.enumerated()), id: \.element) { index, bundleID in
                folderCell(bundleID: bundleID, index: index, panel: panel)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: appeared)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private func panelBackground(panel: FolderPanelLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        ZStack {
            // 系统模糊模式下直接用系统材质做玻璃底（免权限）；
            // 壁纸模式下则从壁纸位图里裁一块出来，保持"玻璃窗外就是壁纸"的观感。
            if Prefs.backdropStyle == .blur {
                VisualEffectBackdrop(material: .hudWindow, isEmphasized: true)
                    .frame(width: panel.frame.width, height: panel.frame.height)
            } else if let backdrop = controller.backdropImage(for: display),
               let crop = ImageEffects.cropBackdrop(backdrop,
                                                   displayRect: panel.frame,
                                                   displaySize: metrics.size) {
                Image(decorative: crop, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: panel.frame.width, height: panel.frame.height)
            } else {
                shape.fill(Color.black.opacity(0.35))
            }
            shape.fill(Color.black.opacity(0.14))
            shape.fill(Color.white.opacity(0.12))
            shape.stroke(Color.white.opacity(0.20), lineWidth: 0.8)
        }
        .frame(width: panel.frame.width, height: panel.frame.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .position(x: panel.frame.midX, y: panel.frame.midY)
        .onTapGesture { }
    }

    @ViewBuilder
    private func nameView(panel: FolderPanelLayout) -> some View {
        Group {
            if controller.folderNameEditing {
                IMETextField(text: Binding(get: { controller.folderNameDraft },
                                           set: { controller.folderNameDraft = $0 }),
                             placeholder: "",
                             fontSize: nameFont,
                             alignment: .center,
                             isFocused: true,
                             role: .folderName,
                             onCommit: { controller.commitFolderName() },
                             onCancel: { controller.folderNameEditing = false })
                    .frame(width: max(120, panel.nameFrame.width - 60), height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .frame(height: 34)
            } else {
                Text(folder.name)
                    .font(.system(size: nameFont, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .onTapGesture { controller.beginRenamingFolder() }
            }
        }
        .frame(width: panel.nameFrame.width, height: panel.nameFrame.height)
        .position(x: panel.nameFrame.midX, y: panel.nameFrame.midY)
    }

    private var nameFont: CGFloat { max(20, metrics.iconSize * 0.185) }

    @ViewBuilder
    private func folderCell(bundleID: String, index: Int, panel: FolderPanelLayout) -> some View {
        let center = panel.cellCenter(index: index)
        let item = LPItem.app(bundleID)
        let isInHand = controller.drag?.itemID == item.id && controller.drag?.pending == nil
        let labelHeight = ceil(metrics.labelFont * 1.3)

        ZStack {
            if let entry = controller.catalog.entry(bundleID), let image = IconStore.shared.icon(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: panel.iconSize, height: panel.iconSize)
                    .shadow(color: Theme.iconShadow, radius: 5, y: 2)
            }
        }
        .frame(width: panel.iconSize, height: panel.iconSize + 5 + labelHeight, alignment: .top)
        .overlay(alignment: .topLeading) {
            if !isInHand, controller.showsDeleteBadge(for: item) {
                DeleteBadge { controller.requestDelete(bundleID) }
                    .offset(x: panel.iconSize * 0.14 - 11, y: panel.iconSize * 0.14 - 11)
            }
        }
        .overlay(alignment: .bottom) {
            Text(controller.name(of: bundleID))
                .font(Theme.labelFont(metrics.labelFont * 0.95))
                .foregroundStyle(Theme.labelColor)
                .shadow(color: Theme.labelShadow, radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: panel.itemLabelWidth)
        }
        .jiggling(controller.wobbles(item) && !isInHand, seed: Double(index) * 0.137)
        .opacity(isInHand ? 0.05 : 1)
        .frame(width: panel.itemInteractiveWidth, height: panel.itemInteractiveHeight)
        .contentShape(Rectangle())
        .gesture(tileDragGesture(controller: controller,
                                 item: item,
                                 center: center,
                                 sourceFolder: folder.id,
                                 onClick: { controller.launch(bundleID) }))
        .onTapGesture { controller.launch(bundleID) }
        .contextMenu {
            Button("打开") { controller.launch(bundleID) }
            Button("在访达中显示") { controller.revealInFinder(bundleID) }
            if controller.canDelete(bundleID) {
                Button("移到废纸篓") { controller.requestDelete(bundleID) }
            }
        }
        .position(x: center.x, y: center.y)
    }
}
