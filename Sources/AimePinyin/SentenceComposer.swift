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
    /// 来自简拼索引（nh→你好）而非全拼解析
    public var isAbbreviation = false
}

/// 本地造句：在音节假设序列上跑 beam Viterbi（词频 unigram + 语法搭配转移 + 每词惩罚 λ）。
/// 得分 = Σ [ log(权重+1) + Σlog(音节可信度) − λ + gram(上文,词) ]，兜底边保证任何输入都有完整路径。
/// gram 未安装时转移项为 0，退化为纯 unigram（与 M4 行为一致）。
public struct SentenceComposer {
    let lexicon: Lexicon
    /// 语法模型（万象 LMDG 剪枝版）；nil = 未安装
    public var gram: GramModel?
    /// 语法转移分权重（评测扫参）
    public var gramWeight: Double
    /// 每词固定惩罚：偏向长词。评测调参（docs/algorithm.md §4.3）。
    public var lambda: Double
    /// 单字额外惩罚：抑制"高频单字串"打败整词（8105 字频与词频量纲不同）。
    public var singleCharDamp: Double
    /// beam 宽度：每个音节位置保留的（按句面尾部去重后的）最优路径数
    public var beamWidth = 8

    public init(
        lexicon: Lexicon, gram: GramModel? = nil, gramWeight: Double = 0.3,
        lambda: Double = 16.0, singleCharDamp: Double = 3.0
    ) {
        self.lexicon = lexicon
        self.gram = gram
        self.gramWeight = gramWeight
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
    /// gram 存在时是 beam Viterbi：转移分取决于句面尾部，每个位置按尾部去重保留 beamWidth 条路径。
    public func composeScored(syllables: [Syllable]) -> (sentence: String, score: Double) {
        let count = syllables.count
        guard count > 0 else { return ("", -.infinity) }
        struct Cell {
            var score: Double
            var previous: Int
            var previousBeam: Int
            var word: String
            /// 句面尾部（≤ collocationMaxLength−1 字）：语法查询上下文 + beam 去重键。
            /// 句首为 "#"（LMDG 的句首标记）。
            var tail: String
        }
        let tailLimit = (gram?.penalties.collocationMaxLength ?? 6) - 1
        // gram 缺失时转移分恒 0，多路径无意义：退化为经典单路径 Viterbi
        let effectiveBeam = gram == nil ? 1 : beamWidth
        // gram 给每个非搭配词加 gramWeight×nonCollocation 的常数偏置，等效削弱每词惩罚；
        // λ 自动补回，保持"词多词少"的偏好与无 gram 时一致（λ16 + 0.3×6 ≈ 评测最优的 18）
        let effectiveLambda = lambda + (gram.map { gramWeight * -$0.penalties.nonCollocation } ?? 0)
        var dp = [[Cell]](repeating: [], count: count + 1)
        dp[0] = [Cell(score: 0, previous: 0, previousBeam: 0, word: "", tail: "#")]

        for position in 0 ..< count where !dp[position].isEmpty {
            var edges = wordMatches(syllables: syllables, from: position)
            // 兜底：该位置无任何词（如 partial 尾巴）→ 音节原文透传
            if !edges.contains(where: { $0.syllableCount == 1 }) {
                edges.append(WordCandidate(
                    word: syllables[position].typed, syllableCount: 1,
                    typedLength: syllables[position].typed.count, score: -30
                ))
            }
            // beam > 1 时边数直接乘进转移查询量：每个词长档只留 unigram 前几名。
            // （不同词长的 edge.score 不可比——长词省 λ——所以按档剪而不是全局剪。）
            if effectiveBeam > 1 {
                var byLength = [Int: Int]()
                edges = edges.filter { edge in
                    byLength[edge.syllableCount, default: 0] += 1
                    return byLength[edge.syllableCount]! <= 6
                }
            }
            for edge in edges {
                let target = position + edge.syllableCount
                guard target <= count else { continue }
                let damp = edge.syllableCount == 1 ? singleCharDamp : 0
                for (beamIndex, cell) in dp[position].enumerated() {
                    var transition = 0.0
                    if let gram {
                        transition = gramWeight * gram.score(
                            context: cell.tail, word: edge.word, isRear: target == count
                        )
                    }
                    let score = cell.score + edge.score - effectiveLambda - damp + transition
                    let tail = String((cell.tail + edge.word).suffix(tailLimit))
                    // 按尾部去重：同尾部只留最高分（后续转移分只看尾部，低分同尾必然被支配）
                    if let existing = dp[target].firstIndex(where: { $0.tail == tail }) {
                        if dp[target][existing].score < score {
                            dp[target][existing] = Cell(
                                score: score, previous: position, previousBeam: beamIndex,
                                word: edge.word, tail: tail
                            )
                        }
                    } else {
                        dp[target].append(Cell(
                            score: score, previous: position, previousBeam: beamIndex,
                            word: edge.word, tail: tail
                        ))
                    }
                }
            }
            // 每个目标位置的 beam 截断推迟到该位置被展开前：这里只截当前已满的
            for target in (position + 1) ... count where dp[target].count > effectiveBeam {
                dp[target].sort { $0.score > $1.score }
                dp[target].removeLast(dp[target].count - effectiveBeam)
            }
        }

        guard let bestFinal = dp[count].indices.max(by: { dp[count][$0].score < dp[count][$1].score })
        else { return ("", -.infinity) }
        var words: [String] = []
        var cursor = count
        var beam = bestFinal
        while cursor > 0 {
            let cell = dp[cursor][beam]
            words.append(cell.word)
            beam = cell.previousBeam
            cursor = cell.previous
        }
        return (words.reversed().joined(), dp[count][bestFinal].score)
    }
}

/// 引擎门面：切分 + 词库 + 本地造句，一次同步调用（微秒级）。
/// IME / Playground / CLI 共用。lexicon 未安装时 localSentence/wordCandidates 为空，
/// 流程退化为 M3 的纯 LLM 模式。
public final class PinyinEngine {
    public static let shared = PinyinEngine()

    public private(set) var lexicon: Lexicon?
    public private(set) var gram: GramModel?
    private var composer: SentenceComposer?

    public init(lexiconURL: URL = Lexicon.defaultURL, gramURL: URL = GramModel.defaultURL) {
        reloadLexicon(from: lexiconURL, gramURL: gramURL)
    }

    /// 调参入口（CLI 扫参用）。默认 λ=16/damp=3 来自 560 句测试集扫参
    /// （无 gram 39.5%；gram 时 λ 由 composer 按 gramWeight 自动补偿）
    public var lambda: Double = 16.0 {
        didSet { composer?.lambda = lambda }
    }
    public var singleCharDamp: Double = 3.0 {
        didSet { composer?.singleCharDamp = singleCharDamp }
    }
    /// 语法转移分权重（gram 未安装时无效果）
    public var gramWeight: Double = 0.3 {
        didSet { composer?.gramWeight = gramWeight }
    }
    /// beam 宽度（gram 未安装时恒为 1）
    public var beamWidth: Int = 8 {
        didSet { composer?.beamWidth = beamWidth }
    }

    private var lexiconURL = Lexicon.defaultURL
    private var gramURL = GramModel.defaultURL
    private var loadedMTime: Date?
    private var loadedGramMTime: Date?

    public func reloadLexicon(from url: URL = Lexicon.defaultURL, gramURL: URL = GramModel.defaultURL) {
        lexiconURL = url
        self.gramURL = gramURL
        lexicon = Lexicon(url: url)
        gram = GramModel(url: gramURL)
        loadedMTime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        loadedGramMTime = (try? FileManager.default.attributesOfItem(atPath: gramURL.path)[.modificationDate]) as? Date
        composer = lexicon.map {
            SentenceComposer(
                lexicon: $0, gram: gram, gramWeight: gramWeight,
                lambda: lambda, singleCharDamp: singleCharDamp
            )
        }
    }

    /// 词库/语法模型文件被（另一进程）更新或删除后热重载。IME 在 activateServer 时调用，stat 开销可忽略。
    public func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: lexiconURL.path)[.modificationDate]) as? Date
        let gramMTime = (try? FileManager.default.attributesOfItem(atPath: gramURL.path)[.modificationDate]) as? Date
        if mtime != loadedMTime || gramMTime != loadedGramMTime {
            reloadLexicon(from: lexiconURL, gramURL: gramURL)
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

        // 简拼：整串是 2–8 个小写字母时试缩写索引（"nh"→你好）。
        // 全拼可解析的串（如 nihao）取的是"n i h a o"这类不存在的 key，天然空结果，无冲突。
        var abbrCandidates: [WordCandidate] = []
        if raw.count >= 2, raw.count <= 8, raw.allSatisfy({ $0.isLowercase && $0.isLetter }),
           let lexicon {
            abbrCandidates = lexicon.abbrMatches(key: raw, limit: 8).map { entry in
                // 词频 + 用户习惯：选过的简拼词排前（nh→你好 靠一次选择学会，
                // 白霜里"你会"频次反而更高——完整表达的偏好只能来自用户）
                let userBoost = 2 * log(1 + UserDictionary.shared.score(of: entry.word))
                return WordCandidate(
                    word: entry.word,
                    syllableCount: entry.key.split(separator: " ").count,
                    typedLength: raw.count,
                    score: log(entry.weight + 1) + userBoost,
                    isAbbreviation: true
                )
            }
            .sorted { $0.score > $1.score }
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
            // 简拼 vs 全拼的先后：全拼解析全程无需纠错修复 → 用户在打全拼，简拼靠后；
            // 解析里有修复出来的音节（如 "nh" 靠漏敲修出 nu）→ 简拼意图更可信，排前
            let parseIsExact = syllables.allSatisfy { $0.source == .exact }
            if !parseIsExact {
                for candidate in abbrCandidates {
                    seen.insert(candidate.word)
                    candidates.append(candidate)
                }
            }
            for candidate in ranked {
                let dedupeKey = candidate.word
                guard !seen.contains(dedupeKey) else { continue }
                seen.insert(dedupeKey)
                candidates.append(candidate)
                if candidates.count >= 24 { break }
            }
            if parseIsExact {
                for candidate in abbrCandidates where !seen.contains(candidate.word) {
                    seen.insert(candidate.word)
                    candidates.append(candidate)
                }
            }
        } else {
            candidates = abbrCandidates
        }
        return Result(
            segments: segments,
            localSentence: sentence.isEmpty ? nil : sentence,
            wordCandidates: candidates,
            boundaryAlternatives: alternatives
        )
    }

    /// 联想：语法模型后继候选 + 词库真词校验（搭配串无词边界，裸 remainder 可能拼错词）。
    /// 无干净命中时返回空（IME 不弹联想栏）。
    public func predictions(context: String, limit: Int = 5) -> [String] {
        guard let gram, let lexicon else { return [] }
        var results: [String] = []
        for word in gram.completions(context: context, limit: 16) {
            // 单字直接放行（都是真字）；多字必须能在词库里以整词存在
            if word.count > 1 {
                guard let syllables = PinyinVerifier.derivePinyinSyllables(from: word),
                      lexicon.exactMatches(key: syllables.joined(separator: " "))
                      .contains(where: { $0.word == word })
                else { continue }
            }
            results.append(word)
            if results.count >= limit { break }
        }
        return results
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
