import Foundation

/// 无声调拼音音节表（普通话全集，ü 按用户输入习惯写作 v：nv/lv/nve/lve）。
public enum PinyinTable {
    static let finalsByInitial: [String: [String]] = [
        "": ["a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "er"],
        "y": ["a", "e", "i", "o", "u", "ao", "ou", "an", "in", "un", "ang", "ing", "ong", "ue", "uan"],
        "w": ["a", "o", "u", "ai", "ei", "an", "en", "ang", "eng"],
        "b": ["a", "o", "ai", "ei", "ao", "an", "en", "ang", "eng", "i", "ie", "iao", "ian", "in", "ing", "u"],
        "p": ["a", "o", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "i", "ie", "iao", "ian", "in", "ing", "u"],
        "m": ["a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "i", "ie", "iao", "iu", "ian", "in", "ing", "u"],
        "f": ["a", "o", "ei", "ou", "an", "en", "ang", "eng", "u"],
        "d": ["a", "e", "ai", "ei", "ao", "ou", "an", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo", "i", "ia", "ie", "iao", "iu", "ian", "ing"],
        "t": ["a", "e", "ai", "ao", "ou", "an", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo", "i", "ie", "iao", "ian", "ing"],
        "n": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uan", "uo", "v", "ve", "i", "ie", "iao", "iu", "ian", "in", "iang", "ing"],
        "l": ["a", "e", "ai", "ei", "ao", "ou", "an", "ang", "eng", "ong", "u", "uan", "un", "uo", "v", "ve", "i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing"],
        "g": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uai", "uan", "uang", "ui", "un", "uo"],
        "k": ["a", "e", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uai", "uan", "uang", "ui", "un", "uo"],
        "h": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uai", "uan", "uang", "ui", "un", "uo"],
        "j": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
        "q": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
        "x": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
        "zh": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uai", "uan", "uang", "ui", "un", "uo"],
        "ch": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uai", "uan", "uang", "ui", "un", "uo"],
        "sh": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "u", "ua", "uai", "uan", "uang", "ui", "un", "uo"],
        "r": ["e", "i", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo"],
        "z": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo"],
        "c": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo"],
        "s": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uan", "ui", "un", "uo"],
    ]

    /// 全部合法音节（小写、无声调）。
    public static let syllables: Set<String> = {
        var set = Set<String>()
        for (initial, finals) in finalsByInitial {
            for final in finals {
                set.insert(initial + final)
            }
        }
        // 常见口语音节补充
        set.formUnion(["dia", "yo", "lo", "ei", "o"])
        return set
    }()

    public static let maxSyllableLength = 6

    public static func isValid(_ candidate: String) -> Bool {
        syllables.contains(candidate)
    }
}
