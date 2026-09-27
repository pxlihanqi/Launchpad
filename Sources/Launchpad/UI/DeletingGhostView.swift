import AppKit
import SwiftUI

/// 删除应用时在原位置播放的"消散"特效：放大一下就缩小、淡出并轻微虚化。
struct DeletingGhostView: View {
    let ghost: LaunchpadController.DeletingGhost
    let metrics: Metrics
    let catalog: AppCatalog
    @State private var progress: CGFloat = 0

    var body: some View {
        Group {
            if let bundleID = ghost.item.appID,
               let entry = catalog.entry(bundleID),
               let image = IconStore.shared.icon(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.2))
            }
        }
        .frame(width: metrics.iconSize, height: metrics.iconSize)
        .shadow(color: Theme.iconShadow, radius: 8, y: 3)
        .scaleEffect(1.0 + (1 - progress) * 0.18 - progress * 0.92)
        .opacity(Double(1 - progress))
        .blur(radius: progress * 2.5)
        .position(x: ghost.center.x, y: ghost.center.y)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeIn(duration: 0.42)) { progress = 1 }
        }
    }
}
