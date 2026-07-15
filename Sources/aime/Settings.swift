import AimeASR
import AimePinyin
import Foundation

/// UserDefaults 键名。SwiftUI 视图用 @AppStorage 绑定同名键，逻辑层通过 `Settings` 读取。
enum SettingsKey {
    static let asrBackend = "asrBackend"
    static let fuzzyRules = "fuzzyRules"
    static let qwen3ModelID = "qwen3ModelID"
    static let apiBaseURL = "apiBaseURL"
    static let apiModel = "apiModel"
    static let apiKey = "apiKey" // TODO: M2 迁移到 Keychain
    static let hotkey = "hotkey"
    static let refineStyle = "refineStyle"
    static let bluetoothMicStrategy = "bluetoothMicStrategy"
    static let startChimeAlways = "startChimeAlways"
    static let customPromptRefine = "customPromptRefine"
    /// 从「自定义」切回内置风格时的暂存，仅设置页 UI 使用，引擎与 IME 不读
    static let customPromptRefineDraft = "customPromptRefineDraft"
    static let customPromptPinyin = "customPromptPinyin"
    static let customPromptTranslate = "customPromptTranslate"
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "右 Option ⌥"
        case .rightCommand: return "右 Command ⌘"
        case .fn: return "Fn 🌐"
        }
    }
}

/// Qwen3-ASR 可选档位（HF 上的 MLX 转换版）
enum Qwen3ModelChoice: String, CaseIterable, Identifiable {
    case small4bit = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    case large8bit = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small4bit: return "标准（400MB）"
        case .large8bit: return "高精度（1.8GB）"
        }
    }
}

/// 逻辑层的只读设置快照。
struct Settings {
    /// 识别语言定死中文普通话：中英混说由它覆盖，英文术语纠错交给精修层
    static let recognitionLocaleID = "zh_CN"
    /// 光标前文本读取长度（评测定值，不暴露给用户调节）
    static let contextMaxChars = 200

    var asrBackend: ASRBackendID
    var fuzzyRuleIDs: Set<String>
    var qwen3ModelID: String
    var apiBaseURL: String
    var apiModel: String
    var apiKey: String
    var hotkey: HotkeyChoice
    var refineStyle: RefineStyle
    var bluetoothMicStrategy: BluetoothMicStrategy
    /// 蓝牙输入时也播放开始提示音（默认关：多数耳机切 HFP 自带提示音，叠播更烦；
    /// 切换静默的耳机开这个兜底）。非蓝牙输入始终播放，不受此项影响。
    var startChimeAlways: Bool
    /// 自定义 LLM prompt（空 = 内置）
    var customPromptRefine: String
    var customPromptPinyin: String
    var customPromptTranslate: String

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.asrBackend: ASRBackendID.speechAnalyzer.rawValue,
            SettingsKey.fuzzyRules: Array(FuzzyRule.defaultEnabled),
            SettingsKey.qwen3ModelID: Qwen3ModelChoice.small4bit.rawValue,
            SettingsKey.apiBaseURL: "https://api.deepseek.com/v1",
            SettingsKey.apiModel: "deepseek-v4-flash",
            SettingsKey.apiKey: "",
            SettingsKey.hotkey: HotkeyChoice.rightOption.rawValue,
            SettingsKey.refineStyle: RefineStyle.clean.rawValue,
            SettingsKey.bluetoothMicStrategy: BluetoothMicStrategy.quickRelease.rawValue,
            SettingsKey.startChimeAlways: false,
            SettingsKey.customPromptRefine: "",
            SettingsKey.customPromptRefineDraft: "",
            SettingsKey.customPromptPinyin: "",
            SettingsKey.customPromptTranslate: "",
        ])
    }

    /// 存储的自定义 prompt 与内置一致就当没自定义（语音精修恢复跟随输出风格）。
    /// 旧版设置页「填入内置」会把内置文本存为自定义，启动时清理一次。
    static func normalizeCustomPrompts() {
        let d = UserDefaults.standard
        let refineDefaults = RefineStyle.allCases.map { VoiceRefiner.defaultInstructions(style: $0) }
        if let stored = d.string(forKey: SettingsKey.customPromptRefine), refineDefaults.contains(stored) {
            d.set("", forKey: SettingsKey.customPromptRefine)
        }
        if let draft = d.string(forKey: SettingsKey.customPromptRefineDraft), refineDefaults.contains(draft) {
            d.set("", forKey: SettingsKey.customPromptRefineDraft)
        }
        if d.string(forKey: SettingsKey.customPromptPinyin) == PinyinPromptBuilder.defaultInstructions() {
            d.set("", forKey: SettingsKey.customPromptPinyin)
        }
        if d.string(forKey: SettingsKey.customPromptTranslate) == TranslatorPromptBuilder.defaultInstructions() {
            d.set("", forKey: SettingsKey.customPromptTranslate)
        }
    }

    static func current() -> Settings {
        let d = UserDefaults.standard
        return Settings(
            asrBackend: ASRBackendID(rawValue: d.string(forKey: SettingsKey.asrBackend) ?? "") ?? .speechAnalyzer,
            fuzzyRuleIDs: Set((d.array(forKey: SettingsKey.fuzzyRules) as? [String]) ?? Array(FuzzyRule.defaultEnabled)),
            qwen3ModelID: d.string(forKey: SettingsKey.qwen3ModelID) ?? Qwen3ModelChoice.small4bit.rawValue,
            apiBaseURL: d.string(forKey: SettingsKey.apiBaseURL) ?? "https://api.deepseek.com/v1",
            apiModel: d.string(forKey: SettingsKey.apiModel) ?? "deepseek-v4-flash",
            apiKey: d.string(forKey: SettingsKey.apiKey) ?? "",
            hotkey: HotkeyChoice(rawValue: d.string(forKey: SettingsKey.hotkey) ?? "") ?? .rightOption,
            refineStyle: RefineStyle(rawValue: d.string(forKey: SettingsKey.refineStyle) ?? "") ?? .clean,
            bluetoothMicStrategy: BluetoothMicStrategy(
                rawValue: d.string(forKey: SettingsKey.bluetoothMicStrategy) ?? ""
            ) ?? .quickRelease,
            startChimeAlways: d.bool(forKey: SettingsKey.startChimeAlways),
            customPromptRefine: d.string(forKey: SettingsKey.customPromptRefine) ?? "",
            customPromptPinyin: d.string(forKey: SettingsKey.customPromptPinyin) ?? "",
            customPromptTranslate: d.string(forKey: SettingsKey.customPromptTranslate) ?? ""
        )
    }
}
