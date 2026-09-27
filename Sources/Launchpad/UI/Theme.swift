import SwiftUI

enum Theme {
    static let labelColor = Color.white.opacity(0.96)
    static let labelShadow = Color.black.opacity(0.55)
    static let iconShadow = Color.black.opacity(0.38)
    static let selectionFill = Color.white.opacity(0.16)
    static let selectionStroke = Color.white.opacity(0.28)
    static let badgeFill = Color(white: 0.44)
    static let searchFill = Color.black.opacity(0.22)
    static let searchStroke = Color.white.opacity(0.16)
    static let dotActive = Color.white.opacity(0.95)
    static let dotInactive = Color.white.opacity(0.32)

    static let baseFont = Font.system(size: 13)

    static func labelFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
}

/// The ⊗ badge shown on removable apps while the grid is editable.
struct DeleteBadge: View {
    let action: () -> Void
    var size: CGFloat = 22

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.badgeFill)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
