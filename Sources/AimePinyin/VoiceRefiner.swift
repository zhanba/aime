import Foundation

/// 精修输出风格：一个维度替代「去填充词/转书面」两个独立开关。
/// 放在共享模块：app 全局热键与 IME 语音段两条路径共用，保证行为一致。
public enum RefineStyle: String, CaseIterable, Identifiable, Sendable {
    case raw
    case clean
    case formal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raw: return "原样"
        case .clean: return "清爽（去语气词）"
        case .formal: return "书面（整理表达）"
        }
    }

    public var removesFillers: Bool { self != .raw }
    public var formalizes: Bool { self == .formal }
}

/// OpenAI 兼容语音转写精修，与拼音整句/翻译共用 LLM 配置。
public struct VoiceRefiner {
    public init() {}

    public func refine(
        transcript: String,
        appName: String?,
        textBeforeCursor: String?,
        style: RefineStyle,
        config: PinyinLLMConfig
    ) async throws -> String {
        var base = config.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !config.apiKey.isEmpty, let url = URL(string: base + "/chat/completions") else {
            throw PinyinError.notConfigured
        }

        let deadline = Self.deadline(for: transcript)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = deadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.apiModel,
            "temperature": 0.2,
            "messages": [
                [
                    "role": "system",
                    "content": Self.systemPrompt(style: style, appName: appName, textBeforeCursor: textBeforeCursor, custom: config.customPromptRefine),
                ],
                ["role": "user", "content": transcript],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.withDeadline(deadline) {
            try await URLSession.shared.data(for: request)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PinyinError.httpError(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw PinyinError.emptyResponse
        }
        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refined.isEmpty else { throw PinyinError.emptyResponse }
        return refined
    }

    /// 精修总时长上限：用户在盯着浮层等上屏，宁可回退原文也不久等。
    /// 短句 8s 起步，长文按长度放宽（每 50 字 +1s），上限 15s。
    static func deadline(for transcript: String) -> TimeInterval {
        min(15, 8 + TimeInterval(transcript.count) / 50)
    }

    /// URLRequest.timeoutInterval 只是空闲超时（收到数据就重置），这里用竞速兜出总时长硬上限。
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PinyinError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 内置指令部分（不含上下文），设置页「填入内置」也用它。
    /// 自定义 prompt 会整体替换它，包括随「输出风格」变化的两条规则。
    public static func defaultInstructions(style: RefineStyle) -> String {
        var lines: [String] = []
        lines.append("你是一个语音输入法的后处理引擎。用户通过语音说了一段话，语音识别的原始结果可能包含同音字/近音字错误、错误的英文术语识别、缺失或错误的标点、口语填充词。")
        lines.append("")
        lines.append("你的任务：")
        lines.append("1. 修正明显的识别错误（同音字、近音词、中英混说时被误识别的英文单词或术语）")
        lines.append("2. 补全并修正标点符号")
        if style.removesFillers {
            lines.append("3. 删除口语填充词（嗯、呃、啊、就是说、那个、然后那种口头禅）")
        } else {
            lines.append("3. 保留说话人的口语风格，不删减语气词")
        }
        if style.formalizes {
            lines.append("4. 在完全保持原意的前提下，把口语表达整理为通顺的书面表达")
        } else {
            lines.append("4. 除上述修正外不要改写句子结构")
        }
        lines.append("")
        lines.append("严格要求：")
        lines.append("- 不增加原话没有的信息，不遗漏信息")
        lines.append("- 中英文混合内容保持混合，英文术语保持英文原样")
        lines.append("- 只输出处理后的文本本身，不要任何解释、引号、markdown 或前缀")
        return lines.joined(separator: "\n")
    }

    public static func systemPrompt(style: RefineStyle, appName: String?, textBeforeCursor: String?, custom: String? = nil) -> String {
        var lines = [PinyinLLMConfig.effectiveCustom(custom) ?? defaultInstructions(style: style)]

        var contextLines: [String] = []
        if let appName, !appName.isEmpty {
            contextLines.append("- 用户正在使用的应用：\(appName)")
        }
        if let textBeforeCursor, !textBeforeCursor.isEmpty {
            contextLines.append("- 光标前已有的文本（输出需要与它衔接自然，但不要重复它）：\n\(textBeforeCursor)")
        }
        if !contextLines.isEmpty {
            lines.append("")
            lines.append("参考信息（帮助你判断专有名词和语境）：")
            lines.append(contentsOf: contextLines)
        }
        return lines.joined(separator: "\n")
    }
}
