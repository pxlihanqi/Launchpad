import AppKit
import Combine
import Foundation
import SwiftUI

struct SearchHit: Identifiable, Equatable {
    var id: String
    var item: LPItem
    var name: String
    var subtitle: String?
    var isFolder: Bool
}

/// The single source of truth for the Launchpad overlay.
@MainActor
final class LaunchpadController: ObservableObject {
    static let shared = LaunchpadController()

    /// `--selftest` sets this so exercising the click path never actually
    /// launches an application.
    static var suppressRealLaunch = false

    // MARK: - Published state

    @Published private(set) var layout = Layout()
    /// 与"画面在动"有关的状态统一放在 MotionState 里（见该文件说明）：
    /// 滑动时只有根视图需要跟着重画，图标格子不必每帧重算。
    let motion = MotionState.shared
    var page: Int {
        get { motion.page }
        set { motion.page = newValue }
    }
    @Published var jiggle = false
    @Published var openFolderID: String?
    @Published var folderNameEditing = false
    @Published var folderNameDraft = ""
    @Published var folderNameCaret = 0
    @Published var searchText = ""
    @Published var searchActive = false
    @Published var searchSelection = 0
    @Published var searchCaret = 0
    @Published var drag: DragState?
    @Published var selection: String?
    /// ⌘ 点选/框选选中的图标（多选，只针对当前页）。
    @Published var multiSelection: Set<String> = []
    /// 正在拖出的框选矩形（左上为原点的 root 坐标）。
    @Published var bandRect: CGRect?
    /// ⌥ 点图标弹出的信息浮层。
    @Published var infoCard: InfoCardState?
    @Published var displays: [DisplayContext] = []
    @Published var isOpen = false
    @Published var launchAnimation: String?
    @Published var lastError: String?
    /// Horizontal offset applied to the grid while the user swipes between pages.
    var swipeOffset: CGFloat {
        get { motion.swipeOffset }
        set { motion.swipeOffset = newValue }
    }
    /// 正在播放关闭动画：此时不再接受键盘/鼠标输入，淡出结束后才真正隐藏窗口。
    var isClosing: Bool {
        get { motion.isClosing }
        set { motion.isClosing = newValue }
    }
    /// 刚刚打开：只有这段时间里的图标格子才播放入场动画。
    /// （否则每次切页、重建格子都会重放一遍，看起来像闪一下。）
    var isOpening: Bool {
        get { motion.isOpening }
        set { motion.isOpening = newValue }
    }
    /// 静止时提前建好的相邻页（见 PageRenderPolicy：起步才不会有构建卡顿）。
    var prefetchedPages: [Int] {
        get { motion.prefetchedPages }
        set { motion.prefetchedPages = newValue }
    }
    /// 正在翻页动画里必须一起绘制的页（起点…终点）。
    var flippingPages: [Int] {
        get { motion.flippingPages }
        set { motion.flippingPages = newValue }
    }
    /// 正在"消散"的图标（删除时播放特效）。
    @Published var deletingGhost: DeletingGhost?

    struct DeletingGhost: Identifiable, Equatable {
        var id: String { item.id }
        var item: LPItem
        var center: CGPoint
    }
    /// True while a modal confirmation is on screen: keyboard/mouse handlers
    /// get out of the way so the alert owns the input.
    var isAlertPresented = false
    /// Test seam: when set, deleting asks this instead of showing the alert.
    var confirmationHandler: ((String) -> Bool)?
    /// 批量删除的测试钩子（一次拿到所有名字）。
    var batchConfirmationHandler: (([String]) -> Bool)?
    /// Test seam: the drag ticker normally ends a drag when the mouse button is
    /// up, which never happens in a scripted test.
    var suppressDragAutoEnd = false
    /// Test seam: overrides the live pointer position used by the drag ticker.
    var pointerLocationOverride: CGPoint?
    /// Test seam: normally terminates the app.
    var terminateHandler: () -> Void = { NSApp.terminate(nil) }
    /// 触控板捏合量的累积值（见 handlePinch）。
    private var pinchAccumulator: CGFloat = 0
    /// Test seam: exercises the folder capacity rule.
    func addToFolderForTesting(_ folderID: String, app bundleID: String) {
        layout.addToFolder(folderID, app: bundleID)
    }
    /// True while the user is dragging the background to move between pages.
    var isPanning: Bool {
        get { motion.isPanning }
        set { motion.isPanning = newValue }
    }
    /// 框选起点（按住 ⌘ 拖背景时）。
    private var bandAnchor: CGPoint?
    var isBanding: Bool { bandAnchor != nil }
    private var prefetchWork: DispatchWorkItem?
    private var flipWork: DispatchWorkItem?

    let catalog = AppCatalog.shared

    private var saveWorkItem: DispatchWorkItem?
    private var dragTicker: Timer?
    private var swipeAccumulator: CGFloat = 0
    private var swipeActive = false
    private var swipeResetWork: DispatchWorkItem?
    /// 跟手位移的最近采样：松手时用它估算手指速度，接到动画上。
    /// 不接速度的话，松手瞬间动画会从 0 速度重新起步，手感就是"顿一下再窜过去"。
    private var panSamples: [(time: Date, value: CGFloat)] = []
    private var lastActivationID: String?
    private var lastActivationTime = Date.distantPast
    /// Offset the grid was given at the moment a page flip was committed; used
    /// by the self test to prove the swap is seamless.
    private(set) var lastSettleOffset: CGFloat = 0

    private init() {}

    // MARK: - Derived state

    var activeDisplay: DisplayContext? {
        displays.first(where: { $0.isActive }) ?? displays.first
    }

    /// Background to draw for a display: the live one when available.
    func backdropImage(for display: DisplayContext) -> CGImage? {
        display.backdrop
    }

    var metrics: Metrics {
        activeDisplay?.metrics ?? Metrics(size: CGSize(width: 1512, height: 982))
    }

    var pageCount: Int { max(1, layout.pages.count) }

    var currentItems: [LPItem] {
        layout.pages.indices.contains(page) ? layout.pages[page] : []
    }

    func items(onPage index: Int) -> [LPItem] {
        layout.pages.indices.contains(index) ? layout.pages[index] : []
    }

    /// True only once the user has actually typed something: an empty search
    /// field still shows the normal grid with every app.
    var isFiltering: Bool {
        searchActive && !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search results, best match first, so the top hit is the first tile.
    func filteredItems() -> [LPItem] {
        searchHits().map(\.item)
    }

    /// What the grid draws right now: the current page, or the matches.
    var displayItems: [LPItem] {
        isFiltering ? filteredItems() : currentItems
    }

    var openFolder: FolderEntry? {
        guard let openFolderID else { return nil }
        return layout.folders[openFolderID]
    }

    func name(of bundleID: String) -> String {
        layout.displayName(for: bundleID, catalog: catalog)
    }

    func itemName(_ item: LPItem) -> String {
        switch item {
        case .app(let bundleID): return name(of: bundleID)
        case .folder(let folderID): return layout.folders[folderID]?.name ?? Layout.defaultFolderName
        }
    }

    func canDelete(_ bundleID: String) -> Bool { catalog.entry(bundleID)?.isRemovable ?? false }

    // MARK: - 多选

    /// 键盘游标和高亮都要算上多选集合。
    func isSelected(_ item: LPItem) -> Bool {
        selection == item.id || multiSelection.contains(item.id)
    }

    var hasMultiSelection: Bool { multiSelection.count > 0 }

    /// 当前页里被选中的图标，按网格顺序返回（成组拖拽要保持原顺序）。
    func selectedItems() -> [LPItem] {
        currentItems.filter { multiSelection.contains($0.id) }
    }

    /// ⌘ 点选：加入 / 移出多选，不启动应用。
    func toggleMultiSelection(_ item: LPItem) {
        if multiSelection.contains(item.id) {
            multiSelection.remove(item.id)
        } else {
            multiSelection.insert(item.id)
        }
        selection = nil
    }

    func clearMultiSelection() {
        if !multiSelection.isEmpty { multiSelection.removeAll() }
        bandRect = nil
    }

    func selectAllOnPage() {
        multiSelection = Set(currentItems.map(\.id))
        selection = nil
    }

    /// 框选：把当前页里与矩形相交的图标选进来。
    func updateBand(from anchor: CGPoint, to point: CGPoint) {
        let rect = CGRect(x: min(anchor.x, point.x),
                          y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x),
                          height: abs(point.y - anchor.y))
        bandRect = rect
        let items = currentItems
        var hits = Set<String>()
        for index in items.indices where metrics.itemInteractiveFrame(index: index).intersects(rect) {
            hits.insert(items[index].id)
        }
        multiSelection = hits
    }

    func endBand() {
        bandRect = nil
    }

    /// Whether a tile should show its ⊗ badge: edit (jiggle) mode, a removable
    /// app, and never the icon that is currently held by the pointer.
    /// Launchpad keeps the badges visible while dragging, so this deliberately
    /// does not depend on `drag == nil`.
    func showsDeleteBadge(for item: LPItem) -> Bool {
        guard jiggle, let bundleID = item.appID else { return false }
        if drag?.itemID == item.id { return false }
        return canDelete(bundleID)
    }

    /// Icons wobble exactly when they can be deleted: an icon without a ⊗ badge
    /// stays still instead of shaking for no reason.
    func wobbles(_ item: LPItem) -> Bool {
        showsDeleteBadge(for: item)
    }

    // MARK: - Lifecycle

    func bootstrap() {
        // 先把老版本"截屏桌面"的设置迁到免权限的系统模糊，再读背景配置。
        Prefs.migrateBackdropDefaultsIfNeeded()
        catalog.reload()
        var restored: Layout
        if let stored = LayoutStore.load() {
            restored = stored
        } else {
            restored = LayoutStore.makeInitial(catalog: catalog, rows: 5, columns: 7)
        }
        restored.normalize(catalog: catalog, rows: 5, columns: 7)
        layout = restored
        persistNow()
        IconStore.shared.preload(Array(catalog.apps.values))
    }

    /// Re-scans for new apps (and removed ones) each time Launchpad opens.
    func refreshCatalog() {
        catalog.reload()
        var updated = layout
        updated.normalize(catalog: catalog,
                          rows: activeDisplay?.metrics.rows ?? 5,
                          columns: activeDisplay?.metrics.columns ?? 7)
        if updated != layout {
            layout = updated
            persist()
        }
    }

    /// 用户改了"每行图标数量"：按当前网格容量把所有图标按顺序重新分页
    /// （保持图标/文件夹的相对顺序），否则旧的页会装不下 / 太空。
    func repackForCurrentGrid() {
        guard let metrics = activeDisplay?.metrics else { return }
        let packed = Layout.repack(layout.pages, capacity: metrics.capacity)
        guard packed != layout.pages else { return }
        layout.pages = packed
        persist()
    }

    func prepareForOpen() {
        refreshCatalog()
        page = min(page, pageCount - 1)
        jiggle = false
        openFolderID = nil
        folderNameEditing = false
        endSearch(clearText: true)
        selection = nil
        clearMultiSelection()
        infoCard = nil
        flipWork?.cancel()
        flippingPages = []
        drag = nil
        isOpening = true
        schedulePagePrefetch(after: 0.8)      // 等入场动画放完再预取
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.isOpening = false }
        }
    }

    func close() {
        stopDragTicker()
        drag = nil
        openFolderID = nil
        folderNameEditing = false
        infoCard = nil
        clearMultiSelection()
        flipWork?.cancel()
        flippingPages = []
        jiggle = false
        resetSwipe()
        endSearch(clearText: true)
        persistNow()
    }

    // MARK: - Persistence

    private func persist() {
        saveWorkItem?.cancel()
        let snapshot = layout
        let work = DispatchWorkItem { LayoutStore.save(snapshot) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func persistNow() {
        saveWorkItem?.cancel()
        LayoutStore.save(layout)
    }

    // MARK: - Activation

    func activate(_ item: LPItem) {
        // A click arrives through both the tap gesture and the drag gesture's
        // release handler; only the first one counts.
        if lastActivationID == item.id, Date().timeIntervalSince(lastActivationTime) < 0.6 {
            return
        }
        lastActivationID = item.id
        lastActivationTime = Date()
        switch item {
        case .app(let bundleID): launch(bundleID)
        case .folder(let folderID): openFolderID = folderID
        }
    }

    /// What a plain click on a tile does: apps launch (except while the grid is
    /// editable) and folders open.
    func clickItem(_ item: LPItem) {
        // 同一次点击会从 SwiftUI 手势和 AppKit 兜底两条路进来，只认第一次。
        // （⌘ 点选是"切换"，重复处理会立刻被切回去，所以这里必须去重。）
        if isDuplicateClick(item.id) { return }
        // 改名过程中点别处 = 先确认改名，不要误启动应用
        if folderNameEditing {
            commitFolderName()
            return
        }
        // 信息浮层开着时，点任何图标先收起来（再看新的那个）。
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) {
            showInfo(for: item)
            return
        }
        if infoCard != nil { infoCard = nil }
        if flags.contains(.command) {
            toggleMultiSelection(item)
            return
        }
        if !multiSelection.isEmpty { multiSelection.removeAll() }
        switch item {
        case .app:
            if jiggle { return }
            activate(item)
        case .folder:
            activate(item)
        }
    }

    private var lastClickID: String?
    private var lastClickTime = Date.distantPast

    private func isDuplicateClick(_ id: String) -> Bool {
        if lastClickID == id, Date().timeIntervalSince(lastClickTime) < 0.4 { return true }
        lastClickID = id
        lastClickTime = Date()
        return false
    }

    /// Hit testing used by the AppKit level click fallback. `point` is in the
    /// active display's coordinate space with the origin at the top left.
    func item(atGridPoint point: CGPoint) -> LPItem? {
        guard openFolderID == nil else { return nil }
        let items = displayItems
        for index in items.indices where metrics.itemInteractiveFrame(index: index).contains(point) {
            return items[index]
        }
        return nil
    }

    /// Same, for the open folder panel.
    func app(inFolder folderID: String, atPoint point: CGPoint) -> String? {
        guard let folder = layout.folders[folderID] else { return nil }
        let panel = metrics.folderPanel(itemCount: folder.apps.count)
        for index in folder.apps.indices where panel.itemInteractiveFrame(index: index).contains(point) {
            return folder.apps[index]
        }
        return nil
    }

    // MARK: - Swiping between pages

    /// Two finger horizontal swipes (and wheel tilt) flip pages, the way the
    /// original Launchpad does.
    func handleScroll(deltaX: CGFloat, momentum: Bool = false) {
        guard isOpen, drag == nil, openFolderID == nil, !searchActive else { return }
        // Momentum events would keep pushing after the fingers lifted.
        guard !momentum else { return }
        if !swipeActive {
            swipeActive = true
            swipeAccumulator = 0
            panSamples.removeAll()
        }
        swipeAccumulator += deltaX
        // 页面跟着手指走**满一整屏**（原本只跟到 45%，剩下的靠松手动画一次窜过去，
        // 那一下就是"有点突然"的来源）。
        let limit = metrics.size.width
        swipeOffset = max(-limit, min(limit, swipeAccumulator))
        recordPanSample(swipeOffset)
        scheduleSwipeFinish()
    }

    // MARK: - Dragging the background to move between pages

    /// Launchpad lets you press anywhere on the wallpaper and drag the pages
    /// around; this is the same gesture.
    /// 按住 ⌘ 拖则是**框选**（和 Finder 的橡皮筋选择一样）。
    func beginPan(at point: CGPoint = .zero) {
        guard isOpen, drag == nil, openFolderID == nil, !searchActive else { return }
        if NSEvent.modifierFlags.contains(.command) {
            bandAnchor = point
            bandRect = CGRect(origin: point, size: .zero)
            multiSelection.removeAll()
            return
        }
        // 刚好在翻页动画里就开始拖：先让动画落到终点，否则跟手位移会从半路接上、看着一跳。
        finishFlipIfNeeded()
        isPanning = true
        panSamples.removeAll()
        swipeResetWork?.cancel()
    }

    /// 把还没结束的翻页动画立刻收尾（用于马上要接手指的情况）。
    func finishFlipIfNeeded() {
        guard !flippingPages.isEmpty else { return }
        flipWork?.cancel()
        flipWork = nil
        withAnimation(nil) { swipeOffset = 0 }
        flippingPages = []
        schedulePagePrefetch(after: 0.1)
    }

    /// 提前把这几页图标的文字"烤热"。
    ///
    /// 中文标签的字形是第一次绘制时才栅格化的，一页 30 多个图标凑在一起，
    /// 第一次滑到这一页会多花几十毫秒（实测第一轮最差 68ms，第二轮就回到 38ms）。
    /// 这里在预取的同一时间，用 CoreText 在后台把字形先画一遍 ——
    /// 字形缓存在 CoreText 内部是全局的，主线程之后画同样的字就是直接命中。
    private func warmLabels(onPages pages: [Int]) {
        guard !pages.isEmpty else { return }
        let names = pages.flatMap { items(onPage: $0) }.map { itemName($0) }
        guard !names.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: CGFloat(max(10.5, metrics.labelFont)))
        DispatchQueue.global(qos: .utility).async {
            // 1×1 的位图足够让 CoreText 走完"取字形 → 栅格化"这条路。
            guard let context = CGContext(data: nil, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            for name in names {
                autoreleasepool {
                    let attributed = NSAttributedString(string: name, attributes: [.font: font])
                    let line = CTLineCreateWithAttributedString(attributed)
                    CTLineDraw(line, context)
                }
            }
        }
    }

    func updatePan(translation: CGFloat, point: CGPoint = .zero) {
        if let anchor = bandAnchor {
            updateBand(from: anchor, to: point)
            return
        }
        guard isPanning else { return }
        var value = translation
        // Rubber band past the first and last page.
        if (page == 0 && value > 0) || (page >= pageCount - 1 && value < 0) {
            value *= 0.34
        }
        // 拖动同样可以走满一整屏，和系统一致。
        let limit = metrics.size.width
        swipeOffset = max(-limit, min(limit, value))
        recordPanSample(swipeOffset)
    }

    /// 记录一次跟手位移采样（只留最近 0.12 秒，够算当前速度）。
    private func recordPanSample(_ value: CGFloat) {
        let now = Date()
        panSamples.append((now, value))
        panSamples.removeAll { now.timeIntervalSince($0.time) > 0.12 }
        if panSamples.count > 8 { panSamples.removeFirst(panSamples.count - 8) }
    }

    /// 松手瞬间的手指速度（pt/s），用最近几次采样估算。
    private var panVelocity: CGFloat {
        guard let first = panSamples.first, let last = panSamples.last else { return 0 }
        let interval = last.time.timeIntervalSince(first.time)
        guard interval > 0.012 else { return 0 }
        return (last.value - first.value) / CGFloat(interval)
    }

    func endPan(predicted: CGFloat) {
        if bandAnchor != nil {
            bandAnchor = nil
            endBand()
            return
        }
        guard isPanning else { return }
        isPanning = false
        settle(threshold: max(80, metrics.size.width * 0.12), predicted: predicted)
    }

    private func scheduleSwipeFinish() {
        swipeResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishSwipe() }
        }
        swipeResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func finishSwipe() {
        guard swipeActive else { return }
        swipeActive = false
        swipeAccumulator = 0
        settle(threshold: 90)
    }

    /// Decides whether a pan/swipe ends on the neighbouring page, then springs
    /// the grid back into place.
    private func settle(threshold: CGFloat, predicted: CGFloat = 0) {
        let width = metrics.size.width
        let direction: CGFloat = abs(predicted) > abs(swipeOffset) ? predicted : swipeOffset

        var targetPage = page
        if direction <= -threshold, page < pageCount - 1 {
            targetPage = page + 1
        } else if direction >= threshold, page > 0 {
            targetPage = page - 1
        }

        // Carry the motion over to the new page: the incoming page starts
        // exactly where the neighbouring page already sat on screen, so the
        // swap is invisible and the slide keeps flowing in the drag direction.
        let from = page
        var offset = swipeOffset
        if targetPage != page {
            offset += CGFloat(targetPage - page) * width
            page = targetPage
        }
        swipeOffset = offset
        lastSettleOffset = offset
        selection = nil
        clearMultiSelection()

        if targetPage != from {
            // 关键：`withAnimation { swipeOffset = 0 }` 会把模型值立刻置 0，
            // 渲染规则据此判定"已经不在滑动"，只按预取集合画 —— 而预取这时刚被清掉，
            // 于是**滑出去的那一页当场被移出视图树**，看着就是"上一页突然消失"。
            // 所以这里显式地把两端页钉在渲染集合里，直到动画放完。
            flippingPages = [min(from, targetPage), max(from, targetPage)]
            prefetchedPages = []          // 动画期间只需要这两页，别的先放下
            flipWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flippingPages = []
                    // 动画结束之后再预取，避免在动画中间构建整页（一次 ~30ms 的停顿）。
                    self.schedulePagePrefetch(after: 0.12)
                }
            }
            flipWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
        } else {
            // 没翻页（回弹回原位）：相邻页本来就还在预取集合里，照常预取即可。
            schedulePagePrefetch(after: 0.45)
        }

        // 把松手瞬间的手指速度接到动画上：动画从当前速度继续减速，
        // 而不是从 0 重新加速（那一下就是"顿一下再窜过去"）。
        // 注意 interpolatingSpring 的 initialVelocity 是"剩余距离的每秒比例"，
        // 不是点/秒，所以要按剩余距离归一化；再夹一下，甩太狠也不会冲过头。
        let distance = max(1, abs(offset))
        let initialVelocity = min(max(panVelocity / distance, -3), 3)
        panSamples.removeAll()
        // 刚度更大的阻尼弹簧：落位更快（约 0.25 秒收敛）、几乎没有尾巴，
        // 既贴近 macOS 15 那种"跟着手指减速停住"，动画帧数也更少。
        withAnimation(.interpolatingSpring(stiffness: 240,
                                           damping: 30,
                                           initialVelocity: initialVelocity)) {
            swipeOffset = 0
        }
    }

    private func resetSwipe() {
        swipeResetWork?.cancel()
        swipeResetWork = nil
        swipeActive = false
        swipeAccumulator = 0
        swipeOffset = 0
        isPanning = false
    }

    func launch(_ bundleID: String) {
        guard let entry = catalog.entry(bundleID) else { return }
        launchAnimation = LPItem.app(bundleID).id
        // 记一笔本地启动记录，信息浮层里的"最近打开"会用到（不出本机）。
        UsageStore.shared.record(bundleID: bundleID)
        if Self.suppressRealLaunch { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, self.isOpen else { return }
            self.dismissForLaunch()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { _, error in
                if let error { Log.error("launch failed for \(bundleID): \(error.localizedDescription)") }
            }
        }
    }

    private func dismissForLaunch() {
        OverlayCoordinator.shared.dismiss()
        isOpen = false
        launchAnimation = nil
    }

    func closeAndDismiss() {
        close()
        OverlayCoordinator.shared.dismiss(restoreFocus: true)
        isOpen = false
    }

    /// Quit the helper itself — used by the menu bar item and by ⌘Q/⌘W in the
    /// overlay (the app has no Dock icon, so ⌘Q is the natural shortcut).
    func quitApplication() {
        close()                     // 保存布局、停掉定时器
        OverlayCoordinator.shared.dismiss()
        isOpen = false
        terminateHandler()
    }

    func toggle() {
        if isOpen {
            closeAndDismiss()
        } else {
            OverlayCoordinator.shared.present()
        }
    }

    /// 触控板捏合：`magnification` 为负表示向内捏合。
    /// 已打开时向内捏合 = 关闭（与打开手势互逆）；未打开时向内捏合 = 打开。
    func handlePinch(magnification: CGFloat) {
        // 逐渐衰减，避免缓慢漂移被误判成手势
        pinchAccumulator = pinchAccumulator * 0.6 + magnification
        let threshold: CGFloat = 0.22
        if pinchAccumulator <= -threshold {
            pinchAccumulator = 0
            if isOpen {
                closeAndDismiss()
            } else if Prefs.pinchToOpen {
                OverlayCoordinator.shared.present()
            }
        } else if pinchAccumulator >= threshold {
            pinchAccumulator = 0
        }
    }

    /// Replaces the whole layout (used by the legacy import).
    func replaceLayout(with imported: Layout) {
        var updated = imported
        updated.normalize(catalog: catalog, rows: metrics.rows, columns: metrics.columns)
        layout = updated
        page = 0
        persistNow()
    }

    func resetToAlphabetical() {
        var fresh = Layout.alphabetical(from: catalog, rows: metrics.rows, columns: metrics.columns)
        fresh.normalize(catalog: catalog, rows: metrics.rows, columns: metrics.columns)
        layout = fresh
        page = 0
        persistNow()
    }

    // MARK: - Pages

    func goToPage(_ index: Int) {
        animatePageChange(to: min(max(0, index), pageCount - 1))
    }

    func flipPage(_ delta: Int) {
        animatePageChange(to: page + delta)
    }

    /// 翻到指定页：和系统启动台一样是**整屏平移**，不是瞬间跳过去。
    ///
    /// 做法是先摆出"目标页正停在屏幕外"的那一帧（这一帧和当前画面完全一致，
    /// 所以看不出变化），下一帧再开始动画 —— 这样入场页是**滑进来**的，
    /// 而不是淡入或闪现。
    func animatePageChange(to target: Int) {
        let clamped = min(max(0, target), pageCount - 1)
        guard clamped != page, isOpen else {
            page = clamped
            return
        }
        let width = metrics.size.width
        guard width > 0 else {
            page = clamped
            return
        }
        let delta = clamped - page
        let from = page

        flipWork?.cancel()
        prefetchWork?.cancel()
        prefetchedPages = []
        flippingPages = Array(min(from, clamped) ... max(from, clamped))

        // 起始状态：目标页摆在屏幕外（与当前画面几何完全一致）。
        swipeOffset = CGFloat(delta) * width
        page = clamped
        selection = nil
        clearMultiSelection()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 跨页多的话给一点额外时间，不然 4 屏距离挤在 0.3 秒里会糊成一片。
            // 用 easeOut 而不是弹簧：macOS 15 里点圆点/按快捷键就是一次干净的减速滑动，
            // 没有回弹尾巴，动画帧数也更少。
            let duration = 0.26 + 0.05 * Double(min(3, abs(delta) - 1))
            withAnimation(.easeOut(duration: duration)) {
                self.swipeOffset = 0
            }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.swipeOffset = 0
                    self.flippingPages = []
                    self.schedulePagePrefetch(after: 0.12)
                }
            }
            self.flipWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.12, execute: work)
        }
    }

    /// 立刻切页并滑过去（拖图标到边缘时用：指针还在动，不适合等一帧再开始）。
    /// 两端页在拖动前就已被预取，所以这里是真正的一步滑动，不会闪。
    private func slideToPage(_ target: Int) {
        let clamped = min(max(0, target), pageCount - 1)
        guard clamped != page else { return }
        let from = page
        flippingPages = Array(min(from, clamped) ... max(from, clamped))
        flipWork?.cancel()
        withAnimation(.easeOut(duration: 0.26)) {
            page = clamped
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.swipeOffset = 0
                self.flippingPages = []
                self.schedulePagePrefetch(after: 0.15)
            }
        }
        flipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 静止下来之后再把左右相邻页建好：正在滑动时不建（那一帧会很贵），
    /// 换页动画结束、页面停稳之后再补，用户看到的就是"随时都是顺的"。
    func schedulePagePrefetch(after delay: TimeInterval = 0.25) {
        prefetchWork?.cancel()
        prefetchedPages = []
        let first = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                // 还在滑动/拖动就先不建（那一帧会很贵），停稳了再来。
                guard self.drag == nil, !self.isPanning, !self.isBanding,
                      abs(self.swipeOffset) < 0.5 else {
                    self.schedulePagePrefetch(after: 0.2)
                    return
                }
                // 先建下一页（往右翻更常用），过一会儿再补上一页：
                // 一帧里连建两页会有一次 ~30ms 的停顿，拆开就几乎看不出来。
                self.prefetchedPages = [self.page + 1].filter { $0 < self.pageCount }
                WallpaperProvider.shared.appendNote("prefetch step1 pages=\(self.prefetchedPages)")
                self.warmLabels(onPages: self.prefetchedPages)
                let second = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isOpen, self.drag == nil,
                              abs(self.swipeOffset) < 0.5 else { return }
                        self.prefetchedPages = [self.page - 1, self.page + 1]
                            .filter { $0 >= 0 && $0 < self.pageCount }
                        WallpaperProvider.shared.appendNote("prefetch step2 pages=\(self.prefetchedPages)")
                        self.warmLabels(onPages: self.prefetchedPages)
                    }
                }
                self.prefetchWork = second
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: second)
            }
        }
        prefetchWork = first
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: first)
    }

    func item(at index: Int) -> LPItem? {
        let items = currentItems
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    // MARK: - Folder

    func closeFolder() {
        stopDragTicker()
        drag = nil
        openFolderID = nil
        folderNameEditing = false
    }

    func beginRenamingFolder() {
        guard let folder = openFolder else { return }
        folderNameDraft = folder.name
        folderNameCaret = folder.name.count
        folderNameEditing = true
    }

    func insertFolderNameText(_ text: String) {
        let offset = min(folderNameCaret, folderNameDraft.count)
        let index = folderNameDraft.index(folderNameDraft.startIndex, offsetBy: offset)
        folderNameDraft.insert(contentsOf: text, at: index)
        folderNameCaret = offset + text.count
    }

    func backspaceFolderName() {
        guard folderNameCaret > 0, !folderNameDraft.isEmpty else { return }
        let index = folderNameDraft.index(folderNameDraft.startIndex, offsetBy: folderNameCaret - 1)
        folderNameDraft.remove(at: index)
        folderNameCaret -= 1
    }

    func moveFolderNameCaret(_ delta: Int) {
        folderNameCaret = min(max(0, folderNameCaret + delta), folderNameDraft.count)
    }

    func commitFolderName() {
        guard let openFolderID else { return }
        if var folder = layout.folders[openFolderID] {
            let trimmed = folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            folder.name = trimmed.isEmpty ? Layout.defaultFolderName : trimmed
            layout.folders[openFolderID] = folder
            persist()
        }
        folderNameEditing = false
    }

    func dissolveFolder(_ folderID: String) {
        let items = layout.dissolveFolder(folderID)
        openFolderID = nil
        guard !items.isEmpty else { return }
        var pageIndex = min(page, max(0, layout.pages.count - 1))
        for item in items {
            let count = layout.pages.indices.contains(pageIndex) ? layout.pages[pageIndex].count : 0
            layout.insert(item, page: pageIndex, index: count, capacity: metrics.capacity)
            if layout.pages.indices.contains(pageIndex), layout.pages[pageIndex].count >= metrics.capacity {
                pageIndex += 1
            }
        }
        persist()
    }

    // MARK: - Item actions

    func revealInFinder(_ bundleID: String) {
        guard let entry = catalog.entry(bundleID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        closeAndDismiss()
    }

    func hideFromLaunchpad(_ bundleID: String) {
        layout.detach(app: bundleID)
        layout.pruneEmptyFolders()
        closeEmptyOpenFolder()
        if !layout.hidden.contains(bundleID) { layout.hidden.append(bundleID) }
        persist()
    }

    func unhideAll() {
        layout.hidden = []
        catalog.reload()
        var updated = layout
        updated.normalize(catalog: catalog, rows: metrics.rows, columns: metrics.columns)
        layout = updated
        persist()
    }

    func moveToTrash(_ bundleID: String) {
        guard let entry = catalog.entry(bundleID), entry.isRemovable else { return }
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            // 先放一个"幽灵图标"在原地播放消散动画，同时带动画移除数据，
            // 剩下的图标就会平滑滑动补位，而不是瞬间跳位。
            showGhost(for: .app(bundleID))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                layout.detach(app: bundleID)
                layout.pruneEmptyFolders()
                closeEmptyOpenFolder()
            }
            persist()
            catalog.reload()
        } catch {
            lastError = "无法移到废纸篓：\(error.localizedDescription)"
            Log.error("trash failed: \(error.localizedDescription)")
            Confirmation.error(title: "无法删除“\(name(of: bundleID))”",
                               message: error.localizedDescription)
        }
    }

    /// 在图标原位置留下一个用于播放删除动画的副本。
    private func showGhost(for item: LPItem) {
        guard let location = layout.locate(itemID: item.id),
              location.page == page,
              layout.pages.indices.contains(location.page),
              layout.pages[location.page].indices.contains(location.index) else { return }
        let ghost = DeletingGhost(item: item, center: metrics.cellCenter(index: location.index))
        deletingGhost = ghost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                if self?.deletingGhost?.id == ghost.id { self?.deletingGhost = nil }
            }
        }
    }

    /// Entry point used by the ⊗ badge: ask first, delete only if confirmed.
    func requestDelete(_ bundleID: String) {
        guard let entry = catalog.entry(bundleID), entry.isRemovable else { return }
        let displayName = name(of: bundleID)
        let confirmed = confirmationHandler?(displayName)
            ?? Confirmation.deleteApp(name: displayName, icon: IconStore.shared.icon(for: entry))
        guard confirmed else { return }
        moveToTrash(bundleID)
    }

    // MARK: - 多选批量操作

    /// 批量隐藏：从网格里收起来，之后可以在偏好设置里一次性恢复。
    func hideSelected() {
        let ids = selectedItems().compactMap(\.appID)
        guard !ids.isEmpty else {
            Confirmation.error(title: "没有可以隐藏的应用",
                               message: "所选项目里只有文件夹，文件夹不能单独隐藏。")
            return
        }
        for id in ids { layout.detach(app: id) }
        layout.pruneEmptyFolders()
        closeEmptyOpenFolder()
        for id in ids where !layout.hidden.contains(id) { layout.hidden.append(id) }
        clearMultiSelection()
        persist()
    }

    /// 批量移到废纸篓（先确认）。
    func requestDeleteSelected() {
        let entries = selectedItems()
            .compactMap(\.appID)
            .compactMap { catalog.entry($0) }
            .filter(\.isRemovable)
        guard !entries.isEmpty else {
            Confirmation.error(title: "没有可以删除的应用",
                               message: "所选项目里没有能移到废纸篓的应用（系统自带的应用不允许删除）。")
            return
        }
        let names = entries.map(\.name)
        let confirmed = batchConfirmationHandler?(names)
            ?? confirmationHandler?(names.count == 1 ? names[0] : "\(names.count) 个项目")
            ?? Confirmation.deleteApps(names: names,
                                       icon: entries.count == 1 ? IconStore.shared.icon(for: entries[0]) : nil)
        guard confirmed else { return }
        performDelete(entries)
    }

    private func performDelete(_ entries: [AppEntry]) {
        var removed: [String] = []
        for entry in entries {
            do {
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                removed.append(entry.bundleID)
                showGhost(for: .app(entry.bundleID))
            } catch {
                lastError = "无法移到废纸篓：\(error.localizedDescription)"
                Log.error("trash failed: \(error.localizedDescription)")
                Confirmation.error(title: "无法删除“\(entry.name)”", message: error.localizedDescription)
            }
        }
        guard !removed.isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            for id in removed { layout.detach(app: id) }
            layout.pruneEmptyFolders()
            closeEmptyOpenFolder()
        }
        clearMultiSelection()
        persist()
        catalog.reload()
    }

    /// 把选中的应用收进一个新文件夹。
    func createFolderFromSelection() {
        let items = selectedItems()
        let apps = items.compactMap(\.appID)
        guard apps.count >= 2 else {
            Confirmation.error(title: "至少要选两个应用",
                               message: "选中两个或更多应用才能新建文件夹。")
            return
        }
        let anchor = items.first { $0.appID != nil } ?? items[0]
        let location = layout.locate(itemID: anchor.id) ?? (page: page, index: 0)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            _ = layout.createFolder(appIDs: apps,
                                    page: location.page,
                                    index: location.index,
                                    capacity: metrics.capacity)
        }
        clearMultiSelection()
        persist()
    }

    /// 成组拖拽落位：拖到文件夹上就整组放进去，否则插到指针所在的格子。
    private func commitGroupDrop(state: DragState) {
        let ids = Set([state.item.id] + state.companionIDs)
        let items = currentItems.filter { ids.contains($0.id) }
        guard items.count > 1 else { return }

        if let folderID = state.hoveredFolderID {
            let apps = items.compactMap(\.appID)
            let existing = layout.folders[folderID]?.apps.count ?? 0
            // 文件夹上限和单个拖入一样是 35（7×5），放不下就整体不动，别做一半。
            guard existing + apps.count <= 35 else {
                Confirmation.error(title: "文件夹放不下了",
                                   message: "一个文件夹最多放 35 个应用。现在已有 \(existing) 个，这次想再放 \(apps.count) 个。")
                return
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                for app in apps { layout.addToFolder(folderID, app: app) }
            }
            return
        }

        // 先整组摘下来，再按顺序插到目标位置，顺序才不会被打乱。
        var slot = metrics.slotIndex(at: state.point)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            for item in items { layout.remove(itemID: item.id) }
            for item in items {
                layout.insert(item, page: page, index: slot, capacity: metrics.capacity)
                slot += 1
            }
        }
    }

    // MARK: - 应用信息浮层

    /// ⌥ 点图标：弹出一张小卡片，显示版本、路径、大小、最近打开时间。
    func showInfo(for item: LPItem) {
        let anchor = anchorPoint(for: item)
        switch item {
        case .app(let bundleID):
            guard let entry = catalog.entry(bundleID) else { return }
            let (version, build) = AppInfoProvider.version(of: entry.url)
            let (systemLast, systemSource) = AppInfoProvider.lastOpened(of: entry.url)
            var lastUsed = systemLast
            var lastSource = systemSource
            if let usage = UsageStore.shared.record(for: bundleID),
               usage.lastLaunch > (lastUsed ?? .distantPast) {
                lastUsed = usage.lastLaunch
                lastSource = "启动台启动记录"
            }

            var rows: [InfoRow] = []
            let lastText = AppInfoProvider.dateText(lastUsed)
                + (lastSource.map { "　·　\($0)" } ?? "")
            rows.append(InfoRow(label: "最近打开", value: lastText))
            rows.append(InfoRow(label: "大小", value: "计算中…"))
            rows.append(InfoRow(label: "位置", value: entry.path, mono: true))
            rows.append(InfoRow(label: "标识符", value: bundleID, mono: true))
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                rows.append(InfoRow(label: "状态", value: "正在运行"))
            }

            var subtitleParts: [String] = []
            if let version, version.count > 0 {
                subtitleParts.append(build != nil && build != version
                                     ? "版本 \(version)（\(build!)）"
                                     : "版本 \(version)")
            }
            if entry.isSystem { subtitleParts.append("系统应用") }

            let state = InfoCardState(id: item.id,
                                      item: item,
                                      title: name(of: bundleID),
                                      subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: "　·　"),
                                      rows: rows,
                                      anchor: anchor,
                                      bundleID: bundleID,
                                      path: entry.path)
            infoCard = state

            // 应用包可能很大，体积遍历目录要花时间，放后台算完再补上。
            let url = entry.url
            let cardID = item.id
            Task { [weak self] in
                let size = await Task.detached(priority: .utility) { AppInfoProvider.size(of: url) }.value
                guard let self, var current = self.infoCard, current.id == cardID else { return }
                if let index = current.rows.firstIndex(where: { $0.label == "大小" }) {
                    current.rows[index].value = AppInfoProvider.sizeText(size)
                }
                self.infoCard = current
            }

        case .folder(let folderID):
            guard let folder = layout.folders[folderID] else { return }
            let names = folder.apps.map { name(of: $0) }.joined(separator: "、")
            let rows = [InfoRow(label: "项目", value: "\(folder.apps.count) 个应用"),
                        InfoRow(label: "创建时间", value: AppInfoProvider.dateText(folder.createdAt)),
                        InfoRow(label: "包含", value: names.isEmpty ? "—" : names)]
            infoCard = InfoCardState(id: item.id,
                                     item: item,
                                     title: folder.name,
                                     subtitle: "文件夹",
                                     rows: rows,
                                     anchor: anchor,
                                     bundleID: nil,
                                     path: nil)
        }
    }

    func hideInfo() {
        if infoCard != nil { infoCard = nil }
    }

    private func anchorPoint(for item: LPItem) -> CGPoint {
        if let location = layout.locate(itemID: item.id), location.page == page {
            return metrics.cellCenter(index: location.index)
        }
        return CGPoint(x: metrics.size.width / 2, y: metrics.size.height / 2)
    }

    /// A folder whose last app was just deleted disappears from the grid.
    private func closeEmptyOpenFolder() {
        if let openFolderID, layout.folders[openFolderID] == nil { self.openFolderID = nil }
    }

    // MARK: - Search

    func searchHits() -> [SearchHit] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let needle = AppEntry.sortKey(for: query)

        var hits: [SearchHit] = []
        var seen = Set<String>()

        func consider(app bundleID: String, folderName: String?) {
            let key = "app:" + bundleID
            guard !seen.contains(key) else { return }
            let name = catalog.name(bundleID)
            guard AppEntry.sortKey(for: name).contains(needle) else { return }
            seen.insert(key)
            hits.append(SearchHit(id: key,
                                  item: .app(bundleID),
                                  name: name,
                                  subtitle: folderName,
                                  isFolder: false))
        }

        for page in layout.pages {
            for item in page {
                switch item {
                case .app(let bundleID):
                    consider(app: bundleID, folderName: nil)
                case .folder(let folderID):
                    guard let folder = layout.folders[folderID] else { continue }
                    let key = "folder:" + folderID
                    if !seen.contains(key), AppEntry.sortKey(for: folder.name).contains(needle) {
                        seen.insert(key)
                        hits.append(SearchHit(id: key,
                                              item: .folder(folderID),
                                              name: folder.name,
                                              subtitle: "\(folder.apps.count) 个项目",
                                              isFolder: true))
                    }
                    for bundleID in folder.apps { consider(app: bundleID, folderName: folder.name) }
                }
            }
        }

        return hits.sorted { lhs, rhs in
            let l = AppEntry.sortKey(for: lhs.name)
            let r = AppEntry.sortKey(for: rhs.name)
            let leftPrefix = l.hasPrefix(needle)
            let rightPrefix = r.hasPrefix(needle)
            if leftPrefix != rightPrefix { return leftPrefix }
            if l.count != r.count { return l.count < r.count }
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }

    func beginSearch() {
        searchActive = true
        jiggle = false
        selection = nil
    }

    /// Called by the real text field whenever its contents change (including
    /// input method composition).
    func userTypedSearch(_ text: String) {
        guard searchText != text else { return }
        searchText = text
        searchActive = true
        searchCaret = text.count
        searchSelection = 0
        selection = nil
    }

    func endSearch(clearText: Bool) {
        searchActive = false
        searchSelection = 0
        searchCaret = 0
        if clearText { searchText = "" }
    }

    func insertSearchText(_ text: String) {
        beginSearch()
        let offset = min(searchCaret, searchText.count)
        let index = searchText.index(searchText.startIndex, offsetBy: offset)
        searchText.insert(contentsOf: text, at: index)
        searchCaret = offset + text.count
        searchSelection = 0
    }

    func backspaceSearch() {
        guard searchCaret > 0, !searchText.isEmpty else { return }
        let index = searchText.index(searchText.startIndex, offsetBy: searchCaret - 1)
        searchText.remove(at: index)
        searchCaret -= 1
        searchSelection = 0
    }

    func deleteForwardSearch() {
        guard searchCaret < searchText.count else { return }
        let index = searchText.index(searchText.startIndex, offsetBy: searchCaret)
        searchText.remove(at: index)
        searchSelection = 0
    }

    func moveSearchCaret(_ delta: Int) {
        searchCaret = min(max(0, searchCaret + delta), searchText.count)
    }

    func pasteIntoSearch() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertSearchText(text.replacingOccurrences(of: "\n", with: " "))
    }

    func moveSearchSelection(_ delta: Int) {
        let count = displayItems.count
        guard count > 0 else { return }
        searchSelection = min(max(0, searchSelection + delta), count - 1)
    }

    func commitSearch() {
        let items = displayItems
        guard !items.isEmpty else { return }
        let index = min(max(0, searchSelection), items.count - 1)
        let item = items[index]
        endSearch(clearText: true)
        activate(item)
    }

    // MARK: - Selection / keyboard navigation

    func moveSelection(dx: Int, dy: Int) {
        let items = displayItems
        guard !items.isEmpty else { return }

        guard let selection, let currentIndex = items.firstIndex(where: { $0.id == selection }) else {
            self.selection = items[0].id
            return
        }

        let column = currentIndex % metrics.columns
        var target = currentIndex + dx + dy * metrics.columns

        if dx > 0, column == metrics.columns - 1 { target = currentIndex + 1 }
        if dx < 0, column == 0 { target = currentIndex - 1 }

        if target < 0 {
            if dy != 0 {
                target = max(0, target + items.count)
            } else if page > 0 {
                flipPage(-1)
                self.selection = currentItems.last?.id
                return
            } else {
                target = 0
            }
        }
        if target >= items.count {
            if dy != 0 {
                target = target % max(1, items.count)
            } else if page < pageCount - 1 {
                flipPage(1)
                self.selection = currentItems.first?.id
                return
            } else {
                target = items.count - 1
            }
        }
        self.selection = items[max(0, min(items.count - 1, target))].id
    }

    func activateSelection() {
        if let selection, let item = displayItems.first(where: { $0.id == selection }) {
            activate(item)
        } else if let first = displayItems.first {
            activate(first)
        }
    }

    /// Esc peels back one layer of state at a time, exactly like Launchpad.
    func escape() {
        if drag != nil { cancelDrag(); return }
        if infoCard != nil { infoCard = nil; return }
        if !multiSelection.isEmpty { clearMultiSelection(); return }
        if folderNameEditing { folderNameEditing = false; return }
        if searchActive { endSearch(clearText: true); return }
        if openFolderID != nil { closeFolder(); return }
        if jiggle { jiggle = false; return }
        closeAndDismiss()
    }

    /// Click on the empty backdrop.
    func clickBackdrop() {
        // 点空白处 = 确认改名（Esc 才是取消）
        if folderNameEditing { commitFolderName(); return }
        if infoCard != nil { infoCard = nil; return }
        // 有选中项时，点空白先取消选中，而不是直接退出启动台。
        if !multiSelection.isEmpty { clearMultiSelection(); return }
        if openFolderID != nil { closeFolder(); return }
        if searchActive { endSearch(clearText: true); return }
        if jiggle { jiggle = false; return }
        closeAndDismiss()
    }

    // MARK: - Dragging

    func beginDrag(item: LPItem, point: CGPoint, grabOffset: CGSize, fromFolder folderID: String?) {
        // Search results are for launching, not rearranging.
        guard !isFiltering else { return }
        finishFlipIfNeeded()
        var originPage = page
        var originIndex = 0
        if let location = layout.locate(itemID: item.id) {
            originPage = location.page
            originIndex = location.index
        }
        // 按住多选里的某个图标往外拖 = 整组一起搬走。
        let companions: [String]
        if folderID == nil, multiSelection.contains(item.id), multiSelection.count > 1 {
            companions = selectedItems().filter { $0.id != item.id }.map(\.id)
        } else {
            companions = []
        }
        var state = DragState(item: item,
                              itemID: item.id,
                              startPoint: point,
                              point: point,
                              grabOffset: grabOffset,
                              page: originPage,
                              index: originIndex,
                              originPage: originPage,
                              originIndex: originIndex,
                              sourceFolderID: folderID,
                              startedAt: Date())
        state.companionIDs = companions
        drag = state
        jiggle = true
        selection = nil
        folderNameEditing = false
        startDragTicker()
    }

    func updateDrag(point: CGPoint) {
        guard var state = drag else { return }
        state.point = point

        // Dragging an app out of an open folder pops it onto the grid.
        if let folderID = state.sourceFolderID {
            let panel = metrics.folderPanel(itemCount: layout.folders[folderID]?.apps.count ?? 1)
            if panel.frame.contains(point) {
                reorderInsideFolder(folderID, state: &state, point: point)
                drag = state
                return
            }
            state.sourceFolderID = nil
            if let bundleID = state.item.appID {
                layout.removeFromFolder(folderID, app: bundleID)
            }
            collapseFolderIfNeeded(folderID)
            openFolderID = nil
            let slot = metrics.slotIndex(at: point)
            layout.insert(state.item, page: page, index: slot, capacity: metrics.capacity)
            if let location = layout.locate(itemID: state.itemID) {
                state.page = location.page
                state.index = location.index
            }
        }

        // 成组拖拽：不做实时重排（一组图标互相挤压会很难看也难预测），
        // 只记录指针悬停的文件夹，松手时一次性落位。
        if state.isGroupDrag {
            state.hoveredFolderID = folderTarget(at: point)
            state.pending = nil
            state.folderCandidateID = nil
            state.flipAnchor = nil
            state.flipStarted = nil
            drag = state
            startDragTicker()
            return
        }

        // A folder under the pointer wins over reordering: the icon hovers over
        // it (showing a peek) and dropping puts it inside. Without this the
        // folder would be pushed aside and become almost impossible to hit.
        if let hovered = folderTarget(at: point) {
            state.hoveredFolderID = hovered
            state.pending = nil
            drag = state
            startDragTicker()
            return
        }
        state.hoveredFolderID = nil

        // Page flipping when the pointer is pushed past the grid.
        // Launchpad flips when the icon reaches the screen edge; using the grid
        // frame plus a margin can land outside the display entirely.
        let edge = max(24, metrics.size.width * 0.05)
        if point.x < edge {
            flipDuringDrag(direction: -1, state: &state)
        } else if point.x > metrics.size.width - edge {
            flipDuringDrag(direction: 1, state: &state)
        } else {
            state.flipAnchor = nil
            state.flipStarted = nil
        }

        // 记录"重排前指针下的图标"，作为建文件夹的目标
        let hoveredSlot = metrics.slotIndex(at: point)
        if let candidate = layout.item(atPage: page, index: hoveredSlot),
           candidate.id != state.itemID {
            state.targetUnderPointerID = candidate.id
        }

        if state.pending != nil {
            // Cancel the folder preview if the pointer wanders off.
            if let anchor = state.dwellAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > 26 {
                state.pending = nil
                state.folderCandidateID = nil
                state.dwellAnchor = point
                state.dwellStarted = Date()
            }
            drag = state
            startDragTicker()
            return
        }

        // 指针停住（0.2 秒内移动小于 24pt）就冻结重排，并高亮将要合并的图标；
        // 停满 0.4 秒即进入"正在组成文件夹"的预览。否则图标会一直被挤走，
        // 用户根本看不到自己对着哪个图标。
        let anchorDistance = state.dwellAnchor.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .greatestFiniteMagnitude
        let anchorAge = state.dwellStarted.map { Date().timeIntervalSince($0) } ?? 0
        if anchorDistance > 24 {
            state.dwellAnchor = point
            state.dwellStarted = Date()
        }
        let stationary = anchorDistance <= 24 && anchorAge >= 0.2
        if stationary, let candidate = folderFormationCandidate(state: state, point: point) {
            state.folderCandidateID = candidate.targetItemID
            if anchorAge >= 0.4 { state.pending = candidate }
            drag = state
            startDragTicker()
            return
        }
        state.folderCandidateID = nil

        // Live reorder: the grid rearranges while the icon is held.
        let slot = metrics.slotIndex(at: point)
        if state.page != page {
            layout.move(itemID: state.itemID, toPage: page, index: slot, capacity: metrics.capacity)
        } else if slot != state.index, state.pending == nil {
            layout.move(itemID: state.itemID, toPage: state.page, index: slot, capacity: metrics.capacity)
        }
        if let location = layout.locate(itemID: state.itemID) {
            state.page = location.page
            state.index = location.index
        }
        drag = state
        startDragTicker()
    }

    func endDrag() {
        stopDragTicker()
        guard let state = drag else { return }
        if state.isGroupDrag {
            commitGroupDrop(state: state)
            drag = nil
            clearMultiSelection()
            pruneEmptyPages()
            persist()
            schedulePagePrefetch()
            return
        }
        if let folderID = state.hoveredFolderID, let bundleID = state.item.appID {
            // Dropped straight onto a folder: no dwell required.
            layout.addToFolder(folderID, app: bundleID)
        } else if let pending = state.pending {
            commitFolderFormation(pending: pending, state: state)
        }
        // A click that wobbled a few points must not leave the grid in its
        // editable state — that used to swallow every following click.
        let travelled = hypot(state.point.x - state.startPoint.x, state.point.y - state.startPoint.y)
        if travelled < 16 { jiggle = false }
        drag = nil
        pruneEmptyPages()
        persist()
        schedulePagePrefetch()
    }

    func cancelDrag() {
        stopDragTicker()
        drag = nil
        jiggle = false
        schedulePagePrefetch()
    }

    private func startDragTicker() {
        guard dragTicker == nil else { return }
        // 20 Hz is enough for the dwell/page-flip timers; pointer movement itself
        // arrives through the mouse-dragged monitor at full rate.
        dragTicker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let state = self.drag else { return }
                // Safety net: the pointer may be released while the tile that
                // owned the gesture has already been rebuilt (page flip).
                if !self.suppressDragAutoEnd, NSEvent.pressedMouseButtons & 0x1 == 0 {
                    self.endDrag()
                    return
                }
                self.updateDrag(point: self.pointerLocation() ?? state.point)
            }
        }
    }

    /// Current pointer position in the active display's view coordinates, so the
    /// drag keeps following the mouse even when no SwiftUI gesture is alive.
    private func pointerLocation() -> CGPoint? {
        if let pointerLocationOverride { return pointerLocationOverride }
        guard let display = activeDisplay else { return nil }
        let screen = NSEvent.mouseLocation
        return CGPoint(x: screen.x - display.frame.minX,
                       y: display.frame.maxY - screen.y)
    }

    private func stopDragTicker() {
        dragTicker?.invalidate()
        dragTicker = nil
    }

    /// The neighbour closest to the pointer that can absorb the dragged icon.
    private func folderFormationCandidate(state: DragState, point: CGPoint) -> PendingFolder? {
        // 优先用"重排前指针下那个图标"：用户就是对着它停下来的
        if let id = state.targetUnderPointerID,
           let location = layout.locate(itemID: id),
           layout.pages.indices.contains(location.page),
           layout.pages[location.page].indices.contains(location.index) {
            let item = layout.pages[location.page][location.index]
            var name: String?
            if let folderID = item.folderID { name = layout.folders[folderID]?.name }
            return PendingFolder(targetItemID: item.id,
                                 targetFolderID: item.folderID,
                                 targetFolderName: name,
                                 targetPage: location.page,
                                 targetIndex: location.index)
        }
        guard layout.pages.indices.contains(state.page) else { return nil }
        let pageItems = layout.pages[state.page]
        let neighbours = [-1, 1, -metrics.columns, metrics.columns]
        var best: (index: Int, distance: CGFloat)?

        for offset in neighbours {
            let index = state.index + offset
            guard pageItems.indices.contains(index) else { continue }
            if let draggedApp = state.item.appID, pageItems[index].appID == draggedApp { continue }
            let center = metrics.cellCenter(index: index)
            let distance = hypot(center.x - point.x, center.y - point.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }

        guard let best else { return nil }
        let item = pageItems[best.index]
        var name: String?
        if let folderID = item.folderID { name = layout.folders[folderID]?.name }
        return PendingFolder(targetItemID: item.id,
                             targetFolderID: item.folderID,
                             targetFolderName: name,
                             targetPage: state.page,
                             targetIndex: best.index)
    }

    private func commitFolderFormation(pending: PendingFolder, state: DragState) {
        defer { drag = nil }
        if let folderID = pending.targetFolderID {
            if let bundleID = state.item.appID { layout.addToFolder(folderID, app: bundleID) }
            return
        }
        guard let draggedApp = state.item.appID else { return }
        guard let targetApp = layout.item(atPage: pending.targetPage, index: pending.targetIndex)?.appID else { return }
        _ = layout.createFolder(appIDs: [targetApp, draggedApp],
                                page: pending.targetPage,
                                index: pending.targetIndex,
                                capacity: metrics.capacity)
    }

    private func flipDuringDrag(direction: Int, state: inout DragState) {
        // Dragging past the right edge of the last page creates a new page, the
        // way Launchpad does. Only when the last page actually holds something,
        // so holding at the edge cannot spawn empty pages.
        if direction > 0,
           page == pageCount - 1,
           layout.pages.indices.contains(page),
           !layout.pages[page].isEmpty {
            layout.pages.append([])
        }
        let target = page + direction
        let canFlip = direction < 0 ? page > 0 : page < pageCount - 1
        guard canFlip else {
            state.flipAnchor = nil
            state.flipStarted = nil
            return
        }

        let moved: Bool
        if let anchor = state.flipAnchor {
            moved = hypot(state.point.x - anchor.x, state.point.y - anchor.y) > 30
        } else {
            moved = true
        }
        if moved {
            state.flipAnchor = state.point
            state.flipStarted = Date()
            return
        }
        guard let started = state.flipStarted, Date().timeIntervalSince(started) >= 0.55 else { return }

        state.pending = nil
        // 拖到边缘翻页也要"滑过去"，和系统一样；这里不能用 animatePageChange
        // （它内部会改 page 并等一帧），改成同一套滑动但立刻切换。
        slideToPage(target)
        let slot = metrics.slotIndex(at: state.point)
        layout.move(itemID: state.itemID, toPage: target, index: slot, capacity: metrics.capacity)
        if let location = layout.locate(itemID: state.itemID) {
            state.page = location.page
            state.index = location.index
        }
        state.flipAnchor = state.point
        state.flipStarted = Date()
    }

    private func reorderInsideFolder(_ folderID: String, state: inout DragState, point: CGPoint) {
        guard let folder = layout.folders[folderID] else { return }
        let panel = metrics.folderPanel(itemCount: folder.apps.count)
        let slot = min(folder.apps.count - 1, panel.slotIndex(at: point))
        guard let bundleID = state.item.appID,
              let current = folder.apps.firstIndex(of: bundleID),
              current != slot else { return }
        var apps = folder.apps
        apps.remove(at: current)
        apps.insert(bundleID, at: min(slot, apps.count))
        layout.folders[folderID] = FolderEntry(id: folderID,
                                               name: folder.name,
                                               apps: apps,
                                               createdAt: folder.createdAt)
    }

    private func collapseFolderIfNeeded(_ folderID: String) {
        guard let folder = layout.folders[folderID], folder.apps.isEmpty else { return }
        layout.remove(itemID: LPItem.folder(folderID).id)
        layout.folders.removeValue(forKey: folderID)
    }

    /// The folder whose icon is under `point`, if any.
    func folderTarget(at point: CGPoint) -> String? {
        // The whole slot counts, not just the icon: reordering is triggered by
        // the slot too, so a narrower target would let the folder be pushed away
        // before the pointer ever reaches its icon.
        guard metrics.gridFrame.contains(point) else { return nil }
        let slot = metrics.slotIndex(at: point)
        guard let item = layout.item(atPage: page, index: slot),
              item.id != drag?.itemID,          // dragging the folder itself
              let folderID = item.folderID else { return nil }
        return folderID
    }

    private func pruneEmptyPages() {
        guard layout.pages.count > 1 else { return }
        while layout.pages.count > 1, layout.pages.last?.isEmpty == true {
            layout.pages.removeLast()
        }
        if page >= layout.pages.count { page = layout.pages.count - 1 }
    }
}
