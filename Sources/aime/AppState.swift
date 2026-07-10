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

    private let overlay = OverlayController()
    private let hotkey = HotkeyMonitor()
    private var recorder: AudioRecorder?
    private var transcriberSession: TranscriberSession?
    private var contextSnapshot: ContextSnapshot?
    private var sessionCounter = 0
    private var activeHotkeyChoice: HotkeyChoice?

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
            Task { @MainActor in self?.reloadHotkeyIfNeeded() }
        }

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

    private func prepareModel() async {
        let localeID = Settings.current().localeID
        do {
            phase = .preparingModel
            try await TranscriberSession.ensureModel(localeID: localeID)
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
        let settings = Settings.current()

        // 先采上下文：此刻焦点还在目标应用
        contextSnapshot = settings.contextEnabled
            ? ContextCapture.capture(maxChars: settings.contextMaxChars)
            : ContextSnapshot(appName: NSWorkspace.shared.frontmostApplication?.localizedName, textBeforeCursor: nil)
        usedContext = false
        refineSkipped = settings.apiKey.isEmpty
        liveTranscript = ""
        finalText = ""

        let session = TranscriberSession()
        session.onUpdate = { [weak self] text in
            self?.liveTranscript = text
        }
        transcriberSession = session

        let recorder = AudioRecorder()
        recorder.onBuffer = { [weak session] buffer in
            session?.feed(buffer)
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        self.recorder = recorder

        do {
            try recorder.start()
        } catch {
            fail(error.localizedDescription)
            return
        }

        phase = .recording
        overlay.show(state: self)

        Task {
            do {
                try await session.start(localeID: settings.localeID)
            } catch {
                self.recorder?.stop()
                self.fail(error.localizedDescription)
            }
        }
    }

    private func finishSession() {
        let sessionID = sessionCounter
        recorder?.stop()
        recorder = nil
        audioLevel = 0
        phase = .transcribing

        guard let session = transcriberSession else {
            phase = .idle
            overlay.hide()
            return
        }

        Task {
            do {
                let raw = try await session.finish()
                guard self.sessionCounter == sessionID else { return }
                self.transcriberSession = nil

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
                self.transcriberSession = nil
                self.fail("转写失败：\(error.localizedDescription)")
            }
        }
    }

    func cancelSession() {
        guard phase == .recording || phase == .transcribing || phase == .refining else { return }
        sessionCounter += 1
        recorder?.stop()
        recorder = nil
        audioLevel = 0
        let session = transcriberSession
        transcriberSession = nil
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
