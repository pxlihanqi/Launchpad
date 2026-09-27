import SwiftUI

/// ⌘ 拖背景时拉出来的框选矩形。
struct SelectionBandView: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}
