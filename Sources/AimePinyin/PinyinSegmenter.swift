import Foundation

/// 切分结果中的一段。
public struct PinyinSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 拼音音节序列
        case pinyin([Syllable])
        /// 原样透传（英文/数字/无法解析的串）
        case literal(String)
    }

    public var kind: Kind
    /// 该段对应的原始输入
    public var raw: String
}

/// 单个音节及其备选。
public struct Syllable: Equatable, Sendable {
    /// 采信的音节（修复后的规范拼写；partial 时为已敲的前缀）
    public var text: String
    /// 用户实际敲的串（无修复时与 text 相同）
    public var typed: String
    /// 模糊音变体（合法音节）
    public var fuzzyAlternates: [String]
    /// 变换来源（exact/临近键/换位/漏敲/多敲/partial）
    public var source: TransformSource
    /// partial 时的可补全音节
    public var completions: [String]

    /// 是否经过修复类变换
    public var repaired: Bool {
        switch source {
        case .exact, .partial: return false
        default: return true
        }
    }

    public init(text: String, typed: String, fuzzyAlternates: [String] = [],
                source: TransformSource = .exact, completions: [String] = []) {
        self.text = text
        self.typed = typed
        self.fuzzyAlternates = fuzzyAlternates
        self.source = source
        self.completions = completions
    }
}

/// QWERTY 临近键表（键盘错误模型：把手误替换回邻近键）。
enum QwertyAdjacency {
    static let neighbors: [Character: [Character]] = [
        "q": ["w", "a"], "w": ["q", "e", "s", "a"], "e": ["w", "r", "d", "s"],
        "r": ["e", "t", "f", "d"], "t": ["r", "y", "g", "f"], "y": ["t", "u", "h", "g"],
        "u": ["y", "i", "j", "h"], "i": ["u", "o", "k", "j"], "o": ["i", "p", "l", "k"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"], "s": ["a", "d", "w", "e", "z", "x"],
        "d": ["s", "f", "e", "r", "x", "c"], "f": ["d", "g", "r", "t", "c", "v"],
        "g": ["f", "h", "t", "y", "v", "b"], "h": ["g", "j", "y", "u", "b", "n"],
        "j": ["h", "k", "u", "i", "n", "m"], "k": ["j", "l", "i", "o", "m"],
        "l": ["k", "o", "p"],
        "z": ["a", "s", "x"], "x": ["z", "c", "s", "d"], "c": ["x", "v", "d", "f"],
        "v": ["c", "b", "f", "g"], "b": ["v", "n", "g", "h"], "n": ["b", "m", "h", "j"],
        "m": ["n", "j", "k"],
    ]

    /// 临近键单字符替换候选
    static func substitutionRepairs(of typed: [Character]) -> [String] {
        var results = Set<String>()
        for index in typed.indices {
            for neighbor in neighbors[typed[index]] ?? [] {
                var variant = typed
                variant[index] = neighbor
                results.insert(String(variant))
            }
        }
        results.remove(String(typed))
        return Array(results)
    }

    /// 相邻字符换位候选
    static func transpositionRepairs(of typed: [Character]) -> [String] {
        var results = Set<String>()
        for index in typed.indices.dropLast() {
            var variant = typed
            variant.swapAt(index, index + 1)
            results.insert(String(variant))
        }
        results.remove(String(typed))
        return Array(results)
    }
}

/// 拼音切分器：DP 最优路径 + 键盘错误修复 + 中英混输透传。
///
/// 代价模型（越低越好）：正常音节 1.0（单字母 +0.35），修复音节 +1.6，
/// 大写/数字 literal 1.0，小写不可解析字符 3.0（优先解析成拼音，最后才透传）。
public enum PinyinSegmenter {
    struct Step {
        var cost: Double
        var previous: Int
        var kind: StepKind
    }

    enum StepKind {
        case syllable(text: String, typed: String, source: TransformSource, completions: [String])
        case literal(String)
        case separator
    }

    /// 该字符串能否完整切成合法音节序列（单音节 isValid 的多音节推广）
    static func isExactSyllableSequence(_ chars: [Character]) -> Bool {
        var reachable = [Bool](repeating: false, count: chars.count + 1)
        reachable[0] = true
        for start in 0 ..< chars.count where reachable[start] {
            let maxLength = min(PinyinTable.maxSyllableLength, chars.count - start)
            for length in 1 ... maxLength where PinyinTable.isValid(String(chars[start ..< start + length])) {
                reachable[start + length] = true
            }
        }
        return reachable[chars.count]
    }

    public static func segment(_ input: String, enabledFuzzyRuleIDs: Set<String> = FuzzyRule.defaultEnabled) -> [PinyinSegment] {
        let chars = Array(input)
        let count = chars.count
        guard count > 0 else { return [] }

        var dp = [Step?](repeating: nil, count: count + 1)
        dp[0] = Step(cost: 0, previous: 0, kind: .separator)

        func relax(_ to: Int, cost: Double, from: Int, kind: StepKind) {
            let total = (dp[from]?.cost ?? .infinity) + cost
            if dp[to] == nil || total < dp[to]!.cost {
                dp[to] = Step(cost: total, previous: from, kind: kind)
            }
        }

        for position in 0 ..< count {
            guard dp[position] != nil else { continue }
            let char = chars[position]

            // 分隔符：用户显式切分
            if char == "'" || char == " " {
                relax(position + 1, cost: 0, from: position, kind: .separator)
                continue
            }

            // 大写/数字/符号：吞掉最大同类段作为 literal（明确的非拼音意图）
            if !char.isLowercaseLatin {
                var end = position
                while end < count, !chars[end].isLowercaseLatin, chars[end] != "'", chars[end] != " " {
                    end += 1
                }
                relax(end, cost: 1.0, from: position, kind: .literal(String(chars[position ..< end])))
                continue
            }

            // 小写字母：尝试各长度的音节匹配与拼写变换
            let maxLength = min(PinyinTable.maxSyllableLength + 1, count - position)
            for length in 1 ... maxLength {
                let typed = String(chars[position ..< position + length])
                let typedChars = Array(typed)
                if PinyinTable.isValid(typed) {
                    let shortPenalty = length == 1 ? 0.35 : 0.0
                    relax(position + length, cost: TransformSource.exact.stepCost + shortPenalty, from: position,
                          kind: .syllable(text: typed, typed: typed, source: .exact, completions: []))
                    continue
                }
                // 修复类解释只对无法 exact 切分的跨度生效：正确拼音不当手误
                // （yianzhuang 的 yian = yi|an，不修成 tian；与 deletionMap 的单音节
                // exact 优先同一原则，推广到音节序列。partial 不受此限）
                if !isExactSyllableSequence(typedChars) {
                    // 临近键替换（含相邻换位，区分代价）
                    if length >= 2, length <= PinyinTable.maxSyllableLength {
                        for candidate in QwertyAdjacency.substitutionRepairs(of: typedChars) where PinyinTable.isValid(candidate) {
                            relax(position + length, cost: TransformSource.keyAdjacent.stepCost, from: position,
                                  kind: .syllable(text: candidate, typed: typed, source: .keyAdjacent, completions: []))
                        }
                        for candidate in QwertyAdjacency.transpositionRepairs(of: typedChars) where PinyinTable.isValid(candidate) {
                            relax(position + length, cost: TransformSource.transposition.stepCost, from: position,
                                  kind: .syllable(text: candidate, typed: typed, source: .transposition, completions: []))
                        }
                    }
                    // 漏敲：typed 是某音节挖掉一个字母的变体
                    if length >= 1, length <= PinyinTable.maxSyllableLength - 1,
                       let fullSyllables = SpellingTransforms.deletionMap[typed] {
                        for candidate in fullSyllables.prefix(3) {
                            relax(position + length, cost: TransformSource.deletion.stepCost, from: position,
                                  kind: .syllable(text: candidate, typed: typed, source: .deletion, completions: []))
                        }
                    }
                    // 多敲：typed 删掉一个字母后合法
                    if length >= 3 {
                        for candidate in SpellingTransforms.insertionRepairs(of: typedChars) {
                            relax(position + length, cost: TransformSource.insertion.stepCost, from: position,
                                  kind: .syllable(text: candidate, typed: typed, source: .insertion, completions: []))
                        }
                    }
                }
                // 句尾 partial：到 buffer 末尾且是某音节的真前缀
                if position + length == count, SpellingTransforms.prefixSet.contains(typed) {
                    relax(count, cost: TransformSource.partial.stepCost, from: position,
                          kind: .syllable(text: typed, typed: typed, source: .partial,
                                          completions: SpellingTransforms.completions(of: typed)))
                }
            }

            // 兜底：单个小写字母透传（高代价，仅当无法成拼音）
            relax(position + 1, cost: 3.0, from: position, kind: .literal(String(char)))
        }

        // 回溯
        var steps: [StepKind] = []
        var cursor = count
        while cursor > 0 {
            guard let step = dp[cursor] else { break }
            steps.append(step.kind)
            cursor = step.previous
        }
        steps.reverse()

        // 合并成段：连续音节归一段，连续 literal 归一段
        var segments: [PinyinSegment] = []
        var syllableRun: [Syllable] = []
        var literalRun = ""

        func flushSyllables() {
            if !syllableRun.isEmpty {
                let raw = syllableRun.map(\.typed).joined()
                segments.append(PinyinSegment(kind: .pinyin(syllableRun), raw: raw))
                syllableRun = []
            }
        }
        func flushLiteral() {
            if !literalRun.isEmpty {
                segments.append(PinyinSegment(kind: .literal(literalRun), raw: literalRun))
                literalRun = ""
            }
        }

        for step in steps {
            switch step {
            case .syllable(let text, let typed, let source, let completions):
                flushLiteral()
                // 漏敲/多敲的其他同代价修复优先于模糊音（同为"修复解释"，可信度更高）
                var alternates: [String] = []
                switch source {
                case .deletion:
                    alternates += (SpellingTransforms.deletionMap[typed] ?? []).filter { $0 != text }
                case .insertion:
                    alternates += SpellingTransforms.insertionRepairs(of: Array(typed)).filter { $0 != text }
                default:
                    break
                }
                if source != .partial {
                    alternates += FuzzyExpander.variants(of: text, enabledRuleIDs: enabledFuzzyRuleIDs)
                        .filter { !alternates.contains($0) }
                }
                syllableRun.append(Syllable(
                    text: text,
                    typed: typed,
                    fuzzyAlternates: alternates,
                    source: source,
                    completions: completions
                ))
            case .literal(let text):
                flushSyllables()
                literalRun += text
            case .separator:
                continue
            }
        }
        flushSyllables()
        flushLiteral()
        return segments
    }
}

public extension PinyinSegmenter {
    /// 组合区的分词拼音展示串（主流输入法形态）："yuanshide" → "yuan shi de"，
    /// literal 段原样，partial 尾巴原样。
    static func displayString(of segments: [PinyinSegment]) -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment.kind {
            case .literal(let text):
                parts.append(text)
            case .pinyin(let syllables):
                parts.append(syllables.map(\.typed).joined(separator: " "))
            }
        }
        return parts.joined(separator: " ")
    }

    /// 边界歧义变体：n/g/元音在音节交界处的归属歧义（fangan = fan|gan vs fang|an），
    /// 以及单音节的拆分歧义（shanchuanniu 的 chuan = chu|an → 删除按钮）。
    /// DP 只保留单一最优路径（且偏好更少音节数）会把另一种切法整个丢掉——这里补回，供
    /// 本地造句（双路 Viterbi 择优）、词候选合并、LLM prompt 与回验器使用。
    /// 仅对 exact 音节生效；每个交界/音节独立产生一个变体，上限 3 个。
    static func boundaryVariants(of syllables: [Syllable], enabledFuzzyRuleIDs: Set<String> = FuzzyRule.defaultEnabled) -> [[Syllable]] {
        guard !syllables.isEmpty else { return [] }
        var variants: [[Syllable]] = []

        func makeSyllable(_ text: String) -> Syllable {
            Syllable(
                text: text, typed: text,
                fuzzyAlternates: FuzzyExpander.variants(of: text, enabledRuleIDs: enabledFuzzyRuleIDs),
                source: .exact
            )
        }

        for index in 0 ..< syllables.count - 1 {
            guard variants.count < 3 else { break }
            let a = syllables[index]
            let b = syllables[index + 1]
            guard a.source == .exact, b.source == .exact else { continue }
            let aText = a.text
            let bText = b.text
            var replacement: (String, String)?

            let vowels: Set<Character> = ["a", "o", "e"]
            if aText.hasSuffix("n"), !aText.hasSuffix("ng"), bText.hasPrefix("g"),
               PinyinTable.isValid(aText + "g"), PinyinTable.isValid(String(bText.dropFirst())) {
                replacement = (aText + "g", String(bText.dropFirst()))        // fan|gan → fang|an
            } else if aText.hasSuffix("ng"), let first = bText.first, vowels.contains(first),
                      PinyinTable.isValid(String(aText.dropLast())), PinyinTable.isValid("g" + bText) {
                replacement = (String(aText.dropLast()), "g" + bText)         // fang|an → fan|gan
            } else if aText.hasSuffix("n"), !aText.hasSuffix("ng"), let first = bText.first, vowels.contains(first),
                      PinyinTable.isValid(String(aText.dropLast())), PinyinTable.isValid("n" + bText) {
                replacement = (String(aText.dropLast()), "n" + bText)         // xian|an → xia|nan
            } else if let first = bText.first, first == "n",
                      PinyinTable.isValid(aText + "n"), PinyinTable.isValid(String(bText.dropFirst())) {
                replacement = (aText + "n", String(bText.dropFirst()))        // xia|nan → xian|an
            }

            if let (newA, newB) = replacement {
                var variant = syllables
                variant[index] = makeSyllable(newA)
                variant[index + 1] = makeSyllable(newB)
                variants.append(variant)
            }
        }

        // 单音节拆分：DP 按音节数最少切分，chuan 永远赢过 chu|an，
        // 拆开的读法只能在变体里补回。每个音节取第一个合法拆点。
        for index in syllables.indices {
            guard variants.count < 3 else { break }
            let syllable = syllables[index]
            guard syllable.source == .exact, syllable.text.count >= 3 else { continue }
            let text = Array(syllable.text)
            for splitAt in 1 ..< text.count {
                let head = String(text[..<splitAt])
                let tail = String(text[splitAt...])
                guard PinyinTable.isValid(head), PinyinTable.isValid(tail) else { continue }
                var variant = syllables
                variant.replaceSubrange(index ... index, with: [makeSyllable(head), makeSyllable(tail)])
                variants.append(variant)
                break
            }
        }
        return variants
    }
}

private extension Character {
    var isLowercaseLatin: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x61 && scalar.value <= 0x7A
    }
}
