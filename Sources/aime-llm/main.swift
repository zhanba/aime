import AimeLocalLLM
import AimePinyin
import Foundation
import Qwen3ASR

// 本地拼音 LLM 评测 CLI（形态 A）：解码逻辑在 AimeLocalLLM（与 daemon 共用），
// 这里只做评测协议与延迟统计。
//
// 用法:
//   swift run -c release aime-llm --suite testdata/pinyin_testset_large.tsv \
//     [--model <目录>] [--tokens <cjk_tokens.json>] [--beam 16] [--prior 0.0] \
//     [--fuzzy-penalty 3.0] [--neutral-max 4] [--limit N] [--out <tsv>] [--probe]
//
// 模型/词元表缺省走 PinyinLocalDecoder 的默认路径（App Support → HF 缓存 / bundle）。
// testdata/cjk_tokens.json 由 tokenizer 一次性导出，换模型需重导。
// 评测集角色（holdout 纪律，2026-07-20）：
//   pinyin_testset_large.tsv (560) 调参集 | pinyin_holdout.tsv (238) 开发集（已用于选参）
//   pinyin_holdout_fuzzy.tsv (238) 模糊噪声集（holdout 同句注入六组模糊替换，测容错）
//   pinyin_blind.tsv (147) 盲测集——只做最终验收，不得用于任何调参
//   pinyin_context.tsv (36) 上下文消歧集（三列：拼音\t期望\t上下文；--ignore-context 做对照）
//   pinyin_short_dev.tsv (50) 常用短词调参集（无上下文裸解，调 --neutral-max 用）
//   pinyin_short_holdout.tsv (45) 常用短词验收集——不得用于调参
// 当前默认 = Qwen3-1.7B-4bit（2026-07-21 由 0.6B 升级，--model-size small 走 0.6B 对照）：
// 调参 83.9% | 开发 68.1% | 模糊 67.6% | 盲测 66.0% / p50 ~500ms（0.6B 同参 81.4/67.2/63.0/62.6，p50 247ms）
// （跨格子择优用整句 sum 而非逐字 avg，根治常用整音节被拆成人名/错词，如 xuanzhong→徐安忠）
// 上下文注入（2026-07-20）：消歧集 44.4% → 66.7%，无上下文路径零漂移，开销 ~6ms

var modelDir: String?
var tokensPath: String?
var suitePath: String?
var beamWidth = 16
var priorW = 0.0
var fuzzyPenalty = 3.0
var limit: Int?
var outPath: String?
var probeMode = false
var modelSize = "large"  // large=1.7B(.large config，线上默认) | small=0.6B(.small config，对照用)
var convertRaw: String?  // 单句模式（可配 --context），手工验证用
var contextText: String?
var ignoreContext = false  // 三列 suite 忽略上下文列（对照组）
var neutralMax: Int?  // 中性前缀「嗯」的音节数上限（0=关，缺省用解码器默认）

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--model": modelDir = args.removeFirst()
    case "--tokens": tokensPath = args.removeFirst()
    case "--suite": suitePath = args.removeFirst()
    case "--beam": beamWidth = Int(args.removeFirst()) ?? 16
    case "--prior": priorW = Double(args.removeFirst()) ?? 0.2
    case "--fuzzy-penalty": fuzzyPenalty = Double(args.removeFirst()) ?? 2.0
    case "--limit": limit = Int(args.removeFirst())
    case "--out": outPath = args.removeFirst()
    case "--probe": probeMode = true
    case "--model-size": modelSize = args.removeFirst()
    case "--convert": convertRaw = args.removeFirst()
    case "--context": contextText = args.removeFirst()
    case "--ignore-context": ignoreContext = true
    case "--neutral-max": neutralMax = Int(args.removeFirst())
    default:
        FileHandle.standardError.write(Data("未知参数: \(arg)\n".utf8))
        exit(2)
    }
}

let engine = PinyinEngine()
guard let lexicon = engine.lexicon else {
    FileHandle.standardError.write(Data("词库未安装（aime-pinyin --build-lexicon）\n".utf8))
    exit(1)
}
guard let resolvedModelDir = modelDir.map(URL.init(fileURLWithPath:)) ?? PinyinLocalDecoder.defaultModelDir() else {
    FileHandle.standardError.write(Data("找不到模型目录（--model 或 HF 缓存/App Support）\n".utf8))
    exit(1)
}
let repoTokens = URL(fileURLWithPath: "testdata/cjk_tokens.json")
let resolvedTokens = tokensPath.map(URL.init(fileURLWithPath:))
    ?? PinyinLocalDecoder.defaultTokenTableURL()
    ?? (FileManager.default.fileExists(atPath: repoTokens.path) ? repoTokens : nil)
guard let resolvedTokens else {
    FileHandle.standardError.write(Data("找不到词元表（--tokens / App Support / testdata）\n".utf8))
    exit(1)
}

let began = Date()
let textConfig: TextDecoderConfig = modelSize == "large" ? .large : .small
let decoder = try PinyinLocalDecoder(
    modelDir: resolvedModelDir, tokenTableURL: resolvedTokens, lexicon: lexicon,
    textConfig: textConfig)
decoder.beamWidth = beamWidth
decoder.priorWeight = priorW
decoder.fuzzyPenalty = fuzzyPenalty
if let neutralMax { decoder.neutralPrefixMaxSyllables = neutralMax }
FileHandle.standardError.write(Data("模型加载 \(String(format: "%.1f", Date().timeIntervalSince(began)))s（\(resolvedModelDir.path)）\n".utf8))

if probeMode {
    decoder.runDiagnosticProbes()
    exit(0)
}

let fuzzyRuleIDs = SharedConfig.loadLLMConfig(includeAPIKey: false).enabledFuzzyRuleIDs

if let convertRaw {
    decoder.warmup()
    let start = Date()
    let result = decoder.convert(raw: convertRaw, fuzzyRuleIDs: fuzzyRuleIDs, context: contextText)
    let ms = Date().timeIntervalSince(start) * 1000
    print("\(result?.sentence ?? "<无合法路径>")  (\(String(format: "%.0f", ms))ms\(contextText.map { "，上下文「\($0)」" } ?? "，无上下文"))")
    exit(0)
}

guard let suitePath else {
    print("usage: aime-llm --suite <tsv> | --convert <raw> [--context <text>] | --probe")
    exit(2)
}

func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？.,!?"))
}

// 两列 = 拼音\t期望；三列 = 拼音\t期望\t上下文（上下文条件评测，如 pinyin_context.tsv）
let tsv = try String(contentsOf: URL(fileURLWithPath: suitePath), encoding: .utf8)
var cases: [(pinyin: String, expected: String, context: String?)] = []
for line in tsv.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 2)
    guard parts.count >= 2 else { continue }
    let context = parts.count == 3 && !ignoreContext ? String(parts[2]) : nil
    cases.append((String(parts[0]), String(parts[1]), context))
}
if let limit { cases = Array(cases.prefix(limit)) }

decoder.warmup()  // Metal JIT 不计入延迟

var hit = 0
var fallback = 0
var latencies: [Double] = []
var outLines: [String] = []
// 置顶仲裁评测：无上下文 且 音节数 ≤ maxN 的短输入，LLM 结果不在句引擎
// beam 前 2 名则回退 Viterbi 首选（全集数据表明不加长度条件会错杀 LLM 的
// 整句收益：84.1%→63.6%；短词集上前 2 名门禁零成本）。按 maxN 分别统计选参。
let arbitrateNs = [2, 3, 4]
var hitViterbi = 0
var hitArbitrated = [Int: Int](uniqueKeysWithValues: arbitrateNs.map { ($0, 0) })
var demoted = [Int: Int](uniqueKeysWithValues: arbitrateNs.map { ($0, 0) })
var demotedGain = [Int: Int](uniqueKeysWithValues: arbitrateNs.map { ($0, 0) })  // 降级救对
var demotedLoss = [Int: Int](uniqueKeysWithValues: arbitrateNs.map { ($0, 0) })  // 降级错杀
for (index, testCase) in cases.enumerated() {
    let start = Date()
    var bestText = decoder.convert(
        raw: testCase.pinyin, fuzzyRuleIDs: fuzzyRuleIDs, context: testCase.context)?.sentence
    latencies.append(Date().timeIntervalSince(start))
    let analysis = engine.analyze(testCase.pinyin, fuzzyRuleIDs: fuzzyRuleIDs)
    if bestText == nil {
        fallback += 1
        bestText = analysis.localSentence
    }
    let expected = normalize(testCase.expected)
    let llmRight = bestText.map { normalize($0) == expected } ?? false
    if llmRight { hit += 1 }
    let viterbiRight = analysis.localSentence.map { normalize($0) == expected } ?? false
    if viterbiRight { hitViterbi += 1 }
    let syllableCount = analysis.segments.reduce(0) { sum, segment in
        if case .pinyin(let syllables) = segment.kind { return sum + syllables.count }
        return sum
    }
    let top2 = Set(analysis.localNBest.prefix(2).map(normalize))
    for maxN in arbitrateNs {
        let shortNoContext = testCase.context == nil && syllableCount <= maxN
        let gated = shortNoContext && !top2.isEmpty
            && !(bestText.map { top2.contains(normalize($0)) } ?? true)
        if gated {
            demoted[maxN]! += 1
            if viterbiRight { hitArbitrated[maxN]! += 1 }
            if viterbiRight, !llmRight { demotedGain[maxN]! += 1 }
            if llmRight, !viterbiRight { demotedLoss[maxN]! += 1 }
        } else {
            if llmRight { hitArbitrated[maxN]! += 1 }
        }
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
print("Viterbi 对照: \(hitViterbi)/\(total) = \(String(format: "%.1f%%", Double(hitViterbi) / Double(total) * 100))")
for maxN in arbitrateNs {
    print("仲裁 maxN=\(maxN): \(hitArbitrated[maxN]!)/\(total) = \(String(format: "%.1f%%", Double(hitArbitrated[maxN]!) / Double(total) * 100))  降级 \(demoted[maxN]!)（救对 \(demotedGain[maxN]!) 错杀 \(demotedLoss[maxN]!)）")
}
if !latencies.isEmpty {
    print(String(
        format: "延迟: p50=%.0fms p90=%.0fms",
        latencies[total / 2] * 1000,
        latencies[min(total - 1, total * 9 / 10)] * 1000
    ))
}
