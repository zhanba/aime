import Foundation

/// 词库：编译期把 rime 格式词典合并成排序二进制，运行时 mmap + 二分前缀查询。
///
/// 文件格式（lexicon.bin）：
/// ```
/// magic "AIMELEX2" (8B) | entryCount u32 | offsets u32×(n+1) | records
///   | abbrCount u32 | abbrOffsets u32×(m+1) | abbrRecords
/// record = "音节序列(空格分隔)\t词\t权重十进制" UTF-8，按 key 字典序排（同 key 按权重逆序）
/// abbrRecord = 简拼串 UTF-8 + u32LE 主记录下标，按 (简拼串, 权重降序) 排——
///   简拼查询即前缀区间顺序扫描，天然按权重出词
/// ```
/// key 全 ASCII，字节序即字典序；排序数组即隐式 trie，前缀区间 = 两次二分。
/// 兼容读旧 AIMELEX1（无简拼段，abbrMatches 返回空）；App 启动检查到旧格式会自动重编译。
public final class Lexicon {
    public struct Entry: Sendable {
        public var key: String     // "jin tian"
        public var word: String    // 今天
        public var weight: Double  // 原始权重
    }

    private let data: Data
    private let offsets: [UInt32]
    private let recordsBase: Int
    public let entryCount: Int
    /// 简拼段（AIMELEX1 旧文件无此段：count=0）
    private let abbrOffsets: [UInt32]
    private let abbrRecordsBase: Int
    public let abbrCount: Int
    /// 是否旧格式（提示上层重编译）
    public let isLegacyFormat: Bool

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
            .appendingPathComponent("lexicon.bin")
    }

    /// mmap 加载（毫秒级，不解析全部词条）。文件不存在/损坏返回 nil。
    public init?(url: URL = Lexicon.defaultURL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count > 12
        else { return nil }
        let isLegacy = data.prefix(8) == Data("AIMELEX1".utf8)
        guard isLegacy || data.prefix(8) == Data("AIMELEX2".utf8) else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let entryCount = Int(UInt32(littleEndian: count))
        let offsetsEnd = 12 + (entryCount + 1) * 4
        guard entryCount > 0, data.count > offsetsEnd else { return nil }
        var offsets = [UInt32](repeating: 0, count: entryCount + 1)
        data.withUnsafeBytes { raw in
            for index in 0 ... entryCount {
                offsets[index] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12 + index * 4, as: UInt32.self))
            }
        }
        self.data = data
        self.offsets = offsets
        self.recordsBase = offsetsEnd
        self.entryCount = entryCount
        self.isLegacyFormat = isLegacy

        // 简拼段（紧跟主记录之后）
        let recordsEnd = offsetsEnd + Int(offsets[entryCount])
        if !isLegacy, data.count >= recordsEnd + 4 {
            let abbrCountRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: recordsEnd, as: UInt32.self) }
            let abbrCount = Int(UInt32(littleEndian: abbrCountRaw))
            let abbrOffsetsEnd = recordsEnd + 4 + (abbrCount + 1) * 4
            if abbrCount > 0, data.count > abbrOffsetsEnd {
                var abbrOffsets = [UInt32](repeating: 0, count: abbrCount + 1)
                data.withUnsafeBytes { raw in
                    for index in 0 ... abbrCount {
                        abbrOffsets[index] = UInt32(littleEndian: raw.loadUnaligned(
                            fromByteOffset: recordsEnd + 4 + index * 4, as: UInt32.self
                        ))
                    }
                }
                self.abbrOffsets = abbrOffsets
                self.abbrRecordsBase = abbrOffsetsEnd
                self.abbrCount = abbrCount
                return
            }
        }
        self.abbrOffsets = [0]
        self.abbrRecordsBase = 0
        self.abbrCount = 0
    }

    // MARK: - 查询

    /// 记录的 key 字节（到第一个 \t 为止）
    private func keyBytes(of index: Int) -> Data {
        let start = recordsBase + Int(offsets[index])
        let end = recordsBase + Int(offsets[index + 1])
        let record = data[start ..< end]
        if let tab = record.firstIndex(of: 0x09) {
            return record[record.startIndex ..< tab]
        }
        return record
    }

    private func entry(at index: Int) -> Entry? {
        let start = recordsBase + Int(offsets[index])
        let end = recordsBase + Int(offsets[index + 1])
        guard let line = String(data: data[start ..< end], encoding: .utf8) else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return Entry(
            key: String(parts[0]),
            word: String(parts[1]),
            weight: parts.count > 2 ? Double(parts[2]) ?? 1 : 1
        )
    }

    /// 第一个 key >= target 的下标（lower bound）
    private func lowerBound(_ target: Data) -> Int {
        var low = 0
        var high = entryCount
        while low < high {
            let mid = (low + high) / 2
            if keyBytes(of: mid).lexicographicallyPrecedes(target) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// key 精确等于 syllables 连接串的全部词条（即"这串音节是一个词"）
    public func exactMatches(key: String) -> [Entry] {
        let target = Data(key.utf8)
        var index = lowerBound(target)
        var results: [Entry] = []
        while index < entryCount, keyBytes(of: index) == target {
            if let entry = entry(at: index) {
                results.append(entry)
            }
            index += 1
        }
        return results
    }

    // MARK: - 简拼

    /// 音节 → 简拼字母（声母首字母；零声母取韵母首字母）
    static func abbrLetter(of syllable: String) -> String {
        String(syllable.prefix(1))
    }

    /// 词条 key 的简拼变体：首字母版必有；含 zh/ch/sh 的再加全翘舌版（"zhsh" 风格）
    static func abbrKeys(for syllables: [Substring]) -> [String] {
        var primary = ""
        var retroflex = ""
        var differs = false
        for syllable in syllables {
            primary += syllable.prefix(1)
            if syllable.hasPrefix("zh") || syllable.hasPrefix("ch") || syllable.hasPrefix("sh") {
                retroflex += syllable.prefix(2)
                differs = true
            } else {
                retroflex += syllable.prefix(1)
            }
        }
        return differs ? [primary, retroflex] : [primary]
    }

    private func abbrKeyBytes(of index: Int) -> Data {
        let start = abbrRecordsBase + Int(abbrOffsets[index])
        let end = abbrRecordsBase + Int(abbrOffsets[index + 1]) - 4
        return data[start ..< end]
    }

    private func abbrEntryIndex(of index: Int) -> Int {
        let end = abbrRecordsBase + Int(abbrOffsets[index + 1])
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: end - 4, as: UInt32.self) }
        return Int(UInt32(littleEndian: raw))
    }

    /// 简拼精确匹配（"nh" → 你好/内河/…），已按权重降序，最多 limit 条
    public func abbrMatches(key: String, limit: Int = 24) -> [Entry] {
        guard abbrCount > 0 else { return [] }
        let target = Data(key.utf8)
        var low = 0
        var high = abbrCount
        while low < high {
            let mid = (low + high) / 2
            if abbrKeyBytes(of: mid).lexicographicallyPrecedes(target) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var results: [Entry] = []
        var index = low
        while index < abbrCount, results.count < limit, abbrKeyBytes(of: index) == target {
            if let entry = entry(at: abbrEntryIndex(of: index)) {
                results.append(entry)
            }
            index += 1
        }
        return results
    }

    /// 是否存在以 key 开头（按音节边界）的任何词条——BFS 剪枝用
    public func hasPrefix(key: String) -> Bool {
        let target = Data(key.utf8)
        let index = lowerBound(target)
        guard index < entryCount else { return false }
        let found = keyBytes(of: index)
        guard found.count >= target.count, found.prefix(target.count) == target else { return false }
        // 边界：精确相等，或下一个字节是空格（音节边界）
        return found.count == target.count || found[found.startIndex + target.count] == 0x20
    }

    // MARK: - 编译

    /// 把 rime 词典文件（`词\t拼音\t权重`，YAML 头以 `...` 行结束）合并编译为 lexicon.bin。
    /// 过滤非法音节的词条；同 key+词 取最大权重。返回（收录数，丢弃数）。
    @discardableResult
    public static func compile(rimeDicts: [URL], to output: URL) throws -> (kept: Int, dropped: Int) {
        var best: [String: (word: String, weight: Double)] = [:]  // "key\u{1}word" → entry
        var dropped = 0
        for url in rimeDicts {
            let text = try String(contentsOf: url, encoding: .utf8)
            var inBody = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if !inBody {
                    if line == "..." { inBody = true }
                    continue
                }
                if line.hasPrefix("#") { continue }
                let parts = line.split(separator: "\t")
                guard parts.count >= 2 else { continue }
                let word = String(parts[0])
                let syllables = parts[1].split(separator: " ").map(String.init)
                guard !syllables.isEmpty, syllables.allSatisfy({ PinyinTable.isValid($0) }) else {
                    dropped += 1
                    continue
                }
                let weight = parts.count > 2 ? Double(parts[2]) ?? 1 : 1
                let key = syllables.joined(separator: " ")
                let mapKey = key + "\u{1}" + word
                if let existing = best[mapKey], existing.weight >= weight { continue }
                best[mapKey] = (word, weight)
            }
        }

        struct Row {
            var key: String
            var word: String
            var weight: Double
        }
        var rows = best.map { mapKey, value -> Row in
            let key = String(mapKey.split(separator: "\u{1}")[0])
            return Row(key: key, word: value.word, weight: value.weight)
        }
        rows.sort {
            $0.key == $1.key ? $0.weight > $1.weight : $0.key < $1.key
        }

        var records = Data()
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(rows.count + 1)
        for row in rows {
            let weightText = row.weight == row.weight.rounded()
                ? String(Int(row.weight))
                : String(row.weight)
            records.append(Data("\(row.key)\t\(row.word)\t\(weightText)".utf8))
            offsets.append(UInt32(records.count))
        }

        // 简拼段：≥2 音节的词生成首字母 key（含 zh/ch/sh 变体），按 (key, 权重降序) 排
        struct AbbrRow {
            var key: String
            var entryIndex: UInt32
            var weight: Double
        }
        var abbrRows: [AbbrRow] = []
        for (index, row) in rows.enumerated() {
            let syllables = row.key.split(separator: " ")
            guard syllables.count >= 2, syllables.count <= 8 else { continue }
            for abbrKey in abbrKeys(for: syllables) {
                abbrRows.append(AbbrRow(key: abbrKey, entryIndex: UInt32(index), weight: row.weight))
            }
        }
        abbrRows.sort {
            $0.key == $1.key ? $0.weight > $1.weight : $0.key < $1.key
        }
        var abbrRecords = Data()
        var abbrOffsets: [UInt32] = [0]
        abbrOffsets.reserveCapacity(abbrRows.count + 1)
        for row in abbrRows {
            abbrRecords.append(Data(row.key.utf8))
            var entryIndex = row.entryIndex.littleEndian
            withUnsafeBytes(of: &entryIndex) { abbrRecords.append(contentsOf: $0) }
            abbrOffsets.append(UInt32(abbrRecords.count))
        }

        var file = Data("AIMELEX2".utf8)
        var count = UInt32(rows.count).littleEndian
        withUnsafeBytes(of: &count) { file.append(contentsOf: $0) }
        for offset in offsets {
            var value = offset.littleEndian
            withUnsafeBytes(of: &value) { file.append(contentsOf: $0) }
        }
        file.append(records)
        var abbrCount = UInt32(abbrRows.count).littleEndian
        withUnsafeBytes(of: &abbrCount) { file.append(contentsOf: $0) }
        for offset in abbrOffsets {
            var value = offset.littleEndian
            withUnsafeBytes(of: &value) { file.append(contentsOf: $0) }
        }
        file.append(abbrRecords)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try file.write(to: output, options: .atomic)
        return (rows.count, dropped)
    }
}
