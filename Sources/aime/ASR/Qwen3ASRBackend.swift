import AVFoundation
import Qwen3ASR

/// Qwen3-ASR（MLX 本地推理）后端。
///
/// speech-swift 的所有调用收敛在本文件（依赖锁精确版本，升级时只需过这一个文件）。
/// 模型非线程安全，所有推理经 `Qwen3Inference` actor 串行化。
final class Qwen3ASRBackend: ASRBackend {
    let id: ASRBackendID = .qwen3ASR

    private let inference = Qwen3Inference()

    func prepareModel(localeID: String) async throws {
        try await inference.load(modelID: Settings.current().qwen3ModelID)
    }

    func makeSession() -> ASRSession {
        Qwen3ASRSession(inference: inference)
    }
}

/// 持有已加载的模型并串行化推理。
actor Qwen3Inference {
    private var model: Qwen3ASRModel?
    private var loadedModelID: String?

    /// 某个模型的专属目录。必须符合 HF Hub 布局 `<base>/models/<org>/<name>`——
    /// speech-swift 的下载器靠路径后缀反推 downloadBase，不匹配时会静默下载到别处。
    /// 加载器还要求目录已存在，访问时确保创建。
    static func modelDir(for modelID: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load(modelID: String) async throws {
        if loadedModelID == modelID, model != nil { return }
        model = nil // 先释放旧模型再加载，避免两份权重同时驻留
        loadedModelID = nil
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: modelID,
            cacheDir: Self.modelDir(for: modelID),
            offlineMode: false,
            progressHandler: { progress, status in
                Task { @MainActor in
                    AppState.shared.modelDownloadStatus = progress < 1.0
                        ? "\(status) \(Int(progress * 100))%"
                        : nil
                }
            }
        )
        model = loaded
        loadedModelID = modelID
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
}

/// 一次录音会话：feed 侧把音频重采样为 16k 单声道 Float 并累积；
/// 录音期间周期性对已累积音频做局部转写产出实时预览；finish 做整段定稿转写。
final class Qwen3ASRSession: ASRSession {
    var onUpdate: (@MainActor (String) -> Void)?
    var contextHint: String?

    private let inference: Qwen3Inference
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var language: String?
    private var partialTask: Task<Void, Never>?
    private var cancelled = false

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    /// 少于 0.3s 的音频视为误触，不转写（也是 LLM ASR 幻觉的高发输入）
    private static let minSampleCount = 4800

    init(inference: Qwen3Inference) {
        self.inference = inference
    }

    func start(localeID: String) async throws {
        language = Self.languageHint(for: localeID)
        startPartialLoop()
    }

    /// NSLock 的同步作用域封装，可安全地从 async 上下文调用。
    private func snapshotSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    func finish() async throws -> ASRResult {
        partialTask?.cancel()
        let snapshot = snapshotSamples()
        guard snapshot.count >= Self.minSampleCount else {
            return ASRResult(text: "", segments: nil)
        }
        let text = try await inference.transcribe(
            samples: snapshot, language: language, context: contextHint
        )
        return ASRResult(text: Self.sanitize(text, sampleCount: snapshot.count), segments: nil)
    }

    func cancel() async {
        cancelled = true
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

    private static func languageHint(for localeID: String) -> String? {
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
