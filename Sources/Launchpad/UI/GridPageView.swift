import SwiftUI

/// All tiles of the current page.
struct GridPageView: View, Equatable {
    @ObservedObject var controller: LaunchpadController
    let display: DisplayContext
    /// Items to draw: a page, or the filtered search results.
    let items: [LPItem]
    /// Neighbouring pages are drawn during a pan but never receive clicks.
    var interactive: Bool = true
    /// Search results are for launching, not rearranging.
    var draggable: Bool = true

    var body: some View {
        let metrics = display.metrics
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AppIconCell(controller: controller,
                            item: item,
                            index: index,
                            display: display,
                            sourceFolder: nil,
                            draggable: draggable)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .allowsHitTesting(interactive)
    }

    /// 只比较稳定输入：位移/翻页不影响这一页的内容，父视图重画时可以整页跳过。
    static func == (lhs: GridPageView, rhs: GridPageView) -> Bool {
        lhs.controller === rhs.controller
            && lhs.items == rhs.items
            && lhs.interactive == rhs.interactive
            && lhs.draggable == rhs.draggable
            && lhs.display.id == rhs.display.id
            && lhs.display.metrics == rhs.display.metrics
    }
}
