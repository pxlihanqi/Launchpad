import AppKit
import SwiftUI

/// A folder rendered the way Launchpad renders it: a frosted rounded square
/// containing up to nine miniature app icons.
struct FolderIconView: View {
    let appIDs: [String]
    let size: CGFloat
    let glass: CGImage?
    let catalog: AppCatalog
    let iconStore: IconStore
    var hollow: Bool = false
    var partners: [String] = []

    private var entries: [AppEntry] {
        appIDs.compactMap { catalog.entry($0) }
    }

    private var displayed: [AppEntry] {
        if !partners.isEmpty {
            return partners.compactMap { catalog.entry($0) }
        }
        return Array(entries.prefix(9))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.285, style: .continuous)
        ZStack {
            if let glass {
                Image(decorative: glass, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                shape.fill(Color.white.opacity(0.16))
            }

            shape.fill(Color.black.opacity(0.16))
            shape.fill(Color.white.opacity(hollow ? 0.05 : 0.10))
            shape.stroke(Color.white.opacity(0.22), lineWidth: max(0.6, size * 0.006))

            miniGrid
                .padding(size * 0.135)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var miniGrid: some View {
        // Launchpad shows up to four apps on a 2x2 grid and nine on a 3x3 grid.
        let columns = displayed.count <= 4 ? 2 : 3
        let padding = size * (columns == 2 ? 0.215 : 0.135)
        let spacing = size * 0.045
        let mini = (size - padding * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)

        // Rows are centred: a folder holding a single app shows it in the
        // middle rather than in a corner.
        var rows: [[Int]] = []
        var index = 0
        let total = max(1, displayed.count)
        while index < total {
            let row = Array(index ..< min(index + columns, total))
            rows.append(row)
            index += columns
        }

        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { slot in
                        if displayed.indices.contains(slot) {
                            iconImage(for: displayed[slot])
                                .frame(width: mini, height: mini)
                        } else {
                            Color.clear.frame(width: mini, height: mini)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func iconImage(for entry: AppEntry) -> some View {
        if let image = iconStore.icon(for: entry) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.25))
        }
    }
}
