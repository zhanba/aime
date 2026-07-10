import AVFoundation

/// 可用的识别引擎。
enum ASRBackendID: String, CaseIterable, Identifiable {
    case speechAnalyzer
    case qwen3ASR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechAnalyzer: return "系统（SpeechAnalyzer，零下载）"
        case .qwen3ASR: return "Qwen3-ASR（MLX 本地，中英混说更强）"
        }
    }
}

struct ASRSegment {
    var text: String
    /// 0...1，nil 表示该后端不提供置信度
    var confidence: Double?
}

struct ASRResult {
    var text: String
    var segments: [ASRSegment]?
}

/// 识别引擎。负责模型生命周期（下载/加载/卸载）与会话创建。
protocol ASRBackend: AnyObject {
    var id: ASRBackendID { get }
    /// 确保模型可用（可能触发下载）。幂等，可重复调用。
    func prepareModel(localeID: String) async throws
    func makeSession() -> ASRSession
}

/// 一次录音对应一个会话。
/// 线程模型约定：`feed(_:)` 在音频线程调用，实现方必须支持在 `start` 完成前
/// 就开始 feed（内部排队），避免丢首音节。
protocol ASRSession: AnyObject {
    /// 增量转写回调（已定稿 + 未定稿的合并文本），在 MainActor 上回调。
    var onUpdate: (@MainActor (String) -> Void)? { get set }
    /// 可选的识别偏置上下文（光标前文本/用户词库）。支持的后端（Qwen3-ASR）
    /// 会将其注入模型的 system 槽位，不支持的后端忽略。
    var contextHint: String? { get set }
    func start(localeID: String) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    /// 结束输入并等待定稿。
    func finish() async throws -> ASRResult
    func cancel() async
}

/// 后端注册表：按需创建并缓存，切换引擎时旧后端随引用释放。
@MainActor
final class ASRBackendRegistry {
    static let shared = ASRBackendRegistry()
    private var cache: [ASRBackendID: ASRBackend] = [:]

    func backend(for id: ASRBackendID) -> ASRBackend {
        if let existing = cache[id] { return existing }
        let backend: ASRBackend
        switch id {
        case .speechAnalyzer:
            backend = SpeechAnalyzerBackend()
        case .qwen3ASR:
            backend = Qwen3ASRBackend()
        }
        cache[id] = backend
        return backend
    }
}
