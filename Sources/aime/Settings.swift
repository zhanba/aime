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
    static let contextEnabled = "contextEnabled"
    static let bluetoothMicStrategy = "bluetoothMicStrategy"
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

/// 精修输出风格：一个维度替代「去填充词/转书面」两个独立开关
enum RefineStyle: String, CaseIterable, Identifiable {
    case raw
    case clean
    case formal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return "原样（保留口语风格）"
        case .clean: return "清爽（去除嗯、就是说等填充词）"
        case .formal: return "书面（整理为书面表达）"
        }
    }

    var removesFillers: Bool { self != .raw }
    var formalizes: Bool { self == .formal }
}

/// Qwen3-ASR 可选档位（HF 上的 MLX 转换版）
enum Qwen3ModelChoice: String, CaseIterable, Identifiable {
    case small4bit = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    case large8bit = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small4bit: return "标准（约 400MB）"
        case .large8bit: return "高精度（约 1.8GB，内存充足时选这个）"
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
    var contextEnabled: Bool
    var bluetoothMicStrategy: BluetoothMicStrategy

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
            SettingsKey.contextEnabled: true,
            SettingsKey.bluetoothMicStrategy: BluetoothMicStrategy.quickRelease.rawValue,
        ])
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
            contextEnabled: d.bool(forKey: SettingsKey.contextEnabled),
            bluetoothMicStrategy: BluetoothMicStrategy(
                rawValue: d.string(forKey: SettingsKey.bluetoothMicStrategy) ?? ""
            ) ?? .quickRelease
        )
    }
}
