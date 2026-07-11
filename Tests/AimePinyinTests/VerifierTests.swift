import XCTest
@testable import AimePinyin

final class VerifierTests: XCTestCase {
    private func segments(_ raw: String, fuzzy: Set<String> = FuzzyRule.defaultEnabled) -> [PinyinSegment] {
        PinyinSegmenter.segment(raw, enabledFuzzyRuleIDs: fuzzy)
    }

    func testExactMatch() {
        XCTAssertEqual(PinyinVerifier.verify(candidate: "你好世界", segments: segments("nihaoshijie")), .pass)
    }

    func testFuzzyReading() {
        // lan 的 n/l 模糊 → 男(nan) 命中备选
        XCTAssertEqual(PinyinVerifier.verify(candidate: "这是一个男人", segments: segments("zheshiyigelanren")), .pass)
        // 格兰人 音也全对（ge lan ren）——验音层放行，语义垃圾由词库层解决
        XCTAssertEqual(PinyinVerifier.verify(candidate: "这是一个格兰人", segments: segments("zheshiyigelanren")), .reject) // 字数 7 vs 音节 6
    }

    func testPhoneticMismatchRejected() {
        // 船员 chuan yuan 对不上 lan ren
        XCTAssertEqual(PinyinVerifier.verify(candidate: "这是一个船员", segments: segments("zheshiyigelanren")), .reject)
    }

    func testSingleMismatchDemoted() {
        // 一字之差降权（好→坏 hao vs huai）
        XCTAssertEqual(PinyinVerifier.verify(candidate: "你坏世界", segments: segments("nihaoshijie")), .demote)
    }

    func testPolyphone() {
        // 银行：行 默认读 xing，补充表给 hang
        XCTAssertEqual(PinyinVerifier.verify(candidate: "银行", segments: segments("yinhang")), .pass)
        XCTAssertEqual(PinyinVerifier.verify(candidate: "音乐", segments: segments("yinyue")), .pass)
    }

    func testMixedLiteralSkipped() {
        XCTAssertEqual(PinyinVerifier.verify(candidate: "这是一个API接口", segments: segments("zheshiyigeAPIjiekou")), .pass)
    }

    func testCharCountMismatchRejected() {
        XCTAssertEqual(PinyinVerifier.verify(candidate: "你好世界啊", segments: segments("nihaoshijie")), .reject)
    }
}
