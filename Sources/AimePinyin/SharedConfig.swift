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

    /// IME 进程发起语音会话所需的 ASR 配置（app 设置变更时镜像）。
    public struct SharedASRConfig {
        public var backendRaw: String
        public var qwen3ModelID: String
        public var localeID: String
    }

    public static func mirrorASRFromApp(backendRaw: String, qwen3ModelID: String, localeID: String) {
        let d = defaults
        if d.string(forKey: "asrBackend") != backendRaw { d.set(backendRaw, forKey: "asrBackend") }
        if d.string(forKey: "qwen3ModelID") != qwen3ModelID { d.set(qwen3ModelID, forKey: "qwen3ModelID") }
        if d.string(forKey: "localeID") != localeID { d.set(localeID, forKey: "localeID") }
    }

    // MARK: - 组合区显示

    /// true=显示分词拼音（主流形态，默认）；false=显示转换预览
    public static var compositionShowsPinyin: Bool {
        defaults.object(forKey: "compositionShowsPinyin") as? Bool ?? true
    }

    public static func mirrorCompositionDisplay(showsPinyin: Bool) {
        if compositionShowsPinyin != showsPinyin {
            defaults.set(showsPinyin, forKey: "compositionShowsPinyin")
        }
    }

    // MARK: - 隐私（P6）

    public static func mirrorPrivacyFromApp(blockedApps: [String], pureLocalMode: Bool) {
        let d = defaults
        if (d.array(forKey: "privacyBlockedApps") as? [String]) ?? [] != blockedApps {
            d.set(blockedApps, forKey: "privacyBlockedApps")
        }
        if d.bool(forKey: "pureLocalMode") != pureLocalMode {
            d.set(pureLocalMode, forKey: "pureLocalMode")
        }
    }

    public static var privacyBlockedApps: [String] {
        (defaults.array(forKey: "privacyBlockedApps") as? [String]) ?? []
    }

    public static var pureLocalMode: Bool {
        defaults.bool(forKey: "pureLocalMode")
    }

    /// 该应用是否禁用上下文读取与 LLM（bundle id 前缀匹配）
    public static func isBlocked(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return privacyBlockedApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    public static func loadASRConfig() -> SharedASRConfig {
        let d = defaults
        return SharedASRConfig(
            backendRaw: d.string(forKey: "asrBackend") ?? "qwen3ASR",
            qwen3ModelID: d.string(forKey: "qwen3ModelID") ?? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
            localeID: d.string(forKey: "localeID") ?? "zh_CN"
        )
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
