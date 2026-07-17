import AVFoundation
import Speech

/// 系统 SpeechAnalyzer 后端：零下载、全离线的基线引擎。
public final class SpeechAnalyzerBackend: ASRBackend {
    public let id: ASRBackendID = .speechAnalyzer
    public var onProgress: ((String?) -> Void)?

    public init() {}

    public func prepareModel(config: ASRSessionConfig) async throws {
        onProgress?("准备系统语音模型…")
        defer { onProgress?(nil) }
        try await SpeechAnalyzerSession.ensureModel(localeID: config.localeID)
    }

    public func makeSession() -> ASRSession {
        SpeechAnalyzerSession()
    }
}

/// 一次录音会话（SpeechAnalyzer 流式转写），自持麦克风采集。
///
/// 线程模型：音频回调在音频线程；缓冲在 analyzer 格式确定前先入队，
/// 确定后统一冲刷，因此录音先于 analyzer 就绪启动也不丢首音节。
public final class SpeechAnalyzerSession: ASRSession {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let recorder = AudioRecorder()

    private let stateLock = NSLock()
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    private var finalizedText = ""
    private var volatileText = ""

    public var onUpdate: (@MainActor (String) -> Void)?
    public var onLevel: (@MainActor (Float) -> Void)?
    public var onCaptureReady: (@MainActor (Bool) -> Void)?

    public init() {}

    /// NSLock 的同步作用域封装，可安全地从 async 上下文调用。
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// 确保 locale 支持且模型资产已安装。首次调用会触发模型下载。
    public static func ensureModel(localeID: String) async throws {
        let locale = Locale(identifier: localeID)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AimeError.localeUnsupported(localeID)
        }
        let probe = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    public func start(config: ASRSessionConfig) async throws {
        let locale = Locale(identifier: config.localeID)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AimeError.localeUnsupported(config.localeID)
        }

        // 先启动录音：缓冲会排队等待 analyzer 就绪
        recorder.bluetoothMicStrategy = config.bluetoothMicStrategy ?? .quickRelease
        recorder.onBuffer = { [weak self] buffer in self?.feed(buffer) }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        recorder.onCaptureReady = { [weak self] isBluetooth in
            Task { @MainActor in self?.onCaptureReady?(isBluetooth) }
        }
        try recorder.start()

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    let combined = self.withState {
                        if result.isFinal {
                            self.finalizedText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        return self.finalizedText + self.volatileText
                    }
                    await MainActor.run { self.onUpdate?(combined) }
                }
            } catch {
                // 结果流因 cancel/finish 终止属正常路径；其余错误由 finish() 的调用方兜底
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let queued = withState {
            analyzerFormat = format
            let queued = pendingBuffers
            pendingBuffers = []
            return queued
        }
        for buffer in queued { convertAndYield(buffer) }
    }

    /// 音频线程调用。
    private func feed(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        if analyzerFormat == nil {
            pendingBuffers.append(buffer)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        convertAndYield(buffer)
    }

    public func finish() async throws -> ASRResult {
        let began = Date()
        recorder.stop()
        inputContinuation?.finish()
        try await withTimeout(seconds: 10) { [analyzer] in
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        let text = withState {
            (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        DiagLog.log(String(format: "定稿：文本%d字 耗时%.0fms", text.count, Date().timeIntervalSince(began) * 1000))
        return ASRResult(text: text, segments: nil)
    }

    public func cancel() async {
        recorder.stop()
        inputContinuation?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private func convertAndYield(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard let format = analyzerFormat else {
            stateLock.unlock()
            return
        }
        if buffer.format == format {
            stateLock.unlock()
            inputContinuation?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var conversionError: NSError?
        var served = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: output))
    }
}
