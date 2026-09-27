import AppKit
import SwiftUI

/// The icon that follows the pointer while dragging.
struct DragProxyView: View {
    @ObservedObject var controller: LaunchpadController
    let display: DisplayContext

    var body: some View {
        if let drag = controller.drag, drag.pending == nil, display.isActive {
            let metrics = display.metrics
            let center = drag.proxyCenter
            let size = metrics.iconSize

            ZStack {
                // 成组拖拽：后面错开两张"影子"，再加一个数量角标，
                // 一眼能看出拿走的是整组而不是一个。
                if drag.isGroupDrag {
                    content(for: drag)
                        .frame(width: size, height: size)
                        .opacity(0.55)
                        .offset(x: 14, y: -10)
                    content(for: drag)
                        .frame(width: size, height: size)
                        .opacity(0.75)
                        .offset(x: 7, y: -5)
                }
                content(for: drag)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 10)
                    .scaleEffect(1.1)
                    .overlay(alignment: .topTrailing) {
                        if drag.isGroupDrag {
                            Text("\(drag.companionIDs.count + 1)")
                                .font(.system(size: max(11, size * 0.16), weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(x: size * 0.28, y: -size * 0.18)
                        }
                    }
            }
            .position(x: center.x, y: center.y)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(for drag: DragState) -> some View {
        switch drag.item {
        case .app(let bundleID):
            if let entry = controller.catalog.entry(bundleID), let image = IconStore.shared.icon(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        case .folder(let folderID):
            FolderIconView(appIDs: controller.layout.folders[folderID]?.apps ?? [],
                           size: display.metrics.iconSize,
                           glass: GlassCache.shared.glass(raw: display.rawWallpaper,
                                                          displaySize: display.metrics.size,
                                                          rect: display.metrics.cellFrame(index: 0)),
                           catalog: controller.catalog,
                           iconStore: IconStore.shared)
        }
    }
}
