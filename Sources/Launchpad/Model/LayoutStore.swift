import Foundation

/// Reads/writes layout.json and produces the very first layout on a fresh
/// install (importing the user's old Launchpad database when it still exists).
enum LayoutStore {
    static func load() -> Layout? {
        guard let data = try? Data(contentsOf: SupportPaths.layoutFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Layout.self, from: data)
    }

    static func save(_ layout: Layout) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layout) else { return }
        let url = SupportPaths.layoutFile
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("failed to save layout: \(error.localizedDescription)")
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: SupportPaths.layoutFile)
    }

    /// First-run layout: reuse the old Launchpad database when available so the
    /// user's pages and folders come back exactly as they were.
    @MainActor
    static func makeInitial(catalog: AppCatalog, rows: Int, columns: Int) -> Layout {
        if let imported = LaunchpadDBImporter.importLayout(catalog: catalog) {
            Log.info("imported layout from old Launchpad db: \(imported.summary)")
            var layout = imported.layout
            layout.normalize(catalog: catalog, rows: rows, columns: columns)
            return layout
        }
        return Layout.alphabetical(from: catalog, rows: rows, columns: columns)
    }
}
