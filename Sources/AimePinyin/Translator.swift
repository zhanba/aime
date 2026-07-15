import Foundation

/// 中→英翻译结果（组合区 Tab 触发）。
public struct TranslationResult: Sendable, Equatable {
    /// 首选译文
    public var best: String
    /// 措辞/语气明显不同的备选译法（可能为空）
    public var alternative: String?

    public init(best: String, alternative: String? = nil) {
        self.best = best
        self.alternative = alternative
    }
}

public enum TranslatorPromptBuilder {
    /// 内置指令部分（不含上下文），设置页「填入内置」也用它
    public static func defaultInstructions() -> String {
        var lines: [String] = []
        lines.append("你是输入法内置的中译英引擎。把用户输入的中文（可能夹杂英文单词）翻译成自然地道的英文。")
        lines.append("")
        lines.append("规则（严格遵守）：")
        lines.append("- 只输出译文：不加引号、不加任何解释或说明")
        lines.append("- 忠实原意，语气与原文一致：口语归口语，书面归书面")
        lines.append("- 原文中已有的英文单词、专有名词原样保留")
        lines.append("- 原文没有句末标点，译文也不加句末标点")
        lines.append("- 第一行输出首选译文；若存在语气或措辞明显不同的另一种译法，第二行输出备选，否则只输出一行")
        return lines.joined(separator: "\n")
    }

    public static func systemPrompt(context: String?, custom: String? = nil) -> String {
        var lines = [PinyinLLMConfig.effectiveCustom(custom) ?? defaultInstructions()]
        if let context, !context.isEmpty {
            lines.append("")
            lines.append("光标前已有的文本（多为对话上文，译文的称呼、用词、语气需与之衔接）：\(context)")
        }
        return lines.joined(separator: "\n")
    }
}

/// OpenAI 兼容中→英翻译，与 PinyinConverter 共用 LLM 配置。
public struct Translator {
    public init() {}

    public func translate(
        _ source: String,
        context: String?,
        config: PinyinLLMConfig
    ) async throws -> TranslationResult {
        var base = config.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !config.apiKey.isEmpty, let url = URL(string: base + "/chat/completions") else {
            throw PinyinError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.apiModel,
            "temperature": 0.3,
            "max_tokens": 512,
            "messages": [
                ["role": "system", "content": TranslatorPromptBuilder.systemPrompt(context: context, custom: config.customPromptTranslate)],
                ["role": "user", "content": source],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PinyinError.httpError(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let result = Self.parse(content)
        else {
            throw PinyinError.emptyResponse
        }
        return result
    }

    /// 解析 LLM 输出：第一行首选，第二行备选；剥掉模型偶尔加上的包裹引号。
    static func parse(_ content: String) -> TranslationResult? {
        let lines = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { Self.stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard let best = lines.first else { return nil }
        let alternative = lines.count > 1 && lines[1] != best ? lines[1] : nil
        return TranslationResult(best: best, alternative: alternative)
    }

    private static func stripQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs {
            if text.count >= 2, text.first == open, text.last == close {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }
}
