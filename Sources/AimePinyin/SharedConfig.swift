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

    /// 自定义 LLM prompt（空 = 内置），app 设置变更时镜像
    public static func mirrorPromptsFromApp(refine: String, pinyin: String, translate: String) {
        let d = defaults
        if d.string(forKey: "customPromptRefine") ?? "" != refine { d.set(refine, forKey: "customPromptRefine") }
        if d.string(forKey: "customPromptPinyin") ?? "" != pinyin { d.set(pinyin, forKey: "customPromptPinyin") }
        if d.string(forKey: "customPromptTranslate") ?? "" != translate {
            d.set(translate, forKey: "customPromptTranslate")
        }
    }

    /// IME 进程发起语音会话所需的 ASR 配置（app 设置变更时镜像）。
    /// 蓝牙收音策略以 rawValue 传递（AimePinyin 不依赖 AimeXPC 的枚举类型）。
    public struct SharedASRConfig {
        public var backendRaw: String
        public var qwen3ModelID: String
        public var localeID: String
        public var bluetoothMicStrategyRaw: String
        /// 蓝牙输入时也播放开始提示音（非蓝牙始终播放）
        public var startChimeAlways: Bool
    }

    public static func mirrorASRFromApp(
        backendRaw: String, qwen3ModelID: String, localeID: String,
        bluetoothMicStrategyRaw: String, startChimeAlways: Bool
    ) {
        let d = defaults
        if d.string(forKey: "asrBackend") != backendRaw { d.set(backendRaw, forKey: "asrBackend") }
        if d.string(forKey: "qwen3ModelID") != qwen3ModelID { d.set(qwen3ModelID, forKey: "qwen3ModelID") }
        if d.string(forKey: "localeID") != localeID { d.set(localeID, forKey: "localeID") }
        if d.string(forKey: "bluetoothMicStrategy") != bluetoothMicStrategyRaw {
            d.set(bluetoothMicStrategyRaw, forKey: "bluetoothMicStrategy")
        }
        if d.bool(forKey: "startChimeAlways") != startChimeAlways {
            d.set(startChimeAlways, forKey: "startChimeAlways")
        }
    }

    // MARK: - 语音精修

    public static func mirrorRefineFromApp(refineStyleRaw: String) {
        if defaults.string(forKey: "refineStyle") != refineStyleRaw {
            defaults.set(refineStyleRaw, forKey: "refineStyle")
        }
    }

    public static var refineStyle: RefineStyle {
        RefineStyle(rawValue: defaults.string(forKey: "refineStyle") ?? "") ?? .clean
    }

    // MARK: - 组合区显示

    /// true=显示分词拼音（主流形态，默认）；false=显示转换预览
    public static var compositionShowsPinyin: Bool {
        defaults.object(forKey: "compositionShowsPinyin") as? Bool ?? true
    }

    /// 中文标点（默认开）。关闭后标点键原样上屏（写代码/英文场景）。
    public static var chinesePunctuation: Bool {
        defaults.object(forKey: "chinesePunctuation") as? Bool ?? true
    }

    /// 词组联想（默认关，无 UI）。LMDG 搭配值跨条目不可比、无词边界，联想质量未达上线标准；
    /// 基建保留，等词级 bigram 数据源（自建统计或用户历史）就绪后再默认开。
    /// 开发自用：defaults write <suite> predictionEnabled -bool true
    public static var predictionEnabled: Bool {
        defaults.object(forKey: "predictionEnabled") as? Bool ?? false
    }

    public static func mirrorChinesePunctuation(_ enabled: Bool) {
        if chinesePunctuation != enabled {
            defaults.set(enabled, forKey: "chinesePunctuation")
        }
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
            localeID: d.string(forKey: "localeID") ?? "zh_CN",
            bluetoothMicStrategyRaw: d.string(forKey: "bluetoothMicStrategy") ?? "",
            startChimeAlways: d.bool(forKey: "startChimeAlways")
        )
    }

    public static func loadLLMConfig() -> PinyinLLMConfig {
        let d = defaults
        let fuzzy = (d.array(forKey: "fuzzyRuleIDs") as? [String]).map(Set.init)
        return PinyinLLMConfig(
            apiBaseURL: d.string(forKey: "apiBaseURL") ?? "https://api.deepseek.com/v1",
            apiModel: d.string(forKey: "apiModel") ?? "deepseek-v4-flash",
            apiKey: d.string(forKey: "apiKey") ?? "",
            enabledFuzzyRuleIDs: fuzzy ?? FuzzyRule.defaultEnabled,
            customPromptRefine: d.string(forKey: "customPromptRefine") ?? "",
            customPromptPinyin: d.string(forKey: "customPromptPinyin") ?? "",
            customPromptTranslate: d.string(forKey: "customPromptTranslate") ?? ""
        )
    }
}
