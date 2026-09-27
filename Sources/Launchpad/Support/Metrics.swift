import CoreGraphics
import Foundation

/// Geometry for one display, derived the way Launchpad derives its grid:
/// as many 7x5 style slots as fit, sized proportionally to the screen.
struct Metrics: Equatable {
    var size: CGSize
    var columns: Int
    var rows: Int
    var gridFrame: CGRect
    var cellSize: CGSize
    var iconSize: CGFloat
    var labelFont: CGFloat
    var searchSize: CGSize
    var searchCenter: CGPoint
    var dotsCenter: CGPoint
    var dotSize: CGFloat = 7
    var dotGap: CGFloat = 8

    /// - Parameters:
    ///   - columns: 每行图标数量；nil 表示按屏幕宽度自动（默认 7）。
    ///   - iconScale: 图标缩放系数，1.0 为默认大小。
    init(size: CGSize, columns columnOverride: Int? = nil, iconScale: CGFloat = 1) {
        let width = max(640, size.width)
        let height = max(480, size.height)
        self.size = CGSize(width: width, height: height)

        let topInset = max(72, height * 0.095)
        let bottomInset = max(54, height * 0.072)
        let sideInset = max(32, width * 0.045)

        let grid = CGRect(x: sideInset,
                          y: topInset,
                          width: width - sideInset * 2,
                          height: height - topInset - bottomInset)
        self.gridFrame = grid

        let autoColumns = min(7, max(4, Int(grid.width / 170)))
        let columns = min(12, max(4, columnOverride ?? autoColumns))
        let rows = min(5, max(3, Int(grid.height / 132)))
        self.columns = columns
        self.rows = rows
        self.cellSize = CGSize(width: grid.width / CGFloat(columns), height: grid.height / CGFloat(rows))

        // Launchpad scales its icons with the display: a 3008pt wide screen
        // gets noticeably larger icons than a 13" laptop.
        let icon = min(168, max(58, min(cellSize.width * 0.62, cellSize.height * 0.70)))
        // 手动缩放后的图标不能把名字挤出格子（留出约 14% 的行高）。
        self.iconSize = min(cellSize.height * 0.86, max(34, icon * max(0.4, iconScale)))
        self.labelFont = min(22, max(10.5, iconSize * 0.117))

        let searchWidth = min(258, width * 0.22)
        self.searchSize = CGSize(width: searchWidth, height: 28)
        self.searchCenter = CGPoint(x: width / 2, y: max(30, height * 0.034) + 14)
        self.dotsCenter = CGPoint(x: width / 2, y: height - max(22, height * 0.026))
    }

    var capacity: Int { max(1, rows * columns) }

    /// Width of an icon's caption (and of the clickable tile: Launchpad only
    /// gives the icon + its name to the app, everything else is background).
    var itemLabelWidth: CGFloat { max(iconSize * 1.35, 100) }
    var itemInteractiveWidth: CGFloat { max(itemLabelWidth, iconSize + 34) }
    var itemInteractiveHeight: CGFloat { iconSize + 5 + ceil(labelFont * 1.3) + 6 }

    func cellFrame(index: Int) -> CGRect {
        let clamped = max(0, index)
        let row = clamped / columns
        let column = clamped % columns
        return CGRect(x: gridFrame.minX + CGFloat(column) * cellSize.width,
                      y: gridFrame.minY + CGFloat(row) * cellSize.height,
                      width: cellSize.width,
                      height: cellSize.height)
    }

    func cellCenter(index: Int) -> CGPoint {
        let frame = cellFrame(index: index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The part of a slot that belongs to the icon: gaps between these areas
    /// stay background, so dragging there moves the pages instead of an icon.
    func itemInteractiveFrame(index: Int) -> CGRect {
        let cell = cellFrame(index: index)
        return CGRect(x: cell.midX - itemInteractiveWidth / 2,
                      y: cell.midY - itemInteractiveHeight / 2,
                      width: itemInteractiveWidth,
                      height: itemInteractiveHeight)
    }

    /// Slot under a point (clamped to the grid).
    func slotIndex(at point: CGPoint) -> Int {
        let column = Int(floor((point.x - gridFrame.minX) / cellSize.width))
        let row = Int(floor((point.y - gridFrame.minY) / cellSize.height))
        let clampedColumn = min(columns - 1, max(0, column))
        let clampedRow = min(rows - 1, max(0, row))
        return clampedRow * columns + clampedColumn
    }

    /// x offset of the page-dots row (used by both the dots and hit testing).
    func dotsTotalWidth(count: Int) -> CGFloat {
        guard count > 1 else { return dotSize }
        return CGFloat(count) * dotSize + CGFloat(count - 1) * dotGap
    }

    /// Geometry of the panel shown when a folder is opened.
    func folderPanel(itemCount: Int) -> FolderPanelLayout {
        FolderPanelLayout(metrics: self, itemCount: max(1, itemCount))
    }
}

/// The expanded folder view: a wide glass panel with up to 7x5 slots.
struct FolderPanelLayout: Equatable {
    var frame: CGRect
    var columns: Int
    var rows: Int
    var cellSize: CGSize
    var iconSize: CGFloat
    var nameFrame: CGRect
    var headerHeight: CGFloat
    var contentOrigin: CGPoint

    init(metrics: Metrics, itemCount: Int) {
        let columns = 7
        let rows = min(5, max(1, Int(ceil(Double(itemCount) / Double(columns)))))
        // The opened folder keeps the *icon* size of the grid but tightens the
        // spacing, which is what makes it a panel rather than a second screen.
        let icon = metrics.iconSize
        let cell = CGSize(width: icon * 1.30, height: icon * 1.42)
        let padding = icon * 0.62
        let header = icon * 0.34 + 26
        let width = CGFloat(columns) * cell.width + padding * 2
        let height = header + CGFloat(rows) * cell.height + padding * 0.75
        let origin = CGPoint(x: (metrics.size.width - width) / 2,
                             y: (metrics.size.height - height) / 2)

        self.columns = columns
        self.rows = rows
        self.cellSize = cell
        self.iconSize = icon
        self.headerHeight = header
        self.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        self.contentOrigin = CGPoint(x: origin.x + padding, y: origin.y + header)
        self.nameFrame = CGRect(x: origin.x, y: origin.y + 12, width: width, height: header - 20)
    }

    func cellFrame(index: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        return CGRect(x: contentOrigin.x + CGFloat(column) * cellSize.width,
                      y: contentOrigin.y + CGFloat(row) * cellSize.height,
                      width: cellSize.width,
                      height: cellSize.height)
    }

    func cellCenter(index: Int) -> CGPoint {
        let frame = cellFrame(index: index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Same contract as Metrics: only the icon + caption belongs to the app.
    var itemLabelWidth: CGFloat { max(iconSize * 1.35, 100) }
    var itemInteractiveWidth: CGFloat { max(itemLabelWidth, iconSize + 34) }
    var itemInteractiveHeight: CGFloat { iconSize + 5 + ceil(iconSize * 0.13) + 6 }

    func itemInteractiveFrame(index: Int) -> CGRect {
        let cell = cellFrame(index: index)
        return CGRect(x: cell.midX - itemInteractiveWidth / 2,
                      y: cell.midY - itemInteractiveHeight / 2,
                      width: itemInteractiveWidth,
                      height: itemInteractiveHeight)
    }

    func slotIndex(at point: CGPoint) -> Int {
        let column = Int(floor((point.x - contentOrigin.x) / cellSize.width))
        let row = Int(floor((point.y - contentOrigin.y) / cellSize.height))
        let clampedColumn = min(columns - 1, max(0, column))
        let clampedRow = min(rows - 1, max(0, row))
        return clampedRow * columns + clampedColumn
    }
}
