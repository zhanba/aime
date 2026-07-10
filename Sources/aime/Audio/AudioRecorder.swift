import AVFoundation
import Accelerate

/// 麦克风采集。回调运行在音频线程，调用方自行处理线程切换。
final class AudioRecorder {
    private let engine = AVAudioEngine()

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
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

    func stop() {
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

enum AimeError: LocalizedError {
    case microphoneUnavailable
    case localeUnsupported(String)
    case transcriberNotReady
    case llmHTTPError(Int, String)
    case llmEmptyResponse

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "麦克风不可用，请检查系统设置中的麦克风权限"
        case .localeUnsupported(let id):
            return "系统语音转写暂不支持语言 \(id)"
        case .transcriberNotReady:
            return "语音模型尚未就绪"
        case .llmHTTPError(let code, let body):
            return "LLM 请求失败（HTTP \(code)）：\(body.prefix(120))"
        case .llmEmptyResponse:
            return "LLM 返回了空结果"
        }
    }
}
