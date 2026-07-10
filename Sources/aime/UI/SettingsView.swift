import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKey.localeID) private var localeID = "zh_CN"
    @AppStorage(SettingsKey.apiBaseURL) private var apiBaseURL = "https://api.deepseek.com/v1"
    @AppStorage(SettingsKey.apiModel) private var apiModel = "deepseek-chat"
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.removeFillers) private var removeFillers = true
    @AppStorage(SettingsKey.formalize) private var formalize = false
    @AppStorage(SettingsKey.contextEnabled) private var contextEnabled = true
    @AppStorage(SettingsKey.contextMaxChars) private var contextMaxChars = 200
    @AppStorage(SettingsKey.injectionMethod) private var injectionMethod = InjectionMethod.paste.rawValue

    @ObservedObject private var state = AppState.shared

    private let locales: [(id: String, name: String)] = [
        ("zh_CN", "中文（普通话）"),
        ("en_US", "English (US)"),
        ("ja_JP", "日本語"),
    ]

    var body: some View {
        Form {
            Section("语音输入") {
                Picker("按住说话快捷键", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                Picker("识别语言", selection: $localeID) {
                    ForEach(locales, id: \.id) { locale in
                        Text(locale.name).tag(locale.id)
                    }
                }
                Text("中英混说选“中文（普通话）”即可，英文术语的纠错交给精修层。切换语言后首次使用会下载对应模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("LLM 精修") {
                TextField("API Base URL", text: $apiBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                TextField("模型", text: $apiModel, prompt: Text("deepseek-chat"))
                SecureField("API Key（留空则跳过精修，直接使用原始转写）", text: $apiKey)
                Toggle("去除口语填充词（嗯、就是说、那个…）", isOn: $removeFillers)
                Toggle("口语转书面表达", isOn: $formalize)
            }

            Section("上下文") {
                Toggle("读取光标前文本辅助纠错", isOn: $contextEnabled)
                if contextEnabled {
                    LabeledContent("读取长度") {
                        Slider(value: Binding(
                            get: { Double(contextMaxChars) },
                            set: { contextMaxChars = Int($0) }
                        ), in: 50 ... 500, step: 50) {
                            Text("读取长度")
                        }
                        Text("\(contextMaxChars) 字")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text("仅在按下快捷键的瞬间读取一次，并随精修请求发送给你配置的 API。未配置 API 时不会发送。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("文本注入") {
                Picker("注入方式", selection: $injectionMethod) {
                    ForEach(InjectionMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                }
            }

            Section("权限") {
                permissionRow(
                    name: "麦克风",
                    granted: state.micGranted,
                    pane: "Privacy_Microphone"
                )
                permissionRow(
                    name: "辅助功能（全局快捷键 / 上下文 / 注入）",
                    granted: state.accessibilityGranted,
                    pane: "Privacy_Accessibility"
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private func permissionRow(name: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(name)
            Spacer()
            if !granted {
                Button("打开系统设置") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
