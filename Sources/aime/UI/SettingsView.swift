import AimeASR
import AimePinyin
import SwiftUI

/// 分页式设置窗（macOS 标准形态）。分组按用户心智而非模块架构：
/// 语音（怎么说）/ 拼音（怎么打，含词库）/ AI 服务（大脑与数据）。
/// 权限、后台服务这类排障项不单设页面：正常时不可见，异常时在语音页浮出；
/// 蓝牙收音选项同理，只在默认输入是蓝牙耳机时出现。
struct SettingsView: View {
    var body: some View {
        TabView {
            VoiceSettingsTab()
                .tabItem { Label("语音", systemImage: "mic") }
            PinyinSettingsTab()
                .tabItem { Label("拼音", systemImage: "keyboard") }
            AIServiceTab()
                .tabItem { Label("AI 服务", systemImage: "sparkles") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
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
    @AppStorage(SettingsKey.bluetoothMicStrategy) private var bluetoothMicStrategy = BluetoothMicStrategy.quickRelease.rawValue
    @AppStorage(SettingsKey.startChimeAlways) private var startChimeAlways = false
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var daemon = AppState.shared.daemon
    @State private var bluetoothInput = AudioRecorder.defaultInputIsBluetoothHeadset

    private var enhancedRecognition: Binding<Bool> {
        Binding(
            get: { asrBackend == ASRBackendID.qwen3ASR.rawValue },
            set: { asrBackend = ($0 ? ASRBackendID.qwen3ASR : ASRBackendID.speechAnalyzer).rawValue }
        )
    }

    private var needsAttention: Bool {
        !state.micGranted || !state.accessibilityGranted || daemon.approvalRequired
    }

    /// 存储值容错：历史/未知取值（如已下线的常驻模式）显示为默认策略
    private var micStrategy: Binding<BluetoothMicStrategy> {
        Binding(
            get: { BluetoothMicStrategy(rawValue: bluetoothMicStrategy) ?? .quickRelease },
            set: { bluetoothMicStrategy = $0.rawValue }
        )
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
                Toggle("增强识别", isOn: enhancedRecognition)
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
                Text("中英混说更准，首次开启需下载模型。")
            }
            if bluetoothInput {
                Section {
                    Picker("麦克风", selection: micStrategy) {
                        ForEach(BluetoothMicStrategy.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    if micStrategy.wrappedValue == .quickRelease {
                        Toggle("始终播放开始提示音", isOn: $startChimeAlways)
                    }
                } footer: {
                    Text(
                        micStrategy.wrappedValue == .quickRelease
                            ? "耳机麦启动约 1 秒；内置麦克风即按即录。听不到耳机自带的启动提示音时，开启始终播放。"
                            : "耳机麦启动约 1 秒；内置麦克风即按即录。"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { bluetoothInput = AudioRecorder.defaultInputIsBluetoothHeadset }
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

// MARK: - 关于

private struct AboutTab: View {
    /// 裸跑（swift run，非 bundle）时没有版本字段，标开发版
    private var versionText: String {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "开发版"
        }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: versionText)
                LabeledContent("软件更新") {
                    Button("检查更新…") {
                        UpdaterController.shared.checkForUpdates()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI 服务

private struct AIServiceTab: View {
    @AppStorage(SettingsKey.apiBaseURL) private var apiBaseURL = "https://api.deepseek.com/v1"
    @AppStorage(SettingsKey.apiModel) private var apiModel = "deepseek-v4-flash"
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.refineStyle) private var refineStyle = RefineStyle.clean.rawValue
    @AppStorage(SettingsKey.customPromptRefine) private var customPromptRefine = ""
    @AppStorage(SettingsKey.customPromptRefineDraft) private var customPromptRefineDraft = ""
    @AppStorage(SettingsKey.customPromptPinyin) private var customPromptPinyin = ""
    @AppStorage(SettingsKey.customPromptTranslate) private var customPromptTranslate = ""
    @State private var promptTarget = PromptTarget.refine

    /// 语音精修的 prompt 模式：三个内置风格 + 「自定义」（有自定义文本时才出现）
    private enum RefinePromptMode: Hashable {
        case style(RefineStyle)
        case custom
    }

    private enum PromptTarget: String, CaseIterable, Identifiable {
        case refine, pinyin, translate

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .refine: return "语音精修"
            case .pinyin: return "拼音转换"
            case .translate: return "中译英"
            }
        }
    }

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
                Text("留空即纯本地运行；只发送文本，永不发送音频。")
            }
            Section {
                Picker("功能", selection: $promptTarget) {
                    ForEach(PromptTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                if promptTarget == .refine {
                    Picker("输出风格", selection: refineMode) {
                        ForEach(RefineStyle.allCases) { style in
                            Text(style.displayName).tag(RefinePromptMode.style(style))
                        }
                        if !customPromptRefine.isEmpty || !customPromptRefineDraft.isEmpty {
                            Text("自定义").tag(RefinePromptMode.custom)
                        }
                    }
                }
                TextEditor(text: currentPrompt)
                    .font(.callout)
                    .frame(height: 140)
                    .id(editorIdentity) // 内容来源变化时重建编辑器，防止旧文本经复用的 NSTextView 写进新目标
                if promptTarget != .refine, isCustomized {
                    HStack {
                        Text("已自定义")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复内置") { storedPrompt.wrappedValue = "" }
                    }
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text(
                    promptTarget == .refine
                        ? "直接编辑即成为「自定义」；切回任一风格时自定义内容保留，可随时切换。光标前文等上下文始终自动附加。"
                        : "可直接修改。光标前文、用户词库等上下文仍会自动附加。"
                )
            }
        }
        .formStyle(.grouped)
    }

    /// 精修 prompt 模式：选中风格＝清掉自定义（文本进草稿）；选中「自定义」＝从草稿恢复。
    /// 切换全程无损，所以不需要确认框。
    private var refineMode: Binding<RefinePromptMode> {
        Binding(
            get: {
                customPromptRefine.isEmpty
                    ? .style(RefineStyle(rawValue: refineStyle) ?? .clean)
                    : .custom
            },
            set: { mode in
                switch mode {
                case .style(let style):
                    if !customPromptRefine.isEmpty {
                        customPromptRefineDraft = customPromptRefine
                        customPromptRefine = ""
                    }
                    refineStyle = style.rawValue
                case .custom:
                    if customPromptRefine.isEmpty, !customPromptRefineDraft.isEmpty {
                        customPromptRefine = customPromptRefineDraft
                    }
                }
            }
        )
    }

    /// 编辑器身份跟随内容来源：功能、精修风格、内置/自定义。任一变化都重建，
    /// 避免复用的 NSTextView 把旧文本写回新来源（表现为切个风格就莫名变成自定义）。
    private var editorIdentity: String {
        "\(promptTarget.rawValue)-\(refineStyle)-\(customPromptRefine.isEmpty)"
    }

    /// 内容与内置一致就不算自定义（不只看非空）
    private var isCustomized: Bool {
        let stored = storedPrompt.wrappedValue
        return !stored.isEmpty && stored != defaultPrompt
    }

    /// 存储值：空 = 未自定义（引擎用内置）
    private var storedPrompt: Binding<String> {
        switch promptTarget {
        case .refine: return $customPromptRefine
        case .pinyin: return $customPromptPinyin
        case .translate: return $customPromptTranslate
        }
    }

    /// 编辑框显示生效中的 prompt：未自定义时显示内置；
    /// 改回与内置一致（或清空）即恢复未自定义，语音精修重新跟随输出风格
    private var currentPrompt: Binding<String> {
        let stored = storedPrompt
        let fallback = defaultPrompt
        return Binding(
            get: { stored.wrappedValue.isEmpty ? fallback : stored.wrappedValue },
            set: { edited in
                let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                stored.wrappedValue = (edited == fallback || trimmed.isEmpty) ? "" : edited
            }
        )
    }

    private var defaultPrompt: String {
        switch promptTarget {
        case .refine:
            return VoiceRefiner.defaultInstructions(style: RefineStyle(rawValue: refineStyle) ?? .clean)
        case .pinyin:
            return PinyinPromptBuilder.defaultInstructions()
        case .translate:
            return TranslatorPromptBuilder.defaultInstructions()
        }
    }
}
