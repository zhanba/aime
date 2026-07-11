import Foundation

/// 词候选（供候选栏与部分上屏）。
public struct WordCandidate: Equatable, Sendable {
    public var word: String
    /// 消耗的音节数（相对活动段起点）
    public var syllableCount: Int
    /// 消耗的实际按键数（音节 typed 长度之和）。部分上屏必须用它：
    /// 边界变体的音节数与主切分可以不同（chuan vs chu|an），按键数才是稳定量。
    public var typedLength: Int
    /// 排序得分（log 词频 + 变换可信度）
    public var score: Double
}

/// 本地造句：在音节假设序列上跑 Viterbi（词频 unigram + 每词惩罚 λ）。
/// 得分 = Σ [ log(权重+1) + Σlog(音节可信度) − λ ]，兜底边保证任何输入都有完整路径。
public struct SentenceComposer {
    let lexicon: Lexicon
    /// 每词固定惩罚：偏向长词。评测调参（docs/algorithm.md §4.3）。
    public var lambda: Double
    /// 单字额外惩罚：抑制"高频单字串"打败整词（8105 字频与词频量纲不同）。
    public var singleCharDamp: Double

    public init(lexicon: Lexicon, lambda: Double = 14.0, singleCharDamp: Double = 3.0) {
        self.lexicon = lexicon
        self.lambda = lambda
        self.singleCharDamp = singleCharDamp
    }

    /// 每个音节位置的读音假设（正解 + 模糊音 + 漏敲多敲备选，带可信度）
    static func hypotheses(for syllable: Syllable) -> [(text: String, credibility: Double)] {
        var list: [(String, Double)] = []
        if syllable.source == .partial {
            // 未打完的音节：用补全候选参与组词（可信度低）
            for completion in syllable.completions.prefix(3) {
                list.append((completion, 0.5))
            }
            return list
        }
        list.append((syllable.text, syllable.source.credibility))
        for alternate in syllable.fuzzyAlternates.prefix(3) {
            list.append((alternate, syllable.source.credibility * 0.9))
        }
        return list
    }

    /// 从音节位置 start 出发的全部词匹配（BFS 前缀下潜，假设分支 ×每步剪枝）。
    func wordMatches(syllables: [Syllable], from start: Int, maxLength: Int = 8) -> [WordCandidate] {
        var results: [WordCandidate] = []
        // (当前 key, 累计可信度 log)
        var frontier: [(key: String, credibilityLog: Double)] = [("", 0)]
        var length = 0
        var typedLength = 0
        while !frontier.isEmpty, start + length < syllables.count, length < maxLength {
            let syllable = syllables[start + length]
            typedLength += syllable.typed.count
            var next: [(String, Double)] = []
            for (key, credibilityLog) in frontier {
                for (text, credibility) in Self.hypotheses(for: syllable) {
                    let newKey = key.isEmpty ? text : key + " " + text
                    guard lexicon.hasPrefix(key: newKey) else { continue }
                    let newLog = credibilityLog + log(credibility)
                    next.append((newKey, newLog))
                    for entry in lexicon.exactMatches(key: newKey) {
                        results.append(WordCandidate(
                            word: entry.word,
                            syllableCount: length + 1,
                            typedLength: typedLength,
                            score: log(entry.weight + 1) + newLog
                        ))
                    }
                }
            }
            // 剪枝：每层最多 8 条路径
            frontier = Array(next.sorted { $0.1 > $1.1 }.prefix(8))
            length += 1
        }
        return results.sorted { $0.score > $1.score }
    }

    /// Viterbi：整段音节 → 最优词序列（本地整句）。
    public func compose(syllables: [Syllable]) -> String {
        composeScored(syllables: syllables).sentence
    }

    /// 带总分版本：边界歧义多路径间择优用。
    public func composeScored(syllables: [Syllable]) -> (sentence: String, score: Double) {
        let count = syllables.count
        guard count > 0 else { return ("", -.infinity) }
        struct Cell {
            var score: Double
            var previous: Int
            var word: String
        }
        var dp = [Cell?](repeating: nil, count: count + 1)
        dp[0] = Cell(score: 0, previous: 0, word: "")

        for position in 0 ..< count where dp[position] != nil {
            let base = dp[position]!.score
            var edges = wordMatches(syllables: syllables, from: position)
            // 兜底：该位置无任何词（如 partial 尾巴）→ 音节原文透传
            if !edges.contains(where: { $0.syllableCount == 1 }) {
                edges.append(WordCandidate(
                    word: syllables[position].typed, syllableCount: 1,
                    typedLength: syllables[position].typed.count, score: -30
                ))
            }
            for edge in edges {
                let target = position + edge.syllableCount
                guard target <= count else { continue }
                let damp = edge.syllableCount == 1 ? singleCharDamp : 0
                let score = base + edge.score - lambda - damp
                if dp[target] == nil || score > dp[target]!.score {
                    dp[target] = Cell(score: score, previous: position, word: edge.word)
                }
            }
        }

        var words: [String] = []
        var cursor = count
        while cursor > 0, let cell = dp[cursor] {
            words.append(cell.word)
            cursor = cell.previous
        }
        return (words.reversed().joined(), dp[count]?.score ?? -.infinity)
    }
}

/// 引擎门面：切分 + 词库 + 本地造句，一次同步调用（微秒级）。
/// IME / Playground / CLI 共用。lexicon 未安装时 localSentence/wordCandidates 为空，
/// 流程退化为 M3 的纯 LLM 模式。
public final class PinyinEngine {
    public static let shared = PinyinEngine()

    public private(set) var lexicon: Lexicon?
    private var composer: SentenceComposer?

    public init(lexiconURL: URL = Lexicon.defaultURL) {
        reloadLexicon(from: lexiconURL)
    }

    /// 调参入口（CLI 扫参用）。默认 λ=14/damp=3 来自 20 句测试集扫参（70% 本地命中）
    public var lambda: Double = 14.0 {
        didSet { composer?.lambda = lambda }
    }
    public var singleCharDamp: Double = 3.0 {
        didSet { composer?.singleCharDamp = singleCharDamp }
    }

    private var lexiconURL = Lexicon.defaultURL
    private var loadedMTime: Date?

    public func reloadLexicon(from url: URL = Lexicon.defaultURL) {
        lexiconURL = url
        lexicon = Lexicon(url: url)
        loadedMTime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        composer = lexicon.map { SentenceComposer(lexicon: $0, lambda: lambda, singleCharDamp: singleCharDamp) }
    }

    /// 词库文件被（另一进程）更新或删除后热重载。IME 在 activateServer 时调用，stat 一次开销可忽略。
    public func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: lexiconURL.path)[.modificationDate]) as? Date
        if mtime != loadedMTime {
            reloadLexicon(from: lexiconURL)
        }
    }

    public struct Result: Sendable {
        public var segments: [PinyinSegment]
        /// 本地整句（词库+Viterbi；词库未装则 nil）
        public var localSentence: String?
        /// 活动段起点的词候选（部分上屏用），已按分排序去重
        public var wordCandidates: [WordCandidate]
        /// 边界歧义的替代切分（如 fangan 的 "fang an"），供 LLM prompt 提示
        public var boundaryAlternatives: [String] = []
    }

    public func analyze(_ raw: String, fuzzyRuleIDs: Set<String> = FuzzyRule.defaultEnabled) -> Result {
        let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: fuzzyRuleIDs)
        guard let composer else {
            return Result(segments: segments, localSentence: nil, wordCandidates: [])
        }

        // 本地整句：拼音段（含边界歧义变体）多路 Viterbi 择优，literal 段透传
        var sentence = ""
        var alternatives: [String] = []
        for segment in segments {
            switch segment.kind {
            case .literal(let text):
                sentence += text
            case .pinyin(let syllables):
                let variants = PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: fuzzyRuleIDs)
                alternatives += variants.map { $0.map(\.text).joined(separator: " ") }
                var best = composer.composeScored(syllables: syllables)
                for variant in variants {
                    let scored = composer.composeScored(syllables: variant)
                    if scored.score > best.score { best = scored }
                }
                sentence += best.sentence
            }
        }

        // 词候选：第一个拼音段的起点（活动段），主切分 + 边界变体合并
        var candidates: [WordCandidate] = []
        if let firstPinyin = segments.first(where: {
            if case .pinyin = $0.kind { return true }
            return false
        }), case .pinyin(let syllables) = firstPinyin.kind {
            var seen = Set<String>()
            var matches = composer.wordMatches(syllables: syllables, from: 0)
            for variant in PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: fuzzyRuleIDs) {
                matches += composer.wordMatches(syllables: variant, from: 0)
            }
            // 展示排序：长词加成 + 用原始分；单字海量高频不该淹没整词
            let ranked = matches
                .sorted { ($0.score + Double($0.syllableCount) * 4) > ($1.score + Double($1.syllableCount) * 4) }
            for candidate in ranked {
                let dedupeKey = candidate.word
                guard !seen.contains(dedupeKey) else { continue }
                seen.insert(dedupeKey)
                candidates.append(candidate)
                if candidates.count >= 24 { break }
            }
        }
        return Result(
            segments: segments,
            localSentence: sentence.isEmpty ? nil : sentence,
            wordCandidates: candidates,
            boundaryAlternatives: alternatives
        )
    }

    /// 词消耗的原始按键长度（含被跳过的分隔符），部分上屏用。
    /// typedLength 是候选自带的按键数（WordCandidate.typedLength）——
    /// 不能按主切分音节数换算：候选可能来自音节数不同的边界变体。
    public static func consumedKeyLength(raw: String, typedLength: Int) -> Int {
        var remaining = typedLength
        var rawCount = 0
        for char in raw {
            guard remaining > 0 else { break }
            rawCount += 1
            if char == "'" || char == " " { continue }
            remaining -= 1
        }
        return rawCount
    }
}
