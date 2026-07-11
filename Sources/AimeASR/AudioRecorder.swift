import AVFoundation
import Accelerate

/// 麦克风采集。回调运行在音频线程，调用方自行处理线程切换。
public final class AudioRecorder {
    private let engine = AVAudioEngine()

    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AimeError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            self.onLevel?(Self.rmsLevel(of: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 归一化到 0...1 的响度，供浮层电平动画使用。
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return 0 }
        // 转 dB 后映射 [-50, 0] → [0, 1]
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 50))
    }
}

/// 超时保护：超时抛 CancellationError，避免 finalize 卡死整个会话。
public func withTimeout(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Void) async throws {
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
