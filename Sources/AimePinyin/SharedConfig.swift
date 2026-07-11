import Foundation

/// app 与 IME 进程的共享配置（非沙盒下 UserDefaults suite 即普通 plist，两进程均可读写）。
/// app 侧在设置变更时调用 `mirrorFromApp`，IME 侧只读。
public enum SharedConfig {
    public static let suiteName = "com.zhanba.aime.shared"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 只在值变化时写入：set 会触发 didChangeNotification，无脑写会造成通知风暴
    public static func mirrorFromApp(apiBaseURL: String, apiModel: String, apiKey: String, fuzzyRuleIDs: Set<String>) {
        let d = defaults
        if d.string(forKey: "apiBaseURL") != apiBaseURL { d.set(apiBaseURL, forKey: "apiBaseURL") }
        if d.string(forKey: "apiModel") != apiModel { d.set(apiModel, forKey: "apiModel") }
        if d.string(forKey: "apiKey") != apiKey { d.set(apiKey, forKey: "apiKey") }
        let stored = Set((d.array(forKey: "fuzzyRuleIDs") as? [String]) ?? [])
        if stored != fuzzyRuleIDs { d.set(Array(fuzzyRuleIDs), forKey: "fuzzyRuleIDs") }
    }

    public static func loadLLMConfig() -> PinyinLLMConfig {
        let d = defaults
        let fuzzy = (d.array(forKey: "fuzzyRuleIDs") as? [String]).map(Set.init)
        return PinyinLLMConfig(
            apiBaseURL: d.string(forKey: "apiBaseURL") ?? "https://api.deepseek.com/v1",
            apiModel: d.string(forKey: "apiModel") ?? "deepseek-chat",
            apiKey: d.string(forKey: "apiKey") ?? "",
            enabledFuzzyRuleIDs: fuzzy ?? FuzzyRule.defaultEnabled
        )
    }
}
