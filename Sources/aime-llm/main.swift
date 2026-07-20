import AimeLocalLLM
import AimePinyin
import Foundation

// 本地拼音 LLM 评测 CLI（形态 A）：解码逻辑在 AimeLocalLLM（与 daemon 共用），
// 这里只做评测协议与延迟统计。
//
// 用法:
//   swift run -c release aime-llm --suite testdata/pinyin_testset_large.tsv \
//     [--model <目录>] [--tokens <cjk_tokens.json>] [--beam 16] [--prior 0.0] \
//     [--fuzzy-penalty 3.0] [--limit N] [--out <tsv>] [--probe]
//
// 模型/词元表缺省走 PinyinLocalDecoder 的默认路径（App Support → HF 缓存 / bundle）。
// testdata/cjk_tokens.json 由 tokenizer 一次性导出，换模型需重导。
// 评测集角色（holdout 纪律，2026-07-20）：
//   pinyin_testset_large.tsv (560) 调参集 | pinyin_holdout.tsv (238) 开发集（已用于选参）
//   pinyin_holdout_fuzzy.tsv (238) 模糊噪声集（holdout 同句注入六组模糊替换，测容错）
//   pinyin_blind.tsv (147) 盲测集——只做最终验收，不得用于任何调参
//   pinyin_context.tsv (36) 上下文消歧集（三列：拼音\t期望\t上下文；--ignore-context 做对照）
// 当前默认参数：560 句 81.2% | 开发集 67.2% | 模糊 63.0% | 盲测 61.2% / p50 247ms
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
var convertRaw: String?  // 单句模式（可配 --context），手工验证用
var contextText: String?
var ignoreContext = false  // 三列 suite 忽略上下文列（对照组）

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
    case "--convert": convertRaw = args.removeFirst()
    case "--context": contextText = args.removeFirst()
    case "--ignore-context": ignoreContext = true
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
let decoder = try PinyinLocalDecoder(
    modelDir: resolvedModelDir, tokenTableURL: resolvedTokens, lexicon: lexicon)
decoder.beamWidth = beamWidth
decoder.priorWeight = priorW
decoder.fuzzyPenalty = fuzzyPenalty
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
for (index, testCase) in cases.enumerated() {
    let start = Date()
    var bestText = decoder.convert(
        raw: testCase.pinyin, fuzzyRuleIDs: fuzzyRuleIDs, context: testCase.context)?.sentence
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
