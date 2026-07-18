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
    private let data: Data
    private let offsets: [UInt32]
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
    }

    // MARK: - 底层记录访问

    private func keyBytes(of index: Int) -> Data {
        let start = recordsBase + Int(offsets[index])
        let end = recordsBase + Int(offsets[index + 1]) - 4
        return data[start ..< end]
    }

    private func value(of index: Int) -> Double {
        let end = recordsBase + Int(offsets[index + 1])
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: end - 4, as: UInt32.self) }
        return Double(UInt32(littleEndian: raw)) / 10_000.0
    }

    private func lowerBound(_ target: [UInt8]) -> Int {
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

    private func exactValue(_ key: [UInt8]) -> Double? {
        let index = lowerBound(key)
        guard index < entryCount, keyBytes(of: index).elementsEqual(key) else { return nil }
        return value(of: index)
    }

    // MARK: - 查询

    /// 词 `word` 接在 `context`（句面已成部分）之后的转移得分。
    /// `isRear` 表示该词收尾整句（查 "词$" 条目）。
    public func score(context: String, word: String, isRear: Bool) -> Double {
        let maxQuery = penalties.collocationMaxLength - 1
        guard maxQuery > 0, !context.isEmpty, !word.isEmpty else { return penalties.nonCollocation }

        let contextTail = Array(context.unicodeScalars.suffix(maxQuery))
        let wordHead = Array(word.unicodeScalars.prefix(maxQuery))
        let wordBytes: [[UInt8]] = wordHead.map { Array(String($0).utf8) }

        var best = penalties.nonCollocation
        for suffixStart in 0 ..< contextTail.count {
            let contextLen = contextTail.count - suffixStart
            var key = Array(String(String.UnicodeScalarView(contextTail[suffixStart...])).utf8)
            // 逐字延长词头前缀：搭配串按前缀区间连续，一次 lowerBound 后线性推进即可，
            // 但实现从简：每个前缀一次精确查（key 数 ≤ 5×5）
            for prefixLen in 1 ... wordBytes.count {
                key += wordBytes[prefixLen - 1]
                guard let hit = exactValue(key) else { continue }
                let collocationLen = contextLen + prefixLen
                let coversWhole = suffixStart == 0 && prefixLen == wordBytes.count
                let penalty = (collocationLen >= penalties.collocationMinLength || coversWhole)
                    ? penalties.collocation : penalties.weakCollocation
                best = max(best, hit + penalty)
            }
        }

        if isRear, wordHead.count == word.unicodeScalars.count {
            let rearKey = Array(word.utf8) + [UInt8(ascii: "$")]
            if let hit = exactValue(rearKey) {
                best = max(best, hit + penalties.rear)
            }
        }
        return best
    }
}
