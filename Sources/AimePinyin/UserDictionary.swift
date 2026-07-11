import Foundation

/// 用户词库 v1：确认过的转换里挖出的高频词 + 专有名词，JSON 落盘。
/// app（词库管理/ASR 热词）与 IME 进程（prompt 注入）共读写。
public final class UserDictionary {
    public struct Entry: Codable, Identifiable, Sendable {
        public var id: String { text }
        public var text: String
        public var count: Int
        public var lastUsed: Date
        /// 来源："pinyin" / "voice" / "manual"
        public var source: String
    }

    public static let shared = UserDictionary()

    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
            .appendingPathComponent("userdict.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        for entry in list {
            entries[entry.text] = entry
        }
    }

    private func persist() {
        let list = entries.values.sorted { $0.lastUsed > $1.lastUsed }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 从磁盘重载（另一进程可能刚写过）。
    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        load()
    }

    /// 记录一次确认的词（提交的转换结果里抽出的 2–6 字词或英文术语）。
    public func record(_ text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 12).contains(trimmed.count) else { return }
        lock.lock()
        defer { lock.unlock() }
        if var existing = entries[trimmed] {
            existing.count += 1
            existing.lastUsed = Date()
            entries[trimmed] = existing
        } else {
            entries[trimmed] = Entry(text: trimmed, count: 1, lastUsed: Date(), source: source)
        }
        persist()
    }

    public func remove(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: text)
        persist()
    }

    /// 衰减评分：score = count · exp(−天数/30)，旧习惯自然淡出（借鉴 RIME tick 衰减的简化版）
    static func decayedScore(_ entry: Entry, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastUsed) / 86400)
        return Double(entry.count) * exp(-days / 30)
    }

    public var allEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return entries.values.sorted { Self.decayedScore($0, now: now) > Self.decayedScore($1, now: now) }
    }

    /// 注入 prompt / ASR 热词的 top-N（衰减评分排序）。
    public func topEntries(_ limit: Int = 24) -> [String] {
        Array(allEntries.prefix(limit).map(\.text))
    }
}
