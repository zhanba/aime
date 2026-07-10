import Foundation

/// UserDefaults 键名。SwiftUI 视图用 @AppStorage 绑定同名键，逻辑层通过 `Settings` 读取。
enum SettingsKey {
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
struct Settings {
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
