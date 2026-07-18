import Foundation

/// 语法模型：汉字搭配串 → log(词频)×10000，来自万象 LMDG（CC-BY-4.0）离线剪枝转换。
///
/// 文件格式（gram.bin，与 lexicon.bin 同构）：
/// ```
/// magic "AIMEGRM1" (8B) | entryCount u32 | offsets u32×(n+1) | records
/// record = key UTF-8 + value u32LE，按 key 字节序排；key 为 2–8 个汉字，句尾条目以 '$' 结尾
/// ```
/// 查询语义对齐 librime-octagram：候选词接在上文尾部之后，取所有
/// 「上文后缀 + 词头前缀」的搭配串命中里得分最高者；整串命中或长度达标记
/// collocation 惩罚，过短记 weak 惩罚，无命中记 non-collocation 惩罚。
public final class GramModel {
    private let data: NSData  // mmap 持有者；bytes 指针在其生命周期内稳定
    private let bytes: UnsafeRawPointer
    private let recordsBase: Int
    public let entryCount: Int

    /// 打分参数（万象 schema 的调参值作默认）。单位与 SentenceComposer 的 log 频一致。
    public struct Penalties: Sendable {
        public var collocationMaxLength = 6
        public var collocationMinLength = 2
        public var collocation = -14.0
        public var nonCollocation = -6.0
        public var weakCollocation = -100.0
        public var rear = -18.0
        public init() {}
    }

    public var penalties = Penalties()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
            .appendingPathComponent("gram.bin")
    }

    public init?(url: URL = GramModel.defaultURL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count > 12,
              data.prefix(8) == Data("AIMEGRM1".utf8)
        else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let entryCount = Int(UInt32(littleEndian: count))
        let offsetsEnd = 12 + (entryCount + 1) * 4
        guard entryCount > 0, data.count > offsetsEnd else { return nil }
        let nsData = data as NSData
        self.data = nsData
        self.bytes = nsData.bytes
        self.recordsBase = offsetsEnd
        self.entryCount = entryCount
    }

    // MARK: - 底层记录访问（原始指针，避免 Data 切片开销）
    // 偏移表不复制进堆（3000 万条 = 127MB），直接从 mmap 按需读：常驻内存交给页缓存管理。

    @inline(__always)
    private func offsets(_ index: Int) -> UInt32 {
        UInt32(littleEndian: UnsafeRawPointer(bytes + 12 + index * 4).loadUnaligned(as: UInt32.self))
    }

    /// target 与第 index 条 key 的三路比较：<0 表示 key < target
    @inline(__always)
    private func compareKey(at index: Int, with target: [UInt8]) -> Int {
        let start = recordsBase + Int(offsets(index))
        let keyLength = Int(offsets(index + 1)) - Int(offsets(index)) - 4
        let result = target.withUnsafeBytes { targetBuffer in
            memcmp(bytes + start, targetBuffer.baseAddress!, min(keyLength, target.count))
        }
        if result != 0 { return Int(result) }
        return keyLength - target.count
    }

    @inline(__always)
    private func keyEquals(at index: Int, _ target: [UInt8]) -> Bool {
        Int(offsets(index + 1)) - Int(offsets(index)) - 4 == target.count
            && compareKey(at: index, with: target) == 0
    }

    @inline(__always)
    private func value(of index: Int) -> Double {
        let end = recordsBase + Int(offsets(index + 1))
        let raw = UnsafeRawPointer(bytes + end - 4).loadUnaligned(as: UInt32.self)
        return Double(UInt32(littleEndian: raw)) / 10_000.0
    }

    /// 在 [low, high) 内找第一个 key >= target 的下标（区间收窄：嵌套前缀延长时复用上一轮区间）
    private func lowerBound(_ target: [UInt8], low: Int, high: Int) -> Int {
        var low = low
        var high = high
        while low < high {
            let mid = (low + high) / 2
            if compareKey(at: mid, with: target) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// target 的字节 +1（前缀区间上界用）；全 0xFF 时返回 nil（区间到文件尾）
    private static func upperKey(_ target: [UInt8]) -> [UInt8]? {
        var key = target
        var index = key.count - 1
        while index >= 0 {
            if key[index] < 0xFF {
                key[index] += 1
                key.removeLast(key.count - index - 1)
                return key
            }
            index -= 1
        }
        return nil
    }

    // MARK: - 查询

    /// 跨 compose/击键的查询缓存：逐键输入时词图前段不变，重复查询占绝对多数。
    /// key = context尾部 + \u{1} + word (+ "$")。超限整体清空（简单且足够）。
    private var cache: [String: Double] = [:]
    private let cacheLimit = 200_000

    /// 词 `word` 接在 `context`（句面已成部分）之后的转移得分。
    /// `isRear` 表示该词收尾整句（查 "词$" 条目）。
    public func score(context: String, word: String, isRear: Bool) -> Double {
        let maxQuery = penalties.collocationMaxLength - 1
        guard maxQuery > 0, !context.isEmpty, !word.isEmpty else { return penalties.nonCollocation }

        let contextTail = String(context.unicodeScalars.suffix(maxQuery))
        let cacheKey = isRear ? "\(contextTail)\u{1}\(word)$" : "\(contextTail)\u{1}\(word)"
        if let cached = cache[cacheKey] { return cached }

        let tailScalars = Array(contextTail.unicodeScalars)
        let wordHead = Array(word.unicodeScalars.prefix(maxQuery))
        let wordBytes: [[UInt8]] = wordHead.map { Array(String($0).utf8) }

        var best = penalties.nonCollocation
        for suffixStart in 0 ..< tailScalars.count {
            let contextLen = tailScalars.count - suffixStart
            var key = Array(String(String.UnicodeScalarView(tailScalars[suffixStart...])).utf8)
            // 先定位「以该上文后缀开头」的连续区间，后续每次前缀延长都在收窄后的区间内二分
            var low = lowerBound(key, low: 0, high: entryCount)
            var high = GramModel.upperKey(key).map { lowerBound($0, low: low, high: entryCount) } ?? entryCount
            for prefixLen in 1 ... wordBytes.count {
                guard low < high else { break }
                key += wordBytes[prefixLen - 1]
                low = lowerBound(key, low: low, high: high)
                high = GramModel.upperKey(key).map { lowerBound($0, low: low, high: high) } ?? high
                guard low < high, keyEquals(at: low, key) else { continue }
                let collocationLen = contextLen + prefixLen
                let coversWhole = suffixStart == 0 && prefixLen == wordBytes.count
                let penalty = (collocationLen >= penalties.collocationMinLength || coversWhole)
                    ? penalties.collocation : penalties.weakCollocation
                best = max(best, value(of: low) + penalty)
            }
        }

        if isRear, wordHead.count == word.unicodeScalars.count {
            let rearKey = Array(word.utf8) + [UInt8(ascii: "$")]
            let index = lowerBound(rearKey, low: 0, high: entryCount)
            if index < entryCount, keyEquals(at: index, rearKey) {
                best = max(best, value(of: index) + penalties.rear)
            }
        }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = best
        return best
    }

    // MARK: - 联想

    /// 上屏文本之后的联想候选：以上文尾部 2 字（不足取 1 字）为前缀全区间扫描，
    /// 先按 value 选 top（不解码），再解码取后继部分（1–4 字）。
    /// 搭配串无词边界且并非所有词都出现在 key 首位——无命中返回空是常态，调用方静默处理。
    public func completions(context: String, limit: Int = 6) -> [String] {
        let tail = Array(context.unicodeScalars.suffix(2))
        guard !tail.isEmpty else { return [] }
        let prefix = Array(String(String.UnicodeScalarView(tail)).utf8)
        let low = lowerBound(prefix, low: 0, high: entryCount)
        let high = GramModel.upperKey(prefix).map { lowerBound($0, low: low, high: entryCount) } ?? entryCount
        guard low < high, high - low <= 200_000 else { return [] }

        // 第一遍：只读 value 选 top-24。不同长度 key 的值域系统性不同
        // （LMDG 按 n-gram 阶重建频次：3字≈13、4字≈16、5字+≈17），按字数减基线归一后再比。
        // 全 CJK key 的字数 ≈ UTF-8 字节数 / 3，免解码。
        func baseline(charCount: Int) -> Double {
            switch charCount {
            case ..<4: return 13.0
            case 4: return 16.0
            case 5: return 16.6
            default: return 17.0
            }
        }
        var top: [(index: Int, value: Double)] = []
        for index in low ..< high {
            // 后继限 1–2 个 CJK 字（3–6 字节）：预测的是下一词，长"后继"多为截断串/实体垃圾
            let keyBytes = Int(offsets(index + 1)) - Int(offsets(index)) - 4
            guard (3 ... 6).contains(keyBytes - prefix.count) else { continue }
            let rawValue = value(of: index)
            guard abs(rawValue - 22.3327) > 0.01 else { continue }
            let keyChars = keyBytes / 3
            let normalized = rawValue - baseline(charCount: keyChars)
            if top.count < 24 {
                top.append((index, normalized))
                continue
            }
            if let minAt = top.indices.min(by: { top[$0].value < top[$1].value }),
               top[minAt].value < normalized {
                top[minAt] = (index, normalized)
            }
        }

        // 第二遍：解码后继并过滤（排序沿用归一分）
        var bestByWord: [String: Double] = [:]
        for (index, normalizedValue) in top {
            let start = recordsBase + Int(offsets(index))
            let keyLength = Int(offsets(index + 1)) - Int(offsets(index)) - 4
            guard keyLength > prefix.count else { continue }
            let remainderBytes = Data(bytes: bytes + start + prefix.count, count: keyLength - prefix.count)
            guard let remainder = String(data: remainderBytes, encoding: .utf8),
                  !remainder.contains("$"), !remainder.contains("#")
            else { continue }
            // 下一词预测只要 1–2 字单元；3 字+的"后继"多是无词边界的截断串或实体垃圾
            let charCount = remainder.unicodeScalars.count
            guard charCount >= 1, charCount <= 2 else { continue }
            if bestByWord[remainder, default: -.infinity] < normalizedValue {
                bestByWord[remainder] = normalizedValue
            }
        }
        return bestByWord.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: - 编译

    /// 把（搭配串, log(频)×10000）编译为 gram.bin。aime-gram 工具与测试共用。
    public static func compile(entries: [(key: String, value: UInt32)], to url: URL) throws {
        let sorted = entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        var records = Data()
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(sorted.count + 1)
        for entry in sorted {
            records.append(Data(entry.key.utf8))
            var value = entry.value.littleEndian
            withUnsafeBytes(of: &value) { records.append(contentsOf: $0) }
            offsets.append(UInt32(records.count))
        }
        var file = Data("AIMEGRM1".utf8)
        var count = UInt32(sorted.count).littleEndian
        withUnsafeBytes(of: &count) { file.append(contentsOf: $0) }
        for offset in offsets {
            var value = offset.littleEndian
            withUnsafeBytes(of: &value) { file.append(contentsOf: $0) }
        }
        file.append(records)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try file.write(to: url, options: .atomic)
    }
}
