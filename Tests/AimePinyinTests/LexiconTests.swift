import XCTest
@testable import AimePinyin

final class LexiconTests: XCTestCase {
    /// 用小词库 fixture 编译→加载→查询→造句 全链路
    var lexiconURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aime-lexicon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dict = dir.appendingPathComponent("mini.dict.yaml")
        try """
        # mini fixture
        ...
        你	ni	80000
        好	hao	60000
        是	shi	900000
        届	jie	3000
        你好	ni hao	50000
        世界	shi jie	90000
        今天	jin tian	100000
        下午	xia wu	60000
        开会	kai hui	30000
        中国	zhong guo	200000
        金	jin	40000
        天	tian	50000
        下	xia	70000
        午	wu	9000
        开	kai	50000
        会	hui	80000
        中	zhong	90000
        国	guo	60000
        方案	fang an	50000
        反感	fan gan	9000
        方	fang	40000
        安	an	30000
        反	fan	35000
        感	gan	25000
        删除	shan chu	40000
        按钮	an niu	30000
        山川	shan chuan	8000
        牛	niu	30000
        坏音节	bad syl	1
        """.write(to: dict, atomically: true, encoding: .utf8)
        lexiconURL = dir.appendingPathComponent("lexicon.bin")
        let (kept, dropped) = try Lexicon.compile(rimeDicts: [dict], to: lexiconURL)
        XCTAssertEqual(kept, 28)
        XCTAssertEqual(dropped, 1) // "bad syl" 非法音节被过滤
    }

    func testExactAndPrefixQuery() throws {
        let lexicon = try XCTUnwrap(Lexicon(url: lexiconURL))
        XCTAssertEqual(lexicon.entryCount, 28)
        XCTAssertEqual(lexicon.exactMatches(key: "shi jie").map(\.word), ["世界"])
        XCTAssertTrue(lexicon.hasPrefix(key: "jin"))       // 金 / 今天
        XCTAssertTrue(lexicon.hasPrefix(key: "jin tian"))
        XCTAssertFalse(lexicon.hasPrefix(key: "jin tia"))  // 非音节边界
        XCTAssertFalse(lexicon.hasPrefix(key: "zzz"))
    }

    func testViterbiPrefersWords() throws {
        let lexicon = try XCTUnwrap(Lexicon(url: lexiconURL))
        let composer = SentenceComposer(lexicon: lexicon)
        let segments = PinyinSegmenter.segment("nihaoshijie")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        // 尽管"是"权重远超"世界"，λ+单字抑制应让整词获胜
        XCTAssertEqual(composer.compose(syllables: syllables), "你好世界")
    }

    func testViterbiWithDeletionRepair() throws {
        let lexicon = try XCTUnwrap(Lexicon(url: lexiconURL))
        let composer = SentenceComposer(lexicon: lexicon)
        let segments = PinyinSegmenter.segment("zhngguo")
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        // zhng 的修复假设含 zhong；词库中 中国 权重高 → 本地层即可修对
        XCTAssertEqual(composer.compose(syllables: syllables), "中国")
    }

    func testEngineEndToEnd() throws {
        let engine = PinyinEngine(lexiconURL: lexiconURL)
        let result = engine.analyze("jintianxiawukaihui")
        XCTAssertEqual(result.localSentence, "今天下午开会")
        XCTAssertEqual(result.wordCandidates.first?.word, "今天")
        // 词消耗按键长度映射（今天 = jin+tian = 7 键）
        let first = try XCTUnwrap(result.wordCandidates.first)
        XCTAssertEqual(first.typedLength, 7)
        XCTAssertEqual(PinyinEngine.consumedKeyLength(raw: "jintianxiawukaihui", typedLength: first.typedLength), 7)
        // 分隔符计入消耗（jin'tian → 8 键）
        XCTAssertEqual(PinyinEngine.consumedKeyLength(raw: "jin'tianxiawu", typedLength: 7), 8)
    }

    func testSyllableSplitAmbiguityReachable() throws {
        // shanchuanniu：主切分 shan|chuan|niu（音节数更少必胜），
        // 删除按钮需要 chuan 拆成 chu|an 的变体路径
        let engine = PinyinEngine(lexiconURL: lexiconURL)
        let result = engine.analyze("shanchuanniu")
        let words = result.wordCandidates.map(\.word)
        XCTAssertTrue(words.contains("删除"), "\(words)")
        XCTAssertTrue(result.boundaryAlternatives.contains("shan chu an niu"), "\(result.boundaryAlternatives)")
        // 部分上屏「删除」只消耗 shanchu 7 键，剩 anniu
        let shanchu = try XCTUnwrap(result.wordCandidates.first { $0.word == "删除" })
        XCTAssertEqual(shanchu.typedLength, 7)
        XCTAssertEqual(result.localSentence, "删除按钮", "词库若含 按钮 应整句修对")
    }

    func testBoundaryAmbiguityReachable() throws {
        // fangan：词候选与本地整句要能同时触达两种切法（方案权重更高应胜出）
        let engine = PinyinEngine(lexiconURL: lexiconURL)
        let result = engine.analyze("fangan")
        let words = result.wordCandidates.map(\.word)
        XCTAssertTrue(words.contains("方案"), "\(words)")
        XCTAssertTrue(words.contains("反感"), "\(words)")
        XCTAssertEqual(result.localSentence, "方案")
        XCTAssertTrue(result.boundaryAlternatives.contains("fang an"))
    }

    func testEngineWithoutLexiconDegrades() {
        let engine = PinyinEngine(lexiconURL: URL(fileURLWithPath: "/nonexistent"))
        let result = engine.analyze("nihao")
        XCTAssertNil(result.localSentence)
        XCTAssertTrue(result.wordCandidates.isEmpty)
        XCTAssertFalse(result.segments.isEmpty)
    }
}
