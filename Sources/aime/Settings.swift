import AimeASR
import AimePinyin
import Foundation

/// UserDefaults 键名。SwiftUI 视图用 @AppStorage 绑定同名键，逻辑层通过 `Settings` 读取。
enum SettingsKey {
    static let asrBackend = "asrBackend"
    static let useDaemon = "useDaemon"
    static let fuzzyRules = "fuzzyRules"
    static let qwen3ModelID = "qwen3ModelID"
    static let apiBaseURL = "apiBaseURL"
    static let apiModel = "apiModel"
    static let apiKey = "apiKey" // TODO: M2 迁移到 Keychain
    static let localeID = "localeID"
    static let hotkey = "hotkey"
    static let removeFillers = "removeFillers"
    static let formalize = "formalize"
    static let contextEnabled = "contextEnabled"
    static let contextMaxChars = "contextMaxChars"
    static let injectionMethod = "injectionMethod"
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

enum InjectionMethod: String, CaseIterable, Identifiable {
    case paste
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: return "粘贴（推荐，长文本可靠）"
        case .type: return "模拟键入（不占用剪贴板）"
        }
    }
}

/// 逻辑层的只读设置快照。
/// Qwen3-ASR 可选档位（HF 上的 MLX 转换版）
enum Qwen3ModelChoice: String, CaseIterable, Identifiable {
    case small4bit = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    case large8bit = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small4bit: return "0.6B 4-bit（约 400MB，低配机型）"
        case .large8bit: return "1.7B 8-bit（约 1.8GB，质量更高）"
        }
    }
}

struct Settings {
    var asrBackend: ASRBackendID
    var useDaemon: Bool
    var fuzzyRuleIDs: Set<String>
    var qwen3ModelID: String
    var apiBaseURL: String
    var apiModel: String
    var apiKey: String
    var localeID: String
    var hotkey: HotkeyChoice
    var removeFillers: Bool
    var formalize: Bool
    var contextEnabled: Bool
    var contextMaxChars: Int
    var injectionMethod: InjectionMethod

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.asrBackend: ASRBackendID.speechAnalyzer.rawValue,
            SettingsKey.useDaemon: false,
            SettingsKey.fuzzyRules: Array(FuzzyRule.defaultEnabled),
            SettingsKey.qwen3ModelID: Qwen3ModelChoice.small4bit.rawValue,
            SettingsKey.apiBaseURL: "https://api.deepseek.com/v1",
            SettingsKey.apiModel: "deepseek-chat",
            SettingsKey.apiKey: "",
            SettingsKey.localeID: "zh_CN",
            SettingsKey.hotkey: HotkeyChoice.rightOption.rawValue,
            SettingsKey.removeFillers: true,
            SettingsKey.formalize: false,
            SettingsKey.contextEnabled: true,
            SettingsKey.contextMaxChars: 200,
            SettingsKey.injectionMethod: InjectionMethod.paste.rawValue,
        ])
    }

    static func current() -> Settings {
        let d = UserDefaults.standard
        return Settings(
            asrBackend: ASRBackendID(rawValue: d.string(forKey: SettingsKey.asrBackend) ?? "") ?? .speechAnalyzer,
            useDaemon: d.bool(forKey: SettingsKey.useDaemon),
            fuzzyRuleIDs: Set((d.array(forKey: SettingsKey.fuzzyRules) as? [String]) ?? Array(FuzzyRule.defaultEnabled)),
            qwen3ModelID: d.string(forKey: SettingsKey.qwen3ModelID) ?? Qwen3ModelChoice.small4bit.rawValue,
            apiBaseURL: d.string(forKey: SettingsKey.apiBaseURL) ?? "https://api.deepseek.com/v1",
            apiModel: d.string(forKey: SettingsKey.apiModel) ?? "deepseek-chat",
            apiKey: d.string(forKey: SettingsKey.apiKey) ?? "",
            localeID: d.string(forKey: SettingsKey.localeID) ?? "zh_CN",
            hotkey: HotkeyChoice(rawValue: d.string(forKey: SettingsKey.hotkey) ?? "") ?? .rightOption,
            removeFillers: d.bool(forKey: SettingsKey.removeFillers),
            formalize: d.bool(forKey: SettingsKey.formalize),
            contextEnabled: d.bool(forKey: SettingsKey.contextEnabled),
            contextMaxChars: d.integer(forKey: SettingsKey.contextMaxChars),
            injectionMethod: InjectionMethod(rawValue: d.string(forKey: SettingsKey.injectionMethod) ?? "") ?? .paste
        )
    }
}
