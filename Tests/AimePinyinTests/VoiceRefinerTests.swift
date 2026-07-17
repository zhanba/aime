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
}
