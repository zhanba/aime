import Foundation

/// 转换配置（由共享配置读出，IME 进程与 app 共用）。
public struct PinyinLLMConfig: Codable, Sendable {
    public var apiBaseURL: String
    public var apiModel: String
    public var apiKey: String
    public var enabledFuzzyRuleIDs: Set<String>
    /// 自定义 system prompt（空 = 用内置）。只替换指令部分，光标前文/用户词库等上下文仍由代码附加。
    public var customPromptRefine: String
    public var customPromptPinyin: String
    public var customPromptTranslate: String

    public init(
        apiBaseURL: String, apiModel: String, apiKey: String, enabledFuzzyRuleIDs: Set<String>,
        customPromptRefine: String = "", customPromptPinyin: String = "", customPromptTranslate: String = ""
    ) {
        self.apiBaseURL = apiBaseURL
        self.apiModel = apiModel
        self.apiKey = apiKey
        self.enabledFuzzyRuleIDs = enabledFuzzyRuleIDs
        self.customPromptRefine = customPromptRefine
        self.customPromptPinyin = customPromptPinyin
        self.customPromptTranslate = customPromptTranslate
    }

    /// 空白视为未自定义
    static func effectiveCustom(_ custom: String?) -> String? {
        guard let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct PinyinConversion: Sendable {
    /// 首选整句
    public var best: String
    /// 句级备选（可能为空）
    public var alternative: String?

    public init(best: String, alternative: String? = nil) {
        self.best = best
        self.alternative = alternative
    }
}

/// 结构化 prompt：原始按键 + 切分 + 模糊/修复标注 + 光标前文 + 用户词库。
/// 这是与 ds-input（裸字符串直扔 LLM）的核心差异。
public enum PinyinPromptBuilder {
    public static func describe(segments: [PinyinSegment]) -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment.kind {
            case .literal(let text):
                parts.append("[原样保留:\(text)]")
            case .pinyin(let syllables):
                let inner = syllables.map { syllable -> String in
                    var note = syllable.text
                    switch syllable.source {
                    case .exact:
                        break
                    case .keyAdjacent, .transposition:
                        note += "(疑似手误,实际敲的是\(syllable.typed))"
                    case .deletion:
                        note += "(疑似漏敲一个字母,实际敲的是\(syllable.typed))"
                    case .insertion:
                        note += "(疑似多敲一个字母,实际敲的是\(syllable.typed))"
                    case .partial:
                        note = "\(syllable.typed)(最后一个音节未打完,可能是:\(syllable.completions.joined(separator: "/")))"
                    }
                    if !syllable.fuzzyAlternates.isEmpty {
                        note += "(也可能是:\(syllable.fuzzyAlternates.joined(separator: "/")))"
                    }
                    return note
                }.joined(separator: " ")
                parts.append(inner)
            }
        }
        return parts.joined(separator: " | ")
    }

    /// 内置指令部分（不含上下文），设置页「填入内置」也用它
    public static func defaultInstructions() -> String {
        var lines: [String] = []
        lines.append("你是拼音输入法的整句转换引擎。用户输入无声调拼音（可能混有英文单词、数字），你输出对应的中文整句。")
        lines.append("")
        lines.append("输入格式说明：给出原始按键串和切分分析。切分中 [原样保留:X] 表示 X 是英文/数字，输出时原样保留；")
        lines.append("音节后的括号标注了可能的模糊音或手误修复，选择哪个读音由整句语义决定。")
        lines.append("")
        lines.append("规则（严格遵守）：")
        lines.append("- 这是转写不是改写：每个音节对应恰好一个汉字，禁止增字、删字、换近义词。")
        lines.append("  反例：xiazhouyiyao 必须转成「下周一要」，不能转成「下周就要」——「就」读 jiu，输入里没有这个音节")
        lines.append("- 每个汉字的读音必须就是对应音节（或其标注的模糊音/手误备选之一）")
        lines.append("- 英文/数字片段原样保留，与中文之间不加空格")
        lines.append("- 例外：切分中孤立的单字母，或音节与字母的组合，若拼起来是语境合理的英文单词（如 bu+g=bug、a+pp=app），应作为英文单词输出")
        lines.append("- 输出不加句末标点（用户自己打标点）")
        lines.append("- 只输出转换结果。第一行是首选；如果存在语义截然不同的第二种理解，第二行输出备选，否则只输出一行")
        return lines.joined(separator: "\n")
    }

    public static func systemPrompt(context: String?, userDictEntries: [String], custom: String? = nil) -> String {
        var lines = [PinyinLLMConfig.effectiveCustom(custom) ?? defaultInstructions()]
        if let context, !context.isEmpty {
            lines.append("")
            lines.append("光标前已有的文本（输出需与它衔接）：\(context)")
        }
        if !userDictEntries.isEmpty {
            lines.append("")
            lines.append("用户常用词（优先采用这些写法）：\(userDictEntries.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(raw: String, segments: [PinyinSegment], boundaryAlternatives: [String] = []) -> String {
        var text = "原始按键：\(raw)\n切分分析：\(describe(segments: segments))"
        if !boundaryAlternatives.isEmpty {
            text += "\n另一种可能的切分：\(boundaryAlternatives.joined(separator: "；"))（若按此切分语义更合理，请按此转换）"
        }
        return text
    }
}

/// OpenAI 兼容整句转换。
public struct PinyinConverter {
    public init() {}

    public func convert(
        raw: String,
        context: String?,
        userDictEntries: [String],
        config: PinyinLLMConfig
    ) async throws -> PinyinConversion {
        let segments = PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs)
        var alternatives: [String] = []
        for segment in segments {
            if case .pinyin(let syllables) = segment.kind {
                alternatives += PinyinSegmenter.boundaryVariants(of: syllables, enabledFuzzyRuleIDs: config.enabledFuzzyRuleIDs)
                    .map { $0.map(\.text).joined(separator: " ") }
            }
        }
        return try await convert(raw: raw, segments: segments, context: context, userDictEntries: userDictEntries, config: config, boundaryAlternatives: alternatives)
    }

    public func convert(
        raw: String,
        segments: [PinyinSegment],
        context: String?,
        userDictEntries: [String],
        config: PinyinLLMConfig,
        boundaryAlternatives: [String] = []
    ) async throws -> PinyinConversion {
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
            "temperature": 0.1,
            "max_tokens": 256,
            "messages": [
                ["role": "system", "content": PinyinPromptBuilder.systemPrompt(context: context, userDictEntries: userDictEntries, custom: config.customPromptPinyin)],
                ["role": "user", "content": PinyinPromptBuilder.userPrompt(raw: raw, segments: segments, boundaryAlternatives: boundaryAlternatives)],
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
              let content = message["content"] as? String
        else {
            throw PinyinError.emptyResponse
        }
        let lines = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let best = lines.first else { throw PinyinError.emptyResponse }
        return PinyinConversion(best: best, alternative: lines.count > 1 ? lines[1] : nil)
    }
}

public enum PinyinError: LocalizedError {
    case notConfigured
    case httpError(Int)
    case emptyResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 LLM API（在 Aime 设置 → 精修 里填写）"
        case .httpError(let code): return "LLM 请求失败（HTTP \(code)）"
        case .emptyResponse: return "LLM 返回了空结果"
        case .timeout: return "LLM 响应超时"
        }
    }
}
