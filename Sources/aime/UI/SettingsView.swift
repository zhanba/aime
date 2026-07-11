import AimeASR
import SwiftUI

/// 分页式设置窗（macOS 标准形态），每页内容紧凑，避免单页 Form 把窗口撑得过高。
struct SettingsView: View {
    var body: some View {
        TabView {
            VoiceSettingsTab()
                .tabItem { Label("语音", systemImage: "mic") }
            RefineSettingsTab()
                .tabItem { Label("精修", systemImage: "sparkles") }
            InputSettingsTab()
                .tabItem { Label("上下文与注入", systemImage: "text.cursor") }
            AdvancedSettingsTab()
                .tabItem { Label("高级", systemImage: "gearshape.2") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - 语音

private struct VoiceSettingsTab: View {
    @AppStorage(SettingsKey.asrBackend) private var asrBackend = ASRBackendID.speechAnalyzer.rawValue
    @AppStorage(SettingsKey.qwen3ModelID) private var qwen3ModelID = Qwen3ModelChoice.small4bit.rawValue
    @AppStorage(SettingsKey.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKey.localeID) private var localeID = "zh_CN"
    @ObservedObject private var state = AppState.shared

    private let locales: [(id: String, name: String)] = [
        ("zh_CN", "中文（普通话）"),
        ("en_US", "English (US)"),
        ("ja_JP", "日本語"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("识别引擎", selection: $asrBackend) {
                    ForEach(ASRBackendID.allCases) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                }
                if asrBackend == ASRBackendID.qwen3ASR.rawValue {
                    Picker("Qwen3 模型档位", selection: $qwen3ModelID) {
                        ForEach(Qwen3ModelChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice.rawValue)
                        }
                    }
                    if let status = state.modelDownloadStatus {
                        Label(status, systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    modelDiskRow
                }
            }
            Section {
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
            } footer: {
                Text("中英混说选“中文（普通话）”即可，英文术语的纠错交给精修层。切换语言后首次使用会下载对应模型。")
            }
        }
        .formStyle(.grouped)
    }

    /// 当前 Qwen3 档位的磁盘占用与管理入口
    @ViewBuilder
    private var modelDiskRow: some View {
        let usage = ModelStore.diskUsage(for: qwen3ModelID)
        HStack {
            Text("磁盘占用：\(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("打开模型目录") {
                NSWorkspace.shared.open(ModelStore.baseDir)
            }
            Button("删除此模型", role: .destructive) {
                ModelStore.delete(modelID: qwen3ModelID)
            }
            .disabled(usage == 0)
        }
    }
}

// MARK: - 精修

private struct RefineSettingsTab: View {
    @AppStorage(SettingsKey.apiBaseURL) private var apiBaseURL = "https://api.deepseek.com/v1"
    @AppStorage(SettingsKey.apiModel) private var apiModel = "deepseek-chat"
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.removeFillers) private var removeFillers = true
    @AppStorage(SettingsKey.formalize) private var formalize = false

    var body: some View {
        Form {
            Section {
                TextField("API Base URL", text: $apiBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                TextField("模型", text: $apiModel, prompt: Text("deepseek-chat"))
                SecureField("API Key", text: $apiKey)
            } footer: {
                Text("OpenAI 兼容接口。API Key 留空则跳过精修，直接使用原始转写，不发出任何网络请求。")
            }
            Section {
                Toggle("去除口语填充词（嗯、就是说、那个…）", isOn: $removeFillers)
                Toggle("口语转书面表达", isOn: $formalize)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 上下文与注入

private struct InputSettingsTab: View {
    @AppStorage(SettingsKey.contextEnabled) private var contextEnabled = true
    @AppStorage(SettingsKey.contextMaxChars) private var contextMaxChars = 200
    @AppStorage(SettingsKey.injectionMethod) private var injectionMethod = InjectionMethod.paste.rawValue

    var body: some View {
        Form {
            Section {
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
                }
            } footer: {
                Text("仅在按下快捷键的瞬间读取一次，用于识别偏置与精修纠错；只有配置了 API 时才会随精修请求发送。")
            }
            Section {
                Picker("注入方式", selection: $injectionMethod) {
                    ForEach(InjectionMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 高级（daemon + 权限）

private struct AdvancedSettingsTab: View {
    @AppStorage(SettingsKey.useDaemon) private var useDaemon = false
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Form {
            Section("后台推理服务（实验性）") {
                Toggle("使用 aime-daemon 承载模型与录音", isOn: $useDaemon)
                HStack {
                    Text("状态：\(state.daemon.statusText) · 会话运行于 \(state.executionMode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.daemon.approvalRequired {
                        Button("去批准") { state.daemon.openLoginItemsSettings() }
                    }
                    Button("重新注册") { state.daemon.register() }
                }
                Text("开启后模型常驻后台进程，app 重启不用重新加载；首次使用需为 aime-daemon 单独授予麦克风权限。不可用时自动回退进程内运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
