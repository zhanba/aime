import Foundation

/// 音节一致性回验：把候选句逐字转回拼音，与输入的音节假设集比对，
/// 过滤 LLM 的读音幻觉。多音字用补充表兜底。
public enum PinyinVerifier {
    public enum Verdict: Equatable, Sendable {
        case pass        // 全部匹配
        case demote      // 1 字不匹配（可能是多音字漏收）→ 降权展示
        case reject      // ≥2 字不匹配或字数不符 → 丢弃
    }

    /// 常见多音字补充读音（CFStringTransform 只给默认读音）
    static let polyphones: [Character: [String]] = [
        "行": ["hang"], "长": ["zhang"], "重": ["chong"], "乐": ["yue"], "觉": ["jiao"],
        "得": ["de", "dei"], "地": ["de"], "了": ["liao"], "还": ["huan"], "都": ["du"],
        "会": ["kuai"], "便": ["pian"], "差": ["chai", "ci"], "教": ["jiao"], "应": ["ying"],
        "相": ["xiang"], "兴": ["xing"], "省": ["xing"], "传": ["zhuan"], "曲": ["qu"],
        "血": ["xie"], "落": ["lao", "la"], "薄": ["bo"], "切": ["qie"], "弹": ["dan"],
        "数": ["shu"], "缝": ["feng"], "强": ["jiang"], "校": ["jiao"], "假": ["jia"],
        "种": ["zhong"], "处": ["chu"], "结": ["jie"], "那": ["nei"], "什": ["shen"],
        "着": ["zhao", "zhuo"], "藏": ["zang"], "调": ["diao"], "发": ["fa"], "干": ["gan"],
        "背": ["bei"], "倒": ["dao"], "圈": ["juan"], "卡": ["qia"], "壳": ["qiao"],
    ]

    private static var cache: [Character: [String]] = [:]
    private static let cacheLock = NSLock()

    /// 单个汉字的读音集合（默认读音 + 多音字补充），非汉字返回空
    public static func readings(of char: Character) -> [String] {
        cacheLock.lock()
        if let cached = cache[char] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var result: [String] = []
        let mutable = NSMutableString(string: String(char))
        if CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) {
            CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
            let base = (mutable as String)
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "ü", with: "u")
            if !base.isEmpty, base.allSatisfy({ $0.isASCII && $0.isLetter }) {
                result.append(base)
            }
        }
        result.append(contentsOf: polyphones[char] ?? [])

        cacheLock.lock()
        cache[char] = result
        cacheLock.unlock()
        return result
    }

    /// 纯中文文本 → 无声调拼音串（多音字取默认读音；含非汉字返回 nil）。
    /// 跨模态纠错 v1 的入口：语音文本反推拼音后，整套拼音机器直接可用。
    public static func derivePinyin(from text: String) -> String? {
        derivePinyinSyllables(from: text)?.joined()
    }

    /// 逐字读音（音节数组，词库 key 用空格 join）。含非汉字或未知字返回 nil。
    public static func derivePinyinSyllables(from text: String) -> [String]? {
        var result: [String] = []
        for char in text {
            guard char.isChineseCharacter, let reading = readings(of: char).first else {
                return nil
            }
            result.append(reading)
        }
        return result.isEmpty ? nil : result
    }

    /// v↔u 归一（nv/lv 与 nü/lü 拼写差异）
    private static func normalize(_ syllable: String) -> String {
        syllable.replacingOccurrences(of: "v", with: "u")
    }

    /// 校验候选句与切分假设的读音一致性（含边界歧义变体：fangan 的两种切法都接受）。
    /// 候选中的非汉字字符与 literal 段宽松跳过（英文/数字/标点不参与验音）。
    public static func verify(candidate: String, segments: [PinyinSegment]) -> Verdict {
        var best = verifyOnePath(candidate: candidate, segments: segments)
        if best == .pass { return best }
        for (index, segment) in segments.enumerated() {
            guard case .pinyin(let syllables) = segment.kind else { continue }
            for variant in PinyinSegmenter.boundaryVariants(of: syllables) {
                var altSegments = segments
                altSegments[index] = PinyinSegment(kind: .pinyin(variant), raw: segment.raw)
                let verdict = verifyOnePath(candidate: candidate, segments: altSegments)
                if verdict == .pass { return .pass }
                if verdict == .demote, best == .reject { best = .demote }
            }
        }
        return best
    }

    private static func verifyOnePath(candidate: String, segments: [PinyinSegment]) -> Verdict {
        // 展开全部音节的假设集（正解 + 模糊/修复备选 + partial 补全）
        var hypotheses: [Set<String>] = []
        for segment in segments {
            guard case .pinyin(let syllables) = segment.kind else { continue }
            for syllable in syllables {
                var set = Set<String>()
                if syllable.source == .partial {
                    for completion in syllable.completions { set.insert(normalize(completion)) }
                } else {
                    set.insert(normalize(syllable.text))
                    for alternate in syllable.fuzzyAlternates { set.insert(normalize(alternate)) }
                }
                hypotheses.append(set)
            }
        }
        let chineseChars = candidate.filter { $0.isChineseCharacter }
        guard !hypotheses.isEmpty else {
            // 纯 literal 输入：候选不该有汉字
            return chineseChars.isEmpty ? .pass : .reject
        }
        guard chineseChars.count == hypotheses.count else { return .reject }

        var mismatches = 0
        for (char, expected) in zip(chineseChars, hypotheses) {
            let actual = readings(of: char).map(normalize)
            if actual.isEmpty || !expected.isDisjoint(with: actual) { continue }
            mismatches += 1
        }
        switch mismatches {
        case 0: return .pass
        case 1: return .demote
        default: return .reject
        }
    }
}

public extension Character {
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00 ... 0x9FFF).contains(scalar.value) || (0x3400 ... 0x4DBF).contains(scalar.value)
    }
}
