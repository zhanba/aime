import XCTest
@testable import AimePinyin

final class TranslatorTests: XCTestCase {
    func testParseSingleLine() {
        XCTAssertEqual(
            Translator.parse("Hi, how have you been?"),
            TranslationResult(best: "Hi, how have you been?")
        )
    }

    func testParseWithAlternative() {
        XCTAssertEqual(
            Translator.parse("Hi, how have you been?\nHello, how's it going lately?"),
            TranslationResult(best: "Hi, how have you been?", alternative: "Hello, how's it going lately?")
        )
    }

    func testParseStripsWrappingQuotesAndBlankLines() {
        XCTAssertEqual(
            Translator.parse("\"Sounds good to me\"\n\n“听起来不错”"),
            TranslationResult(best: "Sounds good to me", alternative: "听起来不错")
        )
    }

    func testParseDuplicateAlternativeDropped() {
        XCTAssertEqual(
            Translator.parse("Same line\nSame line"),
            TranslationResult(best: "Same line", alternative: nil)
        )
    }

    func testParseEmpty() {
        XCTAssertNil(Translator.parse("   \n  "))
    }
}
