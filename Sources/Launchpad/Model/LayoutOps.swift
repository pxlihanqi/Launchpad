import Foundation

/// Pure helpers that keep the invariant "every app appears exactly once"
/// while the user drags things around.
extension Layout {
    static func pageCapacity(rows: Int, columns: Int) -> Int { max(1, rows * columns) }

    nonisolated static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400 ... 0x9FFF).contains(scalar.value) || (0xF900 ... 0xFAFF).contains(scalar.value)
        }
    }

    /// True when `short` is a whole-word prefix of `long`, so that
    /// "IntelliJ IDEA" matches "IntelliJ IDEA Community Edition" while
    /// "Notes" does not match "Goodnotes".
    nonisolated static func isWordPrefix(_ short: String, of long: String) -> Bool {
        guard !short.isEmpty, short != long, long.count > short.count, long.hasPrefix(short) else { return false }
        let index = long.index(long.startIndex, offsetBy: short.count)
        let separator = long[index]
        return separator == " " || separator == "-" || separator == "_"
    }

    nonisolated static func words(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }
    }

    /// Launchpad's own name for an app. Names captured from the old database
    /// win when the installed bundle no longer carries a localized name, so the
    /// grid shows 邮件 instead of Mail on a Chinese system.
    @MainActor
    func displayName(for bundleID: String, catalog: AppCatalog) -> String {
        let current = catalog.name(bundleID)
        guard let legacy = titles[bundleID], !legacy.isEmpty, legacy != current else { return current }
        // A name localized inside the bundle is always the freshest source.
        if catalog.entry(bundleID)?.nameIsLocalized == true { return current }
        // macOS 26 system apps ship no localized name at all, so the name the
        // old Launchpad recorded is the only Chinese one available.
        if Layout.containsCJK(legacy), !Layout.containsCJK(current) { return legacy }
        return current
    }

    func folder(_ id: String) -> FolderEntry? { folders[id] }

    func appIDs() -> [String] {
        var result: [String] = []
        for page in pages {
            for item in page {
                switch item {
                case .app(let bundleID): result.append(bundleID)
                case .folder(let folderID): result.append(contentsOf: folders[folderID]?.apps ?? [])
                }
            }
        }
        return result
    }

    func contains(app bundleID: String) -> Bool {
        pages.contains { page in
            page.contains { item in
                switch item {
                case .app(let id): return id == bundleID
                case .folder(let folderID): return folders[folderID]?.apps.contains(bundleID) ?? false
                }
            }
        }
    }

    /// Where an item currently lives.
    func locate(itemID: String) -> (page: Int, index: Int)? {
        for (pageIndex, page) in pages.enumerated() {
            if let index = page.firstIndex(where: { $0.id == itemID }) {
                return (pageIndex, index)
            }
        }
        return nil
    }

    func item(atPage page: Int, index: Int) -> LPItem? {
        guard pages.indices.contains(page), pages[page].indices.contains(index) else { return nil }
        return pages[page][index]
    }

    @discardableResult
    mutating func remove(itemID: String) -> LPItem? {
        for pageIndex in pages.indices {
            if let index = pages[pageIndex].firstIndex(where: { $0.id == itemID }) {
                // 只移除网格上的条目，保留 FolderEntry 本身。
                // （移动/换页都会经过这里，之前顺手删掉内容字典，导致文件夹一拖就"解散"。）
                return pages[pageIndex].remove(at: index)
            }
        }
        return nil
    }

    /// Removes an app no matter whether it sits on a page or inside a folder.
    @discardableResult
    mutating func detach(app bundleID: String) -> Bool {
        for pageIndex in pages.indices {
            if let index = pages[pageIndex].firstIndex(where: { $0.appID == bundleID }) {
                pages[pageIndex].remove(at: index)
                return true
            }
            for item in pages[pageIndex] {
                guard let folderID = item.folderID, var folder = folders[folderID] else { continue }
                if let appIndex = folder.apps.firstIndex(of: bundleID) {
                    folder.apps.remove(at: appIndex)
                    folders[folderID] = folder
                    return true
                }
            }
        }
        return false
    }

    /// Inserts an item on a page, growing pages as needed.
    mutating func insert(_ item: LPItem, page: Int, index: Int, capacity: Int) {
        while pages.count <= page { pages.append([]) }
        var targetPage = max(0, page)
        var targetIndex = max(0, min(index, pages[targetPage].count))

        if pages[targetPage].count >= capacity {
            // Overflow: push the last item to the next page (Launchpad does this
            // when a page is full).
            let overflow = pages[targetPage].removeLast()
            if targetIndex > pages[targetPage].count { targetIndex = pages[targetPage].count }
            pages[targetPage].insert(item, at: targetIndex)
            insert(overflow, page: targetPage + 1, index: 0, capacity: capacity)
            return
        }
        pages[targetPage].insert(item, at: targetIndex)
    }

    /// Moves an existing item (app or folder) to a new page/index.
    /// `index` is a slot index taken from the pointer's position in the grid,
    /// so it needs no adjustment for the removed item.
    mutating func move(itemID: String, toPage page: Int, index: Int, capacity: Int) {
        guard locate(itemID: itemID) != nil else { return }
        guard let item = remove(itemID: itemID) else { return }
        insert(item, page: page, index: index, capacity: capacity)
    }

    mutating func move(app bundleID: String, toPage page: Int, index: Int, capacity: Int) {
        guard contains(app: bundleID) else { return }
        detach(app: bundleID)
        insert(.app(bundleID), page: page, index: index, capacity: capacity)
    }

    /// Creates a folder out of one or more apps at a given grid position.
    mutating func createFolder(name: String? = nil,
                               appIDs: [String],
                               page: Int,
                               index: Int,
                               capacity: Int) -> FolderEntry? {
        let unique = appIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard unique.count >= 2 else { return nil }

        // Insertion point = position of the first participant.
        var insertionIndex = index
        if let first = unique.first, let location = locate(itemID: LPItem.app(first).id) {
            insertionIndex = location.page == page ? location.index : index
        }
        for id in unique { detach(app: id) }

        let folder = FolderEntry(id: UUID().uuidString, name: name ?? Self.defaultFolderName, apps: unique)
        folders[folder.id] = folder
        insert(.folder(folder.id), page: page, index: insertionIndex, capacity: capacity)
        return folder
    }

    static var defaultFolderName: String { "文件夹" }

    mutating func addToFolder(_ folderID: String, app bundleID: String, at index: Int? = nil) {
        guard var folder = folders[folderID] else { return }
        // A folder page holds 7x5 icons; Launchpad does not grow beyond that.
        guard folder.apps.count < 35 else { return }
        detach(app: bundleID)
        if let index, folder.apps.indices.contains(index) {
            folder.apps.insert(bundleID, at: index)
        } else {
            folder.apps.append(bundleID)
        }
        folders[folderID] = folder
    }

    mutating func removeFromFolder(_ folderID: String, app bundleID: String) {
        guard var folder = folders[folderID] else { return }
        folder.apps.removeAll { $0 == bundleID }
        folders[folderID] = folder
    }

    /// Pulls every app out of a folder and returns the items to re-insert.
    mutating func dissolveFolder(_ folderID: String) -> [LPItem] {
        guard let folder = folders[folderID] else { return [] }
        remove(itemID: LPItem.folder(folderID).id)
        folders.removeValue(forKey: folderID)
        return folder.apps.map { LPItem.app($0) }
    }

    /// Drops folder tiles that no longer hold any app (e.g. after deleting the
    /// last app of a folder from inside it).
    mutating func pruneEmptyFolders() {
        for pageIndex in pages.indices {
            pages[pageIndex].removeAll { item in
                guard let folderID = item.folderID else { return false }
                let empty = folders[folderID]?.apps.isEmpty ?? true
                if empty { folders.removeValue(forKey: folderID) }
                return empty
            }
        }
    }

    /// Reconciles the stored layout with what is actually installed:
    /// drops uninstalled apps, dissolves one-app folders, hides hidden apps and
    /// appends newly installed apps at the end (Launchpad's behaviour).
    @MainActor
    mutating func normalize(catalog: AppCatalog, rows: Int, columns: Int) {
        let capacity = Self.pageCapacity(rows: rows, columns: columns)
        let hiddenSet = Set(hidden)
        let available = Set(catalog.apps.keys)

        var seenApps = Set<String>()
        var newPages: [[LPItem]] = []
        var newFolders: [String: FolderEntry] = [:]

        func accepts(_ bundleID: String) -> Bool {
            available.contains(bundleID) && !hiddenSet.contains(bundleID) && !seenApps.contains(bundleID)
        }

        for page in pages {
            var outPage: [LPItem] = []
            for item in page {
                switch item {
                case .app(let bundleID):
                    if accepts(bundleID) {
                        seenApps.insert(bundleID)
                        outPage.append(item)
                    }
                case .folder(let folderID):
                    guard let folder = folders[folderID] else { continue }
                    let apps = folder.apps.filter { accepts($0) }
                    apps.forEach { seenApps.insert($0) }
                    if !apps.isEmpty {
                        var updated = folder
                        updated.apps = apps
                        newFolders[folderID] = updated
                        outPage.append(item)
                    }
                }
            }
            newPages.append(outPage)
        }

        // Newly installed apps land at the end of the last page.
        let missing = catalog.orderedBundleIDs.filter { !seenApps.contains($0) && !hiddenSet.contains($0) }
        for bundleID in missing {
            insertRemainder(bundleID, into: &newPages, capacity: capacity)
        }

        if newPages.isEmpty { newPages = [[]] }
        // 用户自己排的分页要保留（例如拖到右缘新建的一页），所以这里只做
        // "拆分"：任何一页超过当前容量时切成多页，避免图标溢出屏幕。
        newPages = Self.splitOverflowing(newPages, capacity: capacity)
        pages = newPages
        folders = newFolders
        updatedAt = Date()
    }

    /// 把项目按顺序重新切成容量为 capacity 的页（保持图标/文件夹的相对顺序）。
    /// 用户显式改变"每行图标数量"时才调用 —— 这时按顺序重排是符合预期的；
    /// 平时打开应用走 `splitOverflowing`，不会破坏用户自己排的分页。
    static func repack(_ pages: [[LPItem]], capacity: Int) -> [[LPItem]] {
        let items = pages.flatMap { $0 }
        guard !items.isEmpty else { return [[]] }
        var out: [[LPItem]] = []
        var index = 0
        while index < items.count {
            out.append(Array(items[index ..< min(index + capacity, items.count)]))
            index += capacity
        }
        return out
    }

    /// 只把超出容量的页拆开，页数与其余页的划分保持原样。
    static func splitOverflowing(_ pages: [[LPItem]], capacity: Int) -> [[LPItem]] {
        var out: [[LPItem]] = []
        for page in pages {
            guard page.count > capacity else {
                out.append(page)
                continue
            }
            var index = 0
            while index < page.count {
                out.append(Array(page[index ..< min(index + capacity, page.count)]))
                index += capacity
            }
        }
        return out.isEmpty ? [[]] : out
    }

    private func insertRemainder(_ bundleID: String, into pages: inout [[LPItem]], capacity: Int) {
        guard !pages.isEmpty else {
            pages = [[.app(bundleID)]]
            return
        }
        if let last = pages.indices.last, pages[last].count < capacity {
            pages[last].append(.app(bundleID))
        } else {
            pages.append([.app(bundleID)])
        }
    }

    /// Builds a layout purely from the catalog (alphabetical, like a fresh
    /// macOS install).
    @MainActor
    static func alphabetical(from catalog: AppCatalog, rows: Int, columns: Int) -> Layout {
        var layout = Layout()
        let capacity = pageCapacity(rows: rows, columns: columns)
        let ids = catalog.orderedBundleIDs
        var index = 0
        while index < ids.count {
            let slice = ids[index ..< min(index + capacity, ids.count)]
            layout.pages.append(slice.map { LPItem.app($0) })
            index += capacity
        }
        if layout.pages.isEmpty { layout.pages = [[]] }
        return layout
    }
}
