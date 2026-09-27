import AppKit
import Foundation

/// 信息浮层里的一行。
struct InfoRow: Equatable, Identifiable {
    var label: String
    var value: String
    /// 路径、标识符这类用等宽字体更好读。
    var mono: Bool = false

    var id: String { label }
}

/// 信息浮层要显示的内容（应用和文件夹共用一套结构）。
struct InfoCardState: Equatable, Identifiable {
    var id: String
    var item: LPItem
    var title: String
    var subtitle: String?
    var rows: [InfoRow]
    /// 被点图标在网格里的位置，卡片会贴着它显示。
    var anchor: CGPoint
    var bundleID: String?
    var path: String?
}

/// 收集应用信息。纯本地读取，不做任何网络请求。
enum AppInfoProvider {
    /// 版本号、构建号直接读应用包里的 Info.plist。
    static func version(of url: URL) -> (version: String?, build: String?) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else { return (nil, nil) }
        let version = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let build = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        return (version?.isEmpty == true ? nil : version,
                build?.isEmpty == true ? nil : build)
    }

    /// 应用包占用空间，用于信息浮层里的"大小"。
    static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        guard let bytes, bytes > 0 else { return nil }
        return Int64(bytes)
    }

    /// 最近打开时间。优先用 Spotlight 记录的 `kMDItemLastUsedDate`（与 Finder 显示的一致），
    /// 其次文件访问时间，最后是启动台自己的启动记录。
    static func lastOpened(of url: URL) -> (date: Date?, source: String?) {
        if let item = NSMetadataItem(url: url),
           let value = item.value(forAttribute: kMDItemLastUsedDate as String) as? Date {
            return (value, "系统记录")
        }
        if let values = try? url.resourceValues(forKeys: [.contentAccessDateKey]),
           let date = values.contentAccessDate {
            return (date, "文件访问时间")
        }
        return (nil, nil)
    }

    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
