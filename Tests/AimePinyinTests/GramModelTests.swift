import XCTest
@testable import AimePinyin

final class GramModelTests: XCTestCase {
    var gramURL: URL!

    /// 微型语法模型：编译→mmap→查询语义（值单位 log(频)×10000）
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aime-gram-test-\(UUID().uuidString)")
        gramURL = dir.appendingPathComponent("gram.bin")
        try GramModel.compile(entries: [
            ("一只小", 150_000),      // "一只" 接 "小×" 的搭配
            ("一只小狗", 160_000),
            ("养了一只", 155_000),
            ("一直小", 90_000),       // 错误搭配给低值
            ("世界$", 140_000),       // 句尾条目
            ("#今天", 130_000),       // 句首条目
        ], to: gramURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: gramURL.deletingLastPathComponent())
    }

    func testLoadAndBasicQuery() throws {
        let gram = try XCTUnwrap(GramModel(url: gramURL))
        XCTAssertEqual(gram.entryCount, 6)
        // "一只" 之后接 "小狗"：命中 一只小 / 一只小狗，取高者 16.0 + collocation
        let hit = gram.score(context: "养了一只", word: "小狗", isRear: false)
        XCTAssertEqual(hit, 16.0 + gram.penalties.collocation, accuracy: 0.001)
        // 无任何搭配 → non-collocation
        let miss = gram.score(context: "苹果", word: "小狗", isRear: false)
        XCTAssertEqual(miss, gram.penalties.nonCollocation, accuracy: 0.001)
    }

    func testCollocationBeatsWrongHomophone() throws {
        let gram = try XCTUnwrap(GramModel(url: gramURL))
        let right = gram.score(context: "养了一只", word: "小狗", isRear: false)
        let wrong = gram.score(context: "养了一直", word: "小狗", isRear: false)
        XCTAssertGreaterThan(right, wrong, "正确量词的搭配得分应高于同音错字")
    }

    func testRearEntry() throws {
        let gram = try XCTUnwrap(GramModel(url: gramURL))
        let rear = gram.score(context: "你好", word: "世界", isRear: true)
        // 无 "你好世界" 搭配，但有 "世界$"：14.0 + rear
        XCTAssertEqual(rear, 14.0 + gram.penalties.rear, accuracy: 0.001)
        let notRear = gram.score(context: "你好", word: "世界", isRear: false)
        XCTAssertEqual(notRear, gram.penalties.nonCollocation, accuracy: 0.001)
    }

    func testSentenceStartMarker() throws {
        let gram = try XCTUnwrap(GramModel(url: gramURL))
        // composeScored 的初始尾部是 "#"：句首词可命中 "#今天"
        let start = gram.score(context: "#", word: "今天", isRear: false)
        XCTAssertEqual(start, 13.0 + gram.penalties.collocation, accuracy: 0.001)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(GramModel(url: gramURL.deletingLastPathComponent().appendingPathComponent("absent.bin")))
    }

    /// 端到端：同音词"一直/一只"——unigram 偏高频"一直"，搭配知识翻成量词"一只"
    func testGramFlipsComposeChoice() throws {
        let dir = gramURL.deletingLastPathComponent()
        let dict = dir.appendingPathComponent("mini.dict.yaml")
        try """
        ...
        一直\tyi zhi\t500000
        一只\tyi zhi\t20000
        小狗\txiao gou\t30000
        一\tyi\t900000
        只\tzhi\t100000
        直\tzhi\t80000
        小\txiao\t200000
        狗\tgou\t60000
        """.write(to: dict, atomically: true, encoding: .utf8)
        let lexiconURL = dir.appendingPathComponent("lexicon.bin")
        try Lexicon.compile(rimeDicts: [dict], to: lexiconURL)

        let lexicon = try XCTUnwrap(Lexicon(url: lexiconURL))
        let segments = PinyinSegmenter.segment("yizhixiaogou")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }

        // 无语法模型：高频"一直"胜
        let plain = SentenceComposer(lexicon: lexicon)
        XCTAssertEqual(plain.compose(syllables: syllables), "一直小狗")
        // 有语法模型（fixture 含 一只小/一只小狗 搭配）：量词翻盘
        let gram = try XCTUnwrap(GramModel(url: gramURL))
        let boosted = SentenceComposer(lexicon: lexicon, gram: gram, gramWeight: 1.0)
        XCTAssertEqual(boosted.compose(syllables: syllables), "一只小狗")
    }
}
