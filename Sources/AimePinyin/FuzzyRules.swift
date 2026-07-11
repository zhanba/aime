import Foundation

/// 模糊音规则（双向）。用户按方言习惯在设置中勾选。
public struct FuzzyRule: Hashable, Codable, Identifiable, Sendable {
    public let a: String
    public let b: String
    public let kind: Kind

    public enum Kind: String, Codable, Sendable {
        case initialRule   // 声母互换（z/zh）
        case finalRule     // 韵母互换（in/ing）
    }

    public var id: String { "\(a)/\(b)" }
    public var displayName: String { "\(a) ↔ \(b)" }

    public static let all: [FuzzyRule] = [
        FuzzyRule(a: "z", b: "zh", kind: .initialRule),
        FuzzyRule(a: "c", b: "ch", kind: .initialRule),
        FuzzyRule(a: "s", b: "sh", kind: .initialRule),
        FuzzyRule(a: "n", b: "l", kind: .initialRule),
        FuzzyRule(a: "f", b: "h", kind: .initialRule),
        FuzzyRule(a: "r", b: "l", kind: .initialRule),
        FuzzyRule(a: "in", b: "ing", kind: .finalRule),
        FuzzyRule(a: "en", b: "eng", kind: .finalRule),
        FuzzyRule(a: "an", b: "ang", kind: .finalRule),
        FuzzyRule(a: "ian", b: "iang", kind: .finalRule),
        FuzzyRule(a: "uan", b: "uang", kind: .finalRule),
    ]

    /// 默认开启集：南方口音最常见的六组
    public static let defaultEnabled: Set<String> = [
        "z/zh", "c/ch", "s/sh", "n/l", "in/ing", "en/eng",
    ]

    public init(a: String, b: String, kind: Kind) {
        self.a = a
        self.b = b
        self.kind = kind
    }
}

public enum FuzzyExpander {
    /// 拆音节为（声母, 韵母）。声母取最长匹配（zh > z）。
    static func split(_ syllable: String) -> (initial: String, final: String)? {
        guard PinyinTable.isValid(syllable) else { return nil }
        for length in [2, 1, 0] {
            guard syllable.count >= length else { continue }
            let initial = String(syllable.prefix(length))
            let final = String(syllable.dropFirst(length))
            if let finals = PinyinTable.finalsByInitial[initial], finals.contains(final) {
                return (initial, final)
            }
        }
        return nil
    }

    /// 给定音节按启用规则生成模糊变体（仅返回合法音节，不含原音节）。
    public static func variants(of syllable: String, enabledRuleIDs: Set<String>) -> [String] {
        guard let (initial, final) = split(syllable) else { return [] }
        var results = Set<String>()
        for rule in FuzzyRule.all where enabledRuleIDs.contains(rule.id) {
            switch rule.kind {
            case .initialRule:
                if initial == rule.a { results.insert(rule.b + final) }
                if initial == rule.b { results.insert(rule.a + final) }
            case .finalRule:
                if final == rule.a { results.insert(initial + rule.b) }
                if final == rule.b { results.insert(initial + rule.a) }
            }
        }
        results.remove(syllable)
        return results.filter { PinyinTable.isValid($0) }.sorted()
    }
}
