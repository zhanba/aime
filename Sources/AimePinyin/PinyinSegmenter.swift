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
    /// 采信的音节（修复后的规范拼写）
    public var text: String
    /// 用户实际敲的串（无修复时与 text 相同）
    public var typed: String
    /// 模糊音变体（合法音节）
    public var fuzzyAlternates: [String]
    /// 是否经过键盘错误修复
    public var repaired: Bool

    public init(text: String, typed: String, fuzzyAlternates: [String] = [], repaired: Bool = false) {
        self.text = text
        self.typed = typed
        self.fuzzyAlternates = fuzzyAlternates
        self.repaired = repaired
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

    /// 生成 1-编辑修复候选：临近键单字符替换 + 相邻字符换位。
    static func repairs(of typed: [Character]) -> [String] {
        var results = Set<String>()
        for index in typed.indices {
            for neighbor in neighbors[typed[index]] ?? [] {
                var variant = typed
                variant[index] = neighbor
                results.insert(String(variant))
            }
        }
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
        case syllable(text: String, typed: String, repaired: Bool)
        case literal(String)
        case separator
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

            // 小写字母：尝试各长度的音节匹配与修复
            let maxLength = min(PinyinTable.maxSyllableLength, count - position)
            for length in 1 ... maxLength {
                let typed = String(chars[position ..< position + length])
                if PinyinTable.isValid(typed) {
                    let shortPenalty = length == 1 ? 0.35 : 0.0
                    relax(position + length, cost: 1.0 + shortPenalty, from: position,
                          kind: .syllable(text: typed, typed: typed, repaired: false))
                } else if length >= 2 {
                    // 键盘错误修复：临近键替换/相邻换位后合法 → 带惩罚接受
                    for candidate in QwertyAdjacency.repairs(of: Array(typed)) where PinyinTable.isValid(candidate) {
                        relax(position + length, cost: 1.0 + 1.6, from: position,
                              kind: .syllable(text: candidate, typed: typed, repaired: true))
                    }
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
            case .syllable(let text, let typed, let repaired):
                flushLiteral()
                syllableRun.append(Syllable(
                    text: text,
                    typed: typed,
                    fuzzyAlternates: FuzzyExpander.variants(of: text, enabledRuleIDs: enabledFuzzyRuleIDs),
                    repaired: repaired
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

private extension Character {
    var isLowercaseLatin: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x61 && scalar.value <= 0x7A
    }
}
