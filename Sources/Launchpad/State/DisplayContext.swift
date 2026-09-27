import AppKit
import Foundation

/// One display participating in the overlay.
struct DisplayContext: Identifiable {
    var id: CGDirectDisplayID
    var screen: NSScreen?
    var frame: CGRect          // AppKit screen frame
    var scale: CGFloat
    var metrics: Metrics
    var isActive: Bool
    var backdrop: CGImage?
    var strongBackdrop: CGImage?
    var rawWallpaper: CGImage?

    var size: CGSize { frame.size }
}
