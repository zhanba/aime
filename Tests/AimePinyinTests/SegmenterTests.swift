import XCTest
@testable import AimePinyin

final class SegmenterTests: XCTestCase {
    private func syllableTexts(_ segments: [PinyinSegment]) -> [String] {
        segments.flatMap { segment -> [String] in
            if case .pinyin(let syllables) = segment.kind {
                return syllables.map(\.text)
            }
            return []
        }
    }

    private func flatDescription(_ segments: [PinyinSegment]) -> [String] {
        segments.map { segment in
            switch segment.kind {
            case .pinyin(let syllables): return "P:" + syllables.map(\.text).joined(separator: "-")
            case .literal(let text): return "L:" + text
            }
        }
    }

    // MARK: 基础切分

    func testBasicSegmentation() {
        let segments = PinyinSegmenter.segment("nihaoshijie")
        XCTAssertEqual(syllableTexts(segments), ["ni", "hao", "shi", "jie"])
    }

    func testAmbiguousXian() {
        // xian 整体是合法音节，DP 偏好更少音节
        XCTAssertEqual(syllableTexts(PinyinSegmenter.segment("xian")), ["xian"])
        // 显式分隔可拆开
        XCTAssertEqual(syllableTexts(PinyinSegmenter.segment("xi'an")), ["xi", "an"])
    }

    func testLongSentence() {
        let segments = PinyinSegmenter.segment("jintianxiawusandianwomenkaihui")
        XCTAssertEqual(
            syllableTexts(segments),
            ["jin", "tian", "xia", "wu", "san", "dian", "wo", "men", "kai", "hui"]
        )
    }

    // MARK: 验收用例：中英混输透传

    func testMixedEnglishPassthrough() {
        let segments = PinyinSegmenter.segment("zheshiyigeAPIjiekou")
        XCTAssertEqual(
            flatDescription(segments),
            ["P:zhe-shi-yi-ge", "L:API", "P:jie-kou"]
        )
    }

    func testDigitsPassthrough() {
        let segments = PinyinSegmenter.segment("xiawu3dian")
        XCTAssertEqual(flatDescription(segments), ["P:xia-wu", "L:3", "P:dian"])
    }

    func testUnparseableLowercaseFallsBackToLiteral() {
        // 无法解析成拼音的小写串退化为 literal，不崩、不吞字符
        let segments = PinyinSegmenter.segment("vvv")
        let rawJoined = segments.map(\.raw).joined()
        XCTAssertEqual(rawJoined, "vvv")
    }

    // MARK: 验收用例：键盘错误修复

    func testKeyboardRepairNihso() {
        // nihsoshijie：hao 被敲成 hso（a→s 临近键误触）
        let segments = PinyinSegmenter.segment("nihsoshijie")
        XCTAssertEqual(syllableTexts(segments), ["ni", "hao", "shi", "jie"])
        let repaired = segments.flatMap { segment -> [Syllable] in
            if case .pinyin(let syllables) = segment.kind { return syllables.filter(\.repaired) }
            return []
        }
        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(repaired.first?.typed, "hso")
        XCTAssertEqual(repaired.first?.text, "hao")
    }

    func testTranspositionRepair() {
        // womne：men 敲成 mne（相邻换位）
        let segments = PinyinSegmenter.segment("womne")
        XCTAssertEqual(syllableTexts(segments), ["wo", "men"])
    }

    // MARK: 模糊音

    func testFuzzyVariants() {
        XCTAssertEqual(FuzzyExpander.variants(of: "zi", enabledRuleIDs: ["z/zh"]), ["zhi"])
        XCTAssertEqual(FuzzyExpander.variants(of: "xin", enabledRuleIDs: ["in/ing"]), ["xing"])
        XCTAssertTrue(FuzzyExpander.variants(of: "lan", enabledRuleIDs: ["n/l"]).contains("nan"))
        // 未启用的规则不生效
        XCTAssertTrue(FuzzyExpander.variants(of: "zi", enabledRuleIDs: []).isEmpty)
    }

    func testFuzzyAttachedToSegmentation() {
        let segments = PinyinSegmenter.segment("zisebuhao", enabledFuzzyRuleIDs: ["z/zh", "s/sh"])
        guard case .pinyin(let syllables) = segments[0].kind else {
            return XCTFail("应为拼音段")
        }
        XCTAssertEqual(syllables[0].text, "zi")
        XCTAssertEqual(syllables[0].fuzzyAlternates, ["zhi"])
        XCTAssertEqual(syllables[1].text, "se")
        XCTAssertEqual(syllables[1].fuzzyAlternates, ["she"])
    }

    // MARK: 音节表健全性

    func testSyllableTableSanity() {
        for syllable in ["zhuang", "xiong", "er", "nv", "lve", "jue", "dia", "a", "o"] {
            XCTAssertTrue(PinyinTable.isValid(syllable), "\(syllable) 应为合法音节")
        }
        for junk in ["zh", "x", "iang", "abc", "vvv", "hso"] {
            XCTAssertFalse(PinyinTable.isValid(junk), "\(junk) 不应为合法音节")
        }
    }

    // MARK: 拼写变换：漏敲/多敲/句尾 partial

    func testDeletionRepair() {
        // zhngguo：zhong 漏敲 o
        let segments = PinyinSegmenter.segment("zhngguo")
        guard case .pinyin(let syllables) = segments[0].kind, syllables.count == 2 else {
            return XCTFail("应切成两个音节: \(segments)")
        }
        XCTAssertEqual(syllables[0].source, .deletion)
        XCTAssertTrue(["zhang", "zheng", "zhong"].contains(syllables[0].text))
        // 其余同代价修复进备选
        let all = [syllables[0].text] + syllables[0].fuzzyAlternates
        XCTAssertTrue(all.contains("zhong"), "\(all)")
        XCTAssertEqual(syllables[1].text, "guo")
    }

    func testInsertionRepair() {
        // zhoongguo：zhong 多敲一个 o
        let segments = PinyinSegmenter.segment("zhoongguo")
        XCTAssertEqual(syllableTexts(segments), ["zhong", "guo"])
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        XCTAssertEqual(syllables[0].source, .insertion)
    }

    func testTrailingPartialSyllable() {
        // nihaosh：句尾 sh 未打完，不再是 literal
        let segments = PinyinSegmenter.segment("nihaosh")
        guard case .pinyin(let syllables) = segments[0].kind, syllables.count == 3 else {
            return XCTFail("应为三音节段: \(segments)")
        }
        XCTAssertEqual(syllables[2].source, .partial)
        XCTAssertEqual(syllables[2].typed, "sh")
        XCTAssertFalse(syllables[2].completions.isEmpty)
        XCTAssertTrue(syllables[2].completions.allSatisfy { $0.hasPrefix("sh") })
    }

    func testPartialOnlyAtEnd() {
        // 中间的破碎串不按 partial 处理（xq 无解 → 修复或 literal，但不能吞掉后文）
        let segments = PinyinSegmenter.segment("nihao")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        XCTAssertTrue(syllables.allSatisfy { $0.source == .exact })
    }

    // MARK: prompt 构造

    func testPromptDescribe() {
        let segments = PinyinSegmenter.segment("nihsoAPI", enabledFuzzyRuleIDs: [])
        let description = PinyinPromptBuilder.describe(segments: segments)
        XCTAssertTrue(description.contains("疑似手误"), description)
        XCTAssertTrue(description.contains("[原样保留:API]"), description)
    }
}

final class BoundaryAmbiguityTests: XCTestCase {
    func testBoundaryVariantsGenerated() {
        // fangan：主切分 fan|gan，变体应含 fang|an
        let segments = PinyinSegmenter.segment("fangan")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        let variants = PinyinSegmenter.boundaryVariants(of: syllables)
        XCTAssertTrue(variants.contains { $0.map(\.text) == ["fang", "an"] }, "\(variants.map { $0.map(\.text) })")
    }

    func testReverseDirection() {
        // wanan：主切分 wa|nan（或 wan|an），另一方向也要能生成
        let segments = PinyinSegmenter.segment("wanan")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        let variants = PinyinSegmenter.boundaryVariants(of: syllables)
        let all = [syllables.map(\.text)] + variants.map { $0.map(\.text) }
        XCTAssertTrue(all.contains(["wan", "an"]), "\(all)")
    }

    func testVerifierAcceptsBothReadings() {
        let segments = PinyinSegmenter.segment("fangan")
        XCTAssertEqual(PinyinVerifier.verify(candidate: "方案", segments: segments), .pass)
        XCTAssertEqual(PinyinVerifier.verify(candidate: "反感", segments: segments), .pass)
        // 房间：fang 命中变体首音节、jian 不匹配 → 1 字容差 = demote（多音字容差的正确行为）
        XCTAssertEqual(PinyinVerifier.verify(candidate: "房间", segments: segments), .demote)
        // 两字都对不上 → reject
        XCTAssertEqual(PinyinVerifier.verify(candidate: "电脑", segments: segments), .reject)
    }
}
