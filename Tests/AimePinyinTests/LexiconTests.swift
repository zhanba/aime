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
        坏音节	bad syl	1
        """.write(to: dict, atomically: true, encoding: .utf8)
        lexiconURL = dir.appendingPathComponent("lexicon.bin")
        let (kept, dropped) = try Lexicon.compile(rimeDicts: [dict], to: lexiconURL)
        XCTAssertEqual(kept, 18)
        XCTAssertEqual(dropped, 1) // "bad syl" 非法音节被过滤
    }

    func testExactAndPrefixQuery() throws {
        let lexicon = try XCTUnwrap(Lexicon(url: lexiconURL))
        XCTAssertEqual(lexicon.entryCount, 18)
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
        // 词消耗按键长度映射
        XCTAssertEqual(PinyinEngine.consumedKeyLength(raw: "jintianxiawukaihui", segments: result.segments, syllableCount: 2), 7)
    }

    func testEngineWithoutLexiconDegrades() {
        let engine = PinyinEngine(lexiconURL: URL(fileURLWithPath: "/nonexistent"))
        let result = engine.analyze("nihao")
        XCTAssertNil(result.localSentence)
        XCTAssertTrue(result.wordCandidates.isEmpty)
        XCTAssertFalse(result.segments.isEmpty)
    }
}
