import Foundation

struct AppStyleEntry: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    var appName: String
    var styleInstructions: String
    var enabled: Bool

    init(bundleID: String, appName: String, styleInstructions: String, enabled: Bool = true) {
        self.bundleID = bundleID
        self.appName = appName
        self.styleInstructions = styleInstructions
        self.enabled = enabled
    }
}

enum AppStyleStorage {

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-styles.json")
    }()

    private static let lock = NSLock()
    private static var cache: [AppStyleEntry]?

    static func load() -> [AppStyleEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([AppStyleEntry].self, from: data)
        else { return [] }
        cache = entries
        return entries
    }

    static func save(_ entries: [AppStyleEntry]) {
        lock.lock()
        cache = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func entry(for bundleID: String) -> AppStyleEntry? {
        load().first { $0.bundleID == bundleID && $0.enabled }
    }

    static func addOrUpdate(_ entry: AppStyleEntry) {
        lock.lock()
        var entries = cache ?? (try? JSONDecoder().decode([AppStyleEntry].self, from: Data(contentsOf: fileURL))) ?? []
        if let idx = entries.firstIndex(where: { $0.bundleID == entry.bundleID }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        cache = entries
        lock.unlock()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func knownBundleIDs() -> Set<String> {
        Set(load().map(\.bundleID))
    }
}
