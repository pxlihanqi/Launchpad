import Combine
import CoreGraphics

/// 只放"画面正在动"相关的那几个状态。
///
/// 为什么单独抽出来：图标格子观察的是 `LaunchpadController`，而 SwiftUI 里
/// `@ObservedObject` 的任何一个 `@Published` 变化都会让**所有**格子重新求值。
/// 翻页位移（`swipeOffset`）每帧都在变，如果放在 controller 上，滑动时每一帧都要
/// 重新算 100 多个图标的布局、阴影和文字 —— 这就是滑动卡的根源。
///
/// 位移其实只影响"整页的偏移量"，因此只有根视图需要观察它；格子完全不用管，
/// 它们的输入在滑动期间没有变化，SwiftUI 就会跳过它们。
@MainActor
final class MotionState: ObservableObject {
    static let shared = MotionState()

    /// 当前页。
    @Published var page = 0
    /// 跟手位移（正数表示往右拖出上一页）。
    @Published var swipeOffset: CGFloat = 0
    /// 正在按住背景拖动。
    @Published var isPanning = false
    /// 刚刚打开（只有这段时间里的图标才播入场动画）。
    @Published var isOpening = false
    /// 正在播放关闭淡出。
    @Published var isClosing = false
    /// 正在翻页动画里必须一起绘制的页（起点…终点）。
    @Published var flippingPages: [Int] = []
    /// 静止时提前建好的相邻页。
    @Published var prefetchedPages: [Int] = []

    private init() {}
}
