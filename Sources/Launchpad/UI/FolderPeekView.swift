import AppKit
import SwiftUI

/// While an icon is dragged over a folder, Launchpad expands that folder and
/// shows what is inside before you drop.
struct FolderPeekView: View {
    let folder: FolderEntry
    let anchor: CGPoint
    let metrics: Metrics
    let catalog: AppCatalog
    @State private var appeared = false

    private var apps: [AppEntry] {
        Array(folder.apps.compactMap { catalog.entry($0) }.prefix(9))
    }

    var body: some View {
        let columns = apps.count <= 4 ? 2 : 3
        let mini = metrics.iconSize * 0.30
        let spacing = metrics.iconSize * 0.10
        let padding = metrics.iconSize * 0.34
        let width = CGFloat(columns) * mini + CGFloat(columns - 1) * spacing + padding * 2
        let height = width + metrics.iconSize * 0.34

        return VStack(spacing: metrics.iconSize * 0.10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: spacing), count: columns),
                      spacing: spacing) {
                ForEach(apps) { entry in
                    if let image = IconStore.shared.icon(for: entry) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: mini, height: mini)
                    }
                }
            }
            Text(folder.name)
                .font(Theme.labelFont(metrics.labelFont * 0.95))
                .foregroundStyle(.white)
                .shadow(color: Theme.labelShadow, radius: 2, y: 1)
                .lineLimit(1)
        }
        .padding(.vertical, metrics.iconSize * 0.16)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(appeared ? 1 : 0.86, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        .position(x: anchor.x, y: max(height / 2 + 20, anchor.y - metrics.cellSize.height * 0.62))
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appeared = true } }
        .allowsHitTesting(false)
    }
}
