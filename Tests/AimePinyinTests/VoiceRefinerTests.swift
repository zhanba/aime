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
}
