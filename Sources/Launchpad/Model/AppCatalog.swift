import AppKit
import Foundation

/// Scans the system for installed applications, mirroring Dock's Launchpad
/// search roots (plus a couple of friendly extras) and deduplicating by bundle id.
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [String: AppEntry] = [:]
    private(set) var orderedBundleIDs: [String] = []

    /// Roots are ordered by priority: earlier roots win when the same bundle id
    /// shows up twice.
    private let roots: [(url: URL, depth: Int)] = {
        let home = NSHomeDirectory()
        var roots: [(url: URL, depth: Int)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), 2),
            // Depth 2 so /System/Applications/Utilities is included, exactly
            // like Launchpad. CoreServices/Applications is intentionally not
            // scanned: Launchpad never showed those launchers.
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), 2),
            (URL(fileURLWithPath: home + "/Applications", isDirectory: true), 2),
            (URL(fileURLWithPath: "/Library/Applications", isDirectory: true), 1)
        ]
        // Apple's Launchpad leaves the CoreServices launchers (Keychain Access,
        // Archive Utility, …) out of the grid, so they are opt-in here.
        if Prefs.includeSystemTools {
            roots.append((URL(fileURLWithPath: "/System/Library/CoreServices/Applications",
                              isDirectory: true), 1))
        }
        return roots
    }()

    private var ownBundleID: String { Bundle.main.bundleIdentifier ?? "com.launchpad.app" }

    func reload() {
        let previous = apps
        var found: [String: AppEntry] = [:]
        for root in roots {
            scan(root.url, depth: root.depth, into: &found)
        }
        apps = found
        // Refresh cached icons for apps that were updated, moved or removed.
        for (bundleID, entry) in found {
            guard let old = previous[bundleID] else { continue }
            if old.bundleModDate != entry.bundleModDate || old.path != entry.path {
                IconStore.shared.invalidate(bundleID)
            }
        }
        for bundleID in previous.keys where found[bundleID] == nil {
            IconStore.shared.invalidate(bundleID)
        }
        orderedBundleIDs = found.values
            .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
            .map(\.bundleID)
        Log.info("catalog: \(apps.count) apps")
    }

    func entry(_ bundleID: String) -> AppEntry? { apps[bundleID] }

    func name(_ bundleID: String) -> String { apps[bundleID]?.name ?? bundleID }

    // MARK: - Scanning

    private func scan(_ root: URL, depth: Int, into found: inout [String: AppEntry]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .contentModificationDateKey]
        // Note: no .skipsHiddenFiles — symlinked system apps (Safari lives in
        // the hidden Preboot cryptex) would be skipped. Dot files are filtered
        // by hand instead.
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return }

        for child in children {
            if child.lastPathComponent.hasPrefix(".") { continue }
            let isApp = child.pathExtension.lowercased() == "app"
            if isApp {
                if let entry = makeEntry(at: child, isSystem: root.path.hasPrefix("/System")) {
                    if found[entry.bundleID] == nil { found[entry.bundleID] = entry }
                }
            } else if depth > 1, (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // One extra level (e.g. /Applications/Adobe Photoshop/Photoshop.app).
                scan(child, depth: depth - 1, into: &found)
            }
        }
    }

    private func makeEntry(at url: URL, isSystem: Bool) -> AppEntry? {
        // /Applications/Safari.app and friends are symlinks into the system
        // cryptex; resolve them so the bundle can be read and so the app is
        // correctly treated as a non deletable system app.
        let resolved = url.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: resolved) ?? Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        if bundleID.contains(".helper") || bundleID.hasSuffix("Helper") { return nil }
        if (info["LSBackgroundOnly"] as? Bool) == true { return nil }
        if (info["LSBackgroundOnly"] as? String) == "1" { return nil }
        if url.path.contains("/Contents/Library/") { return nil }

        let baseName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? resolved.deletingPathExtension().lastPathComponent
        let name = localizedName(bundle: bundle, fallback: resolved)

        let modDate = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date.distantPast

        // System apps cannot be trashed; everything else can (Launchpad shows the
        // delete badge for exactly those).
        // Our own app shows up in the grid like any other installed app, but it
        // must not offer to delete itself.
        let removable = !isSystem && !resolved.path.hasPrefix("/System/") && bundleID != ownBundleID

        return AppEntry(
            bundleID: bundleID,
            name: name,
            nameIsLocalized: name != baseName,
            path: resolved.path,
            bundleModDate: modDate,
            isSystem: isSystem,
            isRemovable: removable
        )
    }

    /// Mirrors what Finder and Dock show: the localized display name from
    /// InfoPlist.strings, falling back to the bundle's own Info.plist.
    private func localizedName(bundle: Bundle, fallback: URL) -> String {
        let info = bundle.infoDictionary ?? [:]
        var display = info["CFBundleDisplayName"] as? String
        var name = info["CFBundleName"] as? String

        let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
        if let localization = Bundle.preferredLocalizations(from: bundle.localizations,
                                                            forPreferences: preferences).first,
           let stringsPath = bundle.path(forResource: "InfoPlist",
                                         ofType: "strings",
                                         inDirectory: nil,
                                         forLocalization: localization),
           let localized = NSDictionary(contentsOfFile: stringsPath) as? [String: String] {
            if let value = localized["CFBundleDisplayName"], !value.isEmpty { display = value }
            if let value = localized["CFBundleName"], !value.isEmpty { name = value }
        }

        if let display, !display.isEmpty { return display }
        if let name, !name.isEmpty { return name }
        return fallback.deletingPathExtension().lastPathComponent
    }
}
