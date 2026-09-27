import Foundation

/// A launchable application discovered on disk.
struct AppEntry: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    /// True when `name` came from a localized resource rather than the bundle's
    /// base (usually English) Info.plist name.
    var nameIsLocalized: Bool = false
    var path: String
    var bundleModDate: Date
    var isSystem: Bool
    var isRemovable: Bool

    var id: String { bundleID }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Sort key used to reproduce Launchpad's alphabetical ordering.
    var sortKey: String { AppEntry.sortKey(for: name) }

    static func sortKey(for name: String) -> String {
        // Launchpad orders by localized name, ignoring leading punctuation such as
        // "1Password" vs "About This Mac" (digits first, then letters).
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "zh-Hans"))
    }
}
