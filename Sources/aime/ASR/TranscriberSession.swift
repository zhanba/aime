import AVFoundation
import Speech

/// 一次录音会话对应一个 TranscriberSession（SpeechAnalyzer 流式转写）。
///
/// 线程模型：`feed(_:)` 在音频线程调用；音频缓冲在 analyzer 格式确定前先入队，
/// 确定后统一冲刷，因此录音可以先于 analyzer 就绪启动，不丢首音节。
final class TranscriberSession {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    private var finalizedText = ""
    private var volatileText = ""

    /// 转写文本更新（已定稿 + 未定稿），在 MainActor 上回调。
    var onUpdate: (@MainActor (String) -> Void)?

    /// NSLock 的同步作用域封装，可安全地从 async 上下文调用。
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// 确保 locale 支持且模型资产已安装。首次调用会触发模型下载。
    static func ensureModel(localeID: String) async throws {
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

    func start(localeID: String) async throws {
        let locale = Locale(identifier: localeID)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AimeError.localeUnsupported(localeID)
        }
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
    func feed(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        if analyzerFormat == nil {
            pendingBuffers.append(buffer)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        convertAndYield(buffer)
    }

    /// 结束输入并等待定稿，返回完整转写文本。
    func finish() async throws -> String {
        inputContinuation?.finish()
        try await withTimeout(seconds: 10) { [analyzer] in
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        return withState {
            (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func cancel() async {
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

/// 超时保护：超时抛 CancellationError，避免 finalize 卡死整个会话。
func withTimeout(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        try await group.next()
        group.cancelAll()
    }
}
