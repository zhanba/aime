import XCTest
@testable import AimePinyin

final class VoiceRefinerTests: XCTestCase {
    // MARK: - 精修超时：短句快速回退，长文放宽但有上限

    func testDeadlineShortTranscriptStartsAtEightSeconds() {
        XCTAssertEqual(VoiceRefiner.deadline(for: ""), 8)
        XCTAssertEqual(VoiceRefiner.deadline(for: "打开设置"), 8.08)
    }

    func testDeadlineGrowsWithLengthAndCapsAtFifteen() {
        let hundred = String(repeating: "字", count: 100)
        XCTAssertEqual(VoiceRefiner.deadline(for: hundred), 10)
        let long = String(repeating: "字", count: 1000)
        XCTAssertEqual(VoiceRefiner.deadline(for: long), 15)
    }

    // MARK: - SSE 流式解析

    func testDeltaContentExtractsIncrementalText() {
        let payload = #"{"choices":[{"delta":{"content":"你好"}}]}"#
        XCTAssertEqual(VoiceRefiner.deltaContent(fromSSEPayload: payload), "你好")
    }

    func testDeltaContentIgnoresRoleAndEmptyAndFinishChunks() {
        // role 首包
        XCTAssertNil(VoiceRefiner.deltaContent(fromSSEPayload: #"{"choices":[{"delta":{"role":"assistant"}}]}"#))
        // 空 content
        XCTAssertNil(VoiceRefiner.deltaContent(fromSSEPayload: #"{"choices":[{"delta":{"content":""}}]}"#))
        // null content（部分服务端在 finish 包里发）
        XCTAssertNil(VoiceRefiner.deltaContent(fromSSEPayload: #"{"choices":[{"delta":{"content":null},"finish_reason":"stop"}]}"#))
        // choices 为空（部分服务端末尾发 usage 包）
        XCTAssertNil(VoiceRefiner.deltaContent(fromSSEPayload: #"{"choices":[],"usage":{"total_tokens":10}}"#))
        // 非 JSON（keep-alive 注释等）
        XCTAssertNil(VoiceRefiner.deltaContent(fromSSEPayload: ""))
    }

    func testNonStreamBodyFallbackParsesRegularResponse() {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"你好，世界。"}}]}"#
        XCTAssertEqual(VoiceRefiner.contentFromNonStreamBody(body), "你好，世界。")
        XCTAssertNil(VoiceRefiner.contentFromNonStreamBody("not json"))
        XCTAssertNil(VoiceRefiner.contentFromNonStreamBody(#"{"choices":[]}"#))
    }

    // MARK: - DeepSeek 关闭思维链

    private func config(baseURL: String, model: String) -> PinyinLLMConfig {
        PinyinLLMConfig(apiBaseURL: baseURL, apiModel: model, apiKey: "k", enabledFuzzyRuleIDs: [])
    }

    func testDisablesThinkingOnlyForDeepSeek() {
        XCTAssertTrue(config(baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-flash").disablesThinking)
        // 第三方网关挂 deepseek 模型也算
        XCTAssertTrue(config(baseURL: "https://gateway.example.com/v1", model: "DeepSeek-V4").disablesThinking)
        XCTAssertFalse(config(baseURL: "https://api.openai.com/v1", model: "gpt-5.2").disablesThinking)
        XCTAssertFalse(config(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-flash").disablesThinking)
    }

    // MARK: - 超短文本跳过精修

    func testCanSkipRefineForUltraShortCleanText() {
        XCTAssertTrue(VoiceRefiner.canSkipRefine("好的"))
        XCTAssertTrue(VoiceRefiner.canSkipRefine("没问题"))
        XCTAssertTrue(VoiceRefiner.canSkipRefine("确认一下"))
        XCTAssertTrue(VoiceRefiner.canSkipRefine("  收到  "))  // 判定前先去首尾空白
        XCTAssertTrue(VoiceRefiner.canSkipRefine("OK"))
    }

    func testCanSkipRefineRejectsLongerText() {
        XCTAssertFalse(VoiceRefiner.canSkipRefine("帮我看一下"))
        XCTAssertFalse(VoiceRefiner.canSkipRefine(String(repeating: "字", count: 20)))
    }

    func testCanSkipRefineRejectsFillers() {
        // 语气字：clean/formal 风格要删，必须送精修
        XCTAssertFalse(VoiceRefiner.canSkipRefine("嗯好的"))
        XCTAssertFalse(VoiceRefiner.canSkipRefine("好啊"))
        XCTAssertFalse(VoiceRefiner.canSkipRefine("哦哦"))
        // 填充词
        XCTAssertFalse(VoiceRefiner.canSkipRefine("那个呢"))
        XCTAssertFalse(VoiceRefiner.canSkipRefine("就是说"))
    }

    func testCanSkipRefineRejectsEmpty() {
        XCTAssertFalse(VoiceRefiner.canSkipRefine(""))
        XCTAssertFalse(VoiceRefiner.canSkipRefine("   "))
    }
}
