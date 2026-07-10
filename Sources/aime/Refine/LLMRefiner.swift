import Foundation

/// OpenAI 兼容 chat/completions 精修层。apiKey 为空时调用方直接跳过精修。
struct LLMRefiner {
    struct Request {
        var rawTranscript: String
        var context: ContextSnapshot?
        var settings: Settings
    }

    func refine(_ request: Request) async throws -> String {
        let settings = request.settings
        var base = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw AimeError.llmHTTPError(0, "无效的 API Base URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": settings.apiModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(settings: settings, context: request.context)],
                ["role": "user", "content": request.rawTranscript],
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AimeError.llmHTTPError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw AimeError.llmEmptyResponse
        }
        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refined.isEmpty else { throw AimeError.llmEmptyResponse }
        return refined
    }

    static func systemPrompt(settings: Settings, context: ContextSnapshot?) -> String {
        var lines: [String] = []
        lines.append("你是一个语音输入法的后处理引擎。用户通过语音说了一段话，语音识别的原始结果可能包含同音字/近音字错误、错误的英文术语识别、缺失或错误的标点、口语填充词。")
        lines.append("")
        lines.append("你的任务：")
        lines.append("1. 修正明显的识别错误（同音字、近音词、中英混说时被误识别的英文单词或术语）")
        lines.append("2. 补全并修正标点符号")
        if settings.removeFillers {
            lines.append("3. 删除口语填充词（嗯、呃、啊、就是说、那个、然后那种口头禅）")
        } else {
            lines.append("3. 保留说话人的口语风格，不删减语气词")
        }
        if settings.formalize {
            lines.append("4. 在完全保持原意的前提下，把口语表达整理为通顺的书面表达")
        } else {
            lines.append("4. 除上述修正外不要改写句子结构")
        }
        lines.append("")
        lines.append("严格要求：")
        lines.append("- 不增加原话没有的信息，不遗漏信息")
        lines.append("- 中英文混合内容保持混合，英文术语保持英文原样")
        lines.append("- 只输出处理后的文本本身，不要任何解释、引号、markdown 或前缀")

        var contextLines: [String] = []
        if let appName = context?.appName, !appName.isEmpty {
            contextLines.append("- 用户正在使用的应用：\(appName)")
        }
        if let before = context?.textBeforeCursor, !before.isEmpty {
            contextLines.append("- 光标前已有的文本（输出需要与它衔接自然，但不要重复它）：\n\(before)")
        }
        if !contextLines.isEmpty {
            lines.append("")
            lines.append("参考信息（帮助你判断专有名词和语境）：")
            lines.append(contentsOf: contextLines)
        }
        return lines.joined(separator: "\n")
    }
}
