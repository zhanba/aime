import AimePinyin
import Foundation
import MLX
import MLXFast
import MLXNN
import MLXCommon
import Qwen3ASR

// 形态 A spike（Swift 版）：Qwen3-0.6B 拼音约束 beam 解码，批量 KV cache。
// 与 Python 参考实现（scratchpad/constrained_beam.py，560 句 78.4%）同一算法：
// 每步只允许"读音与格子当前位置吻合"的词元（多字词元跨位匹配），
// 得分 = LM logprob + priorW×log(词频) − 模糊备选惩罚，按已消耗字数归一剪枝。
// Swift 版的增量：KV cache 随 beam 批量前向 + 分叉 gather——这是延迟能否达标的关键。
//
// 用法:
//   swift run -c release aime-llm --model <HF snapshot 目录> --tokens testdata/cjk_tokens.json \
//     --suite testdata/pinyin_testset_large.tsv [--beam 8] [--prior 0.2] \
//     [--fuzzy-penalty 2.0] [--limit N]
//
// testdata/cjk_tokens.json 由 tokenizer 一次性导出（词表里 1–4 字纯汉字词元 + "句子：" 的
// prompt ids）；换模型需重导：mlx_lm 加载 tokenizer 后按 decode 单 id 过滤 CJK 即可。
// 结果（2026-07-19，560 句）：78.6% / p50 146ms（本地基线 50.9%，重排 65.0%，Python 参考 78.4%）

// MARK: - 参数

var modelDir: String?
var tokensPath: String?
var suitePath: String?
var beamWidth = 8
var priorW = 0.2
var fuzzyPenalty = 2.0
var limit: Int?
var outPath: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--model": modelDir = args.removeFirst()
    case "--tokens": tokensPath = args.removeFirst()
    case "--suite": suitePath = args.removeFirst()
    case "--beam": beamWidth = Int(args.removeFirst()) ?? 8
    case "--prior": priorW = Double(args.removeFirst()) ?? 0.2
    case "--fuzzy-penalty": fuzzyPenalty = Double(args.removeFirst()) ?? 2.0
    case "--limit": limit = Int(args.removeFirst())
    case "--out": outPath = args.removeFirst()
    default:
        FileHandle.standardError.write(Data("未知参数: \(arg)\n".utf8))
        exit(2)
    }
}
guard let modelDir, let tokensPath, let suitePath else {
    print("usage: aime-llm --model <dir> --tokens <cjk_tokens.json> --suite <tsv>")
    exit(2)
}

// MARK: - CJK 词元表（Python 一次性导出：纯汉字词元 id → 字串，及 prompt token ids）

struct TokenTable: Decodable {
    let promptIds: [Int]
    let tokens: [String: String]
}
let table = try JSONDecoder().decode(TokenTable.self, from: Data(contentsOf: URL(fileURLWithPath: tokensPath)))
struct CJKToken {
    let id: Int32
    let chars: [Character]
}
var byFirst: [Character: [CJKToken]] = [:]
for (idString, text) in table.tokens {
    let chars = Array(text)
    guard let first = chars.first, let id = Int32(idString) else { continue }
    byFirst[first, default: []].append(CJKToken(id: id, chars: chars))
}

// MARK: - 字表（词库单字条目：纯简体 + 校对注音 + 词频）

let engine = PinyinEngine()
guard let lexicon = engine.lexicon else {
    FileHandle.standardError.write(Data("词库未安装（aime-pinyin --build-lexicon）\n".utf8))
    exit(1)
}
var syllableChars: [String: [Character: Double]] = [:]
for syllable in PinyinTable.syllables {
    for entry in lexicon.exactMatches(key: syllable) where entry.word.count == 1 {
        let char = entry.word.first!
        let logWeight = log(entry.weight + 1)
        syllableChars[syllable, default: [:]][char] = max(syllableChars[syllable]?[char] ?? -1e9, logWeight)
    }
}

// MARK: - 格子（与 aime-pinyin --nbest 导出一致：主切分 + ≤2 边界变体，正解+模糊备选）

let fuzzyRuleIDs = SharedConfig.loadLLMConfig(includeAPIKey: false).enabledFuzzyRuleIDs

func hypotheses(_ syllables: [Syllable]) -> [[String]] {
    syllables.map { syllable in
        syllable.source == .partial
            ? Array(syllable.completions.prefix(3))
            : [syllable.text] + Array(syllable.fuzzyAlternates.prefix(3))
    }
}

func lattices(for raw: String) -> [[[String]]] {
    let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: fuzzyRuleIDs)
    guard segments.count == 1, case .pinyin(let syllables) = segments[0].kind else { return [] }
    var result = [hypotheses(syllables)]
    for variant in PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: fuzzyRuleIDs).prefix(2) {
        result.append(hypotheses(variant))
    }
    return result
}

/// 逐位置 {字: (log词频, 惩罚)}。hyps[0] 是正解读音（惩罚 0），其余备选 −fuzzyPenalty。
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

// MARK: - 模型

let began = Date()
let config = TextDecoderConfig.small  // 与 Qwen3-0.6B-4bit 逐项一致（ASR 0.6B 骨干即 Qwen3-0.6B）
let model = PinyinTextModel(config: config)  // vendored：修 MLXNN.RoPE 的 batch bug
try PinyinDecoderLoader.load(into: model, from: URL(fileURLWithPath: modelDir))
FileHandle.standardError.write(Data("模型加载 \(String(format: "%.1f", Date().timeIntervalSince(began)))s\n".utf8))

func lmHead(_ hidden: MLXArray) -> MLXArray {
    model.embedTokens.asLinear(hidden)
}

// prompt（"句子："）KV 只算一次，所有 case 复用
let promptArray = MLXArray(table.promptIds.map { Int32($0) }).expandedDimensions(axis: 0)
let (promptHidden, promptCache) = model(inputIds: promptArray)
let promptLogits = lmHead(promptHidden[0..., promptHidden.dim(1) - 1, 0...])  // [1, V]
eval(promptLogits)
if ProcessInfo.processInfo.environment["AIME_LLM_PROBE"] != nil {
    let probe = promptLogits[0].asType(.float32)
    let top = argSort(probe)[(-5)...]
    for id in top.asArray(Int32.self).reversed() {
        print("probe \(id) \(probe[Int(id)].item(Float.self))")
    }
    print("probe dtype: logits=\(promptLogits.dtype) hidden=\(promptHidden.dtype)")

    // 探针2：整段前向 vs 逐步 cache 前向，logits 应一致
    let extra: [Int32] = [35946, 101161]  // "我" "喜欢"
    let fullIds = table.promptIds.map { Int32($0) } + extra
    let (fullHidden, _) = model(inputIds: MLXArray(fullIds).expandedDimensions(axis: 0))
    let fullLast = lmHead(fullHidden[0..., fullHidden.dim(1) - 1, 0...]).asType(.float32)

    var stepCache = promptCache
    var stepLogits = promptLogits
    for token in extra {
        let (h, c) = model(inputIds: MLXArray([token]).reshaped([1, 1]), cache: stepCache)
        stepCache = c
        stepLogits = lmHead(h[0..., 0, 0...])
    }
    let stepLast = stepLogits.asType(.float32)
    let maxDiff = max(abs(fullLast - stepLast)).item(Float.self)
    print("probe2 整段 vs cache 最大差: \(maxDiff)")

    // 探针3：batch=2 + gather 置换后与 batch=1 一致
    let idx = MLXArray([0, 0].map { Int32($0) })
    var batchCache = promptCache.map { (take($0.0, idx, axis: 0), take($0.1, idx, axis: 0)) }
    let input2 = MLXArray([extra[0], extra[0]]).reshaped([2, 1])
    let (h2, c2) = model(inputIds: input2, cache: batchCache)
    batchCache = c2.map { (take($0.0, MLXArray([1].map { Int32($0) }), axis: 0), take($0.1, MLXArray([1].map { Int32($0) }), axis: 0)) }
    let (h3, _) = model(inputIds: MLXArray([extra[1]]).reshaped([1, 1]), cache: batchCache)
    let batchLast = lmHead(h3[0..., 0, 0...]).asType(.float32)
    let maxDiff2 = max(abs(fullLast - batchLast)).item(Float.self)
    print("probe3 batch+gather vs 整段 最大差: \(maxDiff2)")

    // 探针4：batch=2 前向的 row0 logits vs 单路径 cache 前向同 token —— 定位批量本身
    let (hSingle, _) = model(inputIds: MLXArray([extra[0]]).reshaped([1, 1]), cache: promptCache)
    let singleLogits = lmHead(hSingle[0..., 0, 0...]).asType(.float32)
    let batchRow0 = lmHead(h2[0..., 0, 0...]).asType(.float32)[0]
    let maxDiff3 = max(abs(singleLogits[0] - batchRow0)).item(Float.self)
    print("probe4 batch前向row0 vs 单路径: \(maxDiff3)")

    // 探针5：从 c2 取行的两种方式——take gather vs 范围切片
    for (name, picked) in [
        ("take[1]", c2.map { (take($0.0, MLXArray([Int32(1)]), axis: 0), take($0.1, MLXArray([Int32(1)]), axis: 0)) }),
        ("slice[1...1]", c2.map { ($0.0[1 ... 1], $0.1[1 ... 1]) }),
        ("take[0]", c2.map { (take($0.0, MLXArray([Int32(0)]), axis: 0), take($0.1, MLXArray([Int32(0)]), axis: 0)) }),
    ] {
        let (h, _) = model(inputIds: MLXArray([extra[1]]).reshaped([1, 1]), cache: picked)
        let logits = lmHead(h[0..., 0, 0...]).asType(.float32)
        let diff = max(abs(fullLast - logits)).item(Float.self)
        print("probe5 \(name): \(diff)")
    }

    // 探针6：行对称性——输入两行相同，各处 row0/row1 应相同
    let bcache = promptCache.map { (take($0.0, MLXArray([Int32(0), Int32(0)]), axis: 0), take($0.1, MLXArray([Int32(0), Int32(0)]), axis: 0)) }
    print("probe6 输入cache行差: \(max(abs(bcache[0].0[0] - bcache[0].0[1])).item(Float.self))")
    let (h2b, c2b) = model(inputIds: MLXArray([extra[0], extra[0]]).reshaped([2, 1]), cache: bcache)
    print("probe6 h2行差: \(max(abs(h2b[0] - h2b[1])).item(Float.self))")
    print("probe6 c2首层K行差: \(max(abs(c2b[0].0[0] - c2b[0].0[1])).item(Float.self))")
    print("probe6 c2末层K行差: \(max(abs(c2b[27].0[0] - c2b[27].0[1])).item(Float.self))")

    // 探针7：MLXFast SDPA 本体，batch=2 行相同（q seq=1, GQA 16/8）
    func synth(_ shape: [Int], scale: Float) -> MLXArray {
        let n = shape.reduce(1, *)
        return sin(MLXArray(0 ..< Int32(n)).asType(.float32) * scale).reshaped(shape).asType(.bfloat16)
    }
    let q1 = synth([1, 16, 1, 128], scale: 0.013)
    let k1 = synth([1, 8, 9, 128], scale: 0.007)
    let v1 = synth([1, 8, 9, 128], scale: 0.011)
    let q2 = concatenated([q1, q1], axis: 0)
    let k2 = concatenated([k1, k1], axis: 0)
    let v2 = concatenated([v1, v1], axis: 0)
    let out = MLXFast.scaledDotProductAttention(queries: q2, keys: k2, values: v2, scale: 0.0883, mask: nil)
    print("probe7 SDPA行差: \(max(abs(out[0] - out[1])).item(Float.self))")
    let outSingle = MLXFast.scaledDotProductAttention(queries: q1, keys: k1, values: v1, scale: 0.0883, mask: nil)
    print("probe7 SDPA row0 vs 单batch: \(max(abs(out[0] - outSingle[0])).item(Float.self))")

    // 探针8：其余批量原语（真权重的 embedding gather / 量化 matmul；合成权重的 RoPE / RMSNorm）
    let tok = MLXArray([Int32(35946), Int32(35946)]).reshaped([2, 1])
    let emb = model.embedTokens(tok)
    print("probe8 embedding行差: \(max(abs(emb[0] - emb[1])).item(Float.self))")
    let h1 = synth([1, 1, 1024], scale: 0.003)
    let hb = concatenated([h1, h1], axis: 0)
    let lm2 = lmHead(hb)
    print("probe8 量化matmul行差: \(max(abs(lm2[0] - lm2[1])).item(Float.self))")
    let ropeTest = MLXNN.RoPE(dimensions: 128, traditional: false, base: 1000000.0)
    let rq = synth([2, 16, 1, 128], scale: 0.017)
    let ropeOut = ropeTest(concatenated([rq[0...0], rq[0...0]], axis: 0), offset: 5)
    print("probe8 RoPE行差: \(max(abs(ropeOut[0] - ropeOut[1])).item(Float.self))")
    let norm = MLXNN.RMSNorm(dimensions: 1024, eps: 1e-6)
    let normOut = norm(hb)
    print("probe8 RMSNorm行差: \(max(abs(normOut[0] - normOut[1])).item(Float.self))")

    // 探针9：RoPE batch bug 的具体形态——row1 是不是被算成了 offset+seqLen
    let single5 = ropeTest(rq[0 ... 0], offset: 5)[0]
    let single6 = ropeTest(rq[0 ... 0], offset: 6)[0]
    print("probe9 batch_row1 vs offset+1: \(max(abs(ropeOut[1] - single6)).item(Float.self))")
    print("probe9 batch_row0 vs offset:   \(max(abs(ropeOut[0] - single5)).item(Float.self))")
    exit(0)
}

// MARK: - 约束 beam 解码（批量 KV cache：每步所有路径一次前向，分叉按父索引 gather）

struct Path {
    var text: String
    var pos: Int
    var score: Double
}

func decode(charMaps: [[Character: (prior: Double, penalty: Double)]]) -> (text: String, avgScore: Double)? {
    let n = charMaps.count
    // 逐位置合法词元（词元第 i 字 ∈ charMaps[pos+i]）
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
    var cache = promptCache
    var logits = promptLogits
    var finished: [Path] = []

    while !paths.isEmpty {
        let logits32 = logits.asType(.float32)
        let lse = logSumExp(logits32, axis: -1)  // [B]

        // 全部 (路径, 候选词元) 的 logprob 一次 gather
        var rows: [Int32] = []
        var cols: [Int32] = []
        var meta: [(parent: Int, token: CJKToken, bonus: Double)] = []
        for (b, path) in paths.enumerated() {
            for (token, prior, penalty) in allowed[path.pos] {
                rows.append(Int32(b))
                cols.append(Int32(token.id))
                meta.append((b, token, priorW * prior + penalty))
            }
        }
        if meta.isEmpty { break }
        let flat = logits32[MLXArray(rows), MLXArray(cols)] - lse[MLXArray(rows)]
        precondition(flat.size == meta.count, "花式索引应为逐对 gather: \(flat.shape) vs \(meta.count)")
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

        // beam 分叉：cache 按父索引 gather，下一步 [B,1] 批量前向
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

// MARK: - 评测

func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？.,!?"))
}

let tsv = try String(contentsOf: URL(fileURLWithPath: suitePath), encoding: .utf8)
var cases: [(pinyin: String, expected: String)] = []
for line in tsv.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2 else { continue }
    cases.append((String(parts[0]), String(parts[1])))
}
if let limit { cases = Array(cases.prefix(limit)) }

// 预热（Metal JIT），不计入延迟
if let first = cases.first, let maps = lattices(for: first.pinyin).first.flatMap(buildCharMaps) {
    _ = decode(charMaps: maps)
}

var hit = 0
var fallback = 0
var latencies: [Double] = []
var outLines: [String] = []
for (index, testCase) in cases.enumerated() {
    let start = Date()
    var bestText: String?
    var bestScore = -Double.infinity
    for lattice in lattices(for: testCase.pinyin) {
        guard let maps = buildCharMaps(lattice) else { continue }
        if let result = decode(charMaps: maps), result.avgScore > bestScore {
            bestText = result.text
            bestScore = result.avgScore
        }
    }
    latencies.append(Date().timeIntervalSince(start))
    if bestText == nil {
        fallback += 1
        bestText = engine.analyze(testCase.pinyin, fuzzyRuleIDs: fuzzyRuleIDs).localSentence
    }
    if let bestText, normalize(bestText) == normalize(testCase.expected) {
        hit += 1
    }
    outLines.append("\(testCase.pinyin)\t\(testCase.expected)\t\(bestText ?? "-")")
    if (index + 1) % 100 == 0 {
        FileHandle.standardError.write(Data("# \(index + 1)/\(cases.count) 当前句准 \(String(format: "%.1f%%", Double(hit) / Double(index + 1) * 100))\n".utf8))
    }
}

if let outPath {
    try outLines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
}
latencies.sort()
let total = cases.count
print("Swift 约束beam\(beamWidth) prior=\(priorW) fuzzyPenalty=\(fuzzyPenalty): \(hit)/\(total) = \(String(format: "%.1f%%", Double(hit) / Double(total) * 100))  死路兜底 \(fallback)")
if !latencies.isEmpty {
    print(String(
        format: "延迟: p50=%.0fms p90=%.0fms",
        latencies[total / 2] * 1000,
        latencies[min(total - 1, total * 9 / 10)] * 1000
    ))
}
