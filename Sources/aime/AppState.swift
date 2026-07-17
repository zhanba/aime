import AimeASR
import AimePinyin
import AimeUI
import AppKit
import Carbon
import SwiftUI

/// 一次语音输入会话的状态机：
/// idle → recording →（松开）transcribing → refining → done → idle
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// 语音会话可视状态（浮层数据源），与 IME 进程共用同一套 overlay UI
    let voice = VoiceOverlayModel()

    var phase: VoicePhase {
        get { voice.phase }
        set { voice.phase = newValue }
    }

    var audioLevel: Float {
        get { voice.audioLevel }
        set { voice.audioLevel = newValue }
    }

    var liveTranscript: String {
        get { voice.liveTranscript }
        set { voice.liveTranscript = newValue }
    }

    var finalText: String {
        get { voice.finalText }
        set { voice.finalText = newValue }
    }

    var usedContext: Bool {
        get { voice.usedContext }
        set { voice.usedContext = newValue }
    }

    var refineSkipped: Bool {
        get { voice.refineSkipped }
        set { voice.refineSkipped = newValue }
    }

    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var modelReady = false
    /// 模型下载/准备进度文案（nil 表示无进行中）
    @Published var modelDownloadStatus: String?
    /// 会话实际运行的位置："daemon" / "in-process"
    @Published var executionMode = "in-process"

    let daemon = DaemonManager()

    private let overlay = VoiceOverlayController()
    private let hotkey = HotkeyMonitor()
    private var asrSession: ASRSession?
    private var contextSnapshot: ContextSnapshot?
    private var sessionCounter = 0
    private var activeHotkeyChoice: HotkeyChoice?
    private var activeBackendID: ASRBackendID?
    private var activeQwenModelID: String?

    // MARK: - 启动

    func bootstrap() {
        Settings.registerDefaults()
        Settings.normalizeCustomPrompts()
        accessibilityGranted = ContextCapture.ensureAccessibilityPermission(prompt: true)

        hotkey.onPressDown = { [weak self] in Task { @MainActor in self?.hotkeyPressed() } }
        hotkey.onPressUp = { [weak self] in Task { @MainActor in self?.hotkeyReleased() } }
        hotkey.onEscape = { [weak self] in Task { @MainActor in self?.cancelSession() } }
        reloadHotkeyIfNeeded()

        // 只观察 standard defaults：镜像写共享 suite 也会发同名通知，
        // object: nil 会形成 写→通知→再写 的死循环（主线程 100%）
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadHotkeyIfNeeded()
                self?.reloadBackendIfNeeded()
                Self.mirrorSharedConfig()
            }
        }
        Self.mirrorSharedConfig()

        daemon.bootstrap()
        // 词库是本地整句/词候选的前提，缺失时自动补齐（约 12MB），不等用户去设置页点
        LexiconInstaller.shared.installIfNeeded()
        // 输入法副本随主程序更新自动跟进（Sparkle 只更新 aime.app）
        IMEInstaller.autoUpdateIfNeeded()

        Task {
            micGranted = await AudioRecorder.requestPermission()
            await prepareModel()
        }

        // 辅助功能授权是在系统设置里完成的，轮询刷新状态
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.accessibilityGranted = ContextCapture.isTrusted
            }
        }
    }

    /// 把拼音输入法（独立进程）需要的配置镜像到共享 suite
    private static func mirrorSharedConfig() {
        let settings = Settings.current()
        SharedConfig.mirrorFromApp(
            apiBaseURL: settings.apiBaseURL,
            apiModel: settings.apiModel,
            apiKey: settings.apiKey,
            fuzzyRuleIDs: settings.fuzzyRuleIDs
        )
        SharedConfig.mirrorASRFromApp(
            backendRaw: settings.asrBackend.rawValue,
            qwen3ModelID: settings.qwen3ModelID,
            localeID: Settings.recognitionLocaleID,
            bluetoothMicStrategyRaw: settings.bluetoothMicStrategy.rawValue,
            startChimeAlways: settings.startChimeAlways
        )
        SharedConfig.mirrorRefineFromApp(refineStyleRaw: settings.refineStyle.rawValue)
        SharedConfig.mirrorPromptsFromApp(
            refine: settings.customPromptRefine,
            pinyin: settings.customPromptPinyin,
            translate: settings.customPromptTranslate
        )
        // 纯本地模式/屏蔽应用已从产品中移除（API Key 留空即纯本地），清掉历史遗留值
        SharedConfig.mirrorPrivacyFromApp(blockedApps: [], pureLocalMode: false)
        // 组合区形态定死分词拼音（覆盖历史遗留的预览模式取值）
        SharedConfig.mirrorCompositionDisplay(showsPinyin: true)
    }

    /// aime拼音 是当前输入法时，语音热键由 IME 处理（进 composition），app 侧让路
    private var aimeIMESelected: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return id == "com.zhanba.inputmethod.aime"
    }

    private func reloadHotkeyIfNeeded() {
        let choice = Settings.current().hotkey
        guard choice != activeHotkeyChoice else { return }
        activeHotkeyChoice = choice
        hotkey.start(choice: choice)
    }

    private func reloadBackendIfNeeded() {
        let settings = Settings.current()
        let backendChanged = settings.asrBackend != activeBackendID
        let modelChanged = settings.asrBackend == .qwen3ASR && settings.qwen3ModelID != activeQwenModelID
        guard backendChanged || modelChanged, phase == .idle || phase == .preparingModel else { return }
        Task { await prepareModel() }
    }

    private func sessionConfig(contextHint: String? = nil) -> ASRSessionConfig {
        let settings = Settings.current()
        return ASRSessionConfig(
            backend: settings.asrBackend,
            localeID: Settings.recognitionLocaleID,
            qwen3ModelID: settings.qwen3ModelID,
            contextHint: contextHint,
            bluetoothMicStrategy: settings.bluetoothMicStrategy
        )
    }

    /// 选择会话后端：daemon 可用走 XPC，否则自动回退进程内。
    private func resolveBackend() async -> ASRBackend {
        let settings = Settings.current()
        if await daemon.isHealthy() {
            executionMode = "daemon"
            return daemon.proxyBackend
        }
        executionMode = "in-process"
        return ASRBackendRegistry.shared.backend(for: settings.asrBackend)
    }

    private func prepareModel() async {
        let settings = Settings.current()
        activeBackendID = settings.asrBackend
        activeQwenModelID = settings.qwen3ModelID
        let backend = await resolveBackend()
        backend.onProgress = { [weak self] status in
            Task { @MainActor in self?.modelDownloadStatus = status }
        }
        do {
            phase = .preparingModel
            modelReady = false
            try await backend.prepareModel(config: sessionConfig())
            modelReady = true
            phase = .idle
        } catch {
            modelReady = false
            fail("语音模型准备失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 会话流程

    private func hotkeyPressed() {
        guard !aimeIMESelected else { return }
        guard phase == .idle || phase == .done else { return }
        guard micGranted else {
            fail("未授予麦克风权限，请在系统设置中开启")
            return
        }
        startSession()
    }

    private func hotkeyReleased() {
        guard phase == .recording else { return }
        finishSession()
    }

    private func startSession() {
        sessionCounter += 1
        let sessionID = sessionCounter
        let settings = Settings.current()

        // 先采上下文：此刻焦点还在目标应用
        contextSnapshot = ContextCapture.capture(maxChars: Settings.contextMaxChars)
        usedContext = false
        refineSkipped = settings.apiKey.isEmpty
        liveTranscript = ""
        finalText = ""

        // 识别偏置：光标前文本 + 用户词库热词（词库双向增强的语音侧入口）
        var hintParts: [String] = []
        if let before = contextSnapshot?.textBeforeCursor, !before.isEmpty {
            hintParts.append(String(before.suffix(200)))
        }
        let hotwords = UserDictionary.shared.topEntries(12)
        if !hotwords.isEmpty {
            hintParts.append("常用词：" + hotwords.joined(separator: "、"))
        }
        let config = sessionConfig(contextHint: hintParts.isEmpty ? nil : hintParts.joined(separator: "\n"))

        phase = .recording
        voice.captureReady = false
        overlay.show(model: voice)

        Task {
            let session = await resolveBackend().makeSession()
            guard self.sessionCounter == sessionID else {
                await session.cancel()
                return
            }
            session.onUpdate = { [weak self] text in
                // 伪流式整段重解码偶发被幻觉防护清空：忽略空帧保留上一帧，
                // 避免浮层「有无文本」层级来回跳（标题字号/颜色反复切换）
                guard !text.isEmpty else { return }
                self?.liveTranscript = text
            }
            session.onLevel = { [weak self] level in
                self?.audioLevel = level
            }
            session.onCaptureReady = { [weak self] inputIsBluetooth in
                guard let self, self.sessionCounter == sessionID else { return }
                self.voice.captureReady = true
                VoiceChime.playStart(inputIsBluetooth: inputIsBluetooth, always: settings.startChimeAlways)
            }
            self.asrSession = session
            do {
                try await session.start(config: config)
            } catch {
                await session.cancel()
                if self.sessionCounter == sessionID {
                    self.asrSession = nil
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finishSession() {
        let sessionID = sessionCounter
        audioLevel = 0
        phase = .transcribing

        guard let session = asrSession else {
            phase = .idle
            overlay.hide()
            return
        }

        Task {
            do {
                let raw = try await session.finish().text
                guard self.sessionCounter == sessionID else { return }
                self.asrSession = nil

                guard !raw.isEmpty else {
                    self.flash(.noSpeech)
                    return
                }

                let settings = Settings.current()
                var output = raw
                if !settings.apiKey.isEmpty {
                    self.phase = .refining
                    self.usedContext = self.contextSnapshot?.hasText ?? false
                    // 精修期间浮层先展示 ASR 原文，流式精修结果到达后逐步替换
                    self.liveTranscript = raw
                    do {
                        let context = self.contextSnapshot
                        output = try await VoiceRefiner().refine(
                            transcript: raw,
                            appName: context?.appName,
                            textBeforeCursor: context?.textBeforeCursor,
                            style: settings.refineStyle,
                            config: PinyinLLMConfig(
                                apiBaseURL: settings.apiBaseURL,
                                apiModel: settings.apiModel,
                                apiKey: settings.apiKey,
                                enabledFuzzyRuleIDs: [],
                                customPromptRefine: settings.customPromptRefine
                            ),
                            onPartial: { [weak self] partial in
                                Task { @MainActor in
                                    guard let self, self.sessionCounter == sessionID,
                                          self.phase == .refining else { return }
                                    self.liveTranscript = partial
                                }
                            }
                        )
                    } catch {
                        // 精修失败回退原始转写，不阻塞输入
                        NSLog("语音精修失败，已回退原文: \(error)")
                        output = raw
                        self.refineSkipped = true
                    }
                }

                guard self.sessionCounter == sessionID else { return }
                self.finalText = output
                if (2 ... 8).contains(output.count) {
                    UserDictionary.shared.record(output, source: "voice")
                }
                TextInjector.inject(output)
                self.phase = .done
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if self.phase == .done, self.sessionCounter == sessionID {
                    self.phase = .idle
                    self.overlay.hide()
                }
            } catch {
                guard self.sessionCounter == sessionID else { return }
                self.asrSession = nil
                self.fail("转写失败：\(error.localizedDescription)")
            }
        }
    }

    func cancelSession() {
        guard phase == .recording || phase == .transcribing || phase == .refining else { return }
        sessionCounter += 1
        audioLevel = 0
        let session = asrSession
        asrSession = nil
        Task { await session?.cancel() }
        phase = .idle
        overlay.hide()
    }

    private func fail(_ message: String) {
        flash(.failed(message))
    }

    /// 终态短暂停留后自动收起（出错 3s、没听到内容 2s）
    private func flash(_ transient: VoicePhase) {
        phase = transient
        overlay.show(model: voice)
        let sessionID = sessionCounter
        let seconds: UInt64 = transient == .noSpeech ? 2_000_000_000 : 3_000_000_000
        Task {
            try? await Task.sleep(nanoseconds: seconds)
            if self.phase == transient, self.sessionCounter == sessionID {
                self.phase = .idle
                self.overlay.hide()
            }
        }
    }
}
