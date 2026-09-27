import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.launchpad.app", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// Location of our own support directory: ~/Library/Application Support/Launchpad
enum SupportPaths {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"] {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Launchpad", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var layoutFile: URL { directory.appendingPathComponent("layout.json") }
    static var iconCacheDirectory: URL {
        let dir = directory.appendingPathComponent("Icons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
