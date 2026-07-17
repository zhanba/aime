import AVFoundation
import Qwen3ASR
import SpeechVAD

/// Qwen3-ASR（MLX 本地推理）后端。
///
/// speech-swift 的所有调用收敛在本文件（依赖锁精确版本，升级时只需过这一个文件）。
/// 模型非线程安全，所有推理（含 VAD）经 `Qwen3Inference` actor 串行化。
public final class Qwen3ASRBackend: ASRBackend {
    public let id: ASRBackendID = .qwen3ASR
    public var onProgress: ((String?) -> Void)?

    private let inference = Qwen3Inference()

    public init() {}

    public func prepareModel(config: ASRSessionConfig) async throws {
        defer { onProgress?(nil) }
        try await inference.load(modelID: config.qwen3ModelID) { [onProgress] progress, status in
            onProgress?(progress < 1.0 ? "\(status) \(Int(progress * 100))%" : nil)
        }
        try await inference.loadVAD()
    }

    public func makeSession() -> ASRSession {
        Qwen3ASRSession(inference: inference)
    }
}

/// 持有已加载的模型（ASR + Silero VAD）并串行化推理。
actor Qwen3Inference {
    private var model: Qwen3ASRModel?
    private var loadedModelID: String?
    private var vad: SileroVADModel?

    func load(modelID: String, progressHandler: @escaping (Double, String) -> Void) async throws {
        if loadedModelID == modelID, model != nil { return }
        DiagLog.log("加载模型 \(modelID)")
        model = nil // 先释放旧模型再加载，避免两份权重同时驻留
        loadedModelID = nil
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: modelID,
            cacheDir: ModelStore.modelDir(for: modelID),
            offlineMode: ModelStore.hasWeights(for: modelID),
            progressHandler: progressHandler
        )
        model = loaded
        loadedModelID = modelID
        DiagLog.log("模型加载完成 \(modelID)")
    }

    /// VAD 模型很小（~2MB），加载失败不阻塞 ASR（退化为不修剪）。
    func loadVAD() async throws {
        guard vad == nil else { return }
        let modelID = SileroVADModel.defaultModelId
        vad = try? await SileroVADModel.fromPretrained(
            modelId: modelID,
            engine: .mlx,
            cacheDir: ModelStore.modelDir(for: modelID),
            offlineMode: ModelStore.hasWeights(for: modelID)
        )
    }

    func transcribe(samples: [Float], language: String?, context: String?) throws -> String {
        guard let model else { throw AimeError.transcriberNotReady }
        return model.transcribe(
            audio: samples,
            sampleRate: 16000,
            language: language,
            maxTokens: 448,
            context: context
        )
    }

    /// W3 前置过滤：掐首尾静音（带 padding），全静音返回 nil。
    /// VAD 不可用时原样返回（不修剪也不拦截）。
    func vadTrim(samples: [Float], threshold: Float = 0.5, paddingSeconds: Double = 0.25) -> [Float]? {
        guard let vad else { return samples }
        vad.resetState()
        let chunkSize = SileroVADModel.chunkSize
        var firstSpeech: Int?
        var lastSpeech: Int?
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            var chunk = Array(samples[offset ..< end])
            if chunk.count < chunkSize {
                chunk.append(contentsOf: [Float](repeating: 0, count: chunkSize - chunk.count))
            }
            let probability = vad.processChunk(chunk)
            if probability >= threshold {
                if firstSpeech == nil { firstSpeech = offset }
                lastSpeech = end
            }
            offset = end
        }
        guard let firstSpeech, let lastSpeech else { return nil }
        let padding = Int(paddingSeconds * 16000)
        let start = max(0, firstSpeech - padding)
        let stop = min(samples.count, lastSpeech + padding)
        return Array(samples[start ..< stop])
    }
}

/// 一次录音会话：自持麦克风采集，重采样为 16k 单声道累积；
/// 录音期间周期性局部转写产出实时预览；finish 时 VAD 修剪 + 整段定稿转写。
public final class Qwen3ASRSession: ASRSession {
    public var onUpdate: (@MainActor (String) -> Void)?
    public var onLevel: (@MainActor (Float) -> Void)?
    public var onCaptureReady: (@MainActor (Bool) -> Void)?

    private let inference: Qwen3Inference
    private let recorder = AudioRecorder()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var language: String?
    private var contextHint: String?
    private var partialTask: Task<Void, Never>?
    /// 会话内模型自愈加载：prepare 可能发生在另一个进程（app 在 daemon 未就绪时
    /// 进程内加载，之后会话又路由到 daemon），本进程模型可能是 nil。start 时幂等
    /// 补加载（已加载时是 no-op），finish 转写前 await，杜绝 transcriberNotReady。
    private var prepareTask: Task<Void, Error>?
    private var cancelled = false

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    /// 少于 0.3s 的音频视为误触，不转写（也是 LLM ASR 幻觉的高发输入）
    private static let minSampleCount = 4800

    init(inference: Qwen3Inference) {
        self.inference = inference
    }

    /// NSLock 的同步作用域封装，可安全地从 async 上下文调用。
    private func snapshotSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func start(config: ASRSessionConfig) async throws {
        language = Self.languageHint(for: config.localeID)
        contextHint = config.contextHint
        let modelID = config.qwen3ModelID
        prepareTask = Task { [inference] in
            try await inference.load(modelID: modelID) { _, _ in }
            try await inference.loadVAD()
        }
        recorder.bluetoothMicStrategy = config.bluetoothMicStrategy ?? .quickRelease
        recorder.onBuffer = { [weak self] buffer in self?.feed(buffer) }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        recorder.onCaptureReady = { [weak self] isBluetooth in
            Task { @MainActor in self?.onCaptureReady?(isBluetooth) }
        }
        try recorder.start()
        startPartialLoop()
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    public func finish() async throws -> ASRResult {
        let began = Date()
        recorder.stop()
        partialTask?.cancel()
        if let prepareTask {
            try await prepareTask.value
        }
        let snapshot = snapshotSamples()
        guard snapshot.count >= Self.minSampleCount else {
            DiagLog.log("定稿：样本不足 \(snapshot.count)，返回空")
            return ASRResult(text: "", segments: nil)
        }
        // W3：VAD 前置——掐首尾静音，纯静音直接返回空（不喂给 LLM ASR，杜绝幻觉）
        guard let trimmed = await inference.vadTrim(samples: snapshot),
              trimmed.count >= Self.minSampleCount
        else {
            DiagLog.log("定稿：VAD 判定纯静音（样本=\(snapshot.count)），返回空")
            return ASRResult(text: "", segments: nil)
        }
        let text = try await inference.transcribe(
            samples: trimmed, language: language, context: contextHint
        )
        let cleaned = Self.sanitize(text, sampleCount: trimmed.count)
        DiagLog.log(String(format: "定稿：样本=%d VAD后=%d 原文%d字 清理后%d字 耗时%.0fms",
                           snapshot.count, trimmed.count, text.count, cleaned.count,
                           Date().timeIntervalSince(began) * 1000))
        return ASRResult(text: cleaned, segments: nil)
    }

    public func cancel() async {
        cancelled = true
        recorder.stop()
        partialTask?.cancel()
    }

    // MARK: - 实时预览

    /// 录音期间周期性转写已累积音频。节奏自适应：上一次局部转写耗时越长，间隔越大，
    /// 保证 finish 的定稿转写最多排在一次局部转写之后。
    private func startPartialLoop() {
        partialTask = Task { [weak self] in
            var interval: TimeInterval = 1.5
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.cancelled else { return }
                let snapshot = self.snapshotSamples()
                // 新增不足 0.5s 就跳过这一轮
                guard snapshot.count >= Self.minSampleCount, snapshot.count - lastCount > 8000 else { continue }
                lastCount = snapshot.count
                let began = Date()
                guard let text = try? await self.inference.transcribe(
                    samples: snapshot, language: self.language, context: self.contextHint
                ) else { continue }
                let cost = Date().timeIntervalSince(began)
                interval = max(1.5, cost * 1.5)
                guard !Task.isCancelled, !self.cancelled else { return }
                let cleaned = Self.sanitize(text, sampleCount: snapshot.count)
                if !cleaned.isEmpty {
                    await MainActor.run { self.onUpdate?(cleaned) }
                }
            }
        }
    }

    // MARK: - 工具

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }
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
        guard conversionError == nil, output.frameLength > 0, let data = output.floatChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    static func languageHint(for localeID: String) -> String? {
        // Qwen3-ASR 接受 "zh"/"en" 等短代码；中英混说用 "zh" 即可覆盖
        let prefix = localeID.split(separator: "_").first.map(String.init) ?? localeID
        return prefix.isEmpty ? nil : prefix
    }

    /// 幻觉后置检测：文本长度与音频时长比例异常、短音频高重复 → 判为幻觉丢弃。
    static func sanitize(_ text: String, sampleCount: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let seconds = Double(sampleCount) / 16000
        // 正常语速上限约 8 字/秒（含标点放宽到 12/秒）
        if Double(trimmed.count) > seconds * 12 + 8 { return "" }
        if hasRunawayRepetition(trimmed) { return "" }
        return trimmed
    }

    /// LLM ASR 的典型幻觉形态：同一短语循环重复。
    private static func hasRunawayRepetition(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 24 else { return false }
        for windowSize in 2 ... 8 {
            var repeats = 1
            var maxRepeats = 1
            var index = windowSize
            while index + windowSize <= chars.count {
                if Array(chars[index ..< index + windowSize]) == Array(chars[index - windowSize ..< index]) {
                    repeats += 1
                    maxRepeats = max(maxRepeats, repeats)
                } else {
                    repeats = 1
                }
                index += windowSize
            }
            if maxRepeats >= 5 { return true }
        }
        return false
    }
}
