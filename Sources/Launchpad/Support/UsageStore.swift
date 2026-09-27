import Foundation

/// 记录"从启动台启动过哪些应用、最近一次是什么时候"。
///
/// 只写本地 JSON（`~/Library/Application Support/Launchpad/usage.json`），
/// 不联网、不上传；信息浮层里的"最近打开"会用它作为兜底来源。
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    struct Record: Codable, Equatable {
        var lastLaunch: Date
        var launches: Int
    }

    private var records: [String: Record] = [:]
    private var loaded = false

    private var fileURL: URL { SupportPaths.directory.appendingPathComponent("usage.json") }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded
    }

    func record(bundleID: String, at date: Date = Date()) {
        load()
        var record = records[bundleID] ?? Record(lastLaunch: date, launches: 0)
        record.lastLaunch = date
        record.launches += 1
        records[bundleID] = record
        save()
    }

    func record(for bundleID: String) -> Record? {
        load()
        return records[bundleID]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
