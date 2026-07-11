import Foundation

/// 拼写变换来源与可信度（借鉴 RIME 拼写运算：所有容错统一为带可信度的变换）。
public enum TransformSource: Equatable, Sendable {
    case exact
    case keyAdjacent      // 临近键替换（hso→hao）
    case transposition    // 相邻换位（mne→men）
    case deletion         // 漏敲（zhng→zhang）
    case insertion        // 多敲（zhoong→zhong）
    case partial          // 句尾未打完（h→h…）

    public var credibility: Double {
        switch self {
        case .exact: return 1.0
        case .partial: return 0.8
        case .keyAdjacent: return 0.7
        case .transposition: return 0.65
        case .deletion, .insertion: return 0.6
        }
    }

    /// DP 边代价（越可信越低），exact=1.0 基准
    var stepCost: Double {
        1.0 + (1.0 - credibility) * 2.6
    }
}

/// 拼写变换表：漏敲反查、多敲检验、句尾前缀。启动时一次性构建。
public enum SpellingTransforms {
    /// 音节挖掉一个字母的变体 → 原音节列表（漏敲修复：用户敲的正是变体）
    static let deletionMap: [String: [String]] = {
        var map: [String: [String]] = [:]
        for syllable in PinyinTable.syllables where syllable.count >= 2 {
            let chars = Array(syllable)
            for index in chars.indices {
                var variant = chars
                variant.remove(at: index)
                let key = String(variant)
                // 变体本身是合法音节的不收（exact 解释优先，避免把正确输入当漏敲）
                guard !PinyinTable.isValid(key) else { continue }
                map[key, default: []].append(syllable)
            }
        }
        for key in map.keys {
            map[key] = Array(Set(map[key]!)).sorted()
        }
        return map
    }()

    /// 所有音节的真前缀集（句尾 partial 判断）
    static let prefixSet: Set<String> = {
        var set = Set<String>()
        for syllable in PinyinTable.syllables {
            var prefix = ""
            for char in syllable.dropLast() {
                prefix.append(char)
                set.insert(prefix)
            }
        }
        return set
    }()

    /// 给定前缀的可补全音节（partial 的提示候选，上限 6 个）
    static func completions(of prefix: String, limit: Int = 6) -> [String] {
        PinyinTable.syllables
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
            .prefix(limit)
            .map { $0 }
    }

    /// 多敲修复：typed 逐位删一个字母后合法的音节
    static func insertionRepairs(of typed: [Character]) -> [String] {
        guard typed.count >= 3 else { return [] }
        var results = Set<String>()
        for index in typed.indices {
            var variant = typed
            variant.remove(at: index)
            let candidate = String(variant)
            if PinyinTable.isValid(candidate) {
                results.insert(candidate)
            }
        }
        return Array(results).sorted()
    }
}
