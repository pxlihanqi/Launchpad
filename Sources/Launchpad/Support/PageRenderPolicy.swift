import Foundation

/// 决定每一帧要构建哪些页。
///
/// 静止时只建当前页：一页最多 35 个图标，每个图标都带阴影、抖动动画和手势，
/// 把左右相邻页一起建出来等于白做两三倍的工作。只有页面**真的在滑动**
/// （拖动背景、双指滑动、回弹动画）时，相邻页才可能出现屏幕上，那时才需要建。
///
/// 滑动时还按**方向**取舍：偏移为负（内容整体左移）时只有右侧的下一页会进入
/// 视野，左侧那一页离屏幕至少一整屏宽，建了也看不见。反过来同理。
///
/// 这一条不是可有可无的优化：换页那一瞬间 `page` 会跳一格、`swipeOffset` 同时
/// 补上一整屏宽，如果此时按"左右都建"来算，就会在第一帧现场构建 35 个图标视图
/// （实测 73ms vs 32ms），动画第一帧直接卡一下 —— 手感上就是"滑得有点奇怪"。
///
/// 静止时反过来要**预取**两侧：人从静止到真正开始拖动至少有几百毫秒，
/// 趁这段时间把相邻页建好，起步就不会有一次性开销。
///
/// 抽成独立函数是为了能在自检里直接断言这条规则，而不是靠肉眼看。
enum PageRenderPolicy {
    static func pages(current: Int,
                      count: Int,
                      sliding: Bool,
                      offset: CGFloat = 0,
                      prefetch: [Int] = [],
                      flip: [Int] = []) -> [Int] {
        guard count > 0 else { return [] }
        let index = min(max(0, current), count - 1)
        // `flip` 是"正在翻页动画里必须一起画的页"（起点页到终点页），
        // 跨页跳转时中间那些页会快速掠过屏幕，少了它们就会看到背景闪一下。
        var result = [index]
        result.append(contentsOf: flip.filter { $0 >= 0 && $0 < count })
        if sliding {
            // 滑动时把预取好的相邻页**留着**：它们已经构建过，一旦移出视图树就会被
            // 销毁，停稳后又要花一次构建（实测每次 ≈30ms 的主线程停顿）。
            // 方向那一页额外补上（反方向那页离屏至少一整屏宽，属于已知的浪费）。
            result.append(contentsOf: prefetch.filter { $0 >= 0 && $0 < count })
            if offset < 0, index + 1 < count { result.append(index + 1) }
            if offset > 0, index - 1 >= 0 { result.append(index - 1) }
        } else {
            // 静止时把预取好的相邻页留着，起步拖动才不用现建。
            result.append(contentsOf: prefetch.filter { $0 >= 0 && $0 < count })
        }
        return Array(Set(result)).sorted()
    }
}
