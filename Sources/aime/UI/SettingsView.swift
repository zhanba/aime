import AimeASR
import SwiftUI

/// 分页式设置窗（macOS 标准形态）。分组按用户心智而非模块架构：
/// 语音（怎么说）/ 拼音（怎么打）/ 教它（词库）/ AI 服务（大脑与数据）。
/// 权限、后台服务这类排障项不单设页面：正常时不可见，异常时在语音页浮出。
struct SettingsView: View {
    var body: some View {
        TabView {
            VoiceSettingsTab()
                .tabItem { Label("语音", systemImage: "mic") }
            PinyinSettingsTab()
                .tabItem { Label("拼音", systemImage: "keyboard") }
            DictionaryTab()
                .tabItem { Label("教它", systemImage: "book") }
            AIServiceTab()
                .tabItem { Label("AI 服务", systemImage: "sparkles") }
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
    @AppStorage(SettingsKey.refineStyle) private var refineStyle = RefineStyle.clean.rawValue
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var daemon = AppState.shared.daemon

    private var enhancedRecognition: Binding<Bool> {
        Binding(
            get: { asrBackend == ASRBackendID.qwen3ASR.rawValue },
            set: { asrBackend = ($0 ? ASRBackendID.qwen3ASR : ASRBackendID.speechAnalyzer).rawValue }
        )
    }

    private var needsAttention: Bool {
        !state.micGranted || !state.accessibilityGranted || daemon.approvalRequired
    }

    var body: some View {
        Form {
            if needsAttention {
                Section("需要处理") {
                    if !state.micGranted {
                        attentionRow("未授予麦克风权限，语音输入不可用", buttonTitle: "打开系统设置") {
                            openPrivacyPane("Privacy_Microphone")
                        }
                    }
                    if !state.accessibilityGranted {
                        attentionRow("未授予辅助功能权限，快捷键与文本注入不可用", buttonTitle: "打开系统设置") {
                            openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                    if daemon.approvalRequired {
                        attentionRow("后台语音服务等待批准", buttonTitle: "去批准") {
                            daemon.openLoginItemsSettings()
                        }
                    }
                }
            }
            Section {
                Picker("按住说话快捷键", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
            }
            Section {
                Toggle("增强识别（本地 AI 模型）", isOn: enhancedRecognition)
                if enhancedRecognition.wrappedValue {
                    Picker("模型", selection: $qwen3ModelID) {
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
            } footer: {
                Text("中英混说识别显著更准，模型完全在本机运行，首次开启需下载。关闭则使用 macOS 系统识别，零下载。")
            }
            Section {
                Picker("输出风格", selection: $refineStyle) {
                    ForEach(RefineStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
            } footer: {
                Text("「清爽」和「书面」由 AI 精修完成，需配置「AI 服务」；未配置时直接输出识别原文。")
            }
        }
        .formStyle(.grouped)
    }

    private func attentionRow(_ message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
            Spacer()
            Button(buttonTitle, action: action)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    /// 当前增强模型的磁盘占用与删除入口
    @ViewBuilder
    private var modelDiskRow: some View {
        let usage = ModelStore.diskUsage(for: qwen3ModelID)
        if usage > 0 {
            HStack {
                Text("已下载：\(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("删除模型", role: .destructive) {
                    ModelStore.delete(modelID: qwen3ModelID)
                }
            }
        }
    }
}

// MARK: - AI 服务

private struct AIServiceTab: View {
    @AppStorage(SettingsKey.apiBaseURL) private var apiBaseURL = "https://api.deepseek.com/v1"
    @AppStorage(SettingsKey.apiModel) private var apiModel = "deepseek-v4-flash"
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.contextEnabled) private var contextEnabled = true

    private enum APIPreset: String, CaseIterable, Identifiable {
        case deepseek, openai, custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .deepseek: return "DeepSeek"
            case .openai: return "OpenAI"
            case .custom: return "自定义"
            }
        }

        var baseURL: String? {
            switch self {
            case .deepseek: return "https://api.deepseek.com/v1"
            case .openai: return "https://api.openai.com/v1"
            case .custom: return nil
            }
        }

        var defaultModel: String? {
            switch self {
            case .deepseek: return "deepseek-v4-flash"
            case .openai: return "gpt-4o-mini"
            case .custom: return nil
            }
        }
    }

    /// 预设由当前 baseURL 反推，手动改过 URL 即视为自定义
    private var preset: Binding<APIPreset> {
        Binding(
            get: {
                APIPreset.allCases.first { $0.baseURL == apiBaseURL } ?? .custom
            },
            set: { chosen in
                if let base = chosen.baseURL, let model = chosen.defaultModel {
                    apiBaseURL = base
                    apiModel = model
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("服务商", selection: preset) {
                    ForEach(APIPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                if preset.wrappedValue == .custom {
                    TextField("API Base URL", text: $apiBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                }
                TextField("模型", text: $apiModel, prompt: Text("deepseek-v4-flash"))
                SecureField("API Key", text: $apiKey)
            } footer: {
                Text("语音精修与拼音整句共用（OpenAI 兼容接口）。API Key 留空则一切功能纯本地运行，不发出任何网络请求；配置后也只发送转写文本与拼音分析，永不发送音频。")
            }
            Section {
                Toggle("读取光标前文本辅助纠错", isOn: $contextEnabled)
            } footer: {
                Text("仅在开始输入的瞬间读取一次，用于识别偏置与纠错；只会随精修请求发送到上面配置的服务。")
            }
        }
        .formStyle(.grouped)
    }
}
