import SwiftUI

/// Shared drag behaviour for grid tiles and folder tiles.
/// A short press is a click, anything longer becomes a Launchpad style drag
/// with live reordering.
func tileDragGesture(controller: LaunchpadController,
                     item: LPItem,
                     center: CGPoint,
                     sourceFolder: String?,
                     onClick: @escaping () -> Void) -> some Gesture {
    // A short press is a click, anything longer becomes a Launchpad style drag
    // with live reordering. The threshold is deliberately generous so a normal
    // trackpad click never turns into a drag (and never latches jiggle mode).
    DragGesture(minimumDistance: 6, coordinateSpace: .named("launchpad"))
        .onChanged { value in
            // SwiftUI delivers gesture callbacks on the main thread.
            MainActor.assumeIsolated {
                if controller.drag != nil {
                    controller.updateDrag(point: value.location)
                } else {
                    let offset = CGSize(width: value.startLocation.x - center.x,
                                        height: value.startLocation.y - center.y)
                    controller.beginDrag(item: item,
                                         point: value.location,
                                         grabOffset: offset,
                                         fromFolder: sourceFolder)
                }
            }
        }
        .onEnded { value in
            let travelled = hypot(value.translation.width, value.translation.height)
            MainActor.assumeIsolated {
                if controller.drag != nil {
                    controller.endDrag()
                }
                // Generous click window: a trackpad press usually wobbles a few
                // points, and that must still count as a click.
                if travelled < 16 {
                    onClick()
                }
            }
        }
}

/// Attaches click and (optionally) drag handling to a tile. Search results only
/// get the click half.
struct TileInteraction: ViewModifier {
    let controller: LaunchpadController
    let item: LPItem
    let center: CGPoint
    let sourceFolder: String?
    var draggable: Bool = true
    let onClick: () -> Void

    func body(content: Content) -> some View {
        if draggable {
            content
                .gesture(tileDragGesture(controller: controller,
                                         item: item,
                                         center: center,
                                         sourceFolder: sourceFolder,
                                         onClick: onClick))
                .onTapGesture(perform: onClick)
        } else {
            content.onTapGesture(perform: onClick)
        }
    }
}

/// Launchpad's wiggle animation (used while the grid is editable).
struct JiggleModifier: ViewModifier {
    let active: Bool
    let seed: Double
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? angle : 0))
            .onAppear { if active { start() } }
            .onChange(of: active) { _, isActive in
                if isActive {
                    start()
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { angle = 0 }
                }
            }
    }

    private func start() {
        let duration = 0.125 + seed * 0.05
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            angle = seed > 0.5 ? 1.7 : -1.7
        }
    }
}

extension View {
    func jiggling(_ active: Bool, seed: Double) -> some View {
        modifier(JiggleModifier(active: active, seed: seed))
    }
}
