import Foundation
import SQLite3

/// Reads the (now unused) Dock Launchpad database so existing pages, folders
/// and folder names can be restored verbatim.
enum LaunchpadDBImporter {
    struct Result {
        var layout: Layout
        var unresolved: [String]
        var summary: String
    }

    /// The database used to live in the per-user darwin cache directory.
    static func candidateURLs() -> [URL] {
        var candidates: [URL] = []
        let suffixes = ["com.apple.dock.launchpad/db/db", "com.apple.dock.launchpad/db"]

        func baseDirectories() -> [URL] {
            var dirs: [URL] = []
            for key in [Int32(_CS_DARWIN_USER_CACHE_DIR), Int32(_CS_DARWIN_USER_TEMP_DIR)] {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                let length = confstr(key, &buffer, buffer.count)
                guard length > 1 else { continue }
                let path = String(cString: buffer)
                dirs.append(URL(fileURLWithPath: path, isDirectory: true))
            }
            // /var/folders/<x>/<y>/0 is the classic location.
            for dir in dirs {
                let parent = dir.deletingLastPathComponent()
                dirs.append(parent.appendingPathComponent("0", isDirectory: true))
                dirs.append(parent.appendingPathComponent("C", isDirectory: true))
            }
            return dirs
        }

        for dir in baseDirectories() {
            for suffix in suffixes {
                candidates.append(dir.appendingPathComponent(suffix))
            }
        }

        // Brute force fallback (works because we are not sandboxed).
        for root in ["/private/var/folders", "/var/folders"] {
            guard let users = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for user in users {
                let userDir = root + "/" + user
                guard let buckets = try? FileManager.default.contentsOfDirectory(atPath: userDir) else { continue }
                for bucket in buckets {
                    for sub in ["0", "C", "T"] {
                        candidates.append(URL(fileURLWithPath: "\(userDir)/\(bucket)/\(sub)/com.apple.dock.launchpad/db/db"))
                    }
                }
            }
        }
        return candidates
    }

    static func existingDatabaseURL() -> URL? {
        candidateURLs().first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @MainActor
    static func importLayout(catalog: AppCatalog) -> Result? {
        guard let url = existingDatabaseURL() else {
            Log.info("no legacy launchpad database found")
            return nil
        }
        do {
            return try read(url: url, catalog: catalog)
        } catch {
            Log.error("legacy import failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Reading

    private struct Row {
        var rowid: Int
        var parentID: Int
        var type: Int
        var ordering: Int
        var uuid: String
        var bundleID: String
        var title: String
    }

    private enum ImportError: LocalizedError {
        case open(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): return "cannot open database: \(message)"
            case .query(let message): return "query failed: \(message)"
            }
        }
    }

    @MainActor
    private static func read(url: URL, catalog: AppCatalog) throws -> Result {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw ImportError.open(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)

        func scalar(_ sql: String) -> String? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }

        let rootID = Int(scalar("SELECT value FROM dbinfo WHERE key = 'launchpad_root'") ?? "1") ?? 1

        let sql = """
        SELECT i.rowid, i.parent_id, i.type, i.ordering,
               IFNULL(i.uuid, ''), IFNULL(a.bundleid, ''),
               CASE WHEN IFNULL(a.title, '') <> '' THEN a.title ELSE IFNULL(g.title, '') END
        FROM items i
        LEFT JOIN apps a ON a.item_id = i.rowid
        LEFT JOIN groups g ON g.item_id = i.rowid
        ORDER BY i.parent_id, i.ordering
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.query(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var children: [Int: [Row]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let row = Row(
                rowid: Int(sqlite3_column_int64(statement, 0)),
                parentID: Int(sqlite3_column_int64(statement, 1)),
                type: Int(sqlite3_column_int64(statement, 2)),
                ordering: Int(sqlite3_column_int64(statement, 3)),
                uuid: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                bundleID: sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "",
                title: sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            )
            children[row.parentID, default: []].append(row)
        }

        // Item types inside the Dock database:
        //   1 = root page, 2 = folder, 3 = page (a folder's contents live on a
        //   child page), 4/5 = app.
        let pageRows = (children[rootID] ?? []).filter { $0.type == 3 && $0.uuid != "HOLDINGPAGE" }

        /// A grid position, possibly still waiting for an app whose bundle id
        /// changed since the database was written (e.g. Sublime Text 3 -> 4).
        enum Slot {
            case item(LPItem)
            case legacyApp(title: String)
        }

        var layout = Layout()
        var unresolved: [String] = []
        var folderCount = 0

        func slot(forApp row: Row) -> Slot? {
            if catalog.entry(row.bundleID) != nil {
                if !row.title.isEmpty { layout.titles[row.bundleID] = row.title }
                return .item(.app(row.bundleID))
            }
            if !row.bundleID.isEmpty { unresolved.append(row.bundleID) }
            return row.title.isEmpty ? nil : .legacyApp(title: row.title)
        }

        /// A folder's apps live on a child page (type 3) of the folder row, so
        /// resolve one level down when such a page exists.
        func resolveApps(in containerID: Int) -> [Slot] {
            let direct = children[containerID] ?? []
            let subPages = direct.filter { $0.type == 3 }
            let sources = subPages.isEmpty ? direct : subPages.flatMap { children[$0.rowid] ?? [] }
            var result: [Slot] = []
            for row in sources.sorted(by: { $0.ordering < $1.ordering }) {
                guard row.type == 4 || row.type == 5 else { continue }
                if let slot = slot(forApp: row) { result.append(slot) }
            }
            return result
        }

        var pageSlots: [[Slot]] = []
        for page in pageRows {
            var slots: [Slot] = []
            for row in (children[page.rowid] ?? []).sorted(by: { $0.ordering < $1.ordering }) {
                switch row.type {
                case 4, 5:
                    if let slot = slot(forApp: row) { slots.append(slot) }
                case 2:
                    let members = resolveApps(in: row.rowid)
                    let apps = members.compactMap { slot -> String? in
                        if case .item(.app(let bundleID)) = slot { return bundleID }
                        return nil
                    }
                    if !apps.isEmpty {
                        let folderID = row.uuid.isEmpty ? "folder-\(row.rowid)" : row.uuid
                        let name = row.title.isEmpty ? Layout.defaultFolderName : row.title
                        layout.folders[folderID] = FolderEntry(id: folderID, name: name, apps: apps)
                        slots.append(.item(.folder(folderID)))
                        folderCount += 1
                    } else {
                        // A one-app folder dissolves back into the grid, keeping
                        // the member's position (and its legacy placeholder).
                        slots.append(contentsOf: members)
                    }
                default:
                    continue
                }
            }
            pageSlots.append(slots)
        }

        // Re-home apps that were updated to a new bundle id but kept their name.
        var used = Set<String>()
        for slots in pageSlots {
            for slot in slots {
                switch slot {
                case .item(.app(let bundleID)):
                    used.insert(bundleID)
                case .item(.folder(let folderID)):
                    (layout.folders[folderID]?.apps ?? []).forEach { used.insert($0) }
                case .legacyApp:
                    continue
                }
            }
        }
        var byName: [String: String] = [:]
        for bundleID in catalog.orderedBundleIDs where !used.contains(bundleID) {
            let key = AppEntry.sortKey(for: catalog.name(bundleID))
            if byName[key] == nil { byName[key] = bundleID }
        }

        func matchLegacyTitle(_ title: String) -> String? {
            let key = AppEntry.sortKey(for: title)
            if let exact = byName[key], !used.contains(exact) { return exact }
            // "IntelliJ IDEA Community Edition" -> "IntelliJ IDEA"
            var best: (id: String, length: Int)?
            for (name, bundleID) in byName where !used.contains(bundleID) {
                guard Layout.isWordPrefix(key, of: name) || Layout.isWordPrefix(name, of: key) else { continue }
                if best == nil || name.count > best!.length { best = (bundleID, name.count) }
            }
            return best?.id
        }

        for slots in pageSlots {
            var items: [LPItem] = []
            for slot in slots {
                switch slot {
                case .item(let item):
                    items.append(item)
                case .legacyApp(let title):
                    guard let bundleID = matchLegacyTitle(title) else { continue }
                    used.insert(bundleID)
                    layout.titles[bundleID] = title
                    unresolved.removeAll { $0 == bundleID }
                    items.append(.app(bundleID))
                }
            }
            layout.pages.append(items)
        }

        guard !layout.pages.isEmpty else { return Result(layout: Layout.alphabetical(from: catalog, rows: 5, columns: 7), unresolved: unresolved, summary: "empty") }

        let appCount = layout.appIDs().count
        let summary = "\(layout.pages.count) pages, \(appCount) apps, \(folderCount) folders, \(unresolved.count) unresolved"
        return Result(layout: layout, unresolved: unresolved, summary: summary)
    }
}
