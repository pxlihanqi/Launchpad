import CoreGraphics
import Foundation

/// A folder that is currently being formed by hovering one icon over another.
struct PendingFolder: Equatable {
    var targetItemID: String
    var targetFolderID: String?     // set when hovering an existing folder
    var targetFolderName: String?
    var targetPage: Int
    var targetIndex: Int
}

/// Everything about the icon currently held by the pointer.
struct DragState: Equatable {
    var item: LPItem
    var itemID: String
    var startPoint: CGPoint    // where the pointer first went down
    var point: CGPoint          // pointer location in root coordinates
    var grabOffset: CGSize      // pointer - cell centre when the drag started
    var page: Int               // page the item currently occupies
    var index: Int              // slot the item currently occupies
    var originPage: Int
    var originIndex: Int
    var sourceFolderID: String? // dragging out of an open folder
    /// Folder the pointer is currently over: the icon hovers over it instead of
    /// pushing it aside, and dropping puts the icon inside.
    var hoveredFolderID: String?
    /// 指针停住时锁定住的图标：显示高亮提示"松手会和它合成文件夹"。
    var folderCandidateID: String?
    /// 重排**之前**指针所在格子里的那个图标 —— 它就是用户对着的目标。
    /// （重排会把被拖的图标塞进该格子，目标被挤到相邻格，靠几何距离猜会猜错。）
    var targetUnderPointerID: String?
    var startedAt: Date
    var pending: PendingFolder?
    var dwellAnchor: CGPoint?
    var dwellStarted: Date?
    var flipAnchor: CGPoint?
    var flipStarted: Date?
    /// 成组拖拽时被一起带走的其他图标（按当前页顺序）。
    var companionIDs: [String] = []

    var isFromFolder: Bool { sourceFolderID != nil }
    /// 拖的是一个多选组（≥2 个图标）而不是单个图标。
    var isGroupDrag: Bool { !companionIDs.isEmpty }

    /// Icon centre while dragging (the icon stays where it was grabbed).
    var proxyCenter: CGPoint {
        CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
    }
}
