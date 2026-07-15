import XCTest
@testable import AimePinyin

final class PromptBuilderTests: XCTestCase {
    // MARK: - 自定义 prompt 替换内置指令，但上下文仍附加

    func testPinyinCustomPromptReplacesInstructionsKeepsContext() {
        let prompt = PinyinPromptBuilder.systemPrompt(
            context: "上文", userDictEntries: ["词条"], custom: "自定义指令"
        )
        XCTAssertTrue(prompt.hasPrefix("自定义指令"))
        XCTAssertFalse(prompt.contains("整句转换引擎"))
        XCTAssertTrue(prompt.contains("上文"))
        XCTAssertTrue(prompt.contains("词条"))
    }

    func testRefineCustomPromptReplacesStyleRulesKeepsContext() {
        let prompt = VoiceRefiner.systemPrompt(
            style: .formal, appName: "Mail", textBeforeCursor: "光标前", custom: "自定义指令"
        )
        XCTAssertTrue(prompt.hasPrefix("自定义指令"))
        XCTAssertFalse(prompt.contains("后处理引擎"))
        XCTAssertFalse(prompt.contains("书面表达"))
        XCTAssertTrue(prompt.contains("Mail"))
        XCTAssertTrue(prompt.contains("光标前"))
    }

    func testTranslateCustomPromptReplacesInstructionsKeepsContext() {
        let prompt = TranslatorPromptBuilder.systemPrompt(context: "上文", custom: "自定义指令")
        XCTAssertTrue(prompt.hasPrefix("自定义指令"))
        XCTAssertFalse(prompt.contains("中译英引擎"))
        XCTAssertTrue(prompt.contains("上文"))
    }

    // MARK: - 空白 = 未自定义，回落内置

    func testBlankCustomFallsBackToDefault() {
        for custom in [nil, "", "  \n  "] {
            let prompt = PinyinPromptBuilder.systemPrompt(context: nil, userDictEntries: [], custom: custom)
            XCTAssertEqual(prompt, PinyinPromptBuilder.defaultInstructions())
        }
        XCTAssertEqual(
            VoiceRefiner.systemPrompt(style: .clean, appName: nil, textBeforeCursor: nil, custom: " "),
            VoiceRefiner.defaultInstructions(style: .clean)
        )
        XCTAssertEqual(
            TranslatorPromptBuilder.systemPrompt(context: nil, custom: nil),
            TranslatorPromptBuilder.defaultInstructions()
        )
    }

    /// 未自定义时的完整 prompt 与改造前逐字一致（防重构改味）
    func testDefaultPromptUnchangedShape() {
        let prompt = PinyinPromptBuilder.systemPrompt(context: "上文", userDictEntries: ["词条"])
        XCTAssertTrue(prompt.hasPrefix("你是拼音输入法的整句转换引擎"))
        XCTAssertTrue(prompt.contains("光标前已有的文本（输出需与它衔接）：上文"))
        XCTAssertTrue(prompt.contains("用户常用词（优先采用这些写法）：词条"))
    }
}
