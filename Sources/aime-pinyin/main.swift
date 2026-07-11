import AimePinyin
import Foundation

// 拼音引擎评测 CLI：
//   调试单条：  swift run aime-pinyin nihsoshijie [--context "..."]
//   准确率：    swift run aime-pinyin --suite testdata/pinyin_testset.tsv
// LLM 配置读共享 suite（app 设置里配好后自动镜像）；无 key 时只输出切分分析。

var inputs: [String] = []
var suitePath: String?
var context: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--suite": suitePath = args.removeFirst()
    case "--context": context = args.removeFirst()
    default: inputs.append(arg)
    }
}

let config = SharedConfig.loadLLMConfig()
let converter = PinyinConverter()

func analyze(_ raw: String) -> [PinyinSegment] {
    let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs)
    return segments
}

if let suitePath {
    let tsv = try String(contentsOf: URL(fileURLWithPath: suitePath), encoding: .utf8)
    var cases: [(pinyin: String, expected: String)] = []
    for line in tsv.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { continue }
        cases.append((String(parts[0]), String(parts[1])))
    }
    guard !config.apiKey.isEmpty else {
        print("未配置 API key（aime 设置 → 精修），无法跑 LLM 准确率")
        exit(1)
    }
    var correct = 0
    var latencies: [Double] = []
    for (index, testCase) in cases.enumerated() {
        let began = Date()
        do {
            let conversion = try await converter.convert(
                raw: testCase.pinyin, context: nil, userDictEntries: [], config: config
            )
            let cost = Date().timeIntervalSince(began)
            latencies.append(cost)
            let normalize = { (s: String) in
                s.replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？.,!?"))
            }
            let hit = normalize(conversion.best) == normalize(testCase.expected)
            if hit { correct += 1 }
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
    print("首选准确率: \(correct)/\(cases.count) (\(String(format: "%.0f%%", Double(correct) / Double(cases.count) * 100)))")
    if !sorted.isEmpty {
        print(String(format: "延迟: p50=%.2fs p90=%.2fs", sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)]))
    }
} else if !inputs.isEmpty {
    for raw in inputs {
        let segments = analyze(raw)
        print("输入: \(raw)")
        print("切分: \(PinyinPromptBuilder.describe(segments: segments))")
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
