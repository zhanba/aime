import AimeASR
import AppKit
import SwiftUI

/// 一次语音输入会话的状态机：
/// idle → recording →（松开）transcribing → refining → done → idle
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case preparingModel
        case recording
        case transcribing
        case refining
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""
    @Published var finalText: String = ""
    @Published var usedContext = false
    @Published var refineSkipped = false
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var modelReady = false
    /// 模型下载/准备进度文案（nil 表示无进行中）
    @Published var modelDownloadStatus: String?
    /// 会话实际运行的位置："daemon" / "in-process"
    @Published var executionMode = "in-process"

    let daemon = DaemonManager()

    private let overlay = OverlayController()
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
        accessibilityGranted = ContextCapture.ensureAccessibilityPermission(prompt: true)

        hotkey.onPressDown = { [weak self] in Task { @MainActor in self?.hotkeyPressed() } }
        hotkey.onPressUp = { [weak self] in Task { @MainActor in self?.hotkeyReleased() } }
        hotkey.onEscape = { [weak self] in Task { @MainActor in self?.cancelSession() } }
        reloadHotkeyIfNeeded()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadHotkeyIfNeeded()
                self?.reloadBackendIfNeeded()
            }
        }

        daemon.bootstrap()

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
            localeID: settings.localeID,
            qwen3ModelID: settings.qwen3ModelID,
            contextHint: contextHint
        )
    }

    /// 选择会话后端：daemon 可用且用户开启时走 XPC，否则进程内。
    private func resolveBackend() async -> ASRBackend {
        let settings = Settings.current()
        if settings.useDaemon, await daemon.isHealthy() {
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
        contextSnapshot = settings.contextEnabled
            ? ContextCapture.capture(maxChars: settings.contextMaxChars)
            : ContextSnapshot(appName: NSWorkspace.shared.frontmostApplication?.localizedName, textBeforeCursor: nil)
        usedContext = false
        refineSkipped = settings.apiKey.isEmpty
        liveTranscript = ""
        finalText = ""

        // 识别偏置：光标前文本喂给支持 context 的后端（Qwen3-ASR）
        var contextHint: String?
        if settings.contextEnabled, let before = contextSnapshot?.textBeforeCursor, !before.isEmpty {
            contextHint = String(before.suffix(200))
        }
        let config = sessionConfig(contextHint: contextHint)

        phase = .recording
        overlay.show(state: self)

        Task {
            let session = await resolveBackend().makeSession()
            guard self.sessionCounter == sessionID else {
                await session.cancel()
                return
            }
            session.onUpdate = { [weak self] text in
                self?.liveTranscript = text
            }
            session.onLevel = { [weak self] level in
                self?.audioLevel = level
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
                    self.fail("没有听到内容")
                    return
                }

                let settings = Settings.current()
                var output = raw
                if !settings.apiKey.isEmpty {
                    self.phase = .refining
                    self.usedContext = settings.contextEnabled && (self.contextSnapshot?.hasText ?? false)
                    do {
                        output = try await LLMRefiner().refine(.init(
                            rawTranscript: raw,
                            context: settings.contextEnabled ? self.contextSnapshot : nil,
                            settings: settings
                        ))
                    } catch {
                        // 精修失败回退原始转写，不阻塞输入
                        output = raw
                        self.refineSkipped = true
                    }
                }

                guard self.sessionCounter == sessionID else { return }
                self.finalText = output
                TextInjector.inject(output, method: settings.injectionMethod)
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
        phase = .failed(message)
        overlay.show(state: self)
        let sessionID = sessionCounter
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .failed = self.phase, self.sessionCounter == sessionID {
                self.phase = .idle
                self.overlay.hide()
            }
        }
    }
}
