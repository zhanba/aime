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

