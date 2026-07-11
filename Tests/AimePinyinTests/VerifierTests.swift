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

final class M4Tests: XCTestCase {
    func testDerivePinyin() {
        // 语音段退格转拼音（跨模态纠错 v1 的基础）
        XCTAssertEqual(PinyinVerifier.derivePinyin(from: "你好世界"), "nihaoshijie")
        XCTAssertNil(PinyinVerifier.derivePinyin(from: "有API的句子"))
        XCTAssertNil(PinyinVerifier.derivePinyin(from: ""))
        // 反推的拼音再走切分 → 能还原音节
        let pinyin = PinyinVerifier.derivePinyin(from: "今天开会")!
        let segments = PinyinSegmenter.segment(pinyin)
        guard case .pinyin(let syllables) = segments[0].kind else { return XCTFail() }
        XCTAssertEqual(syllables.map(\.text), ["jin", "tian", "kai", "hui"])
    }

    func testUserDictDecay() {
        let old = UserDictionary.Entry(text: "旧词", count: 10, lastUsed: Date(timeIntervalSinceNow: -90 * 86400), source: "pinyin")
        let recent = UserDictionary.Entry(text: "新词", count: 3, lastUsed: Date(), source: "voice")
        // 90 天前的 10 次 < 现在的 3 次
        XCTAssertLessThan(UserDictionary.decayedScore(old), UserDictionary.decayedScore(recent))
    }

    func testPrivacyBlockMatching() {
        SharedConfig.mirrorPrivacyFromApp(blockedApps: ["com.apple.keychainaccess"], pureLocalMode: false)
        XCTAssertTrue(SharedConfig.isBlocked(bundleID: "com.apple.keychainaccess"))
        XCTAssertFalse(SharedConfig.isBlocked(bundleID: "com.apple.Safari"))
        XCTAssertFalse(SharedConfig.isBlocked(bundleID: nil))
        SharedConfig.mirrorPrivacyFromApp(blockedApps: [], pureLocalMode: false)
    }

    func testVoiceDisambiguationGate() {
        // 消歧分流的门控逻辑：语音说"下周一要上线" vs 拼音 xiazhouyiyaoshangxian
        let segments = PinyinSegmenter.segment("xiazhouyiyaoshangxian")
        XCTAssertEqual(PinyinVerifier.verify(candidate: "下周一要上线", segments: segments), .pass)
        // 语音说的是不相关内容 → reject → 走追加分支
        XCTAssertEqual(PinyinVerifier.verify(candidate: "帮我订张机票", segments: segments), .reject)
    }
}
