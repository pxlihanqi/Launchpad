import Combine
import AppKit
import SwiftUI

/// The pill-shaped search field at the top of the screen.
struct SearchFieldView: View {
    @ObservedObject var controller: LaunchpadController
    let metrics: Metrics
    /// Field takes focus while the grid is interactable, so typing anywhere
    /// starts a search — with the input method fully working.
    var isFocused: Bool {
        controller.isOpen && controller.openFolderID == nil && !controller.folderNameEditing
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isFocused ? 0.85 : 0.55))

            IMETextField(text: Binding(get: { controller.searchText },
                                       set: { controller.userTypedSearch($0) }),
                         placeholder: "搜索",
                         fontSize: 13,
                         isFocused: isFocused,
                         role: .search,
                         onCommit: { controller.commitSearch() },
                         onCancel: { controller.escape() })
                .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .frame(width: metrics.searchSize.width, height: metrics.searchSize.height)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.searchFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Theme.searchStroke, lineWidth: 0.8)
        )
        .position(x: metrics.searchCenter.x, y: metrics.searchCenter.y)
        .onTapGesture { FieldFocus.focusSearch() }
    }
}
