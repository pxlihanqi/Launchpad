import Foundation

/// A folder of apps inside the Launchpad grid.
struct FolderEntry: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var apps: [String]
    var createdAt: Date = Date()
}

/// One cell of the grid: either an app or a folder.
enum LPItem: Hashable, Identifiable, Codable {
    case app(String)
    case folder(String)

    var id: String {
        switch self {
        case .app(let bundleID): return "app:" + bundleID
        case .folder(let folderID): return "folder:" + folderID
        }
    }

    var appID: String? {
        if case .app(let bundleID) = self { return bundleID }
        return nil
    }

    var folderID: String? {
        if case .folder(let folderID) = self { return folderID }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, app, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "app": self = .app(try container.decode(String.self, forKey: .app))
        case "folder": self = .folder(try container.decode(String.self, forKey: .folder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "unknown item kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let bundleID):
            try container.encode("app", forKey: .kind)
            try container.encode(bundleID, forKey: .app)
        case .folder(let folderID):
            try container.encode("folder", forKey: .kind)
            try container.encode(folderID, forKey: .folder)
        }
    }
}

/// Persisted Launchpad state: pages of items plus folder definitions.
struct Layout: Codable, Equatable {
    var version: Int = 1
    var pages: [[LPItem]] = []
    var folders: [String: FolderEntry] = [:]
    var hidden: [String] = []
    /// Display names captured from the user's old Launchpad database. macOS 26
    /// system apps no longer ship localized names inside their bundles, so this
    /// is the only way to reproduce the names Launchpad used to show.
    var titles: [String: String] = [:]
    var updatedAt: Date = Date()

    var isEmpty: Bool { pages.allSatisfy(\.isEmpty) }
}
