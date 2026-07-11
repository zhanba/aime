import AVFoundation
import Foundation

/// 可用的识别引擎。
public enum ASRBackendID: String, CaseIterable, Identifiable, Codable, Sendable {
    case speechAnalyzer
    case qwen3ASR

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .speechAnalyzer: return "系统（SpeechAnalyzer，零下载）"
        case .qwen3ASR: return "Qwen3-ASR（MLX 本地，中英混说更强）"
        }
    }
}

public struct ASRSegment: Codable, Sendable {
    public var text: String
    /// 0...1，nil 表示该后端不提供置信度
    public var confidence: Double?

    public init(text: String, confidence: Double?) {
        self.text = text
        self.confidence = confidence
    }
}

public struct ASRResult: Codable, Sendable {
    public var text: String
    public var segments: [ASRSegment]?

    public init(text: String, segments: [ASRSegment]?) {
        self.text = text
        self.segments = segments
    }
}

/// 一次会话的完整配置。app 内直接构造；daemon 场景经 XPC 以 JSON 传递。
public struct ASRSessionConfig: Codable, Sendable {
    public var backend: ASRBackendID
    public var localeID: String
    public var qwen3ModelID: String
    /// 识别偏置上下文（光标前文本/用户词库）。支持的后端（Qwen3-ASR）注入模型
    /// system 槽位，不支持的后端忽略。
    public var contextHint: String?

    public init(backend: ASRBackendID, localeID: String, qwen3ModelID: String, contextHint: String? = nil) {
        self.backend = backend
        self.localeID = localeID
        self.qwen3ModelID = qwen3ModelID
        self.contextHint = contextHint
    }
}

public enum AimeError: LocalizedError {
    case microphoneUnavailable
    case localeUnsupported(String)
    case transcriberNotReady
    case llmHTTPError(Int, String)
    case llmEmptyResponse
    case daemonUnavailable(String)

    public var errorDescription: String? {
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
        case .daemonUnavailable(let reason):
            return "后台服务不可用：\(reason)"
        }
    }
}

/// 识别引擎。负责模型生命周期（下载/加载/卸载）与会话创建。
public protocol ASRBackend: AnyObject {
    var id: ASRBackendID { get }
    /// 模型准备进度文案（下载百分比等），nil 表示无进行中的准备。
    var onProgress: ((String?) -> Void)? { get set }
    /// 确保模型可用（可能触发下载）。幂等。
    func prepareModel(config: ASRSessionConfig) async throws
    func makeSession() -> ASRSession
}

/// 一次录音对应一个会话。会话自持音频采集（start 内启动麦克风，finish/cancel 停止），
/// 因此使用方进程需要麦克风权限。
public protocol ASRSession: AnyObject {
    /// 增量转写回调（已定稿 + 未定稿的合并文本），在 MainActor 上回调。
    var onUpdate: (@MainActor (String) -> Void)? { get set }
    /// 录音电平（0...1），在 MainActor 上回调。
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    func start(config: ASRSessionConfig) async throws
    /// 结束输入并等待定稿。
    func finish() async throws -> ASRResult
    func cancel() async
}

/// 后端注册表：按需创建并缓存（模型常驻在 backend 内），线程安全。
public final class ASRBackendRegistry {
    public static let shared = ASRBackendRegistry()
    private var cache: [ASRBackendID: ASRBackend] = [:]
    private let lock = NSLock()

    public init() {}

    public func backend(for id: ASRBackendID) -> ASRBackend {
        lock.lock()
        defer { lock.unlock() }
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

/// aime 的模型目录布局：`<Application Support>/aime/models/<org>/<name>`。
/// 必须符合 HF Hub 布局——speech-swift 的下载器靠路径后缀反推 downloadBase。
public enum ModelStore {
    public static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    public static func modelDir(for modelID: String) -> URL {
        let dir = baseDir.appendingPathComponent(modelID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 目录中已有权重（.safetensors/.mlmodelc）→ 可走离线模式，避免弱网下卡 HF 校验。
    public static func hasWeights(for modelID: String) -> Bool {
        let dir = modelDir(for: modelID)
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { ["safetensors", "mlmodelc", "mlpackage"].contains($0.pathExtension) }
    }

    public static func diskUsage(for modelID: String) -> Int64 {
        let dir = modelDir(for: modelID)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public static func delete(modelID: String) {
        try? FileManager.default.removeItem(at: modelDir(for: modelID))
    }
}
