import AimePinyin
import Foundation

// 拼音引擎评测 CLI：
//   调试单条：  swift run aime-pinyin nihsoshijie [--context "..."]
//   准确率：    swift run aime-pinyin --suite testdata/pinyin_testset.tsv
// LLM 配置读共享 suite（app 设置里配好后自动镜像）；无 key 时只输出切分分析。
// API Key 在钥匙串：本 CLI 无稳定签名，每次重编译读取都会弹授权，
// 建议用 AIME_API_KEY=sk-xxx 环境变量覆盖。

var inputs: [String] = []
var suitePath: String?
var context: String?
var buildDir: String?
var noLLM = false
var lambdaOverride: Double?
var dampOverride: Double?
var gramPath: String?
var gramWeightOverride: Double?
var beamOverride: Int?
var predictMode = false
var nBest: Int?
var dumpChars = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--suite": suitePath = args.removeFirst()
    case "--context": context = args.removeFirst()
    case "--build-lexicon": buildDir = args.removeFirst()
    case "--no-llm": noLLM = true
    case "--lambda": lambdaOverride = Double(args.removeFirst())
    case "--char-damp": dampOverride = Double(args.removeFirst())
    case "--gram": gramPath = args.removeFirst()
    case "--predict": predictMode = true
    case "--gram-weight": gramWeightOverride = Double(args.removeFirst())
    case "--beam": beamOverride = Int(args.removeFirst())
    case "--nbest": nBest = Int(args.removeFirst())
    case "--dump-chars": dumpChars = true
    default: inputs.append(arg)
    }
}

// 词库编译模式：aime-pinyin --build-lexicon <rime-frost/cn_dicts 目录>
if let buildDir {
    let dir = URL(fileURLWithPath: buildDir)
    let dicts = ["8105.dict.yaml", "base.dict.yaml"].map { dir.appendingPathComponent($0) }
    let began = Date()
    let (kept, droppedCount) = try Lexicon.compile(rimeDicts: dicts, to: Lexicon.defaultURL)
    print("词库编译完成: 收录 \(kept) 条, 丢弃 \(droppedCount) 条, 耗时 \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
    print("输出: \(Lexicon.defaultURL.path)")
    exit(0)
}

let engine = gramPath.map { PinyinEngine(gramURL: URL(fileURLWithPath: $0)) } ?? PinyinEngine()
if let lambdaOverride { engine.lambda = lambdaOverride }
if let dampOverride { engine.singleCharDamp = dampOverride }
if let gramWeightOverride { engine.gramWeight = gramWeightOverride }
if let beamOverride { engine.beamWidth = beamOverride }
if engine.lexicon == nil {
    FileHandle.standardError.write(Data("提示: 词库未安装（--build-lexicon 编译），本地整句/词候选不可用\n".utf8))
}
if gramPath != nil {
    FileHandle.standardError.write(Data("语法模型: \(engine.gram != nil ? "已加载" : "加载失败")\n".utf8))
}

let config = SharedConfig.loadLLMConfig()
let converter = PinyinConverter()

func analyze(_ raw: String) -> [PinyinSegment] {
    let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs)
    return segments
}

// 联想调试：aime-pinyin --predict <中文上下文...>
if predictMode {
    guard engine.gram != nil else {
        print("语法模型未安装")
        exit(1)
    }
    for context in inputs {
        print("\(context) → \(engine.predictions(context: context).joined(separator: " | "))")
    }
    exit(0)
}

// 字表导出（约束解码实验用）：音节 \t 字 \t 词频（词库单字条目，纯简体+校对注音）
if dumpChars {
    guard let lexicon = engine.lexicon else {
        FileHandle.standardError.write(Data("词库未安装\n".utf8))
        exit(1)
    }
    for syllable in PinyinTable.syllables.sorted() {
        for entry in lexicon.exactMatches(key: syllable) where entry.word.count == 1 {
            print("\(syllable)\t\(entry.word)\t\(entry.weight)")
        }
    }
    exit(0)
}

if let suitePath {
    let tsv = try String(contentsOf: URL(fileURLWithPath: suitePath), encoding: .utf8)
    var cases: [(pinyin: String, expected: String)] = []
    for line in tsv.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { continue }
        cases.append((String(parts[0]), String(parts[1])))
    }
    // n-best 导出模式（JSONL，重排/约束解码实验的输入）：
    // {"pinyin","expected","candidates":[{"text","score"}],"lattices":[[[音节假设]]]}
    // lattices = 主切分 + 边界变体（≤3 条），每条是逐位置的假设列表（正解+模糊音，partial 用补全）
    if let nBest {
        struct ExportCandidate: Codable { var text: String; var score: Double }
        struct ExportCase: Codable {
            var pinyin: String
            var expected: String
            var candidates: [ExportCandidate]
            var lattices: [[[String]]]
        }
        func hypotheses(_ syllables: [Syllable]) -> [[String]] {
            syllables.map { syllable in
                syllable.source == .partial
                    ? Array(syllable.completions.prefix(3))
                    : [syllable.text] + Array(syllable.fuzzyAlternates.prefix(3))
            }
        }
        let encoder = JSONEncoder()
        for testCase in cases {
            let candidates = engine.localNBest(testCase.pinyin, fuzzyRuleIDs: config.enabledFuzzyRuleIDs, limit: nBest)
                .map { ExportCandidate(text: $0.sentence, score: $0.score) }
            var lattices: [[[String]]] = []
            let segments = PinyinSegmenter.segment(testCase.pinyin, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs)
            if segments.count == 1, case .pinyin(let syllables) = segments[0].kind {
                lattices.append(hypotheses(syllables))
                for variant in PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs).prefix(2) {
                    lattices.append(hypotheses(variant))
                }
            }
            let record = ExportCase(
                pinyin: testCase.pinyin, expected: testCase.expected,
                candidates: candidates, lattices: lattices
            )
            print(String(data: try encoder.encode(record), encoding: .utf8)!)
        }
        exit(0)
    }
    guard noLLM || !config.apiKey.isEmpty else {
        print("未配置 API key（aime 设置 → 精修），无法跑 LLM 准确率")
        exit(1)
    }
    var correct = 0
    var localCorrect = 0
    var covered = 0
    var latencies: [Double] = []
    // 字准率累计：Σ(期望长 − 编辑距离) / Σ期望长
    var localCharHit = 0
    var llmCharHit = 0
    var charTotal = 0
    let normalize = { (s: String) in
        s.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？.,!?"))
    }
    func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0 ... b.count)
        for i in 1 ... max(a.count, 1) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1 ... max(b.count, 1) where !b.isEmpty {
                current[j] = min(
                    previous[j] + 1, current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return a.isEmpty ? b.count : (b.isEmpty ? a.count : previous[b.count])
    }
    // 命中字数 = 期望长 − 编辑距离（截断到 0）
    func charHits(_ got: String?, expected: String) -> Int {
        let expectedChars = Array(normalize(expected))
        guard let got else { return 0 }
        return max(0, expectedChars.count - editDistance(Array(normalize(got)), expectedChars))
    }
    for (index, testCase) in cases.enumerated() {
        // 本地整句命中（词库层底线质量）
        let local: String? = engine.analyze(testCase.pinyin, fuzzyRuleIDs: config.enabledFuzzyRuleIDs).localSentence
        let localHit = local.map { normalize($0) == normalize(testCase.expected) } ?? false
        if localHit { localCorrect += 1 }
        charTotal += normalize(testCase.expected).count
        localCharHit += charHits(local, expected: testCase.expected)
        if noLLM {
            if !localHit {
                print("[\(index + 1)/\(cases.count)] ✗ 本地: \(local ?? "-")  期望: \(testCase.expected)")
            }
            continue
        }
        let began = Date()
        do {
            let conversion = try await converter.convert(
                raw: testCase.pinyin, context: nil, userDictEntries: [], config: config
            )
            let cost = Date().timeIntervalSince(began)
            latencies.append(cost)
            let hit = normalize(conversion.best) == normalize(testCase.expected)
            if hit { correct += 1 }
            llmCharHit += charHits(conversion.best, expected: testCase.expected)
            // 句级覆盖：首选/备选/本地整句 任一命中
            var sentenceCandidates = [conversion.best]
            if let alternative = conversion.alternative { sentenceCandidates.append(alternative) }
            if let local { sentenceCandidates.append(local) }
            if sentenceCandidates.contains(where: { normalize($0) == normalize(testCase.expected) }) {
                covered += 1
            }
            print("[\(index + 1)/\(cases.count)] \(hit ? "✓" : "✗") \(testCase.pinyin)")
            if !hit {
                print("    期望: \(testCase.expected)")
                print("    得到: \(conversion.best)\(conversion.alternative.map { "（备选: \($0)）" } ?? "")")
            }
        } catch {
            print("[\(index + 1)/\(cases.count)] ✗ \(testCase.pinyin)  错误: \(error.localizedDescription)")
        }
    }
    let sorted = latencies.sorted()
    print("\n===== 汇总 =====")
    if engine.lexicon != nil {
        print("本地整句命中率: \(localCorrect)/\(cases.count) (\(String(format: "%.1f%%", Double(localCorrect) / Double(cases.count) * 100)))")
        if charTotal > 0 {
            print("本地字准率: \(localCharHit)/\(charTotal) (\(String(format: "%.1f%%", Double(localCharHit) / Double(charTotal) * 100)))")
        }
    }
    if noLLM { exit(0) }
    print("首选准确率: \(correct)/\(cases.count) (\(String(format: "%.0f%%", Double(correct) / Double(cases.count) * 100)))")
    if charTotal > 0 {
        print("首选字准率: \(llmCharHit)/\(charTotal) (\(String(format: "%.1f%%", Double(llmCharHit) / Double(charTotal) * 100)))")
    }
    print("句级候选覆盖率: \(covered)/\(cases.count) (\(String(format: "%.0f%%", Double(covered) / Double(cases.count) * 100)))")
    if !sorted.isEmpty {
        print(String(format: "延迟: p50=%.2fs p90=%.2fs", sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)]))
    }
} else if !inputs.isEmpty {
    for raw in inputs {
        let result = engine.analyze(raw, fuzzyRuleIDs: config.enabledFuzzyRuleIDs)
        let segments = result.segments
        print("输入: \(raw)")
        print("切分: \(PinyinPromptBuilder.describe(segments: segments))")
        if let local = result.localSentence {
            print("本地整句: \(local)")
        }
        if !result.wordCandidates.isEmpty {
            let words = result.wordCandidates.prefix(9).map(\.word).joined(separator: " | ")
            print("词候选: \(words)")
        }
        if !config.apiKey.isEmpty {
            do {
                let began = Date()
                let conversion = try await converter.convert(
                    raw: raw, segments: segments, context: context,
                    userDictEntries: UserDictionary.shared.topEntries(), config: config
                )
                print("首选: \(conversion.best)  (\(String(format: "%.2f", Date().timeIntervalSince(began)))s)")
                if let alternative = conversion.alternative {
                    print("备选: \(alternative)")
                }
            } catch {
                print("转换失败: \(error.localizedDescription)")
            }
        }
    }
} else {
    print("usage: aime-pinyin <拼音串...> [--context text] | --suite <tsv>")
    exit(2)
}
