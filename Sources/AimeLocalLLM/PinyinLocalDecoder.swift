import AimePinyin
import Foundation
import MLX
import MLXCommon
import Qwen3ASR

// 本地拼音 LLM（形态 A）：Qwen3-0.6B-4bit 拼音约束 beam 解码的可复用封装。
// daemon（XPC 服务）与 aime-llm（评测 CLI）共用，保证评测数字就是线上行为。
// 默认超参经 holdout 验证（2026-07-20）：调参集 560 句 81.2%、开发集 238 句 67.2%、
// 模糊噪声集 63.0%、盲测集 147 句 61.2% / p50 247ms（各集本地 Viterbi 基线 50.9%/41.2%/40.8%/31.3%）。
// prior 是调参集过拟合产物（holdout 上负收益）故归零；fuzzyPenalty 每 +1 约拿 1 分干净换 2 分
// 模糊容错，3.0 是均衡点；beam 16→8 省 60ms 但模糊集掉 2.5pp。非线程安全——调用方负责串行。

public struct CJKToken: Sendable {
    public let id: Int32
    public let chars: [Character]
}

public final class PinyinLocalDecoder {
    public var beamWidth = 16
    public var priorWeight = 0.0
    public var fuzzyPenalty = 3.0

    public let model: PinyinTextModel
    let byFirst: [Character: [CJKToken]]
    let promptIds: [Int32]
    let syllableChars: [String: [Character: Double]]
    let promptCache: [(MLXArray, MLXArray)]
    let promptLogits: MLXArray

    struct TokenTable: Decodable {
        let promptIds: [Int]
        let tokens: [String: String]
    }

    public init(modelDir: URL, tokenTableURL: URL, lexicon: Lexicon) throws {
        let table = try JSONDecoder().decode(
            TokenTable.self, from: Data(contentsOf: tokenTableURL))
        var byFirst: [Character: [CJKToken]] = [:]
        for (idString, text) in table.tokens {
            let chars = Array(text)
            guard let first = chars.first, let id = Int32(idString) else { continue }
            byFirst[first, default: []].append(CJKToken(id: id, chars: chars))
        }
        self.byFirst = byFirst
        self.promptIds = table.promptIds.map { Int32($0) }

        // 字表：词库单字条目（纯简体+校对注音+词频）。pypinyin 类全字表会混入
        // 繁体与生僻读音——spike 实证垃圾字挤掉正确字（贪心 15%）
        var syllableChars: [String: [Character: Double]] = [:]
        for syllable in PinyinTable.syllables {
            for entry in lexicon.exactMatches(key: syllable) where entry.word.count == 1 {
                let char = entry.word.first!
                let logWeight = log(entry.weight + 1)
                syllableChars[syllable, default: [:]][char] =
                    max(syllableChars[syllable]?[char] ?? -1e9, logWeight)
            }
        }
        self.syllableChars = syllableChars

        self.model = PinyinTextModel(config: .small)
        try PinyinDecoderLoader.load(into: model, from: modelDir)

        // prompt（"句子："）KV 只算一次，所有请求复用
        let promptArray = MLXArray(promptIds).expandedDimensions(axis: 0)
        let (promptHidden, promptCache) = model(inputIds: promptArray)
        self.promptCache = promptCache
        self.promptLogits = model.embedTokens.asLinear(
            promptHidden[0..., promptHidden.dim(1) - 1, 0...])
        eval(self.promptLogits)
    }

    /// 首次前向含 Metal JIT（可达秒级），加载后调用一次把它排除在请求路径外。
    public func warmup() {
        _ = convert(raw: "nihao", fuzzyRuleIDs: [], context: "你好")
    }

    // MARK: - 上下文（光标前文）注入

    /// 上下文只取末尾这么多字：更早的内容对下一句的约束弱，还拖长 prefill。
    static let maxContextChars = 24

    /// 无 BPE tokenizer，用 CJK 词元表贪心最长匹配编码；表外字符（英文/标点/数字）跳过。
    /// 上下文只影响先验不进输出，丢字符可接受。
    static func encodeContext(_ text: String, byFirst: [Character: [CJKToken]]) -> [Int32] {
        let chars = Array(text.suffix(maxContextChars))
        var ids: [Int32] = []
        var i = 0
        while i < chars.count {
            var best: CJKToken?
            for token in byFirst[chars[i]] ?? [] {
                guard token.chars.count > (best?.chars.count ?? 0),
                      i + token.chars.count <= chars.count else { continue }
                if zip(token.chars, chars[i ..< i + token.chars.count]).allSatisfy(==) {
                    best = token
                }
            }
            if let best {
                ids.append(best.id)
                i += best.chars.count
            } else {
                i += 1
            }
        }
        return ids
    }

    /// 上下文 prefill：接在固定 prompt 的 KV 后（batch=1、带 offset，vendored RoPE/mask 已支持）。
    /// 每请求一次前向，~20 token 量级，开销远小于 beam 解码本身。
    func contextState(_ context: String?) -> (cache: [(MLXArray, MLXArray)], logits: MLXArray) {
        guard let context, !context.isEmpty else { return (promptCache, promptLogits) }
        let ids = Self.encodeContext(context, byFirst: byFirst)
        guard !ids.isEmpty else { return (promptCache, promptLogits) }
        let input = MLXArray(ids).expandedDimensions(axis: 0)
        let (hidden, cache) = model(inputIds: input, cache: promptCache)
        let logits = lmHead(hidden[0..., hidden.dim(1) - 1, 0...])
        eval(logits)
        return (cache, logits)
    }

    public func lmHead(_ hidden: MLXArray) -> MLXArray {
        model.embedTokens.asLinear(hidden)
    }

    // MARK: - 格子（与 aime-pinyin --nbest 导出一致）

    static func hypotheses(_ syllables: [Syllable]) -> [[String]] {
        syllables.map { syllable in
            syllable.source == .partial
                ? Array(syllable.completions.prefix(3))
                : [syllable.text] + Array(syllable.fuzzyAlternates.prefix(3))
        }
    }

    static func lattices(for raw: String, fuzzyRuleIDs: Set<String>) -> [[[String]]] {
        let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: fuzzyRuleIDs)
        guard segments.count == 1, case .pinyin(let syllables) = segments[0].kind else { return [] }
        var result = [hypotheses(syllables)]
        for variant in PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: fuzzyRuleIDs).prefix(2) {
            result.append(hypotheses(variant))
        }
        return result
    }

    /// 逐位置 {字: (log词频, 惩罚)}。hyps[0] 是正解读音（惩罚 0），其余备选 −fuzzyPenalty
    /// （对齐本地层"可信度乘进得分"——不罚的话"把门关上"会解成"蒙古鞍山"）。
    func buildCharMaps(_ lattice: [[String]]) -> [[Character: (prior: Double, penalty: Double)]]? {
        var maps: [[Character: (prior: Double, penalty: Double)]] = []
        for hyps in lattice {
            var merged: [Character: (prior: Double, penalty: Double)] = [:]
            for (rank, syllable) in hyps.enumerated() {
                let penalty = rank == 0 ? 0.0 : -fuzzyPenalty
                for (char, logWeight) in syllableChars[syllable] ?? [:] {
                    if let existing = merged[char],
                       existing.penalty > penalty || (existing.penalty == penalty && existing.prior >= logWeight) {
                        continue
                    }
                    merged[char] = (logWeight, penalty)
                }
            }
            if merged.isEmpty { return nil }
            maps.append(merged)
        }
        return maps
    }

    // MARK: - 约束 beam 解码（批量 KV cache：每步全部路径一次前向，分叉按父索引 gather）

    struct Path {
        var text: String
        var pos: Int
        var score: Double
    }

    /// 多条格子（主切分+边界变体）各解一次，按字均分择优。无合法路径返回 nil。
    /// context = 光标前文，注入为生成前缀（不进输出）；nil/空 = 无上下文。
    public func convert(
        raw: String, fuzzyRuleIDs: Set<String>, context: String? = nil
    ) -> (sentence: String, avgScore: Double)? {
        let start = contextState(context)
        var best: (sentence: String, avgScore: Double)?
        for lattice in Self.lattices(for: raw, fuzzyRuleIDs: fuzzyRuleIDs) {
            guard let maps = buildCharMaps(lattice) else { continue }
            if let result = decode(charMaps: maps, start: start),
               result.avgScore > (best?.avgScore ?? -.infinity) {
                best = result
            }
        }
        return best
    }

    func decode(
        charMaps: [[Character: (prior: Double, penalty: Double)]],
        start: (cache: [(MLXArray, MLXArray)], logits: MLXArray)
    ) -> (sentence: String, avgScore: Double)? {
        let n = charMaps.count
        var allowed: [[(token: CJKToken, prior: Double, penalty: Double)]] = []
        for pos in 0 ..< n {
            var list: [(CJKToken, Double, Double)] = []
            for first in charMaps[pos].keys {
                for token in byFirst[first] ?? [] {
                    guard pos + token.chars.count <= n else { continue }
                    var prior = 0.0
                    var penalty = 0.0
                    var ok = true
                    for (i, char) in token.chars.enumerated() {
                        guard let entry = charMaps[pos + i][char] else {
                            ok = false
                            break
                        }
                        prior += entry.prior
                        penalty += entry.penalty
                    }
                    if ok { list.append((token, prior, penalty)) }
                }
            }
            allowed.append(list)
        }

        var paths = [Path(text: "", pos: 0, score: 0)]
        var cache = start.cache
        var logits = start.logits
        var finished: [Path] = []

        while !paths.isEmpty {
            let logits32 = logits.asType(.float32)
            let lse = logSumExp(logits32, axis: -1)  // [B]

            var rows: [Int32] = []
            var cols: [Int32] = []
            var meta: [(parent: Int, token: CJKToken, bonus: Double)] = []
            for (b, path) in paths.enumerated() {
                for (token, prior, penalty) in allowed[path.pos] {
                    rows.append(Int32(b))
                    cols.append(Int32(token.id))
                    meta.append((b, token, priorWeight * prior + penalty))
                }
            }
            if meta.isEmpty { break }
            let flat = logits32[MLXArray(rows), MLXArray(cols)] - lse[MLXArray(rows)]
            let logProbs = flat.asArray(Float.self)

            var expansions: [(parent: Int, token: CJKToken, pos: Int, score: Double)] = []
            expansions.reserveCapacity(meta.count)
            for (i, m) in meta.enumerated() {
                let parent = paths[m.parent]
                expansions.append((
                    m.parent, m.token,
                    parent.pos + m.token.chars.count,
                    parent.score + Double(logProbs[i]) + m.bonus
                ))
            }
            // 剪枝：按每字均分比较不同进度的路径
            expansions.sort { $0.score / Double(max($0.pos, 1)) > $1.score / Double(max($1.pos, 1)) }

            var nextPaths: [Path] = []
            var parents: [Int32] = []
            var nextTokens: [Int32] = []
            for expansion in expansions {
                let text = paths[expansion.parent].text + String(expansion.token.chars)
                if expansion.pos == n {
                    finished.append(Path(text: text, pos: n, score: expansion.score))
                } else if nextPaths.count < beamWidth {
                    nextPaths.append(Path(text: text, pos: expansion.pos, score: expansion.score))
                    parents.append(Int32(expansion.parent))
                    nextTokens.append(expansion.token.id)
                }
            }
            if finished.count >= beamWidth || nextPaths.isEmpty { break }

            let parentIndex = MLXArray(parents)
            cache = cache.map { (take($0.0, parentIndex, axis: 0), take($0.1, parentIndex, axis: 0)) }
            let input = MLXArray(nextTokens).reshaped([nextPaths.count, 1])
            let (hidden, newCache) = model(inputIds: input, cache: cache)
            cache = newCache
            logits = lmHead(hidden[0..., 0, 0...])  // [B, V]
            paths = nextPaths
        }

        guard let best = finished.max(by: { $0.score < $1.score }) else { return nil }
        return (best.text, best.score / Double(n))
    }

    // MARK: - 默认资源路径

    static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
    }

    /// 模型目录：App Support/aime/models/Qwen3-0.6B-4bit 优先（未来下载分发的落点），
    /// 开发机回退 HF 缓存 snapshot。
    public static func defaultModelDir() -> URL? {
        let managed = appSupportDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("Qwen3-0.6B-4bit", isDirectory: true)
        if FileManager.default.fileExists(atPath: managed.appendingPathComponent("model.safetensors").path) {
            return managed
        }
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots")
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: hub, includingPropertiesForKeys: nil) else { return nil }
        return snapshots.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.safetensors").path)
        }
    }

    /// 词元表：App Support/aime/cjk_tokens.json 优先，回退 app bundle Resources。
    public static func defaultTokenTableURL() -> URL? {
        let managed = appSupportDir.appendingPathComponent("cjk_tokens.json")
        if FileManager.default.fileExists(atPath: managed.path) { return managed }
        return Bundle.main.url(forResource: "cjk_tokens", withExtension: "json")
    }
}
