import SwiftUI

/// The row of page indicators at the bottom of the screen.
struct PageDotsView: View {
    let count: Int
    let current: Int
    let metrics: Metrics
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: metrics.dotGap) {
            ForEach(0 ..< max(1, count), id: \.self) { index in
                Circle()
                    .fill(index == current ? Theme.dotActive : Theme.dotInactive)
                    .frame(width: metrics.dotSize, height: metrics.dotSize)
                    .contentShape(Rectangle().size(width: metrics.dotSize + 8,
                                                  height: metrics.dotSize + 12))
                    .onTapGesture { onSelect(index) }
            }
        }
        .frame(width: metrics.dotsTotalWidth(count: max(1, count)) + 20, height: 24)
        .position(x: metrics.dotsCenter.x, y: metrics.dotsCenter.y)
        .opacity(count > 1 ? 1 : 0)
    }
}
